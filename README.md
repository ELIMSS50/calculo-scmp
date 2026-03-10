# calculo-scmp

Microservicio de cálculos de alcalinidad y especiación de carbonatos, desarrollado en Perl con Mojolicious. Basado en "The Alkalinity Calculator" de Stewart A. Rounds (USGS), GPLv2.

## Stack

- **Perl** + **Mojolicious** — API REST, puerto 3000
- **Docker** — despliegue en contenedor

## Métodos de análisis implementados

- **Inflexión** — endpoint por máxima pendiente de la curva de titulación
- **Endpoint fijo** — el usuario especifica el pH del endpoint (default: carbonato pH 8.3, bicarbonato pH 4.5)
- **CTC** — ajuste no-lineal de la curva teórica de carbonatos (método de Powell), dos variantes: por endpoint separado y por curva completa
- **Gran** — funciones lineales F1–F4 para extrapolación de endpoints

## Endpoints

### `GET /health`
Verifica que el servicio está activo.

```json
{ "status": "ok" }
```

### `POST /calcular`
Ejecuta los cálculos de alcalinidad sobre una curva de titulación.

**Body JSON:**
```json
{
  "volumen": 50,
  "concentracion_acido": 0.160,
  "temperatura": 13.8,
  "conductancia": 350,
  "factor_correccion": 1.0,
  "titulacion": [
    { "ph": 6.65, "volumen_acido": 0.000 },
    { "ph": 6.46, "volumen_acido": 0.200 },
    { "ph": 4.07, "volumen_acido": 1.200 }
  ],
  "metodos": {
    "inflexion": true,
    "endpoint_fijo": true,
    "ctc": true,
    "gran": true
  },
  "endpoint_carbonato": 8.3,
  "endpoint_bicarbonato": 4.5
}
```

| Campo | Tipo | Requerido | Default | Descripción |
|---|---|---|---|---|
| `volumen` | número | ✓ | — | Volumen de la muestra en mL |
| `concentracion_acido` | número | ✓ | — | Concentración del ácido titulante en eq/L |
| `titulacion` | array | ✓ | — | Pares pH/volumen, mín 2 puntos, primer punto con `volumen_acido: 0` |
| `temperatura` | número | | 20.0 | Temperatura en °C |
| `conductancia` | número | | 50.0 | Conductancia específica en µS/cm |
| `factor_correccion` | número | | 1.0 | Factor de corrección del ácido (0.8–1.2) |
| `metodos` | objeto | | todos true | Métodos a ejecutar |
| `endpoint_carbonato` | número | | 8.3 | pH del endpoint fijo de carbonato |
| `endpoint_bicarbonato` | número | | 4.5 | pH del endpoint fijo de bicarbonato |

**Respuesta:**
```json
{
  "constantes": {
    "log10_Kw": -14.36,
    "log10_K1": -6.40,
    "log10_K2": -10.35,
    "fuerza_ionica": 0.000207
  },
  "especiacion_basica": {
    "ph_inicial": 6.65,
    "alcalinidad_mg_l": 192.2,
    "alcalinidad_meq_l": 3.84,
    "bicarbonato_mg_l": 234.2,
    "bicarbonato_meq_l": 3.84,
    "carbonato_mg_l": 0.0,
    "carbonato_meq_l": 0.0,
    "hidroxido_mg_l": 0.0
  },
  "inflexion": { "...": "..." },
  "endpoint_fijo": { "...": "..." },
  "ctc_1": { "...": "..." },
  "ctc_2": { "...": "..." },
  "gran": { "F1": {}, "F2": {}, "F3": {}, "F4": {} },
  "advertencias": []
}
```

## Instalación y ejecución

### Con Docker
```bash
sudo docker build -t calculo-scmp .
sudo docker run -d --name calculo-scmp -p 3000:3000 calculo-scmp
```

### Sin Docker
```bash
cpanm --installdeps .
perl script/calculo_scmp daemon -l http://*:3000
```

## Prueba rápida

```bash
curl -s -X POST http://localhost:3000/calcular \
  -H "Content-Type: application/json" \
  -d @muestra.json | python3 -m json.tool
```

## Créditos

Algoritmos basados en **The Alkalinity Calculator** de Stewart A. Rounds, USGS — Oregon Water Science Center. Licencia GPLv2.
