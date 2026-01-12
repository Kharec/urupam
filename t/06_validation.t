use Test::More;
use Test::MockObject;
use Mojo::Promise;
use Urupam::Validation;
use Socket qw(AF_INET);

use_ok('Urupam::Validation');

my $validator = Urupam::Validation->new;

sub wait_promise {
    my ($promise) = @_;
    my ( $value, $error );
    $promise->then( sub { $value = shift } )
      ->catch( sub { $error = shift } )
      ->wait;
    return ( $value, $error );
}

sub mock_ua_with_code {
    my ($code)          = @_;
    my $mock_ua         = Test::MockObject->new;
    my $mock_tx         = Test::MockObject->new;
    my $mock_result     = Test::MockObject->new;
    my $mock_get_tx     = Test::MockObject->new;
    my $mock_get_result = Test::MockObject->new;

    $mock_result->mock( 'code', sub { $code } );
    $mock_tx->mock( 'result', sub { $mock_result } );
    $mock_get_result->mock( 'code', sub { $code } );
    $mock_get_tx->mock( 'result', sub { $mock_get_result } );
    $mock_ua->mock(
        'head_p',
        sub {
            return Mojo::Promise->resolve($mock_tx);
        }
    );
    $mock_ua->mock(
        'get_p',
        sub {
            return Mojo::Promise->resolve($mock_get_tx);
        }
    );

    return $mock_ua;
}

sub mock_ua_with_error {
    my ($error) = @_;
    my $mock_ua = Test::MockObject->new;
    $mock_ua->mock(
        'head_p',
        sub {
            return Mojo::Promise->reject($error);
        }
    );
    $mock_ua->mock(
        'get_p',
        sub {
            return Mojo::Promise->reject($error);
        }
    );
    return $mock_ua;
}

sub with_resolved_addresses {
    my ( $addresses, $code ) = @_;
    no warnings 'redefine';
    local *Urupam::Validation::_resolve_host = sub {
        return Mojo::Promise->resolve($addresses);
    };
    return $code->();
}

sub with_ssrf_ua {
    my ( $ua, $code ) = @_;
    no warnings 'redefine';
    local *Urupam::Validation::_create_ssrf_safe_ua = sub {
        return $ua;
    };
    return $code->();
}

sub with_subprocess_stub {
    my ( $result, $code, $calls_ref ) = @_;
    no warnings 'redefine';
    local *Mojo::IOLoop::subprocess = sub {
        my ( $class, $work, $finish, $host ) = @_;
        $$calls_ref++ if defined $calls_ref;
        $finish->( undef, undef, $result );
        return;
    };
    return $code->();
}

sub clear_validation_caches {
    $validator->_clear_caches;
}

subtest 'is_valid_url_length' => sub {
    ok( $validator->is_valid_url_length('http://example.com'),
        'valid URL length passes' );
    ok( !$validator->is_valid_url_length(undef), 'undef fails length check' );
    ok(
        !$validator->is_valid_url_length(''),
        'empty string fails length check'
    );
    ok( $validator->is_valid_url_length( 'a' x 2048 ),
        'exactly 2048 characters passes' );
    ok( !$validator->is_valid_url_length( 'a' x 2049 ),
        '2049 characters fails' );
    ok(
        $validator->is_valid_url_length(
            'http://example.com/' . ( 'a' x 2000 )
        ),
        'long URL within limit passes'
    );
};

subtest '_classify_error' => sub {
    is( $validator->_classify_error('SSL certificate verification failed'),
        'ssl', 'classifies SSL errors' );
    is( $validator->_classify_error('Name or service not known'),
        'dns', 'classifies DNS errors' );
    is( $validator->_classify_error('Connection refused'),
        'connection', 'classifies connection errors' );
    is( $validator->_classify_error('unexpected failure'),
        'unknown', 'classifies unknown errors' );
};

subtest '_format_error_message' => sub {
    is(
        $validator->_format_error_message( 'ssl', 'bad cert' ),
        'SSL certificate error: bad cert',
        'formats SSL errors'
    );
    is(
        $validator->_format_error_message( 'dns', 'timeout' ),
        'DNS resolution failed: timeout',
        'formats DNS errors'
    );
    is(
        $validator->_format_error_message( 'connection', 'refused' ),
        'Cannot reach URL: refused',
        'formats connection errors'
    );
    is(
        $validator->_format_error_message( 'unknown', 'oops' ),
        'URL validation failed: oops',
        'formats unknown errors'
    );
};

