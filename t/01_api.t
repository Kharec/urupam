use Test::More;
use Test::Mojo;
use Mojo::Promise;
use Urupam::App;

use_ok('Urupam::API');

package Mock::Validator;
use Mojo::Base -base;

has validate_url_cb => sub {
    sub { Mojo::Promise->resolve( $_[1] ) }
};
has validate_short_code_cb => sub {
    sub { 1 }
};

sub validate_url_with_checks {
    my ( $self, $url ) = @_;
    return $self->validate_url_cb->( $self, $url );
}

sub validate_short_code {
    my ( $self, $code ) = @_;
    return $self->validate_short_code_cb->( $self, $code );
}

package Mock::URLService;
use Mojo::Base -base;

has create_short_url_cb => sub {
    sub { Mojo::Promise->resolve('AbCdEf123456') }
};
has get_original_url_cb => sub {
    sub { Mojo::Promise->resolve('https://example.com') }
};

sub create_short_url {
    my ( $self, $url ) = @_;
    return $self->create_short_url_cb->( $self, $url );
}

sub get_original_url {
    my ( $self, $code ) = @_;
    return $self->get_original_url_cb->( $self, $code );
}

package main;

my $t           = Test::Mojo->new('Urupam::App');
my $validator   = Mock::Validator->new;
my $url_service = Mock::URLService->new;

$t->ua->server->url->scheme('http');
$t->ua->server->url->host('unit.test');
$t->ua->server->url->port(80);

$t->app->helper( validator   => sub { return $validator } );
$t->app->helper( url_service => sub { return $url_service } );

my ( $validated_url, $created_url, $validated_code, $get_code );
my ( $validator_called, $url_service_called );

sub reset_mocks {
    ( $validated_url, $created_url, $validated_code, $get_code ) = (undef) x 4;
    ( $validator_called, $url_service_called ) = ( 0, 0 );

    $validator->validate_url_cb(
        sub {
            my ( $self, $url ) = @_;
            $validator_called = 1;
            $validated_url    = $url;
            return Mojo::Promise->resolve($url);
        }
    );

    $validator->validate_short_code_cb(
        sub {
            my ( $self, $code ) = @_;
            $validated_code = $code;
            return 1;
        }
    );

    $url_service->create_short_url_cb(
        sub {
            my ( $self, $url ) = @_;
            $url_service_called = 1;
            $created_url        = $url;
            return Mojo::Promise->resolve('AbCdEf123456');
        }
    );

    $url_service->get_original_url_cb(
        sub {
            my ( $self, $code ) = @_;
            $url_service_called = 1;
            $get_code           = $code;
            return Mojo::Promise->resolve('https://example.com');
        }
    );
}

subtest 'POST /api/shorten - invalid JSON' => sub {
    reset_mocks();
    $t->post_ok(
        '/api/shorten' => { 'Content-Type' => 'application/json' } =>
          'invalid json' )
      ->status_is(400)
      ->json_is( '/error' => 'Invalid JSON format' );
    ok( !$validator_called,   'Validator not called for invalid JSON' );
    ok( !$url_service_called, 'URL service not called for invalid JSON' );
};

subtest 'POST /api/shorten - invalid JSON types' => sub {
    reset_mocks();
    $t->post_ok( '/api/shorten' => json => [] )
      ->status_is(400)
      ->json_is( '/error' => 'Invalid JSON format' );
    $t->post_ok( '/api/shorten' => json => 'not a hash' )
      ->status_is(400)
      ->json_is( '/error' => 'Invalid JSON format' );
    ok( !$validator_called,   'Validator not called for invalid JSON types' );
    ok( !$url_service_called, 'URL service not called for invalid JSON types' );
};

subtest 'POST /api/shorten - missing URL' => sub {
    reset_mocks();
    $t->post_ok( '/api/shorten' => json => {} )
      ->status_is(400)
      ->json_is( '/error' => 'URL is required' );
    ok( !$validator_called,   'Validator not called for missing URL' );
    ok( !$url_service_called, 'URL service not called for missing URL' );
};

