package CalculoSCMP::Controller::Calculos;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# =============================================================================
# CalculoSCMP — Controlador de cálculos de alcalinidad y pH
#
# Basado en "The Alkalinity Calculator" de Stewart A. Rounds (USGS)
# Copyright (c) 2003-2012, Stewart A. Rounds — GPLv2
# Adaptado para API REST con Mojolicious.
#
# Endpoint: POST /calcular
#
# Entrada JSON:
# {
#   "volumen"       : número   — volumen de la muestra en mL (requerido)
#   "concentracion_acido": número — concentración del ácido titulante en eq/L (requerido)
#   "titulacion"    : [         — tabla de titulación, orden pH desc (requerido, mín 2 puntos)
#     { "ph": número, "volumen_acido": número },   ← primer punto: volumen_acido = 0
#     ...
#   ],
#   "temperatura"   : número   — °C (default: 20.0)
#   "conductancia"  : número   — µS/cm (default: 50.0)
#   "factor_correccion": número — factor de corrección del ácido, 0.8–1.2 (default: 1.0)
#   "metodos"       : {         — métodos a ejecutar (default: todos true)
#     "inflexion"   : bool,
#     "endpoint_fijo": bool,
#     "ctc"         : bool,
#     "gran"        : bool
#   },
#   "endpoint_carbonato"  : número  — pH endpoint fijo carbonato (default: 8.3)
#   "endpoint_bicarbonato": número  — pH endpoint fijo bicarbonato (default: 4.5)
#
#   -- PENDIENTE --
#   "calcio": número  — mg/L, recibido pero sin uso definido aún
# }
#
# Salida JSON:
# {
#   "constantes": { "log10_Kw", "log10_K1", "log10_K2", "fuerza_ionica" },
#   "especiacion_basica": { "bicarbonato_mg_l", "carbonato_mg_l",
#                           "hidroxido_mg_l", "alcalinidad_meq_l" },
#   "inflexion":    { ... } | null,
#   "endpoint_fijo":{ ... } | null,
#   "ctc_1":        { ... } | null,
#   "ctc_2":        { ... } | null,
#   "gran":         { ... } | null,
#   "advertencias": [ "texto", ... ]
# }
# =============================================================================

use POSIX qw();

# Pesos moleculares ×1000 — mismos valores que ac_calcs.pl
use constant CARB_MEQ   => 60009.2;
use constant BICARB_MEQ => 61017.1;
use constant ALK_MEQ    => 50043.6;
use constant OH_MEQ     => 17007.3;

# Variables de estado del optimizador (equivalentes a globals de ac_calcs.pl)
my (@_pcom, @_xicom);
my (%_data, $_highest_ph, $_lowest_ph, %_slope);
my ($_Kw, $_K1, $_K2, $_gamma_H);
my ($_volume, $_acid_conc, $_cor_factor);
my ($_do_carb, $_do_bicarb);
my ($_carb_ph_upper, $_carb_ph_lower, $_bicarb_ph_upper, $_bicarb_ph_lower);

