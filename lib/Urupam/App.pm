package Urupam::App;

use Mojo::Base 'Mojolicious';
use Urupam::DB;

sub startup {
    my $self = shift;

    $self->helper(
        db => sub {
            my $c = shift;
            $c->stash->{db} ||= Urupam::DB->new;
        }
    );

    my $r = $self->routes;
    $r->get('/')->to(
        cb => sub {
            my $c  = shift;
            my $tx = $c->render_later->tx;
            my $db = $c->db;

            $db->set( 'test_key' => '123soleil' )->then(
                sub {
                    $c->app->log->info('Value set: test_key => 123soleil');
                    return $db->get('test_key');
                }
            )->then(
                sub {
                    my $value = shift;
                    $c->app->log->info("Value retrieved: $value");
                    $c->render( text => "ok\nRetrieved value: $value" );
                    undef $tx;
                }
            )->catch(
                sub {
                    my $err = shift;
                    $c->app->log->error("DB error: $err");
                    $c->render( text => "ok\nError: $err", status => 500 );
                    undef $tx;
                }
            );
        }
    );
}

1;

