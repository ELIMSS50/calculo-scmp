package CalculoSCMP;
use Mojo::Base 'Mojolicious', -signatures;

sub startup ($self) {

    # Configuración de hypnotoad
    #
    # Cada worker es un PROCESO separado: los cálculos concurrentes están
    # aislados entre sí a nivel de OS (además el controlador no usa estado
    # compartido). Si un worker se traba en un cálculo y deja de mandar
    # heartbeats, el manager lo detiene y levanta uno nuevo automáticamente:
    # la API sigue respondiendo aunque una petición se cuelgue.
    $self->config(
        hypnotoad => {
            listen  => ['http://*:3000'],
            workers => 4,
            heartbeat_interval => 5,    # el worker avisa "estoy vivo" cada 5s
            heartbeat_timeout  => 30,   # 30s sin heartbeat → stop graceful
            graceful_timeout   => 15,   # 15s más sin terminar → KILL forzado
        }
    );

    # Una titulación en JSON ocupa unos pocos KB; 1 MB de tope evita que un
    # body gigante ocupe memoria/CPU de un worker.
    $self->max_request_size(1_048_576);

    my $r = $self->routes;

    $r->get('/health')->to(cb => sub ($c) {
        $c->render(json => { status => 'ok' });
    });

    $r->post('/calcular')->to('Calculos#calcular');
}

1;