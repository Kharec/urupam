package Urupam::API;

use Mojo::Base 'Mojolicious::Controller';
use Urupam::Utils qw(sanitize_input get_error_status sanitize_error_message);

sub shorten {
    my $c = shift;
    $c->render_later;
    my $url_service = $c->url_service;
    my $validator   = $c->validator;

    my $json = $c->req->json;
    unless ( defined $json && ref $json eq 'HASH' ) {
        $c->render(
            json   => { error => 'Invalid JSON format' },
            status => 400
        );
        return;
    }

    my $original_url = sanitize_input( $json->{url} || '' );

    unless ($original_url) {
        $c->render(
            json   => { error => 'URL is required' },
            status => 400
        );
        return;
    }

    my $normalized_url;
    return $validator->validate_url_with_checks($original_url)->then(
        sub {
            my $sanitized_url = shift;
            $normalized_url = $sanitized_url;
            return $url_service->create_short_url($sanitized_url);
        }
    )->then(
        sub {
            my $short_code = shift;
            return if $c->rendered;
            my $short_url = $c->url_for("/$short_code")->to_abs;
            $c->render(
                json => {
                    success      => 1,
                    short_url    => $short_url,
                    short_code   => $short_code,
                    original_url => $normalized_url
                }
            );
        }
    )->catch(
        sub {
            my $err = shift;
            return if $c->rendered;
            $c->app->log->error("API URL validation/creation error: $err");
            my $status          = get_error_status($err);
            my $sanitized_error = sanitize_error_message($err);
            $c->render(
                json   => { error => $sanitized_error },
                status => $status
            );
        }
    );
}

sub get_url {
    my $c = shift;
    $c->render_later;
    my $short_code  = $c->param('short_code') // '';
    my $url_service = $c->url_service;
    my $validator   = $c->validator;

    unless ( $short_code && $validator->validate_short_code($short_code) ) {
        $c->render(
            json   => { error => 'Invalid short code format' },
            status => 400
        );
        return;
    }

    return $url_service->get_original_url($short_code)->then(
        sub {
            my $original_url = shift;
            return if $c->rendered;
            if ($original_url) {
                my $short_url = $c->url_for("/$short_code")->to_abs;
                $c->render(
                    json => {
                        success      => 1,
                        short_code   => $short_code,
                        original_url => $original_url,
                        short_url    => $short_url
                    }
                );
            }
            else {
                $c->render(
                    json   => { error => 'Short code not found' },
                    status => 404
                );
            }
        }
    )->catch(
        sub {
            my $err = shift;
            return if $c->rendered;
            $c->app->log->error("API URL retrieval error: $err");
            my $status          = get_error_status($err);
            my $sanitized_error = sanitize_error_message($err);
            $c->render(
                json   => { error => $sanitized_error },
                status => $status
            );
        }
    );
}

1;