subtest 'POST /api/shorten - whitespace URL' => sub {
    reset_mocks();
    $t->post_ok( '/api/shorten' => json => { url => '   ' } )
      ->status_is(400)
      ->json_is( '/error' => 'URL is required' );
    ok( !$validator_called,   'Validator not called for whitespace URL' );
    ok( !$url_service_called, 'URL service not called for whitespace URL' );
};

subtest 'POST /api/shorten - whitespace-only with tabs/newlines' => sub {
    reset_mocks();
    $t->post_ok( '/api/shorten' => json => { url => "\n\t " } )
      ->status_is(400)
      ->json_is( '/error' => 'URL is required' );
    ok( !$validator_called,   'Validator not called for tab/newline URL' );
    ok( !$url_service_called, 'URL service not called for tab/newline URL' );
};

subtest 'POST /api/shorten - success path' => sub {
    reset_mocks();
    my $tx = $t->post_ok(
        '/api/shorten' => json => { url => '  https://example.com/path  ' } );
    my $base_url = $t->ua->server->url->clone->path('')->to_abs;
    $tx->status_is(200)->json_is( '/success' => 1 );
    $tx->json_is( '/short_code'   => 'AbCdEf123456' );
    $tx->json_is( '/original_url' => 'https://example.com/path' );
    $tx->json_like( '/short_url' => qr{^\Q$base_url\EAbCdEf123456$} );
    ok( $validator_called,   'Validator called' );
    ok( $url_service_called, 'URL service called' );
    is( $validated_url, 'https://example.com/path',
        'URL sanitized before validation' );
    is( $created_url, 'https://example.com/path', 'URL passed to URL service' );
};

subtest 'POST /api/shorten - validator normalization' => sub {
    reset_mocks();
    $validator->validate_url_cb(
        sub {
            $validator_called = 1;
            return Mojo::Promise->resolve('http://normalized.test/path');
        }
    );
    $t->post_ok( '/api/shorten' => json => { url => 'normalized.test/path' } )
      ->status_is(200)
      ->json_is( '/short_code' => 'AbCdEf123456' );
    is( $created_url, 'http://normalized.test/path',
        'URL service receives normalized URL' );
};

subtest 'POST /api/shorten - validator error' => sub {
    reset_mocks();
    $validator->validate_url_cb(
        sub {
            $validator_called = 1;
            return Mojo::Promise->reject('SSL certificate error: bad cert');
        }
    );
    $t->post_ok( '/api/shorten' => json => { url => 'https://example.com' } )
      ->status_is(422)
      ->json_is( '/error' => 'SSL certificate error: bad cert' );
    ok( $validator_called,    'Validator called' );
    ok( !$url_service_called, 'URL service not called after validator error' );
};

subtest 'POST /api/shorten - error sanitization' => sub {
    reset_mocks();
    $url_service->create_short_url_cb(
        sub {
            $url_service_called = 1;
            return Mojo::Promise->reject("Database error: <bad>\n\t!!");
        }
    );
    $t->post_ok( '/api/shorten' => json => { url => 'https://example.com' } )
      ->status_is(400)
      ->json_is( '/error' => 'Database error: bad' );
    ok( $validator_called,   'Validator called' );
    ok( $url_service_called, 'URL service called' );
};

subtest 'POST /api/shorten - error sanitization truncation' => sub {
    reset_mocks();
    my $long_error = 'Database error: ' . ( 'a' x 210 );
    my $expected   = substr( $long_error, 0, 200 ) . '...';
    $url_service->create_short_url_cb(
        sub {
            $url_service_called = 1;
            return Mojo::Promise->reject($long_error);
        }
    );
    $t->post_ok( '/api/shorten' => json => { url => 'https://example.com' } )
      ->status_is(400)
      ->json_is( '/error' => $expected );
    ok( $validator_called,   'Validator called' );
    ok( $url_service_called, 'URL service called' );
};

