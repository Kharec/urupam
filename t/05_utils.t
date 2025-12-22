use Test::More;
use Urupam::Utils ();

subtest 'sanitize_input' => sub {
    is( Urupam::Utils::sanitize_input(undef), '', 'undef becomes empty' );
    is( Urupam::Utils::sanitize_input("  spaced out\t\n"),
        'spaced out', 'trims leading and trailing whitespace' );
    is( Urupam::Utils::sanitize_input('a  b'),
        'a  b', 'preserves internal whitespace' );
    is( Urupam::Utils::sanitize_input(0),   '0', 'handles numeric zero' );
    is( Urupam::Utils::sanitize_input('0'), '0', 'handles string zero' );
};

subtest 'get_error_status' => sub {
    is( Urupam::Utils::get_error_status('SSL certificate error'),
        422, 'SSL error maps to 422' );
    is( Urupam::Utils::get_error_status('Cannot reach URL: timeout'),
        422, 'connection error maps to 422' );
    is( Urupam::Utils::get_error_status('DNS resolution failed'),
        422, 'DNS error maps to 422' );
    is( Urupam::Utils::get_error_status('server error: 500'),
        422, 'server error maps to 422' );
    is( Urupam::Utils::get_error_status('SeRvEr ErRoR'),
        422, 'mixed case matches' );
    is( Urupam::Utils::get_error_status('Database error: connection failed'),
        400, 'default maps to 400' );
    is( Urupam::Utils::get_error_status('unrelated error'),
        400, 'non-matching message maps to 400' );
};

subtest 'sanitize_error_message' => sub {
    is(
        Urupam::Utils::sanitize_error_message(undef),
        'An error occurred',
        'undef gets default message'
    );
    is(
        Urupam::Utils::sanitize_error_message("Database error: <bad>\n\t!!"),
        'Database error: bad',
        'strips unsafe chars and collapses whitespace'
    );
    is(
        Urupam::Utils::sanitize_error_message('Allowed: ./-_: ok'),
        'Allowed: ./-_: ok',
        'preserves allowed punctuation'
    );
    is(
        Urupam::Utils::sanitize_error_message("Error   with   spaces"),
        'Error with spaces',
        'collapses multiple spaces'
    );
    is( Urupam::Utils::sanitize_error_message("Bad\x01\x02Chars"),
        'BadChars', 'strips control characters' );
    is(
        Urupam::Utils::sanitize_error_message("Cafe\x{00E9} error"),
        "Cafe\x{00E9} error",
        'preserves Unicode characters'
    );

    my $long_error = 'Error: ' . ( 'a' x 210 );
    my $expected   = substr( $long_error, 0, 200 ) . '...';
    is( Urupam::Utils::sanitize_error_message($long_error),
        $expected, 'truncates long messages' );
};

subtest 'sanitize_url' => sub {
    is( Urupam::Utils::sanitize_url(undef), undef, 'undef stays undef' );
    is( Urupam::Utils::sanitize_url('   '), undef, 'blank is undef' );
    is( Urupam::Utils::sanitize_url('example.com/path'),
        'http://example.com/path', 'adds scheme when missing' );
    is( Urupam::Utils::sanitize_url('  example.com/path  '),
        'http://example.com/path', 'trims before processing' );
    is( Urupam::Utils::sanitize_url('https://example.com/path'),
        'https://example.com/path', 'preserves http(s) scheme' );
    is( Urupam::Utils::sanitize_url('http://example.com'),
        'http://example.com', 'does not double-add scheme' );
    is( Urupam::Utils::sanitize_url('HTTP://Example.com/Path'),
        'HTTP://Example.com/Path', 'accepts mixed-case scheme' );
    is( Urupam::Utils::sanitize_url('https://example.com/%7Euser'),
        'https://example.com/~user', 'unescapes percent-encoded path' );
    is(
        Urupam::Utils::sanitize_url('https://example.com/%7Euser%2Fdocs'),
        'https://example.com/~user/docs',
        'unescapes multiple percent-encoded segments'
    );
    is(
        Urupam::Utils::sanitize_url('https://example.com?q=hello%20world'),
        'https://example.com?q=hello%20world',
        'preserves percent-encoded query'
    );
    is(
        Urupam::Utils::sanitize_url('https://example.com#frag%20ment'),
        'https://example.com#frag%20ment',
        'preserves percent-encoded fragment'
    );
    is( Urupam::Utils::sanitize_url('https://example.com/%257Euser'),
        'https://example.com/%7Euser', 'unescapes only once' );
    is( Urupam::Utils::sanitize_url('https://ex%61mple.com/path'),
        undef, 'rejects percent-encoded hostname' );
    is( Urupam::Utils::sanitize_url('example.com:8080/path'),
        undef, 'rejects missing scheme with colon' );
    is( Urupam::Utils::sanitize_url('user@example.com'),
        undef, 'rejects missing scheme with at-sign' );
    is( Urupam::Utils::sanitize_url('http://user@example.com/path'),
        undef, 'rejects userinfo with scheme' );
    is( Urupam::Utils::sanitize_url('http://[::1]/path'),
        'http://[::1]/path', 'accepts IPv6 host' );
    is( Urupam::Utils::sanitize_url('http://[::1/path'),
        undef, 'rejects malformed IPv6 host' );
    is( Urupam::Utils::sanitize_url('http://exa mple.com/path'),
        undef, 'rejects whitespace in host' );
};

done_testing();
