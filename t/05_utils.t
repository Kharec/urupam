use Test::More;
use Urupam::Utils ();

use_ok('Urupam::Utils');

subtest 'sanitize_input' => sub {
    my @cases = (
        [ undef,              '',           'undef becomes empty' ],
        [ "  spaced out\t\n", 'spaced out', 'trims leading/trailing' ],
        [ 'a  b',             'a  b',       'preserves internal whitespace' ],
        [ 0,                  '0',          'handles numeric zero' ],
        [ '0',                '0',          'handles string zero' ],
    );

    for my $case (@cases) {
        is( Urupam::Utils::sanitize_input( $case->[0] ),
            $case->[1], $case->[2] );
    }
};

subtest 'get_error_status' => sub {
    my @cases = (
        [ 'SSL certificate error',     422, 'SSL error maps to 422' ],
        [ 'Cannot reach URL: timeout', 422, 'connection error maps to 422' ],
        [ 'DNS resolution failed',     422, 'DNS error maps to 422' ],
        [ 'server error: 500',         422, 'server error maps to 422' ],
        [ 'SeRvEr ErRoR',              422, 'mixed case matches' ],
        [ 'Database error: connection failed', 400, 'default maps to 400' ],
        [ 'unrelated error', 400, 'non-matching message maps to 400' ],
    );

    for my $case (@cases) {
        is( Urupam::Utils::get_error_status( $case->[0] ),
            $case->[1], $case->[2] );
    }
};

subtest 'sanitize_error_message' => sub {
    my @cases = (
        [ undef, 'An error occurred', 'undef gets default message' ],
        [
            "Database error: <bad>\n\t!!",
            'Database error: bad',
            'strips unsafe chars and collapses whitespace'
        ],
        [
            'Allowed: ./-_: ok',
            'Allowed: ./-_: ok',
            'preserves allowed punctuation'
        ],
        [
            "Error   with   spaces",
            'Error with spaces',
            'collapses multiple spaces'
        ],
        [ "Bad\x01\x02Chars", 'BadChars', 'strips control characters' ],
        [
            "Cafe\x{00E9} error",
            "Cafe\x{00E9} error",
            'preserves Unicode characters'
        ],
    );

    for my $case (@cases) {
        is( Urupam::Utils::sanitize_error_message( $case->[0] ),
            $case->[1], $case->[2] );
    }

    my $long_error = 'Error: ' . ( 'a' x 210 );
    my $expected   = substr( $long_error, 0, 200 ) . '...';
    is( Urupam::Utils::sanitize_error_message($long_error),
        $expected, 'truncates long messages' );
};

subtest 'sanitize_url' => sub {
    my @cases = (
        [ undef, undef, 'undef stays undef' ],
        [ '   ', undef, 'blank is undef' ],
        [
            'example.com/path', 'http://example.com/path',
            'adds scheme when missing'
        ],
        [
            '  example.com/path  ',
            'http://example.com/path',
            'trims before processing'
        ],
        [
            'https://example.com/path', 'https://example.com/path',
            'preserves http(s) scheme'
        ],
        [
            'http://example.com', 'http://example.com',
            'does not double-add scheme'
        ],
        [
            'HTTP://Example.com/Path', 'HTTP://Example.com/Path',
            'accepts mixed-case scheme'
        ],
        [
            'https://example.com/%7Euser', 'https://example.com/~user',
            'unescapes percent-encoded path'
        ],
        [
            'https://example.com/%7Euser%2Fdocs',
            'https://example.com/~user/docs',
            'unescapes multiple percent-encoded segments'
        ],
        [
            'https://example.com?q=hello%20world',
            'https://example.com?q=hello%20world',
            'preserves percent-encoded query'
        ],
        [
            'https://example.com#frag%20ment',
            'https://example.com#frag%20ment',
            'preserves percent-encoded fragment'
        ],
        [
            'https://example.com/%257Euser', 'https://example.com/%7Euser',
            'unescapes only once'
        ],
        [
            'https://ex%61mple.com/path', undef,
            'rejects percent-encoded hostname'
        ],
        [ 'example.com:8080/path', undef, 'rejects missing scheme with colon' ],
        [ 'user@example.com', undef, 'rejects missing scheme with at-sign' ],
        [
            'http://user@example.com/path', undef,
            'rejects userinfo with scheme'
        ],
        [ 'http://[::1]/path', 'http://[::1]/path', 'accepts IPv6 host' ],
        [ 'http://[::1/path',         undef, 'rejects malformed IPv6 host' ],
        [ 'http://exa mple.com/path', undef, 'rejects whitespace in host' ],
    );

    for my $case (@cases) {
        is( Urupam::Utils::sanitize_url( $case->[0] ), $case->[1], $case->[2] );
    }
};

done_testing();
