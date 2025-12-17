package Urupam::App;

use Mojo::Base 'Mojolicious';
use Moose;

sub startup {
    my $self = shift;

    my $r = $self->routes;
    $r->get('/')->to(
        cb => sub {
            my $c = shift;
            $c->render( text => 'Hello from urupam!' );
        }
    );
}

1;