# ---------------------------------------------------------------------------
# POST /calcular
# ---------------------------------------------------------------------------
sub calcular ($self) {
    my $p = $self->req->json;

    # Timeout de seguridad: 30 segundos máximo para todo el cálculo
    local $SIG{ALRM} = sub { die "timeout
" };
    alarm(30);

    # --- Validación básica del body ---
    unless (defined $p && ref $p eq 'HASH') {
        return $self->render(json => { error => 'Se requiere un cuerpo JSON válido' }, status => 400);
    }

    # --- Campos requeridos ---
    for my $campo (qw(volumen concentracion_acido titulacion)) {
        unless (defined $p->{$campo}) {
            return $self->render(json => { error => "El campo '$campo' es requerido" }, status => 400);
        }
    }

    my $volume   = $p->{volumen} + 0;
    my $acid_conc = $p->{concentracion_acido} + 0;

    if ($volume <= 0) {
        return $self->render(json => { error => 'El volumen de muestra debe ser mayor que 0' }, status => 400);
    }
    if ($acid_conc <= 0) {
        return $self->render(json => { error => 'La concentración del ácido debe ser mayor que 0' }, status => 400);
    }

    # --- Parámetros opcionales ---
    my $temp       = $p->{temperatura}       // 20.0;
    my $spcond     = $p->{conductancia}      // 50.0;
    my $cor_factor = $p->{factor_correccion} // 1.0;

    if ($cor_factor < 0.8 || $cor_factor > 1.2) {
        return $self->render(json => { error => 'El factor de corrección debe estar entre 0.8 y 1.2' }, status => 400);
    }

    # Métodos a ejecutar (todos por defecto)
    my $met = $p->{metodos} // {};
    my $do_inflexion = exists $met->{inflexion}      ? $met->{inflexion}      : 1;
    my $do_fixed     = exists $met->{endpoint_fijo}  ? $met->{endpoint_fijo}  : 1;
    my $do_ctc       = exists $met->{ctc}            ? $met->{ctc}            : 1;
    my $do_gran      = exists $met->{gran}           ? $met->{gran}           : 1;

    # Endpoints fijos (con defaults estándar)
    my $carb_endpt2  = $p->{endpoint_carbonato}   // 8.3;
    my $bicarb_endpt2 = $p->{endpoint_bicarbonato} // 4.5;

    # TODO: calcio se recibe pero sin uso definido aún
    my $calcio = $p->{calcio};

    # --- Parsear y validar la tabla de titulación ---
    my $tit_raw = $p->{titulacion};
    unless (ref $tit_raw eq 'ARRAY' && scalar @$tit_raw >= 2) {
        return $self->render(json => { error => 'La titulacion debe ser un array con al menos 2 puntos' }, status => 400);
    }

    # Construir %data = ph => volumen_acido (igual que en ac_calcs.pl)
    my %data;
    for my $punto (@$tit_raw) {
        unless (defined $punto->{ph} && defined $punto->{volumen_acido}) {
            return $self->render(json => { error => 'Cada punto de titulación requiere "ph" y "volumen_acido"' }, status => 400);
        }
        my $ph  = sprintf("%.2f", $punto->{ph} + 0);
        $data{$ph} = $punto->{volumen_acido} + 0;
    }

    # Calcular pendientes y detectar highest/lowest pH (mismo código que ac_calcs.pl)
    my (%slope, $highest_ph, $lowest_ph, $last_ph, $last_vol);
    my @advertencias;
    my $warn_vol = 0;

    foreach my $ph (reverse sort { $a <=> $b } keys %data) {
        if (!defined $highest_ph) {
            $highest_ph = $ph;
            $last_ph    = $ph;
            $last_vol   = $data{$ph};
        } elsif (abs($data{$ph} - $last_vol) != 0.0) {
            $slope{$ph} = sprintf("%.6f", ($last_ph - $ph) / ($data{$ph} - $last_vol));
            $warn_vol   = 1 if ($data{$ph} < $last_vol);
            $last_ph    = $ph;
            $last_vol   = $data{$ph};
            $lowest_ph  = $ph;
        } else {
            delete $data{$ph};
        }
    }

    push @advertencias, 'Uno o más puntos tienen volumen de ácido inesperado (debería aumentar con cada punto).' if $warn_vol;

    unless (defined $highest_ph && defined $lowest_ph) {
        return $self->render(json => { error => 'La tabla de titulación no tiene suficientes puntos válidos' }, status => 400);
    }

    if ($data{$highest_ph} != 0.0) {
        return $self->render(json => { error => 'El primer punto de la titulación debe tener volumen_acido = 0 (pH inicial de la muestra)' }, status => 400);
    }

    # --- Constantes de equilibrio ---
    my ($Kw, $K1, $K2, $gamma_H, $I) = _get_constants($temp, $spcond);
    my $log10Kw = log($Kw) / log(10.0);
    my $log10K1 = log($K1) / log(10.0);
    my $log10K2 = log($K2) / log(10.0);
    my $ph_split = -1.0 * $log10K1;

    # Factores F (mismo cálculo que ac_calcs.pl, counts_per_mL=1 porque usamos mL)
    my $F1 = CARB_MEQ   * $acid_conc * $cor_factor;
    my $F2 = BICARB_MEQ * $acid_conc * $cor_factor;
    my $F3 = ALK_MEQ    * $acid_conc * $cor_factor;

    # Guardar estado global para el optimizador
    %_data       = %data;
    $_highest_ph = $highest_ph;
    $_lowest_ph  = $lowest_ph;
    %_slope      = %slope;
    $_Kw         = $Kw;  $_K1 = $K1;  $_K2 = $K2;  $_gamma_H = $gamma_H;
    $_volume     = $volume;
    $_acid_conc  = $acid_conc;
    $_cor_factor = $cor_factor;

    # Verificar que la titulación llega suficientemente abajo
    if ($lowest_ph >= $ph_split && ($do_inflexion || $do_fixed)) {
        push @advertencias, sprintf(
            'El pH más bajo (%.2f) no es suficientemente bajo para el método de inflexión o endpoint fijo. Se requiere pH < %.2f.',
            $lowest_ph, $ph_split
        );
        $do_inflexion = 0;
        $do_fixed     = 0;
    }

    # =========================================================================
    # MÉTODO 1 — Inflexión (siempre se corre internamente, base para otros)
    # =========================================================================
    my ($carb_endpt1_vol, $carb_endpt1, $Method1carb_fail) = (0, undef, 0);
    my ($bicarb_endpt1_vol, $bicarb_endpt1, $alk1);

    # Carbonato (solo si pH inicial > 8.3)
    if ($highest_ph > 8.3) {
        my ($max_slope, $n, $found_tie) = (0, 0, 0);
        my ($tie_vol);
        $last_vol = $data{$highest_ph};
        my $last_ph_l = $highest_ph;

        foreach my $ph (reverse sort { $a <=> $b } keys %data) {
            last if ($ph <= $ph_split);
            if ($ph < $highest_ph && $ph < abs($log10K2)) {
                if ($slope{$ph} > $max_slope) {
                    $max_slope = $slope{$ph};
                    $carb_endpt1_vol = ($data{$ph} + $last_vol) / 2.0;
                    $found_tie = 0;
                } elsif ($slope{$ph} == $max_slope) {
                    $tie_vol = ($data{$ph} + $last_vol) / 2.0;
                    $found_tie = 1;
                }
                $n++;
            }
            $last_vol = $data{$ph};
            $last_ph_l = $ph;
        }

        if ($n > 0) {
            $carb_endpt1_vol = 0.5 * ($carb_endpt1_vol + $tie_vol) if $found_tie;
            # Interpolar pH del endpoint
            $carb_endpt1 = $highest_ph;
            $last_vol = $data{$highest_ph};
            my $last_p = $highest_ph;
            foreach my $ph (reverse sort { $a <=> $b } keys %data) {
                if ($data{$ph} >= $carb_endpt1_vol && $last_vol < $carb_endpt1_vol) {
                    $carb_endpt1 = $last_p + ($ph - $last_p) * ($carb_endpt1_vol - $last_vol) / ($data{$ph} - $last_vol);
                    last;
                }
                $last_vol = $data{$ph};
                $last_p   = $ph;
            }
        } else {
            $Method1carb_fail = 1;
            $carb_endpt1_vol  = 0;
        }
    }

    # Bicarbonato
    {
        my ($max_slope, $n, $found_tie) = (0, 0, 0);
        my ($tie_vol);
        $last_vol = $data{$highest_ph};

        foreach my $ph (reverse sort { $a <=> $b } keys %data) {
            if ($ph < $highest_ph && $ph <= $ph_split) {
                if ($slope{$ph} > $max_slope) {
                    $max_slope = $slope{$ph};
                    $bicarb_endpt1_vol = ($data{$ph} + $last_vol) / 2.0;
                    $found_tie = 0;
                } elsif ($slope{$ph} == $max_slope) {
                    $tie_vol = ($data{$ph} + $last_vol) / 2.0;
                    $found_tie = 1;
                }
                $n++;
            }
            $last_vol = $data{$ph};
        }

        if ($n > 0) {
            $bicarb_endpt1_vol = 0.5 * ($bicarb_endpt1_vol + $tie_vol) if $found_tie;
            $bicarb_endpt1 = $highest_ph;
            $last_vol = $data{$highest_ph};
            my $last_p = $highest_ph;
            foreach my $ph (reverse sort { $a <=> $b } keys %data) {
                if ($data{$ph} >= $bicarb_endpt1_vol && $last_vol < $bicarb_endpt1_vol) {
                    $bicarb_endpt1 = $last_p + ($ph - $last_p) * ($bicarb_endpt1_vol - $last_vol) / ($data{$ph} - $last_vol);
                    last;
                }
                $last_vol = $data{$ph};
                $last_p   = $ph;
            }
            $alk1 = $bicarb_endpt1_vol * $F3 / $volume;
        } else {
            # Sin datos suficientes — usar el último punto como fallback
            $bicarb_endpt1_vol = $data{$lowest_ph};
            $alk1 = $bicarb_endpt1_vol * $F3 / $volume;
            $do_inflexion = 0;
            $do_fixed     = 0;
        }
    }

    my ($bicarb1_mg, $carb1_mg, $oh1_mg) = _get_speciation($alk1 / ALK_MEQ, $highest_ph, $Kw, $K1, $K2, $gamma_H);
    my $check1 = _get_criteria($alk1 / ALK_MEQ, $bicarb_endpt1_vol, $carb_endpt1_vol, 0,
                               $highest_ph, $volume, $acid_conc, $cor_factor, $F1, $F3,
                               $Kw, $K1, $K2, $gamma_H, \%data);

    # =========================================================================
    # MÉTODO 2 — Endpoint fijo
    # =========================================================================
    my $resultado_fijo = undef;
    if ($do_fixed) {
        my ($carb_vol2, $bicarb_vol2, $alk2);
        my $Method2carb_fail = 0;

        # Endpoint de carbonato
        if ($highest_ph >= $carb_endpt2) {
            if (defined $data{sprintf("%.2f", $carb_endpt2)} && $data{sprintf("%.2f", $carb_endpt2)} > 0) {
                $carb_vol2 = $data{sprintf("%.2f", $carb_endpt2)};
            } else {
                $carb_vol2 = $data{$highest_ph};
                my $lp = $highest_ph;
                my $lv = $data{$highest_ph};
                foreach my $ph (reverse sort { $a <=> $b } keys %data) {
                    if ($ph <= $carb_endpt2 && $lp > $carb_endpt2) {
                        $carb_vol2 = $lv + ($data{$ph} - $lv) * ($carb_endpt2 - $lp) / ($ph - $lp);
                        last;
                    }
                    $lv = $data{$ph}; $lp = $ph;
                }
            }
        } else {
            $carb_vol2 = 0;
        }

        # Endpoint de bicarbonato
        if (defined $data{sprintf("%.2f", $bicarb_endpt2)} && $data{sprintf("%.2f", $bicarb_endpt2)} > 0) {
            $bicarb_vol2 = $data{sprintf("%.2f", $bicarb_endpt2)};
        } else {
            $bicarb_vol2 = $data{$highest_ph};
            my $lp = $highest_ph; my $lv = $data{$highest_ph};
            foreach my $ph (reverse sort { $a <=> $b } keys %data) {
                if ($ph <= $bicarb_endpt2 && $lp > $bicarb_endpt2) {
                    $bicarb_vol2 = $lv + ($data{$ph} - $lv) * ($bicarb_endpt2 - $lp) / ($ph - $lp);
                    last;
                }
                $lv = $data{$ph}; $lp = $ph;
            }
        }

        $alk2 = $bicarb_vol2 * $F3 / $volume;
        my ($bicarb2_mg, $carb2_mg, $oh2_mg) = _get_speciation($alk2 / ALK_MEQ, $highest_ph, $Kw, $K1, $K2, $gamma_H);
        my $check2 = _get_criteria($alk2 / ALK_MEQ, $bicarb_vol2, $carb_vol2, 1,
                                   $highest_ph, $volume, $acid_conc, $cor_factor, $F1, $F3,
                                   $Kw, $K1, $K2, $gamma_H, \%data);

        $resultado_fijo = {
            endpoint_carbonato_ph     => $carb_endpt2 + 0,
            endpoint_carbonato_vol_ml => _r2($carb_vol2),
            endpoint_bicarbonato_ph   => $bicarb_endpt2 + 0,
            endpoint_bicarbonato_vol_ml => _r2($bicarb_vol2),
            alcalinidad_mg_l          => _r1($alk2),
            alcalinidad_meq_l         => _r2($alk2 * 1000.0 / ALK_MEQ),
            bicarbonato_mg_l          => _r1($bicarb2_mg),
            bicarbonato_meq_l         => _r2($bicarb2_mg * 1000.0 / BICARB_MEQ),
            carbonato_mg_l            => _r1($carb2_mg),
            carbonato_meq_l           => _r2($carb2_mg * 2000.0 / CARB_MEQ),
            hidroxido_mg_l            => _r1($oh2_mg),
            advertencia               => $check2 || undef,
        };
    }

    # =========================================================================
    # Regiones de pH para CTC y Gran (igual que ac_calcs.pl)
    # =========================================================================
    my ($carb_ph_upper, $carb_ph_lower, $bicarb_ph_upper, $bicarb_ph_lower);
    my ($GranF1_start, $GranF2_start, $GranF2_end, $GranF3_start, $GranF3_end,
        $GranF4_start, $GranF4_end, $GranF5_start, $GranF6_end);

    if ($do_ctc || $do_gran) {
        $carb_ph_upper   = -0.5 * ($log10K1 + $log10K2) + 1.0;
        $carb_ph_lower   = -0.5 * ($log10K1 + $log10K2) - 1.0;
        $bicarb_ph_upper = -1.0 * $log10K1 - 0.6;
        $bicarb_ph_lower = $bicarb_ph_upper - 2.5;

        $GranF1_start = 4.15;
        $GranF2_start = -0.5 * ($log10K1 + $log10K2) - 0.35;
        $GranF2_end   = -1.0 * $log10K1 - 0.5;
        $GranF3_start = -1.0 * $log10K1 + 0.7;
        $GranF3_end   = 4.85;
        $GranF4_start = 10.3;
        $GranF4_end   = -0.5 * ($log10K1 + $log10K2) + 0.35;

        # Estimar Ct para refinar regiones
        my ($Ct6, $use_defaults);
        if ($highest_ph > -1.0 * $log10K1 + 0.3) {
            $Ct6 = $bicarb1_mg / BICARB_MEQ + $carb1_mg / CARB_MEQ;
        } elsif (abs($data{$highest_ph}) < 0.0001) {
            my $alk6  = $alk1 / ALK_MEQ;
            my $H     = 10.0 ** (-$highest_ph);
            my $denom = $K1 * $H + 2.0 * $K1 * $K2;
            $Ct6 = ($alk6 - $Kw/$H + $H/$gamma_H) * ($H*$H + $K1*$H + $K1*$K2) / $denom if $denom;
        } else {
            $use_defaults = 1;
        }
        $use_defaults = 1 if (!defined $Ct6 || $Ct6 <= 0.0);

        unless ($use_defaults) {
            my $bicarb_endpt_H = (-$K1 + sqrt($K1*$K1 + 4.0*$K1*$Ct6)) / 2.0;
            if ($bicarb_endpt_H > 0) {
                my $bep = -log($bicarb_endpt_H) / log(10.0);
                if ($bep > 1 && $bep <= 7) {
                    $bicarb_ph_upper = $bep + 1.2;
                    $bicarb_ph_lower = $bep - 1.2;
                    $GranF1_start    = $bep - 0.35;
                    $GranF3_end      = $bep + 0.35;
                }
            }
        }

        $_carb_ph_upper   = $carb_ph_upper;
        $_carb_ph_lower   = $carb_ph_lower;
        $_bicarb_ph_upper = $bicarb_ph_upper;
        $_bicarb_ph_lower = $bicarb_ph_lower;
    }

    # =========================================================================
    # MÉTODO 4 — CTC sobre endpoint de carbonato (Powell)
    # =========================================================================
    my ($alk4, $Ct4, $carb_endpt4_vol, $carb_endpt4, $Method4_success) = (0, 0, 0, undef, 0);

    if ($do_ctc) {
        my $n = scalar grep { $_ <= $carb_ph_upper && $_ >= $carb_ph_lower } keys %data;

        if ($highest_ph > 8.3 && $n >= 3) {
            $alk4 = $alk1 / ALK_MEQ;
            if (abs($data{$highest_ph}) < 0.0001) {
                my $H = 10.0 ** (-$highest_ph);
                $Ct4  = ($alk4 - $Kw/$H + $H/$gamma_H) * ($H*$H + $K1*$H + $K1*$K2) / ($K1*$H + 2.0*$K1*$K2);
            } else {
                $Ct4 = $bicarb1_mg / BICARB_MEQ + $carb1_mg / CARB_MEQ;
            }

            $_do_carb   = 1;
            $_do_bicarb = 0;
            eval { ($alk4, $Ct4) = _powell($alk4, $Ct4, 0.00001); };
            ($alk4, $Ct4) = (0, 0) if $@;

            if ($alk4 > 0 && $Ct4 > 0) {
                $Method4_success = 1;
                my (%vol4, %calc_slope4);
                my ($lv, $lp);
                my $ph = $carb_ph_upper;
                while ($ph >= $carb_ph_lower) {
                    my $H  = 10.0 ** (-$ph);
                    my $i  = sprintf("%.3f", $ph);
                    $vol4{$i} = $_volume / ($acid_conc * $cor_factor + $Kw/$H - $H/$gamma_H)
                                * ($alk4 - $Ct4*($K1*$H + 2.0*$K1*$K2)/($H*$H + $K1*$H + $K1*$K2) - $Kw/$H + $H/$gamma_H);
                    $calc_slope4{$i} = ($lp - $ph) / ($vol4{$i} - $lv) if defined $lv;
                    $lv = $vol4{$i}; $lp = $ph;
                    $ph -= 0.005;
                }
                my $max_s = 0;
                foreach my $ph (reverse sort { $a <=> $b } keys %calc_slope4) {
                    if ($calc_slope4{$ph} > $max_s) {
                        $max_s = $calc_slope4{$ph};
                        $carb_endpt4 = $ph;
                        $carb_endpt4_vol = $vol4{$ph};
                    }
                }
            }
        }
    }

    # =========================================================================
    # MÉTODO 3 — CTC sobre endpoint de bicarbonato (Powell)
    # =========================================================================
    my ($alk3, $Ct3, $bicarb_endpt3_vol, $bicarb_endpt3, $Method3_success) = (0, 0, 0, undef, 0);
    my $resultado_ctc1 = undef;

    if ($do_ctc) {
        my $n = scalar grep { $_ <= $bicarb_ph_upper && $_ >= $bicarb_ph_lower } keys %data;

        if ($n >= 3) {
            $alk3 = $alk1 / ALK_MEQ;
            if (abs($data{$highest_ph}) < 0.0001) {
                my $H = 10.0 ** (-$highest_ph);
                $Ct3  = ($alk3 - $Kw/$H + $H/$gamma_H) * ($H*$H + $K1*$H + $K1*$K2) / ($K1*$H + 2.0*$K1*$K2);
            } else {
                $Ct3 = $bicarb1_mg / BICARB_MEQ + $carb1_mg / CARB_MEQ;
            }

            $_do_carb   = 0;
            $_do_bicarb = 1;
            eval { ($alk3, $Ct3) = _powell($alk3, $Ct3, 0.00001); };
            ($alk3, $Ct3) = (0, 0) if $@;

            if ($alk3 > 0 && $Ct3 > 0) {
                $Method3_success = 1;
                my (%vol3, %calc_slope3);
                my ($lv, $lp);
                my $ph = $bicarb_ph_upper;
                while ($ph >= $bicarb_ph_lower) {
                    my $H = 10.0 ** (-$ph);
                    my $i = sprintf("%.3f", $ph);
                    $vol3{$i} = $_volume / ($acid_conc * $cor_factor + $Kw/$H - $H/$gamma_H)
                                * ($alk3 - $Ct3*($K1*$H + 2.0*$K1*$K2)/($H*$H + $K1*$H + $K1*$K2) - $Kw/$H + $H/$gamma_H);
                    $calc_slope3{$i} = ($lp - $ph) / ($vol3{$i} - $lv) if defined $lv;
                    $lv = $vol3{$i}; $lp = $ph;
                    $ph -= 0.005;
                }
                my $max_s = 0;
                foreach my $ph (reverse sort { $a <=> $b } keys %calc_slope3) {
                    next if $ph > $highest_ph;
                    if ($calc_slope3{$ph} > $max_s) {
                        $max_s = $calc_slope3{$ph};
                        $bicarb_endpt3 = $ph;
                        $bicarb_endpt3_vol = $vol3{$ph};
                    }
                }
                my $alk3_tmp = $bicarb_endpt3_vol * $F3 / $volume;
                my ($b3, $c3, $oh3) = _get_speciation($alk3_tmp / ALK_MEQ, $highest_ph, $Kw, $K1, $K2, $gamma_H);
                my $check3 = _get_criteria($alk3_tmp / ALK_MEQ, $bicarb_endpt3_vol, $carb_endpt4_vol, 0,
                                           $highest_ph, $volume, $acid_conc, $cor_factor, $F1, $F3,
                                           $Kw, $K1, $K2, $gamma_H, \%data);
                $resultado_ctc1 = {
                    endpoint_carbonato_ph      => defined $carb_endpt4 ? $carb_endpt4 + 0 : undef,
                    endpoint_carbonato_vol_ml  => _r2($carb_endpt4_vol),
                    endpoint_bicarbonato_ph    => defined $bicarb_endpt3 ? $bicarb_endpt3 + 0 : undef,
                    endpoint_bicarbonato_vol_ml => _r2($bicarb_endpt3_vol),
                    alcalinidad_mg_l           => _r1($alk3_tmp),
                    alcalinidad_meq_l          => _r2($alk3_tmp * 1000.0 / ALK_MEQ),
                    bicarbonato_mg_l           => _r1($b3),
                    bicarbonato_meq_l          => _r2($b3 * 1000.0 / BICARB_MEQ),
                    carbonato_mg_l             => _r1($c3),
                    carbonato_meq_l            => _r2($c3 * 2000.0 / CARB_MEQ),
                    hidroxido_mg_l             => _r1($oh3),
                    advertencia                => $check3 || undef,
                };
            }
        }

        $resultado_ctc1 //= { error => 'Datos insuficientes en la región del endpoint de bicarbonato (mín 3 puntos)' };
    }

    # =========================================================================
    # MÉTODO 5 — CTC sobre toda la curva (Powell)
    # =========================================================================
    my $resultado_ctc2 = undef;

    if ($do_ctc) {
        my $n = scalar keys %data;
        if ($n >= 3) {
            my $alk5 = $alk1 / ALK_MEQ;
            my $Ct5;
            if (abs($data{$highest_ph}) < 0.0001) {
                my $H = 10.0 ** (-$highest_ph);
                $Ct5 = ($alk5 - $Kw/$H + $H/$gamma_H) * ($H*$H + $K1*$H + $K1*$K2) / ($K1*$H + 2.0*$K1*$K2);
            } else {
                $Ct5 = $bicarb1_mg / BICARB_MEQ + $carb1_mg / CARB_MEQ;
            }

            $_do_carb   = 0;
            $_do_bicarb = 0;
            eval { ($alk5, $Ct5) = _powell($alk5, $Ct5, 0.00001); };
            ($alk5, $Ct5) = (0, 0) if $@;

            if ($alk5 > 0 && $Ct5 > 0) {
                my (%vol5, %calc_slope5);
                my ($lv, $lp);
                my $start_ph = $highest_ph > $carb_ph_upper ? $highest_ph : $carb_ph_upper;
                my $ph = $start_ph;
                while ($ph >= $lowest_ph && $ph >= $bicarb_ph_lower) {
                    my $H = 10.0 ** (-$ph);
                    my $i = sprintf("%.3f", $ph);
                    $vol5{$i} = $_volume / ($acid_conc * $cor_factor + $Kw/$H - $H/$gamma_H)
                                * ($alk5 - $Ct5*($K1*$H + 2.0*$K1*$K2)/($H*$H + $K1*$H + $K1*$K2) - $Kw/$H + $H/$gamma_H);
                    $calc_slope5{$i} = ($lp - $ph) / ($vol5{$i} - $lv) if defined $lv;
                    $lv = $vol5{$i}; $lp = $ph;
                    $ph -= 0.005;
                }

                # Endpoint carbonato
                my ($carb_endpt5, $carb_endpt5_vol) = (undef, 0);
                if ($highest_ph > 8.3) {
                    my $max_s = 0;
                    foreach my $ph (reverse sort { $a <=> $b } keys %calc_slope5) {
                        next if $ph > $carb_ph_upper;
                        last if $ph < $carb_ph_lower;
                        if ($calc_slope5{$ph} > $max_s) {
                            $max_s = $calc_slope5{$ph};
                            $carb_endpt5 = $ph;
                            $carb_endpt5_vol = $vol5{$ph};
                        }
                    }
                }

                # Endpoint bicarbonato
                my ($bicarb_endpt5, $bicarb_endpt5_vol) = (undef, 0);
                my $max_s = 0;
                foreach my $ph (reverse sort { $a <=> $b } keys %calc_slope5) {
                    next if $ph > $bicarb_ph_upper;
                    last if $ph < $bicarb_ph_lower;
                    if ($calc_slope5{$ph} > $max_s) {
                        $max_s = $calc_slope5{$ph};
                        $bicarb_endpt5 = $ph;
                        $bicarb_endpt5_vol = $vol5{$ph};
                    }
                }

                my $alk5_tmp = $bicarb_endpt5_vol * $F3 / $volume;
                my ($b5, $c5, $oh5) = _get_speciation($alk5_tmp / ALK_MEQ, $highest_ph, $Kw, $K1, $K2, $gamma_H);
                my $check5 = _get_criteria($alk5_tmp / ALK_MEQ, $bicarb_endpt5_vol, $carb_endpt5_vol, 0,
                                           $highest_ph, $volume, $acid_conc, $cor_factor, $F1, $F3,
                                           $Kw, $K1, $K2, $gamma_H, \%data);
                $resultado_ctc2 = {
                    endpoint_carbonato_ph      => defined $carb_endpt5 ? $carb_endpt5 + 0 : undef,
                    endpoint_carbonato_vol_ml  => _r2($carb_endpt5_vol),
                    endpoint_bicarbonato_ph    => defined $bicarb_endpt5 ? $bicarb_endpt5 + 0 : undef,
                    endpoint_bicarbonato_vol_ml => _r2($bicarb_endpt5_vol),
                    alcalinidad_mg_l           => _r1($alk5_tmp),
                    alcalinidad_meq_l          => _r2($alk5_tmp * 1000.0 / ALK_MEQ),
                    bicarbonato_mg_l           => _r1($b5),
                    bicarbonato_meq_l          => _r2($b5 * 1000.0 / BICARB_MEQ),
                    carbonato_mg_l             => _r1($c5),
                    carbonato_meq_l            => _r2($c5 * 2000.0 / CARB_MEQ),
                    hidroxido_mg_l             => _r1($oh5),
                    advertencia                => $check5 || undef,
                };
            } else {
                $resultado_ctc2 = { error => 'El ajuste no convergió' };
            }
        } else {
            $resultado_ctc2 = { error => 'Datos insuficientes (mín 3 puntos)' };
        }
    }

    # =========================================================================
    # MÉTODO 6 — Gran
    # =========================================================================
    my $resultado_gran = undef;

    if ($do_gran) {
        my (%GranF1, %GranF2, %GranF3, %GranF4, %GranF5, %GranF6);
        my (%regF1, %regF2, %regF3, %regF4, %regF5, %regF6);
        my ($GranF1_n, $GranF1_slope, $GranF1_int);
        my ($GranF2_n, $GranF2_slope, $GranF2_int);
        my ($GranF3_n, $GranF3_slope, $GranF3_int);
        my ($GranF4_n, $GranF4_slope, $GranF4_int);
        my ($GranF5_n, $GranF5_slope, $GranF5_int);
        my ($GranF6_n, $GranF6_slope, $GranF6_int);

        # F1 — bicarbonato (pendiente positiva)
        foreach my $ph (reverse sort { $a <=> $b } keys %data) {
            next if $ph > $ph_split;
            my $GrF1 = ($volume + $data{$ph}) * 10.0 ** (-$ph) / $gamma_H;
            $GranF1{$data{$ph}} = $GrF1;
            $regF1{$data{$ph}}  = $GrF1 if $ph <= $GranF1_start;
        }
        ($GranF1_n, $GranF1_slope, $GranF1_int) = _regression(%regF1);

        my ($bicarb_endpt6_vol, $alk6, $bicarb6_mg, $carb6_mg, $oh6_mg);
        my $GranF1_success = 0;

        if ($GranF1_n > 1 && $GranF1_slope != 0) {
            $bicarb_endpt6_vol = -$GranF1_int / $GranF1_slope;
            $GranF1_success    = 1;
            $alk6 = $bicarb_endpt6_vol * $F3 / $volume;
            ($bicarb6_mg, $carb6_mg, $oh6_mg) = _get_speciation($alk6 / ALK_MEQ, $highest_ph, $Kw, $K1, $K2, $gamma_H);

            # F2 — carbonato usando endpoint de F1
            foreach my $ph (reverse sort { $a <=> $b } keys %data) {
                last if $ph < $GranF2_end;
                my $GrF2 = ($bicarb_endpt6_vol - $data{$ph}) * 10.0 ** (-$ph);
                $GranF2{$data{$ph}} = $GrF2;
                $regF2{$data{$ph}}  = $GrF2 if $ph <= $GranF2_start;
            }
            ($GranF2_n, $GranF2_slope, $GranF2_int) = _regression(%regF2);
        }

        my ($carb_endpt6_vol, $GranF2_success) = (0, 0);
        if (($GranF2_n // 0) > 1 && ($GranF2_slope // 0) != 0) {
            my $ep = -$GranF2_int / $GranF2_slope;
            if ($ep > 0) { $carb_endpt6_vol = $ep; $GranF2_success = 1; }
        }

        # F3 — bicarbonato alternativo (pendiente negativa)
        foreach my $ph (sort { $a <=> $b } keys %data) {
            last if $ph > $GranF3_start;
            my $GrF3 = ($data{$ph} - $carb_endpt6_vol) * 10.0 ** $ph;
            $GranF3{$data{$ph}} = $GrF3;
            $regF3{$data{$ph}}  = $GrF3 if $ph >= $GranF3_end;
        }
        ($GranF3_n, $GranF3_slope, $GranF3_int) = _regression(%regF3);

        my ($bicarb_endpt6b_vol, $alk6b, $bicarb6b_mg, $carb6b_mg, $GranF3_success) = (0, 0, 0, 0, 0);
        if ($GranF3_n > 1 && $GranF3_slope != 0) {
            my $ep = -$GranF3_int / $GranF3_slope;
            if ($ep > 0) {
                $bicarb_endpt6b_vol = $ep;
                $GranF3_success     = 1;
                $alk6b = $bicarb_endpt6b_vol * $F3 / $volume;
                ($bicarb6b_mg, $carb6b_mg) = _get_speciation($alk6b / ALK_MEQ, $highest_ph, $Kw, $K1, $K2, $gamma_H);
            }
        }

        # F4 — carbonato alternativo (solo si F2 tuvo éxito)
        my ($carb_endpt6b_vol, $GranF4_success) = (0, 0);
        if ($GranF2_success) {
            foreach my $ph (sort { $a <=> $b } keys %data) {
                next if $ph < $ph_split;
                last if $ph > $GranF4_start;
                my $ref_vol = $GranF1_success ? $bicarb_endpt6_vol : $bicarb_endpt6b_vol;
                my $GrF4 = ($ref_vol - 2.0 * $carb_endpt6_vol + $data{$ph}) * 10.0 ** $ph;
                $GranF4{$data{$ph}} = $GrF4;
                $regF4{$data{$ph}}  = $GrF4 if $ph >= $GranF4_end;
            }
            ($GranF4_n, $GranF4_slope, $GranF4_int) = _regression(%regF4);
            if ($GranF4_n > 1 && $GranF4_slope != 0) {
                my $ep = -$GranF4_int / $GranF4_slope;
                if ($ep > 0) { $carb_endpt6b_vol = $ep; $GranF4_success = 1; }
            }
        }

        my $check6  = $GranF1_success ? _get_criteria($alk6  / ALK_MEQ, $bicarb_endpt6_vol,  $carb_endpt6_vol,  0,
                                                       $highest_ph, $volume, $acid_conc, $cor_factor, $F1, $F3,
                                                       $Kw, $K1, $K2, $gamma_H, \%data) : undef;
        my $check6b = $GranF3_success ? _get_criteria($alk6b / ALK_MEQ, $bicarb_endpt6b_vol, $carb_endpt6_vol,  0,
                                                       $highest_ph, $volume, $acid_conc, $cor_factor, $F1, $F3,
                                                       $Kw, $K1, $K2, $gamma_H, \%data) : undef;

        $resultado_gran = {
            F1 => {
                exito                       => $GranF1_success ? \1 : \0,
                puntos_usados               => $GranF1_n + 0,
                endpoint_bicarbonato_vol_ml => $GranF1_success ? _r2($bicarb_endpt6_vol) : undef,
                alcalinidad_mg_l            => $GranF1_success ? _r1($alk6)  : undef,
                alcalinidad_meq_l           => $GranF1_success ? _r2($alk6 * 1000.0 / ALK_MEQ) : undef,
                bicarbonato_mg_l            => $GranF1_success ? _r1($bicarb6_mg) : undef,
                carbonato_mg_l              => $GranF1_success ? _r1($carb6_mg)   : undef,
                hidroxido_mg_l              => $GranF1_success ? _r1($oh6_mg)     : undef,
                advertencia                 => $check6 || undef,
            },
            F2 => {
                exito                      => $GranF2_success ? \1 : \0,
                puntos_usados              => ($GranF2_n // 0) + 0,
                endpoint_carbonato_vol_ml  => $GranF2_success ? _r2($carb_endpt6_vol) : undef,
            },
            F3 => {
                exito                       => $GranF3_success ? \1 : \0,
                puntos_usados               => $GranF3_n + 0,
                endpoint_bicarbonato_vol_ml => $GranF3_success ? _r2($bicarb_endpt6b_vol) : undef,
                alcalinidad_mg_l            => $GranF3_success ? _r1($alk6b) : undef,
                alcalinidad_meq_l           => $GranF3_success ? _r2($alk6b * 1000.0 / ALK_MEQ) : undef,
                bicarbonato_mg_l            => $GranF3_success ? _r1($bicarb6b_mg) : undef,
                carbonato_mg_l              => $GranF3_success ? _r1($carb6b_mg)   : undef,
                advertencia                 => $check6b || undef,
            },
            F4 => {
                exito                     => $GranF4_success ? \1 : \0,
                puntos_usados             => ($GranF4_n // 0) + 0,
                endpoint_carbonato_vol_ml => $GranF4_success ? _r2($carb_endpt6b_vol) : undef,
            },
        };
    }

    # =========================================================================
    # Resultado del método de inflexión (para la respuesta)
    # =========================================================================
    my $resultado_inflexion = undef;
    if ($do_inflexion) {
        $resultado_inflexion = {
            endpoint_carbonato_ph      => defined $carb_endpt1 ? $carb_endpt1 + 0 : undef,
            endpoint_carbonato_vol_ml  => _r2($carb_endpt1_vol),
            endpoint_bicarbonato_ph    => defined $bicarb_endpt1 ? $bicarb_endpt1 + 0 : undef,
            endpoint_bicarbonato_vol_ml => _r2($bicarb_endpt1_vol),
            alcalinidad_mg_l           => _r1($alk1),
            alcalinidad_meq_l          => _r2($alk1 * 1000.0 / ALK_MEQ),
            bicarbonato_mg_l           => _r1($bicarb1_mg),
            bicarbonato_meq_l          => _r2($bicarb1_mg * 1000.0 / BICARB_MEQ),
            carbonato_mg_l             => _r1($carb1_mg),
            carbonato_meq_l            => _r2($carb1_mg * 2000.0 / CARB_MEQ),
            hidroxido_mg_l             => _r1($oh1_mg),
            advertencia                => $check1 || undef,
        };
    }

    # =========================================================================
    # DATOS PARA GRÁFICAS
    # =========================================================================

    # --- Gráfica 1: Curva de titulación medida + pendiente ---
    my (@g_titulacion, @g_pendiente);
    {
        my $lv;
        foreach my $ph (reverse sort { $a <=> $b } keys %data) {
            push @g_titulacion, { x => $data{$ph} + 0, ph => $ph + 0 };
            if (defined $lv && exists $slope{$ph}) {
                push @g_pendiente, {
                    x         => _r2(($data{$ph} + $lv) / 2.0),
                    pendiente => $slope{$ph} + 0,
                };
            }
            $lv = $data{$ph};
        }
    }

    # --- Gráfica 2: Curva teórica CTC-1 ---
    my (@g_ctc1_curva, @g_ctc1_pendiente);
    if ($do_ctc && $resultado_ctc1 && !exists $resultado_ctc1->{error}
        && defined $resultado_ctc1->{endpoint_bicarbonato_vol_ml}) {
        if (1) {
            my $ep_vol = $resultado_ctc1->{endpoint_bicarbonato_vol_ml};
            my $alk3_r = $ep_vol * $F3 / $volume;
            my $H0     = 10.0 ** (-$highest_ph);
            my $Ct3_r  = ($alk3_r / ALK_MEQ - $Kw/$H0 + $H0/$gamma_H)
                         * ($H0*$H0 + $K1*$H0 + $K1*$K2) / ($K1*$H0 + 2.0*$K1*$K2);
            my ($lv2, $lp2);
            my $_phi_hi3 = $bicarb_ph_upper < $highest_ph ? $bicarb_ph_upper : $highest_ph;
            my $_phi_lo3 = $bicarb_ph_lower > $lowest_ph  ? $bicarb_ph_lower : $lowest_ph;
            my $ph = $_phi_hi3;
            while ($ph >= $_phi_lo3 - 0.001) {
                my $H   = 10.0 ** (-$ph);
                my $den = $acid_conc * $cor_factor + $Kw/$H - $H/$gamma_H;
                if ($den) {
                    my $v = $volume / $den
                            * ($alk3_r / ALK_MEQ
                               - $Ct3_r * ($K1*$H + 2.0*$K1*$K2) / ($H*$H + $K1*$H + $K1*$K2)
                               - $Kw/$H + $H/$gamma_H);
                    push @g_ctc1_curva, { x => _r2($v), ph => _r2($ph) };
                    if (defined $lv2 && abs($v - $lv2) > 1e-10) {
                        push @g_ctc1_pendiente, { x => _r2(($v + $lv2) / 2.0), pendiente => _r2(($lp2 - $ph) / ($v - $lv2)) };
                    }
                    $lv2 = $v; $lp2 = $ph;
                }
                $ph -= 0.01;
            }
        }
    }

    # --- Gráfica 3: Curva teórica CTC-2 (ajuste curva completa) ---
    my (@g_ctc2_curva, @g_ctc2_pendiente);
    if ($do_ctc && $resultado_ctc2 && !exists $resultado_ctc2->{error}) {
        if (defined $resultado_ctc2->{endpoint_bicarbonato_vol_ml}) {
            my $ep_vol = $resultado_ctc2->{endpoint_bicarbonato_vol_ml};
            my $alk5_r = $ep_vol * $F3 / $volume;
            my $H0     = 10.0 ** (-$highest_ph);
            my $Ct5_r  = ($alk5_r / ALK_MEQ - $Kw/$H0 + $H0/$gamma_H)
                         * ($H0*$H0 + $K1*$H0 + $K1*$K2) / ($K1*$H0 + 2.0*$K1*$K2);
            my ($lv2, $lp2);
            my $ph_start = $highest_ph > $carb_ph_upper ? $highest_ph : $carb_ph_upper;
            my $ph = $ph_start;
            while ($ph >= $lowest_ph - 0.001) {
                my $H   = 10.0 ** (-$ph);
                my $den = $acid_conc * $cor_factor + $Kw/$H - $H/$gamma_H;
                if ($den) {
                    my $v = $volume / $den
                            * ($alk5_r / ALK_MEQ
                               - $Ct5_r * ($K1*$H + 2.0*$K1*$K2) / ($H*$H + $K1*$H + $K1*$K2)
                               - $Kw/$H + $H/$gamma_H);
                    push @g_ctc2_curva, { x => _r2($v), ph => _r2($ph) };
                    if (defined $lv2) {
                        my $s = ($lp2 - $ph) / ($v - $lv2) if abs($v - $lv2) > 1e-10;
                        push @g_ctc2_pendiente, { x => _r2(($v + $lv2) / 2.0), pendiente => _r2($s // 0) };
                    }
                    $lv2 = $v; $lp2 = $ph;
                }
                $ph -= 0.01;
            }
        }
    }

    # --- Gráfica 4: Funciones Gran ---
    my (%g_gran_F1, %g_gran_F2, %g_gran_F3, %g_gran_F4);
    my (@g_F1, @g_F2, @g_F3, @g_F4);
    if ($do_gran && $resultado_gran) {
        my $bicarb_ep = $resultado_gran->{F1}{endpoint_bicarbonato_vol_ml} // 0;
        my $carb_ep   = $resultado_gran->{F2}{endpoint_carbonato_vol_ml}  // 0;

        foreach my $ph (reverse sort { $a <=> $b } keys %data) {
            my $H = 10.0 ** (-$ph);
            # F1
            if ($ph <= $ph_split) {
                my $gf1 = ($volume + $data{$ph}) * $H / $gamma_H;
                push @g_F1, { x => $data{$ph} + 0, y => $gf1 + 0 };
            }
            # F2 — solo si F1 tuvo éxito
            if ($bicarb_ep > 0) {
                my $gf2 = ($bicarb_ep - $data{$ph}) * $H;
                push @g_F2, { x => $data{$ph} + 0, y => $gf2 + 0 };
            }
            # F3
            if ($carb_ep >= 0) {
                my $gf3 = ($data{$ph} - $carb_ep) * (10.0 ** $ph);
                push @g_F3, { x => $data{$ph} + 0, y => $gf3 + 0 };
            }
        }
    }

    # =========================================================================
    # Respuesta final
    # =========================================================================
    alarm(0); # cancelar el alarm antes de responder
    return $self->render(json => {
        constantes => {
            log10_Kw      => _r2($log10Kw),
            log10_K1      => _r2($log10K1),
            log10_K2      => _r2($log10K2),
            fuerza_ionica => $I + 0,
        },
        especiacion_basica => {
            ph_inicial       => $highest_ph + 0,
            alcalinidad_mg_l => _r1($alk1),
            alcalinidad_meq_l => _r2($alk1 * 1000.0 / ALK_MEQ),
            bicarbonato_mg_l => _r1($bicarb1_mg),
            bicarbonato_meq_l => _r2($bicarb1_mg * 1000.0 / BICARB_MEQ),
            carbonato_mg_l   => _r1($carb1_mg),
            carbonato_meq_l  => _r2($carb1_mg * 2000.0 / CARB_MEQ),
            hidroxido_mg_l   => _r1($oh1_mg),
        },
        inflexion    => $resultado_inflexion,
        endpoint_fijo => $resultado_fijo,
        ctc_1        => $resultado_ctc1,
        ctc_2        => $resultado_ctc2,
        gran         => $resultado_gran,
        advertencias => \@advertencias,
        graficas     => {
            titulacion => \@g_titulacion,
            pendiente  => \@g_pendiente,
            ctc_1      => {
                curva     => \@g_ctc1_curva,
                pendiente => \@g_ctc1_pendiente,
            },
            ctc_2      => {
                curva     => \@g_ctc2_curva,
                pendiente => \@g_ctc2_pendiente,
            },
            gran       => {
                F1 => \@g_F1,
                F2 => \@g_F2,
                F3 => \@g_F3,
            },
        },
    });
}

# =============================================================================
# FUNCIONES INTERNAS — traducción directa de ac_calcs.pl (Rounds, USGS, GPLv2)
# =============================================================================

# --- Constantes de equilibrio (get_constants) --------------------------------
sub _get_constants {
    my ($T, $spc) = @_;
    $T += 273.15;
    my $ds    = 0.59 * $spc;
    my $I     = 0.000025 * $ds;
    my $sqrtI = sqrt($I);

    my $dh1 = -0.5085  * $sqrtI / (1.0 + 1.3124 * $sqrtI) + 0.004745694 + 0.04160762 * $I - 0.009284843 * $I * $I;
    my $dh2 = -2.0340  * $sqrtI / (1.0 + 1.4765 * $sqrtI) + 0.01205665  + 0.09715745 * $I - 0.02067746  * $I * $I;

    my $gH2CO3 = 10.0 ** (0.0755 * $I);
    my $gHCO3  = 10.0 ** $dh1;
    my $gCO3   = 10.0 ** $dh2;
    my $gOH    = $gHCO3;
    my $gH     = $gHCO3;

    my $Kw = (10.0 ** (-283.9710 - 0.05069842*$T + 13323.00/$T + 102.24447*log($T)/log(10) - 1119669/($T*$T))) / $gOH;
    my $K1 = (10.0 ** (-356.3094 - 0.06091964*$T + 21834.37/$T + 126.8339 *log($T)/log(10) - 1684915/($T*$T))) * $gH2CO3 / $gHCO3;
    my $K2 = (10.0 ** (-107.8871 - 0.03252849*$T +  5151.79/$T +  38.92561*log($T)/log(10) - 563713.9/($T*$T))) * $gHCO3  / $gCO3;

    return ($Kw, $K1, $K2, $gH, $I);
}

# --- Especiación (get_speciation) --------------------------------------------
sub _get_speciation {
    my ($alk, $highest_ph, $Kw, $K1, $K2, $gamma_H) = @_;
    my $H0     = 10.0 ** (-$highest_ph);
    my $bicarb = BICARB_MEQ * ($alk - $Kw/$H0 + $H0/$gamma_H) / (1.0 + 2.0*$K2/$H0);
    my $carb   = CARB_MEQ   * ($alk - $Kw/$H0 + $H0/$gamma_H) / (2.0 + $H0/$K2);
    my $oh     = OH_MEQ * $Kw / $H0;
    $bicarb = 0 if $bicarb < 0;
    $carb   = 0 if $carb   < 0;
    $oh     = 0 if $oh     < 0;
    return ($bicarb, $carb, $oh);
}

# --- Criterios de calidad (get_criteria) -------------------------------------
sub _get_criteria {
    my ($alk, $bicarb_endpt_vol, $carb_endpt_vol, $endpt_fixed,
        $highest_ph, $volume, $acid_conc, $cor_factor, $F1, $F3,
        $Kw, $K1, $K2, $gamma_H, $data_ref) = @_;

    my $H0       = 10.0 ** (-$highest_ph);
    my $n        = 0;
    my $mean_err = 0;

    foreach my $ph (reverse sort { $a <=> $b } keys %$data_ref) {
        my $H = 10.0 ** (-$ph);
        next if $H == 0.0;
        my $denom = $acid_conc * $cor_factor + $Kw/$H - $H/$gamma_H;
        next unless $denom;
        my $alpha0 = ($K1*$H + 2.0*$K1*$K2) / ($H*$H + $K1*$H + $K1*$K2);
        my $alpha0_0 = ($K1*$H0 + 2.0*$K1*$K2) / ($H0*$H0 + $K1*$H0 + $K1*$K2);
        my $vol_teo = $volume / $denom
                      * ($alk - $Kw/$H + $H/$gamma_H
                         - ($alk - $Kw/$H0 + $H0/$gamma_H) * $alpha0
                         * ($H0*$H0 + $K1*$H0 + $K1*$K2) / ($K1*$H0 + 2.0*$K1*$K2));
        $n++;
        $mean_err += abs($data_ref->{$ph} - $vol_teo);
    }
    $mean_err /= $n if $n;

    my $denom_check = $acid_conc * $cor_factor;
    my $check_vol = $denom_check > 0
        ? $volume / $denom_check
          * ($alk - ($alk - $Kw/$H0 + $H0/$gamma_H) * ($H0*$H0 + $K1*$H0 + $K1*$K2) / ($K1*$H0 + 2.0*$K1*$K2))
        : 0;

    my $carb_vol_err = abs($carb_endpt_vol - $check_vol);
    my ($str1, $str2) = ('', '');

    if ($highest_ph > 8.3 && $carb_endpt_vol > 0 &&
        $carb_vol_err > 0.05 * $bicarb_endpt_vol &&
        $carb_endpt_vol > 0 && $bicarb_endpt_vol > 0 &&
        $carb_vol_err * $F1 / $volume > 1.0) {
        $str1 = sprintf('El endpoint de carbonato encontrado (%.2f mL) no coincide bien con el teórico (%.2f mL). ',
                        $carb_endpt_vol, $check_vol);
    }

    if ($n > 10 && $bicarb_endpt_vol > 0 && $mean_err > 0.05 * $bicarb_endpt_vol && $mean_err * $F3 / $volume > 1.0) {
        $str2 = ($str1 ? 'Además, la ' : 'La ')
              . sprintf('curva teórica de carbonatos (alcalinidad %.2f meq/L, pH %.2f) no ajusta bien a los datos (error medio = %.2f mL). ',
                        $alk * 1000.0, $highest_ph, $mean_err);
    }

    return '' unless $str1 || $str2;

    my $aviso = 'Advertencia: ' . $str1 . $str2
              . 'Esto indica que hay alcalinidad no-carbonática significativa en la muestra. '
              . 'Los valores de carbonato y bicarbonato deben reportarse solo como estimados.';
    return $aviso;
}

# --- Powell (powell) ---------------------------------------------------------
sub _powell {
    my ($alk, $Ct, $ftol) = @_;
    my $itmax = 75;
    my $n     = 1;
    my (@p, @pt, @xi, @xit, @ptt, @pass);

    $p[0] = ($alk > 0) ? log($alk) : -6;
    $p[1] = ($Ct  > 0) ? log($Ct)  : -6;
    @xi   = ([1, 0], [0, 1]);

    my $fret = _get_func(@p);
    @pt = @p;

    my $iter = 0;
    while ($iter++ <= $itmax) {
        my $fp   = $fret;
        my $ibig = 0;
        my $del  = 0.0;

        for my $i (0..$n) {
            my @xit_l = map { $xi[$_][$i] } 0..$n;
            my $fptt  = $fret;
            @pass = _linmin(@p, @xit_l, $n);
            $fret = pop @pass;
            @p    = splice(@pass, 0, $n+1);
            @xit_l = @pass;

            if (abs($fptt - $fret) > $del) {
                $del  = abs($fptt - $fret);
                $ibig = $i;
            }
            @xit = @xit_l;
        }

        if (2.0 * abs($fp - $fret) <= $ftol * (abs($fp) + abs($fret))) {
            return (exp($p[0]), exp($p[1]));
        }

        for my $j (0..$n) {
            $ptt[$j] = 2.0 * $p[$j] - $pt[$j];
            $xit[$j] = $p[$j] - $pt[$j];
            $pt[$j]  = $p[$j];
        }
        my $fptt = _get_func(@ptt);
        next if $fptt >= $fp;
        my $t = 2.0 * ($fp - 2.0*$fret + $fptt) * ($fp - $fret - $del)**2
                - $del * ($fp - $fptt)**2;
        next if $t >= 0.0;

        @pass = _linmin(@p, @xit, $n);
        $fret = pop @pass;
        @p    = splice(@pass, 0, $n+1);
        @xit  = @pass;
        for my $j (0..$n) { $xi[$j][$ibig] = $xit[$j]; }
    }
    return (exp($p[0]), exp($p[1]));
}

# --- Linmin ------------------------------------------------------------------
sub _linmin {
    my $n  = pop @_;
    my @p  = splice(@_, 0, $n+1);
    my @xi = @_;

    for my $j (0..$n) {
        $_pcom[$j]  = $p[$j];
        $_xicom[$j] = $xi[$j];
    }
    my ($ax, $xx, $bx) = _mnbrak(0.0, 1.0);
    my ($xmin, $fret)  = _brent($ax, $xx, $bx, 0.0001);

    for my $j (0..$n) {
        $xi[$j]  = $xmin * $xi[$j];
        $p[$j]  += $xi[$j];
    }
    return (@p, @xi, $fret);
}

# --- Mnbrak ------------------------------------------------------------------
sub _mnbrak {
    my ($ax, $bx) = @_;
    my ($gold, $glimit, $tiny) = (1.618034, 100.0, 1e-20);
    my ($fa, $fb) = (_onedim($ax), _onedim($bx));

    if ($fb > $fa) { ($ax,$bx) = ($bx,$ax); ($fa,$fb) = ($fb,$fa); }
    my $cx = $bx + $gold * ($bx - $ax);
    my $fc = _onedim($cx);

    my $_mnbrak_iter = 0;
    while ($fb >= $fc && $_mnbrak_iter++ < 200) {
        my $r   = ($bx - $ax) * ($fb - $fc);
        my $q   = ($bx - $cx) * ($fb - $fa);
        my $u   = $bx - (($bx-$cx)*$q - ($bx-$ax)*$r) / (2.0 * _sign(_max(abs($q-$r), $tiny), $q-$r));
        my $ulim = $bx + $glimit * ($cx - $bx);
        my $fu;

        if (($bx-$u)*($u-$cx) > 0.0) {
            $fu = _onedim($u);
            return ($bx, $u, $cx) if $fu < $fc;
            return ($ax, $bx, $u) if $fu > $fb;
            $u = $cx + $gold * ($cx - $bx);
            $fu = _onedim($u);
        } elsif (($cx-$u)*($u-$ulim) > 0.0) {
            $fu = _onedim($u);
            if ($fu < $fc) { $bx=$cx; $cx=$u; $u=$cx+$gold*($cx-$bx); $fb=$fc; $fc=$fu; $fu=_onedim($u); }
        } elsif (($u-$ulim)*($ulim-$cx) >= 0.0) {
            $u = $ulim; $fu = _onedim($u);
        } else {
            $u = $cx + $gold * ($cx - $bx); $fu = _onedim($u);
        }
        ($ax,$bx,$cx) = ($bx,$cx,$u);
        ($fa,$fb,$fc) = ($fb,$fc,$fu);
    }
    return ($ax, $bx, $cx);
}

# --- Brent -------------------------------------------------------------------
sub _brent {
    my ($ax, $bx, $cx, $tol) = @_;
    my ($itmax, $cgold, $zeps) = (100, 0.3819660, 1e-10);
    my ($a, $b) = sort { $a <=> $b } ($ax, $cx);
    my ($v, $w, $x, $e, $d) = ($bx, $bx, $bx, 0.0, 0.0);
    my ($fv, $fw, $fx) = (_onedim($x), _onedim($x), _onedim($x));

    for my $iter (1..$itmax) {
        my $xm   = 0.5 * ($a + $b);
        my $tol1 = $tol * abs($x) + $zeps;
        my $tol2 = 2.0 * $tol1;
        return ($x, $fx) if abs($x - $xm) <= ($tol2 - 0.5*($b-$a));

        my $u;
        if (abs($e) > $tol1) {
            my $r = ($x-$w)*($fx-$fv);
            my $q = ($x-$v)*($fx-$fw);
            my $p = ($x-$v)*$q - ($x-$w)*$r;
            $q = 2.0*($q-$r);
            $p *= -1 if $q > 0;
            $q = abs($q);
            my $etemp = $e;
            $e = $d;
            if (abs($p) >= abs(0.5*$q*$etemp) || $p <= $q*($a-$x) || $p >= $q*($b-$x)) {
                $e = $x >= $xm ? $a-$x : $b-$x;
                $d = $cgold * $e;
            } else {
                $d = $p/$q;
                $u = $x+$d;
                $d = _sign($tol1, $xm-$x) if ($u-$a) < $tol2 || ($b-$u) < $tol2;
            }
        } else {
            $e = $x >= $xm ? $a-$x : $b-$x;
            $d = $cgold * $e;
        }
        $u = abs($d) >= $tol1 ? $x+$d : $x + _sign($tol1, $d);
        my $fu = _onedim($u);

        if ($fu <= $fx) {
            $u >= $x ? ($a=$x) : ($b=$x);
            ($v,$fv) = ($w,$fw); ($w,$fw) = ($x,$fx); ($x,$fx) = ($u,$fu);
        } else {
            $u < $x ? ($a=$u) : ($b=$u);
            if ($fu <= $fw || $w==$x) { ($v,$fv)=($w,$fw); ($w,$fw)=($u,$fu); }
            elsif ($fu <= $fv || $v==$x || $v==$w) { ($v,$fv)=($u,$fu); }
        }
    }
    return ($x, $fx);
}

# --- Onedim ------------------------------------------------------------------
sub _onedim {
    my ($x) = @_;
    my @xt = ($x * $_xicom[0] + $_pcom[0], $x * $_xicom[1] + $_pcom[1]);
    return _get_func(@xt);
}

# --- Get_func ----------------------------------------------------------------
sub _get_func {
    my ($alk, $Ct) = @_;
    $alk = exp($alk); $Ct = exp($Ct);
    my $sum = 0.0;

    foreach my $ph (reverse sort { $a <=> $b } keys %_data) {
        next if ($_do_bicarb && $ph > $_bicarb_ph_upper);
        last if ($_do_bicarb && $ph < $_bicarb_ph_lower);
        next if ($_do_carb   && $ph > $_carb_ph_upper);
        last if ($_do_carb   && $ph < $_carb_ph_lower);
        my $H = 10.0 ** (-$ph);
        next if $H == 0.0;
        my $denom = $_acid_conc * $_cor_factor + $_Kw/$H - $H/$_gamma_H;
        next unless $denom;
        my $vol = $_volume / $denom
                  * ($alk - $Ct*($_K1*$H + 2.0*$_K1*$_K2)/($H*$H + $_K1*$H + $_K1*$_K2)
                     - $_Kw/$H + $H/$_gamma_H);
        $sum += ($vol - $_data{$ph}) ** 2;
    }
    return $sum;
}

# --- Regresión lineal ponderada (regression) ---------------------------------
sub _regression {
    my %xy = @_;
    my (@x, @y);
    for my $xv (sort { $a <=> $b } keys %xy) {
        push @x, $xv;
        push @y, $xy{$xv};
    }
    my $n = scalar @x;
    return (0, 0, 0) if $n < 2;

    my ($last_slope, $last_int, $last_r2, $last_endpt) = (0, 0, 0, 0.0001);
    my $done = 0;

    $n++;
    while (!$done) {
        $n--;
        last if $n < 2;
        my ($sumx, $sumy, $sumxy, $sumx2, $sumy2, $wn) = (0) x 6;
        for my $i (0..$n-1) {
            for my $j (0..$n-1-$i) {
                $wn++;
                $sumx  += $x[$i]; $sumy  += $y[$i];
                $sumxy += $x[$i]*$y[$i]; $sumx2 += $x[$i]*$x[$i];
                $sumy2 += $y[$i]*$y[$i];
            }
        }
        next unless $wn;
        my $slope = ($wn*$sumxy - $sumx*$sumy) / ($wn*$sumx2 - $sumx*$sumx);
        my $int   = $sumy/$wn - $slope*$sumx/$wn;
        my $endpt = $slope ? -$int/$slope : 0;
        my $r_denom = sqrt(($sumx2 - $sumx*$sumx/$wn) * ($sumy2 - $sumy*$sumy/$wn));
        my $r2 = $r_denom ? (($sumxy - $sumx*$sumy/$wn) / $r_denom) ** 2 : 0;

        if ($r2 < $last_r2) {
            return ($n+1, $last_slope, $last_int);
        } elsif ($r2 - $last_r2 < 0.01 && $last_endpt && abs($endpt-$last_endpt)/$last_endpt < 0.01) {
            return ($n, $slope, $int);
        }
        $done = 1 if $n == 2;
        ($last_r2, $last_endpt, $last_slope, $last_int) = ($r2, $endpt, $slope, $int);
    }
    return ($n, $last_slope, $last_int);
}

# --- Utilidades numéricas ----------------------------------------------------
sub _sign { $_[1] >= 0 ? abs($_[0]) : -abs($_[0]) }
sub _max  { $_[0] >= $_[1] ? $_[0] : $_[1] }
sub _r1   { sprintf("%.1f", $_[0] // 0) + 0 }
sub _r2   { sprintf("%.2f", $_[0] // 0) + 0 }

1;