subtest 'classify and format error string' => sub {
    my @cases = (
        [
            'SSL certificate verification failed',
            'SSL certificate error: SSL certificate verification failed',
            'ssl error classified and formatted'
        ],
        [
            'Name or service not known',
            'DNS resolution failed: Name or service not known',
            'dns error classified and formatted'
        ],
        [
            'Connection refused',
            'Cannot reach URL: Connection refused',
            'connection error classified and formatted'
        ],
        [
            'Some unknown error',
            'URL validation failed: Some unknown error',
            'unknown error classified and formatted'
        ],
    );

    for my $case (@cases) {
        my ( $err, $expected, $label ) = @$case;
        my $type = $validator->_classify_error($err);
        is( $validator->_format_error_message( $type, $err ),
            $expected, $label );
    }
};

subtest '_is_valid_ipv4' => sub {
    my @valid = (
        [ '192.168.1.1',     'valid IPv4 passes' ],
        [ '0.0.0.0',         '0.0.0.0 is valid' ],
        [ '255.255.255.255', '255.255.255.255 is valid' ],
    );
    my @invalid = (
        [ '256.1.1.1',         'octet > 255 fails' ],
        [ '192.168.1',         'missing octet fails' ],
        [ '192.168.1.1.1',     'extra octet fails' ],
        [ 'not.an.ip.address', 'non-numeric fails' ],
        [ '192.168.-1.1',      'negative octet fails' ],
    );

    for my $case (@valid) {
        ok( $validator->_is_valid_ipv4( $case->[0] ), $case->[1] );
    }

    for my $case (@invalid) {
        ok( !$validator->_is_valid_ipv4( $case->[0] ), $case->[1] );
    }

    ok( !$validator->_is_valid_ipv4(undef), 'undef fails' );
};

subtest '_is_private_ipv4' => sub {
    my @private = (
        [ '127.0.0.1',      '127.0.0.1 is private' ],
        [ '192.168.1.1',    '192.168.x.x is private' ],
        [ '10.0.0.1',       '10.x.x.x is private' ],
        [ '172.16.0.1',     '172.16.x.x is private' ],
        [ '172.31.255.255', '172.31.x.x is private' ],
    );
    my @public = (
        [ '172.15.0.1', '172.15.x.x is not private' ],
        [ '172.32.0.1', '172.32.x.x is not private' ],
        [ '8.8.8.8',    '8.8.8.8 is not private' ],
        [ 'invalid',    'invalid IP is not private' ],
    );

    for my $case (@private) {
        ok( $validator->_is_private_ipv4( $case->[0] ), $case->[1] );
    }

    for my $case (@public) {
        ok( !$validator->_is_private_ipv4( $case->[0] ), $case->[1] );
    }
};

subtest '_is_private_ipv6' => sub {
    my @private = (
        [ '::1',                   '::1 is private' ],
        [ '[::1]',                 '[::1] is private' ],
        [ '::',                    ':: is private' ],
        [ '::ffff:127.0.0.1',      '::ffff:127.0.0.1 is private' ],
        [ '::ffff:192.168.1.1',    '::ffff:192.168.1.1 is private' ],
        [ '::ffff:10.0.0.1',       '::ffff:10.0.0.1 is private' ],
        [ '::ffff:172.16.0.1',     '::ffff:172.16.0.1 is private' ],
        [ 'fc00:0:0:0:0:0:0:1',    'fc00::/7 (unique local) is private' ],
        [ 'fcff:0:0:0:0:0:0:1',    'fc00::/7 (unique local) is private' ],
        [ 'fd00:0:0:0:0:0:0:1',    'fc00::/7 (unique local) is private' ],
        [ 'fdff:0:0:0:0:0:0:1',    'fc00::/7 (unique local) is private' ],
        [ 'fe80:0:0:0:0:0:0:1',    'fe80::/10 (link-local) is private' ],
        [ 'fe80:0:0:0:0:0:0:abcd', 'fe80::/10 (link-local) is private' ],
        [ 'febf:0:0:0:0:0:0:1',    'fe80::/10 (link-local) is private' ],
    );
    my @public = (
        [ '2001:db8::1',    '2001:db8::1 is not private' ],
        [ '::ffff:8.8.8.8', '::ffff:8.8.8.8 is not private' ],
        [ 'fec0::1', 'fec0:: is not private (deprecated, but not blocked)' ],
        [ 'fec1::1', 'fec1:: is not private' ],
        [ 'invalid', 'invalid IPv6 is not private' ],
    );

    for my $case (@private) {
        ok( $validator->_is_private_ipv6( $case->[0] ), $case->[1] );
    }

    for my $case (@public) {
        ok( !$validator->_is_private_ipv6( $case->[0] ), $case->[1] );
    }
};