subtest 'POST /api/shorten - URL service error' => sub {
    reset_mocks();
    $url_service->create_short_url_cb(
        sub {
            $url_service_called = 1;
            return Mojo::Promise->reject('Database error: connection failed');
        }
    );
    $t->post_ok( '/api/shorten' => json => { url => 'https://example.com' } )
      ->status_is(400)
      ->json_is( '/error' => 'Database error: connection failed' );
    ok( $validator_called,   'Validator called' );
    ok( $url_service_called, 'URL service called' );
};

subtest 'POST /api/shorten - status mapping for network error' => sub {
    reset_mocks();
    $validator->validate_url_cb(
        sub {
            $validator_called = 1;
            return Mojo::Promise->reject(
                'Cannot reach URL: Connection refused');
        }
    );
    $t->post_ok( '/api/shorten' => json => { url => 'https://example.com' } )
      ->status_is(422)
      ->json_is( '/error' => 'Cannot reach URL: Connection refused' );
    ok( $validator_called,    'Validator called' );
    ok( !$url_service_called, 'URL service not called after validator error' );
};

subtest 'GET /api/url - invalid short code format' => sub {
    reset_mocks();
    $validator->validate_short_code_cb( sub { 0 } );
    $t->get_ok('/api/url?short_code=bad@code')
      ->status_is(400)
      ->json_is( '/error' => 'Invalid short code format' );
    ok( !$url_service_called, 'URL service not called for invalid short code' );
};

subtest 'GET /api/url - missing short_code param' => sub {
    reset_mocks();
    $t->get_ok('/api/url')
      ->status_is(400)
      ->json_is( '/error' => 'Invalid short code format' );
    ok( !$url_service_called, 'URL service not called for missing short_code' );
};

subtest 'GET /api/url - empty short_code param' => sub {
    reset_mocks();
    $t->get_ok('/api/url?short_code=')
      ->status_is(400)
      ->json_is( '/error' => 'Invalid short code format' );
    ok( !$url_service_called, 'URL service not called for empty short_code' );
};

subtest 'GET /api/url - not found' => sub {
    reset_mocks();
    $url_service->get_original_url_cb(
        sub {
            $url_service_called = 1;
            return Mojo::Promise->resolve(undef);
        }
    );
    $t->get_ok('/api/url?short_code=AbCdEf123456')
      ->status_is(404)
      ->json_is( '/error' => 'Short code not found' );
    ok( $url_service_called, 'URL service called' );
};

subtest 'GET /api/url - success path' => sub {
    reset_mocks();
    my $base_url = $t->ua->server->url->clone->path('')->to_abs;
    $t->get_ok('/api/url?short_code=AbCdEf123456')
      ->status_is(200)
      ->json_is( '/success'      => 1 )
      ->json_is( '/short_code'   => 'AbCdEf123456' )
      ->json_is( '/original_url' => 'https://example.com' )
      ->json_like( '/short_url' => qr{^\Q$base_url\EAbCdEf123456$} );
    ok( $url_service_called, 'URL service called' );
    is( $validated_code, 'AbCdEf123456', 'Short code validated' );
    is( $get_code,       'AbCdEf123456', 'Short code passed to URL service' );
};

subtest 'GET /api/url - URL service error' => sub {
    reset_mocks();
    $url_service->get_original_url_cb(
        sub {
            $url_service_called = 1;
            return Mojo::Promise->reject('DNS resolution failed: timeout');
        }
    );
    $t->get_ok('/api/url?short_code=AbCdEf123456')
      ->status_is(422)
      ->json_is( '/error' => 'DNS resolution failed: timeout' );
    ok( $url_service_called, 'URL service called' );
};

subtest 'GET /api/url - non-422 error mapping' => sub {
    reset_mocks();
    $url_service->get_original_url_cb(
        sub {
            $url_service_called = 1;
            return Mojo::Promise->reject('Database error: connection failed');
        }
    );
    $t->get_ok('/api/url?short_code=AbCdEf123456')
      ->status_is(400)
      ->json_is( '/error' => 'Database error: connection failed' );
    ok( $url_service_called, 'URL service called' );
};

done_testing();
