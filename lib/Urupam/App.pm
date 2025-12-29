package Urupam::App;

use Mojo::Base 'Mojolicious';
use Urupam::DB;
use Urupam::URL;
use Urupam::Validation;
use Urupam::API;
use Urupam::Version;

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
    $self->helper(
        version => sub {
            my $c = shift;
            $c->stash->{version} ||= Urupam::Version->new->get_version;
        }
    );

    my $r = $self->routes;

    $r->get('/health')->to(
        cb => sub {
            my $c = shift;
            $c->render_later;
            my $responded = 0;
            $c->db->ping->then(
                sub {
                    return if $responded;
                    $responded = 1;
                    $c->render(
                        json => {
                            status  => 'ok',
                            version => $c->version
                        }
                    );
                }
            )->catch(
                sub {
                    my $err = shift;
                    return if $responded;
                    $responded = 1;
                    $c->app->log->error("Health check DB error: $err");
                    $c->render(
                        json => {
                            status => 'error',
                            error  => 'Database connection failed'
                        },
                        status => 503
                    );
                }
            );
        }
    );
    $r->get('/')->to(
        cb => sub {
            my $c = shift;
            $c->render( template => 'index' );
        }
    );

    my $api_v1 = $r->under('/api/v1');
    $api_v1->post('/urls')->to(
        cb => sub {
            my $c = shift;
            bless $c, 'Urupam::API';
            $c->shorten;
        }
    );
    $api_v1->get('/urls/:short_code')->to(
        cb => sub {
            my $c = shift;
            bless $c, 'Urupam::API';
            $c->get_url;
        }
    );

    $r->get('/:short_code')->to(
        cb => sub {
            my $c = shift;
            $c->render_later;
            my $responded   = 0;
            my $short_code  = $c->param('short_code') // '';
            my $url_service = $c->url_service;
            my $validator   = $c->validator;

            unless ( $short_code
                && $validator->validate_short_code($short_code) )
            {
                return if $responded;
                $responded = 1;
                $c->render(
                    template => '404',
                    status   => 404
                );
                return;
            }

            return $url_service->get_original_url($short_code)->then(
                sub {
                    my $original_url = shift;
                    return if $responded;
                    $responded = 1;
                    if ($original_url) {
                        $c->redirect_to($original_url);
                    }
                    else {
                        $c->render(
                            template => '404',
                            status   => 404
                        );
                    }
                }
            )->catch(
                sub {
                    my $err = shift;
                    return if $responded;
                    $responded = 1;
                    $c->app->log->error("Redirect lookup error: $err");
                    $c->render(
                        template => '500',
                        status   => 500
                    );
                }
            );
        }
    );

}

1;
