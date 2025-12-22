package Urupam::App;

use Mojo::Base 'Mojolicious';
use Urupam::DB;
use Urupam::URL;
use Urupam::Validation;
use Urupam::API;

sub startup {
    my $self = shift;

    $self->helper(
        db => sub {
            my $c = shift;
            $c->stash->{db} ||= Urupam::DB->new;
        }
    );

    $self->helper(
        url_service => sub {
            my $c = shift;
            $c->stash->{url_service} ||= Urupam::URL->new( db => $c->db );
        }
    );

    $self->helper(
        validator => sub {
            my $c = shift;
            $c->stash->{validator} ||= Urupam::Validation->new;
        }
    );

    my $r   = $self->routes;
    my $api = $r->under('/api');
    $api->post('/shorten')->to(
        cb => sub {
            my $c = shift;
            bless $c, 'Urupam::API';
            $c->shorten;
        }
    );
    $api->get('/url')->to(
        cb => sub {
            my $c = shift;
            bless $c, 'Urupam::API';
            $c->get_url;
        }
    );

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
                    $c->render( json => { status => 'ok', value => $value } );
                    undef $tx;
                }
            )->catch(
                sub {
                    my $err = shift;
                    $c->app->log->error("DB error: $err");
                    $c->render(
                        json   => { status => 'error', message => "$err" },
                        status => 500
                    );
                    undef $tx;
                }
            );
        }
    );
}

1;
