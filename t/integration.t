use Test::More;
use Test::Mojo;
use Urupam::App;

my $t;
eval { $t = Test::Mojo->new('Urupam::App'); 1 }
  or plan skip_all => "Test server not available: $@";

sub wait_promise {
    my ($promise) = @_;
    my ( $value, $error );
    $promise->then( sub { $value = shift } )
      ->catch( sub { $error = shift } )
      ->wait;
    return ( $value, $error );
}

my ( $pong, $ping_err ) = wait_promise( $t->app->db->ping );
plan skip_all => "Redis not available: $ping_err" if $ping_err;

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

sub expected_normalized_url {
    my ($url) = @_;
    return $url if defined $url && $url =~ m{^https?://}i;
    return defined $url ? "http://$url" : undef;
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
    is( $json->{original_url}, $url, "$label: original URL matches" )
      if defined $url;
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

subtest 'POST /api/v1/urls - Real validator success cases' => sub {
    for my $url ( 'https://www.example.com', 'http://www.perl.org' ) {
        my $res = post_shorten($url);
        is( $res->{code}, 200, "URL accepted: $url" );
        validate_shorten_response( $res, $url, "URL: $url" );
    }
};

subtest 'POST /api/v1/urls - Real validator URL normalization' => sub {
    for my $input ( 'www.example.com', 'example.com' ) {
        my $res = post_shorten($input);
        is( $res->{code}, 200, "URL normalized: $input" );
        my $expected = expected_normalized_url($input);
        validate_shorten_response( $res, $expected, "URL normalized: $input" );
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
        is( $res->{code}, 200, "Network URL accepted asynchronously: $url" );
        validate_shorten_response( $res, $url, "URL: $url" );
    }
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

};

subtest 'POST /api/v1/urls - Real validator bare hostname' => sub {
    my $res = post_shorten('not-a-url');
    is( $res->{code}, 200, 'Bare hostname accepted: not-a-url' );
    validate_shorten_response( $res, 'http://not-a-url',
        'Bare hostname normalized' );
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
        is( $res->{code}, 200, "Edge case handled: $url" );
        validate_shorten_response( $res, $url, "Edge case handled: $url" );
    }
};

subtest 'POST /api/v1/urls - Real database persistence and retrieval' => sub {
    my $url  = 'https://www.example.com';
    my $res1 = post_shorten($url);

    is( $res1->{code}, 200, 'Database write succeeded' );
    my $code = $res1->{json}->{short_code};
    ok( validate_short_code_format($code), 'Code generated and stored' );

    my $res2 = get_url($code);
    is( $res2->{code}, 200, 'Database read succeeded' );
    validate_get_response( $res2, $url, $code, 'Database retrieval' );
    pass('Database persistence verified');
};

subtest 'POST /api/v1/urls - Real database duplicate URL handling' => sub {
    my $url  = 'https://www.example.com';
    my $res1 = post_shorten($url);

    is( $res1->{code}, 200, 'First create succeeded' );
    my $code1 = $res1->{json}->{short_code};
    ok( validate_short_code_format($code1), 'First code generated' );

    my $res2 = post_shorten($url);
    is( $res2->{code}, 200, 'Second create succeeded' );
    my $code2 = $res2->{json}->{short_code};
    ok( validate_short_code_format($code2), 'Second code generated' );
    ok( $code1 ne $code2, 'Duplicate URLs generate different codes' );

    my $get1 = get_url($code1);
    my $get2 = get_url($code2);

    is( $get1->{code}, 200, 'First code retrieves' );
    is( $get2->{code}, 200, 'Second code retrieves' );
    is( $get1->{json}->{original_url},
        $url, 'First code retrieves original URL' );
    is( $get2->{json}->{original_url},
        $url, 'Second code retrieves original URL' );
    pass('Both codes persist and retrieve same URL');
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

done_testing();
