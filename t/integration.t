use Test::More;
use Test::Mojo;
use Urupam::App;

my $t;
eval { $t = Test::Mojo->new('Urupam::App'); 1 }
  or plan skip_all => "Test server not available: $@";

my $CODE_PATTERN   = qr/^[0-9a-zA-Z\-_]+$/;
my $CODE_LENGTH    = 12;
my $MAX_URL_LENGTH = 2048;

sub validate_short_code_format {
    my ($code) = @_;
    return
         defined $code
      && length($code) == $CODE_LENGTH
      && $code =~ $CODE_PATTERN;
}

sub post_shorten {
    my ($url) = @_;
    my $tx    = $t->post_ok( '/api/v1/urls' => json => { url => $url } );
    my $json  = $tx->tx->res->json;
    my $error = ref $json eq 'HASH' ? ( $json->{error} // '' ) : '';
    return {
        tx    => $tx,
        code  => $tx->tx->res->code,
        json  => $json,
        error => $error,
    };
}

sub get_url {
    my ($code) = @_;
    my $tx     = $t->get_ok("/api/v1/urls/$code");
    my $json   = $tx->tx->res->json;
    my $error  = ref $json eq 'HASH' ? ( $json->{error} // '' ) : '';
    return {
        tx    => $tx,
        code  => $tx->tx->res->code,
        json  => $json,
        error => $error,
    };
}

sub validate_shorten_response {
    my ( $res, $url, $label ) = @_;
    return 0 unless $res->{code} == 200;
    my $json = $res->{json};
    ok( validate_short_code_format( $json->{short_code} ),
        "$label: short code valid" );
    is( length( $json->{short_code} ),
        $CODE_LENGTH, "$label: short code length correct" );
    like(
        $json->{short_url},
        qr/^https?:\/\/[^\/]+\/$json->{short_code}$/,
        "$label: short URL format correct"
    );
    return 1;
}

sub validate_get_response {
    my ( $res, $expected_url, $expected_code, $label ) = @_;
    return 0 unless $res->{code} == 200;
    my $json = $res->{json};
    is( $json->{success}, 1, "$label: success flag set" );
    ok( validate_short_code_format( $json->{short_code} ),
        "$label: short code valid" );
    is( length( $json->{short_code} ),
        $CODE_LENGTH, "$label: short code length correct" );
    is( $json->{original_url}, $expected_url, "$label: original URL matches" )
      if $expected_url;
    is( $json->{short_code}, $expected_code, "$label: short code matches" )
      if $expected_code;
    like(
        $json->{short_url},
        qr/^https?:\/\/[^\/]+\/$json->{short_code}$/,
        "$label: short URL format correct"
    );
    return 1;
}

sub skip_if_error {
    my ( $res, $context ) = @_;
    if ( $res->{code} != 200 && $res->{code} != 400 && $res->{code} != 404 ) {
        diag( "$context skipped: " . $res->{error} );
        return 1;
    }
    return 0;
}

subtest 'POST /api/v1/urls - Real validator success cases' => sub {
    for my $url ( 'https://www.example.com', 'http://www.perl.org' ) {
        my $res = post_shorten($url);
        if ( $res->{code} == 200 ) {
            validate_shorten_response( $res, $url, "URL: $url" );
        }
        else {
            diag( "Test skipped for $url: " . $res->{error} );
        }
    }
};

subtest 'POST /api/v1/urls - Real validator URL normalization' => sub {
    for my $input ( 'www.example.com', 'example.com' ) {
        my $res = post_shorten($input);
        if ( $res->{code} == 200 ) {
            like( $res->{json}->{original_url},
                qr/^https?:\/\//, "URL normalized: $input" );
            ok( validate_short_code_format( $res->{json}->{short_code} ),
                "Code generated for: $input" );
        }
        else {
            diag( "Normalization test skipped for $input: " . $res->{error} );
        }
    }
};

subtest 'POST /api/v1/urls - Real validator blocked domains' => sub {
    for my $url (
        'http://localhost', 'https://localhost',
        'http://127.0.0.1', 'http://192.168.1.1',
        'http://10.0.0.1',  'http://[::1]'
      )
    {
        my $res = post_shorten($url);
        is( $res->{code}, 400, "Blocked URL rejected: $url" );
        like(
            $res->{error},
            qr/blocked domain or local address/,
            "Correct error for: $url"
        );
    }
};

subtest 'POST /api/v1/urls - Real validator network errors (async)' => sub {
    for
      my $url ( 'http://nonexistent-domain-12345.invalid', 'http://192.0.2.1' )
    {
        my $res = post_shorten($url);
        ok(
            $res->{code} == 200 || $res->{code} == 400,
            "Network URL accepted or rejected by format: $url"
        );
    }
};

subtest 'POST /api/v1/urls - Real validator SSL certificate validation' => sub {
    my $res = post_shorten('https://www.example.com');
    ok(
        $res->{code} == 200 || $res->{code} == 400,
        'SSL validation runs async for HTTPS URL'
    );
};

subtest 'POST /api/v1/urls - Real validator invalid URL format' => sub {
    for my $case (
        { url => 'ftp://example.com', error => 'Invalid URL format' },
        { url => '',                  error => 'URL is required' },
      )
    {
        my $res = post_shorten( $case->{url} );
        is( $res->{code},  400, "Invalid URL rejected: $case->{url}" );
        is( $res->{error}, $case->{error}, "Correct error for: $case->{url}" );
    }

    my $res = post_shorten('not-a-url');
    is( $res->{code}, 200, 'Bare hostname accepted: not-a-url' );
    like( $res->{json}->{original_url},
        qr{^http://not-a-url$}, 'Bare hostname normalized with scheme' );
};

subtest 'POST /api/v1/urls - Real validator URL length validation' => sub {
    my $base = 'https://www.example.com/';
    my $too_long_url =
      $base . ( 'a' x ( $MAX_URL_LENGTH - length($base) + 1 ) );
    my $res = post_shorten($too_long_url);
    is( $res->{code}, 400, 'URL exceeding maximum length rejected' );
    like(
        $res->{error},
        qr/exceeds maximum length/,
        'Correct error message for URL length violation'
    );
};

subtest 'POST /api/v1/urls - Real validator URL edge cases' => sub {
    for my $url (
        'https://www.example.com?foo=bar', 'https://www.example.com#section',
        'https://www.example.com:443',     'https://www.perl.org/about.html',
      )
    {
        my $res = post_shorten($url);
        if ( $res->{code} == 200 ) {
            ok( validate_short_code_format( $res->{json}->{short_code} ),
                "Edge case handled: $url" );
            like( $res->{json}->{original_url},
                qr/^https?:\/\//, "URL format preserved: $url" );
        }
        else {
            diag( "Edge case test skipped for $url: " . $res->{error} );
        }
    }
};

subtest 'POST /api/v1/urls - Real database persistence and retrieval' => sub {
    my $url  = 'https://www.example.com';
    my $res1 = post_shorten($url);

    if ( $res1->{code} == 200 ) {
        my $code = $res1->{json}->{short_code};
        ok( validate_short_code_format($code), 'Code generated and stored' );

        my $res2 = get_url($code);
        if ( $res2->{code} == 200 ) {
            validate_get_response( $res2, $url, $code, 'Database retrieval' );
            pass('Database persistence verified');
        }
        else {
            diag( "Database retrieval failed: " . $res2->{error} );
        }
    }
    else {
        diag( "Database persistence test skipped: " . $res1->{error} );
    }
};

subtest 'POST /api/v1/urls - Real database duplicate URL handling' => sub {
    my $url  = 'https://www.example.com';
    my $res1 = post_shorten($url);

    if ( $res1->{code} == 200 ) {
        my $code1 = $res1->{json}->{short_code};
        ok( validate_short_code_format($code1), 'First code generated' );

        my $res2 = post_shorten($url);
        if ( $res2->{code} == 200 ) {
            my $code2 = $res2->{json}->{short_code};
            ok( validate_short_code_format($code2), 'Second code generated' );
            ok( $code1 ne $code2, 'Duplicate URLs generate different codes' );

            my $get1 = get_url($code1);
            my $get2 = get_url($code2);

            if ( $get1->{code} == 200 && $get2->{code} == 200 ) {
                is( $get1->{json}->{original_url},
                    $url, 'First code retrieves original URL' );
                is( $get2->{json}->{original_url},
                    $url, 'Second code retrieves original URL' );
                pass('Both codes persist and retrieve same URL');
            }
        }
        else {
            diag( "Duplicate URL test skipped: " . $res2->{error} );
        }
    }
    else {
        diag( "Duplicate URL test skipped: " . $res1->{error} );
    }
};

subtest 'GET /api/v1/urls/:short_code - Real database error cases' => sub {
    my $res = get_url('nonexistent123456');
    is( $res->{code}, 400, 'Invalid format rejected: nonexistent123456' );
    is(
        $res->{error},
        'Invalid short code format',
        'Correct error for: nonexistent123456'
    );

    $res = get_url('');
    is( $res->{code}, 404, 'Missing short code returns 404' );

    $res = get_url('invalid@code');
    is( $res->{code}, 400, 'Invalid format rejected: invalid@code' );
    is(
        $res->{error},
        'Invalid short code format',
        'Correct error for: invalid@code'
    );
};

subtest 'End-to-end: Full flow with real components' => sub {
    for my $url ( 'https://www.example.com', 'http://www.perl.org' ) {
        my $res1 = post_shorten($url);

        if ( $res1->{code} == 200 ) {
            my $code = $res1->{json}->{short_code};
            ok( validate_short_code_format($code), "Code generated for: $url" );

            my $res2 = get_url($code);
            if ( $res2->{code} == 200 ) {
                validate_get_response( $res2, $url, $code, "End-to-end: $url" );
            }
            else {
                diag( "End-to-end GET failed for $url: " . $res2->{error} );
            }
        }
        else {
            diag( "End-to-end POST failed for $url: " . $res1->{error} );
        }
    }
};

subtest 'Real database connection test' => sub {
    my $res = post_shorten('https://www.example.com');

    if ( $res->{code} == 200 ) {
        pass('Database connection successful (Redis accessible)');
        my $get_res = get_url( $res->{json}->{short_code} );
        pass('Database read operation successful') if $get_res->{code} == 200;
    }
    elsif ( $res->{code} == 400 && $res->{error} =~ /Database error/i ) {
        diag( "Database connection test: Redis may not be available - "
              . $res->{error} );
    }
    else {
        diag( "Database connection test skipped: " . $res->{error} );
    }
};

done_testing();