subtest 'is_blocked_url' => sub {
    my @blocked = (
        [ 'http://localhost/path',   'localhost is blocked' ],
        [ 'http://127.0.0.1/path',   '127.0.0.1 is blocked' ],
        [ 'http://0.0.0.0/path',     '0.0.0.0 is blocked' ],
        [ 'http://[::1]/path',       '::1 is blocked' ],
        [ 'http://[::]/path',        ':: is blocked' ],
        [ 'http://192.168.1.1/path', '192.168.1.1 is blocked' ],
        [ 'http://10.0.0.1/path',    '10.0.0.1 is blocked' ],
        [ 'http://172.16.0.1/path',  '172.16.0.1 is blocked' ],
        [
            'http://[fc00:0:0:0:0:0:0:1]/path',
            'fc00::/7 (unique local) is blocked'
        ],
        [
            'http://[fd00:0:0:0:0:0:0:1]/path',
            'fc00::/7 (unique local) is blocked'
        ],
        [
            'http://[fe80:0:0:0:0:0:0:1]/path',
            'fe80::/10 (link-local) is blocked'
        ],
        [
            'http://[febf:0:0:0:0:0:0:1]/path',
            'fe80::/10 (link-local) is blocked'
        ],
    );
    my @allowed = (
        [ 'http://example.com/path', 'public domain is not blocked' ],
        [ 'http://8.8.8.8/path',     'public IP is not blocked' ],
        [ 'invalid url',             'invalid URL is not blocked' ],
        [ undef,                     'undef is not blocked' ],
    );

    with_resolved_addresses(
        [],
        sub {
            for my $case (@blocked) {
                my ( $result, $error ) =
                  wait_promise( $validator->is_blocked_url( $case->[0] ) );
                ok( $result, $case->[1] );
                is( $error, undef, "no error for $case->[1]" );
            }

            for my $case (@allowed) {
                my ( $result, $error ) =
                  wait_promise( $validator->is_blocked_url( $case->[0] ) );
                ok( !$result, $case->[1] );
                is( $error, undef, "no error for $case->[1]" );
            }
        }
    );
};

subtest '_resolve_host - caches results' => sub {
    my $calls  = 0;
    my $result = {
        error   => 0,
        results => [ { addr => '127.0.0.1', family => AF_INET } ],
    };

    with_subprocess_stub(
        $result,
        sub {
            my ( $value, $error ) =
              wait_promise( $validator->_resolve_host('example.com') );
            is( $error,         undef, 'first resolve has no error' );
            is( scalar @$value, 1,     'first resolve returns one address' );
        },
        \$calls
    );

    with_subprocess_stub(
        $result,
        sub {
            my ( $value, $error ) =
              wait_promise( $validator->_resolve_host('example.com') );
            is( $error,         undef, 'cached resolve has no error' );
            is( scalar @$value, 1,     'cached resolve returns one address' );
        },
        \$calls
    );

    is( $calls, 1, 'subprocess called once due to cache' );
};

subtest 'validate_short_code' => sub {
    my @valid = (
        [ 'abc123456789', 'alphanumeric code passes' ],
        [ 'ABC123456789', 'uppercase code passes' ],
        [ 'ab-123456789', 'code with dash passes' ],
        [ 'ab_123456789', 'code with underscore passes' ],
        [ '0123456789ab', '12 character code passes' ],
    );
    my @invalid = (
        [ 'abc@12345678',       'code with @ fails' ],
        [ 'abc.12345678',       'code with dot fails' ],
        [ 'abc 12345678',       'code with space fails' ],
        [ 'abc123',             'code too short fails' ],
        [ 'a',                  'single character fails' ],
        [ 'abc123456789012345', 'code too long fails' ],
        [ '',                   'empty code fails' ],
        [ undef,                'undef code fails' ],
    );

    for my $case (@valid) {
        ok( $validator->validate_short_code( $case->[0] ), $case->[1] );
    }

    for my $case (@invalid) {
        ok( !$validator->validate_short_code( $case->[0] ), $case->[1] );
    }
};

