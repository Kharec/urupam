use Test::More;
use Test::Mojo;
use Mojo::Promise;
use Urupam::App;

use_ok('Urupam::App');

package Mock::DB;
use Mojo::Base -base;
use Mojo::Promise;

has ping_cb => sub {
    sub { Mojo::Promise->resolve(1) }
};

sub ping {
    my ( $self, @args ) = @_;
    return $self->ping_cb->( $self, @args );
}

package Mock::Validator;
use Mojo::Base -base;

has validate_short_code_cb => sub {
    sub { 1 }
};

sub validate_short_code {
    my ( $self, $code ) = @_;
    return $self->validate_short_code_cb->( $self, $code );
}

package Mock::URLService;
use Mojo::Base -base;
use Mojo::Promise;

has get_original_url_cb => sub {
    sub { Mojo::Promise->resolve('https://example.com') }
};

sub get_original_url {
    my ( $self, $code ) = @_;
    return $self->get_original_url_cb->( $self, $code );
}

package main;

my $t           = Test::Mojo->new('Urupam::App');
my $db          = Mock::DB->new;
my $validator   = Mock::Validator->new;
my $url_service = Mock::URLService->new;

$t->app->helper( db          => sub { $db } );
$t->app->helper( validator   => sub { $validator } );
$t->app->helper( url_service => sub { $url_service } );

sub reset_mocks {
    $db->ping_cb( sub { Mojo::Promise->resolve(1) } );
    $validator->validate_short_code_cb( sub { 1 } );
    $url_service->get_original_url_cb(
        sub { Mojo::Promise->resolve('https://example.com') } );
}

subtest 'GET /health' => sub {
    reset_mocks();
    $t->get_ok('/health')->status_is(200)->json_is( '/status' => 'ok' );

    reset_mocks();
    $db->ping_cb( sub { Mojo::Promise->reject('boom') } );
    $t->get_ok('/health')
      ->status_is(503)
      ->json_is( '/status' => 'error' )
      ->json_is( '/error'  => 'Database connection failed' );
};

subtest 'GET / - index template' => sub {
    reset_mocks();
    $t->get_ok('/')->status_is(200)->content_like(qr/urupam/i);
};

subtest 'GET /:short_code' => sub {
    reset_mocks();
    $validator->validate_short_code_cb( sub { 0 } );
    $t->get_ok('/bad@code')->status_is(404)->content_like(qr/404 Not Found/);

    reset_mocks();
    $url_service->get_original_url_cb( sub { Mojo::Promise->resolve(undef) } );
    $t->get_ok('/AbCdEf123456')
      ->status_is(404)
      ->content_like(qr/404 Not Found/);

    reset_mocks();
    $t->get_ok('/AbCdEf123456')
      ->status_is(302)
      ->header_is( Location => 'https://example.com' );

    reset_mocks();
    $url_service->get_original_url_cb( sub { Mojo::Promise->reject('boom') } );
    $t->get_ok('/AbCdEf123456')
      ->status_is(500)
      ->content_like(qr/500 Internal Server Error/);
};

done_testing();
