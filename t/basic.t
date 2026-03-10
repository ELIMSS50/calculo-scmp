use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('CalculoSCMP');

# Tabla de titulación de ejemplo (basada en wellwater.dat, convertida a mL)
my @titulacion = (
    { ph => 6.65, volumen_acido => 0.000 },
    { ph => 6.46, volumen_acido => 0.200 },
    { ph => 6.34, volumen_acido => 0.325 },
    { ph => 6.19, volumen_acido => 0.475 },
    { ph => 6.04, volumen_acido => 0.625 },
    { ph => 5.89, volumen_acido => 0.750 },
    { ph => 5.75, volumen_acido => 0.850 },
    { ph => 5.59, volumen_acido => 0.938 },
    { ph => 5.44, volumen_acido => 1.000 },
    { ph => 5.25, volumen_acido => 1.063 },
    { ph => 4.99, volumen_acido => 1.114 },
    { ph => 4.74, volumen_acido => 1.143 },
    { ph => 4.41, volumen_acido => 1.169 },
    { ph => 4.34, volumen_acido => 1.175 },
    { ph => 4.27, volumen_acido => 1.181 },
    { ph => 4.21, volumen_acido => 1.188 },
    { ph => 4.13, volumen_acido => 1.194 },
    { ph => 4.07, volumen_acido => 1.200 },
);

# ---------------------------------------------------------------------------
# GET /health
# ---------------------------------------------------------------------------
$t->get_ok('/health')
  ->status_is(200)
  ->json_is('/status', 'ok');

# ---------------------------------------------------------------------------
# POST /calcular — caso completo con todos los métodos
# ---------------------------------------------------------------------------
$t->post_ok('/calcular', json => {
    volumen              => 50,
    concentracion_acido  => 0.160,
    temperatura          => 13.8,
    conductancia         => 350,
    factor_correccion    => 1.0,
    titulacion           => \@titulacion,
    metodos => {
        inflexion     => 1,
        endpoint_fijo => 1,
        ctc           => 1,
        gran          => 1,
    },
})
->status_is(200)
->json_has('/constantes')
->json_has('/constantes/log10_K1')
->json_has('/constantes/log10_K2')
->json_has('/constantes/log10_Kw')
->json_has('/constantes/fuerza_ionica')
->json_has('/especiacion_basica')
->json_has('/especiacion_basica/bicarbonato_mg_l')
->json_has('/especiacion_basica/carbonato_mg_l')
->json_has('/especiacion_basica/hidroxido_mg_l')
->json_has('/especiacion_basica/alcalinidad_mg_l')
->json_has('/inflexion')
->json_has('/inflexion/alcalinidad_mg_l')
->json_has('/inflexion/bicarbonato_mg_l')
->json_has('/endpoint_fijo')
->json_has('/endpoint_fijo/alcalinidad_mg_l')
->json_has('/ctc_1')
->json_has('/ctc_2')
->json_has('/gran')
->json_has('/gran/F1')
->json_has('/gran/F2')
->json_has('/gran/F3')
->json_has('/gran/F4')
->json_has('/advertencias');

# ---------------------------------------------------------------------------
# POST /calcular — solo con campos mínimos (defaults)
# ---------------------------------------------------------------------------
$t->post_ok('/calcular', json => {
    volumen             => 50,
    concentracion_acido => 0.160,
    titulacion          => \@titulacion,
})
->status_is(200)
->json_has('/constantes')
->json_has('/inflexion');

# ---------------------------------------------------------------------------
# POST /calcular — solo método inflexión
# ---------------------------------------------------------------------------
$t->post_ok('/calcular', json => {
    volumen             => 50,
    concentracion_acido => 0.160,
    titulacion          => \@titulacion,
    metodos => { inflexion => 1, endpoint_fijo => 0, ctc => 0, gran => 0 },
})
->status_is(200)
->json_has('/inflexion')
->json_is('/endpoint_fijo', undef)
->json_is('/ctc_1',         undef)
->json_is('/ctc_2',         undef)
->json_is('/gran',          undef);

# ---------------------------------------------------------------------------
# POST /calcular — errores de validación
# ---------------------------------------------------------------------------

# Sin cuerpo JSON
$t->post_ok('/calcular', json => undef)
  ->status_is(400)
  ->json_has('/error');

# Falta volumen
$t->post_ok('/calcular', json => {
    concentracion_acido => 0.160,
    titulacion          => \@titulacion,
})->status_is(400)->json_has('/error');

# Falta concentracion_acido
$t->post_ok('/calcular', json => {
    volumen    => 50,
    titulacion => \@titulacion,
})->status_is(400)->json_has('/error');

# Falta titulacion
$t->post_ok('/calcular', json => {
    volumen             => 50,
    concentracion_acido => 0.160,
})->status_is(400)->json_has('/error');

# Titulacion con menos de 2 puntos
$t->post_ok('/calcular', json => {
    volumen             => 50,
    concentracion_acido => 0.160,
    titulacion          => [{ ph => 7.0, volumen_acido => 0 }],
})->status_is(400)->json_has('/error');

# Primer punto sin volumen_acido = 0
$t->post_ok('/calcular', json => {
    volumen             => 50,
    concentracion_acido => 0.160,
    titulacion          => [
        { ph => 7.0, volumen_acido => 0.5 },
        { ph => 6.0, volumen_acido => 1.0 },
    ],
})->status_is(400)->json_has('/error');

# Volumen <= 0
$t->post_ok('/calcular', json => {
    volumen             => 0,
    concentracion_acido => 0.160,
    titulacion          => \@titulacion,
})->status_is(400)->json_has('/error');

# Factor de corrección fuera de rango
$t->post_ok('/calcular', json => {
    volumen              => 50,
    concentracion_acido  => 0.160,
    titulacion           => \@titulacion,
    factor_correccion    => 1.5,
})->status_is(400)->json_has('/error');

done_testing();