subtest 'check_url_reachable - success codes' => sub {
    clear_validation_caches();
    for my $code ( 200, 201 ) {
        with_ssrf_ua(
            mock_ua_with_code($code),
            sub {
                my ( $result, $error ) = wait_promise(
                    $validator->check_url_reachable('http://example.com') );
                is( $result, 1,     "$code status returns 1" );
                is( $error,  undef, "$code status has no error" );
            }
        );
    }
};

subtest 'check_url_reachable - error codes' => sub {
    clear_validation_caches();
    my @cases = (
        [ 410, qr/URL returned 410 error/, '4xx status returns error' ],
        [ 500, qr/URL returned 500 error/, '5xx status returns error' ],
        [ 100, qr/unexpected status/,      'unexpected status returns error' ],
    );

    for my $case (@cases) {
        my $url = "http://example.com/$case->[0]";
        with_ssrf_ua(
            mock_ua_with_code( $case->[0] ),
            sub {
                my ( $result, $error ) =
                  wait_promise( $validator->check_url_reachable($url) );
                is( $result, undef, "$case->[0] status has no result" );
                like( $error, $case->[1], $case->[2] );
            }
        );
    }
};

subtest 'check_url_reachable - HEAD fallback to GET' => sub {
    clear_validation_caches();
    my $mock_ua     = Test::MockObject->new;
    my $head_tx     = Test::MockObject->new;
    my $head_result = Test::MockObject->new;
    my $get_tx      = Test::MockObject->new;
    my $get_result  = Test::MockObject->new;

    $head_result->mock( 'code', sub { 404 } );
    $head_tx->mock( 'result', sub { $head_result } );

    $get_result->mock( 'code', sub { 200 } );
    $get_tx->mock( 'result', sub { $get_result } );

    $mock_ua->mock(
        'head_p',
        sub {
            return Mojo::Promise->resolve($head_tx);
        }
    );
    $mock_ua->mock(
        'get_p',
        sub {
            return Mojo::Promise->resolve($get_tx);
        }
    );

    my ( $result, $error );
    with_ssrf_ua(
        $mock_ua,
        sub {
            ( $result, $error ) = wait_promise(
                $validator->check_url_reachable('http://example.com') );
        }
    );

    is( $result, 1,     'GET fallback returns success' );
    is( $error,  undef, 'GET fallback has no error' );
};

subtest 'check_url_reachable - HEAD fallback error' => sub {
    clear_validation_caches();
    my $mock_ua     = Test::MockObject->new;
    my $head_tx     = Test::MockObject->new;
    my $head_result = Test::MockObject->new;
    my $get_tx      = Test::MockObject->new;
    my $get_result  = Test::MockObject->new;

    $head_result->mock( 'code', sub { 405 } );
    $head_tx->mock( 'result', sub { $head_result } );

    $get_result->mock( 'code', sub { 500 } );
    $get_tx->mock( 'result', sub { $get_result } );

    $mock_ua->mock(
        'head_p',
        sub {
            return Mojo::Promise->resolve($head_tx);
        }
    );
    $mock_ua->mock(
        'get_p',
        sub {
            return Mojo::Promise->resolve($get_tx);
        }
    );

    my ( $result, $error );
    with_ssrf_ua(
        $mock_ua,
        sub {
            ( $result, $error ) = wait_promise(
                $validator->check_url_reachable('http://example.com') );
        }
    );

    is( $result, undef, 'GET fallback error has no result' );
    like( $error, qr/URL returned 500 error/, 'GET fallback error reported' );
};

