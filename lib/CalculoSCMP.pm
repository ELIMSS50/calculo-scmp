package CalculoSCMP;
use Mojo::Base 'Mojolicious', -signatures;

sub startup ($self) {

    # Configuración de hypnotoad
    $self->config(
        hypnotoad => {
            listen  => ['http://*:3000'],
            workers => 4,
        }
    );

    my $r = $self->routes;

    $r->get('/health')->to(cb => sub ($c) {
        $c->render(json => { status => 'ok' });
    });

    $r->post('/calcular')->to('Calculos#calcular');
}

1;