subtest 'check_url_reachable - classified errors' => sub {
    clear_validation_caches();
    my @cases = (
        [
            'Name or service not known',
            qr/DNS resolution failed/,
            'DNS error is classified'
        ],
        [
            'SSL certificate verification failed',
            qr/SSL certificate error/,
            'SSL error is classified'
        ],
        [
            'Connection refused',
            qr/Cannot reach URL/,
            'connection error is classified'
        ],
        [
            'Some unknown error',
            qr/URL validation failed/,
            'unknown error is classified'
        ],
    );

    for my $case (@cases) {
        clear_validation_caches();
        with_ssrf_ua(
            mock_ua_with_error( $case->[0] ),
            sub {
                my ( $result, $error ) = wait_promise(
                    $validator->check_url_reachable('http://example.com') );
                is( $result, undef, 'no success result' );
                like( $error, $case->[1], $case->[2] );
            }
        );
    }
};

subtest 'check_url_reachable - missing URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->check_url_reachable(undef) );

    is( $result, undef,             'missing URL has no result' );
    is( $error,  'URL is required', 'missing URL returns error' );
};

subtest 'check_url_reachable - empty URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->check_url_reachable('') );

    is( $result, undef,             'empty URL has no result' );
    is( $error,  'URL is required', 'empty URL returns error' );
};

subtest 'check_ssl_certificate - non-HTTPS URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate('http://example.com') );

    is( $result, 1,     'non-HTTPS URL passes without check' );
    is( $error,  undef, 'non-HTTPS URL has no error' );
};

subtest 'check_ssl_certificate - HTTPS success' => sub {
    $validator->ua( mock_ua_with_code(200) );
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate('https://example.com') );

    is( $result, 1,     'valid SSL certificate passes' );
    is( $error,  undef, 'valid SSL certificate has no error' );
};

subtest 'check_ssl_certificate - SSL error' => sub {
    $validator->ua( mock_ua_with_error('SSL certificate verification failed') );
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate('https://example.com') );

    is( $result, 1,     'SSL error is async' );
    is( $error,  undef, 'SSL error has no error' );
};

subtest 'check_ssl_certificate - non-SSL error' => sub {
    $validator->ua( mock_ua_with_error('Connection refused') );
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate('https://example.com') );

    is( $result, 1,     'non-SSL error is async' );
    is( $error,  undef, 'non-SSL error has no error' );
};

subtest 'check_ssl_certificate - DNS error' => sub {
    $validator->ua( mock_ua_with_error('Name or service not known') );
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate('https://example.com') );

    is( $result, 1,     'DNS error is async' );
    is( $error,  undef, 'DNS error has no error' );
};

subtest 'check_ssl_certificate - unknown error' => sub {
    $validator->ua( mock_ua_with_error('Some unknown error') );
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate('https://example.com') );

    is( $result, 1,     'unknown error is async' );
    is( $error,  undef, 'unknown error has no error' );
};

subtest 'check_ssl_certificate - missing URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate(undef) );

    is( $result, 1,     'missing URL passes' );
    is( $error,  undef, 'missing URL has no error' );
};

subtest 'check_ssl_certificate - empty URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->check_ssl_certificate('') );

    is( $result, 1,     'empty URL passes' );
    is( $error,  undef, 'empty URL has no error' );
};

subtest 'validate_url_with_checks - missing URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->validate_url_with_checks(undef) );

    is( $result, undef,             'missing URL has no result' );
    is( $error,  'URL is required', 'missing URL returns error' );
};

subtest 'validate_url_with_checks - empty URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->validate_url_with_checks('') );

    is( $result, undef,             'empty URL has no result' );
    is( $error,  'URL is required', 'empty URL returns error' );
};

subtest 'validate_url_with_checks - invalid URL format' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->validate_url_with_checks('not a url') );

    is( $result, undef,                'invalid format has no result' );
    is( $error,  'Invalid URL format', 'invalid URL format returns error' );
};

subtest 'validate_url_with_checks - invalid scheme' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->validate_url_with_checks('ftp://example.com') );

    is( $result, undef,                'invalid scheme has no result' );
    is( $error,  'Invalid URL format', 'invalid scheme returns error' );
};

subtest 'validate_url_with_checks - missing host' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->validate_url_with_checks('http://') );

    is( $result, undef,                'missing host has no result' );
    is( $error,  'Invalid URL format', 'missing host returns error' );
};

subtest 'validate_url_with_checks - URL too long' => sub {
    my $long_url = 'http://example.com/' . ( 'a' x 2049 );
    my ( $result, $error ) =
      wait_promise( $validator->validate_url_with_checks($long_url) );

    is( $result, undef, 'URL too long has no result' );
    like( $error, qr/exceeds maximum length/, 'URL too long returns error' );
};

subtest 'validate_url_with_checks - blocked URL' => sub {
    my ( $result, $error ) =
      wait_promise(
        $validator->validate_url_with_checks('http://localhost/path') );

    is( $result, undef, 'blocked URL has no result' );
    like( $error, qr/cannot be shortened/, 'blocked URL returns error' );
};

subtest 'validate_url_with_checks - blocked IPv6 URL' => sub {
    my ( $result, $error ) =
      wait_promise( $validator->validate_url_with_checks('http://[::1]/path') );

    is( $result, undef, 'blocked IPv6 URL has no result' );
    like( $error, qr/cannot be shortened/, 'blocked IPv6 URL returns error' );
};

subtest 'validate_url_with_checks - HTTP success' => sub {
    $validator->ua( mock_ua_with_code(200) );
    my ( $result, $error );
    with_resolved_addresses(
        [],
        sub {
            with_ssrf_ua(
                mock_ua_with_code(200),
                sub {
                    ( $result, $error ) = wait_promise(
                        $validator->validate_url_with_checks(
                            'http://example.com/path')
                    );
                }
            );
        }
    );

    is( $result, 'http://example.com/path', 'valid HTTP URL passes' );
    is( $error,  undef,                     'valid HTTP URL has no error' );
};

subtest 'validate_url_with_checks - HTTPS success' => sub {
    $validator->ua( mock_ua_with_code(200) );
    my ( $result, $error );
    with_resolved_addresses(
        [],
        sub {
            with_ssrf_ua(
                mock_ua_with_code(200),
                sub {
                    ( $result, $error ) = wait_promise(
                        $validator->validate_url_with_checks(
                            'https://example.com/path')
                    );
                }
            );
        }
    );

    is( $result, 'https://example.com/path', 'valid HTTPS URL passes' );
    is( $error,  undef,                      'valid HTTPS URL has no error' );
};

subtest 'validate_url_with_checks - URL sanitization' => sub {
    $validator->ua( mock_ua_with_code(200) );
    my ( $result, $error );
    with_resolved_addresses(
        [],
        sub {
            with_ssrf_ua(
                mock_ua_with_code(200),
                sub {
                    ( $result, $error ) = wait_promise(
                        $validator->validate_url_with_checks(
                            'example.com/path')
                    );
                }
            );
        }
    );

    is( $result, 'http://example.com/path', 'URL is sanitized' );
    is( $error,  undef,                     'URL sanitization has no error' );
};

subtest 'validate_url_with_checks - SSL check failure' => sub {
    $validator->ua( mock_ua_with_error('SSL certificate verification failed') );
    my ( $result, $error );
    with_resolved_addresses(
        [],
        sub {
            with_ssrf_ua(
                mock_ua_with_code(200),
                sub {
                    ( $result, $error ) = wait_promise(
                        $validator->validate_url_with_checks(
                            'https://example.com')
                    );
                }
            );
        }
    );

    is( $result, 'https://example.com', 'SSL check failure is async' );
    is( $error,  undef,                 'SSL check async has no error' );
};

subtest 'validate_url_with_checks - reachability check failure' => sub {
    my $mock_ua     = Test::MockObject->new;
    my $mock_tx     = Test::MockObject->new;
    my $mock_result = Test::MockObject->new;
    my $call_count  = 0;

    $mock_result->mock( 'code', sub { 200 } );
    $mock_tx->mock( 'result', sub { $mock_result } );
    $mock_ua->mock(
        'head_p',
        sub {
            $call_count++;
            return $call_count == 1
              ? Mojo::Promise->resolve($mock_tx)
              : Mojo::Promise->reject('Connection refused');
        }
    );

    $validator->ua($mock_ua);

    my ( $result, $error );
    with_resolved_addresses(
        [],
        sub {
            with_ssrf_ua(
                $mock_ua,
                sub {
                    ( $result, $error ) = wait_promise(
                        $validator->validate_url_with_checks(
                            'https://example.com')
                    );
                }
            );
        }
    );

    is( $result, 'https://example.com', 'reachability failure is async' );
    is( $error,  undef,                 'reachability async has no error' );
};

done_testing();
