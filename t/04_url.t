use Test::More;
use Mojo::Promise;
use Urupam::URL;

use_ok('Urupam::URL');

package Mock::DB;
use Mojo::Base -base;
use Mojo::Promise;

has setnx_cb => sub {
    sub { Mojo::Promise->resolve(1) }
};

has get_cb => sub {
    sub { Mojo::Promise->resolve('https://example.com') }
};

sub setnx {
    my ( $self, $key, $value ) = @_;
    return $self->setnx_cb->( $self, $key, $value );
}

sub get {
    my ( $self, $key ) = @_;
    return $self->get_cb->( $self, $key );
}

package main;

my $db  = Mock::DB->new;
my $url = Urupam::URL->new( db => $db );

sub wait_promise {
    my ($promise) = @_;
    my ( $value, $error );
    $promise->then( sub { $value = shift } )
      ->catch( sub { $error = shift } )
      ->wait;
    return ( $value, $error );
}

sub reset_db {
    $db->setnx_cb( sub { Mojo::Promise->resolve(1) } );
    $db->get_cb( sub { Mojo::Promise->resolve('https://example.com') } );
}

subtest '_validate_short_code' => sub {
    my @valid   = ( [ 'AbCdEf123456', 'valid short code passes' ], );
    my @invalid = (
        [ 'short',         'short code length fails' ],
        [ 'AbCdEf1234567', 'long code length fails' ],
        [ 'AbCdEf12@456',  'invalid chars fail' ],
        [ undef,           'undef fails' ],
    );

    for my $case (@valid) {
        ok( $url->_validate_short_code( $case->[0] ), $case->[1] );
    }

    for my $case (@invalid) {
        ok( !$url->_validate_short_code( $case->[0] ), $case->[1] );
    }
};

subtest 'generate_short_code - invalid URL' => sub {
    my $long_url = 'http://example.com/' . ( 'a' x 2049 );
    my @cases    = (
        [ '',        qr/^Original URL is required$/, 'empty URL rejected' ],
        [ $long_url, qr/exceeds maximum length/,     'long URL rejected' ],
    );

    for my $case (@cases) {
        my ( $value, $error ) =
          wait_promise( $url->generate_short_code( $case->[0] ) );
        is( $value, undef, 'invalid URL has no result' );
        like( $error, $case->[1], $case->[2] );
    }
};

subtest 'generate_short_code - success' => sub {
    my ( $value, $error ) =
      wait_promise( $url->generate_short_code('https://example.com') );
    is( $error, undef, 'no error for valid URL' );
    ok( defined $value, 'short code generated' );
    is( length($value), 12, 'short code length is 12' );
    like( $value, qr/^[0-9a-zA-Z\-_]+$/, 'short code matches pattern' );
};

subtest 'create_short_url - custom code' => sub {
    reset_db();
    my ( $value, $error ) =
      wait_promise(
        $url->create_short_url( 'https://example.com', 'AbCdEf123456' ) );
    is( $error, undef,          'no error for custom code' );
    is( $value, 'AbCdEf123456', 'custom code is returned' );

    my @cases = (
        [
            sub { reset_db(); },
            'bad',
            qr/^Invalid short code format$/,
            'invalid custom code rejected'
        ],
        [
            sub {
                reset_db();
                $db->setnx_cb( sub { Mojo::Promise->resolve(0) } );
            },
            'AbCdEf123456',
            qr/^Database error: Short code already exists$/,
            'custom code collision rejected'
        ],
        [
            sub {
                reset_db();
                $db->setnx_cb(
                    sub { Mojo::Promise->reject('connection failed') } );
            },
            'AbCdEf123456',
            qr/^Database error: connection failed$/,
            'db error message is wrapped'
        ],
    );

    for my $case (@cases) {
        $case->[0]->();
        ( $value, $error ) =
          wait_promise(
            $url->create_short_url( 'https://example.com', $case->[1] ) );
        is( $value, undef, 'custom code failure has no result' );
        like( $error, $case->[2], $case->[3] );
    }
};

subtest 'create_short_url - retry behavior' => sub {
    reset_db();
    $db->setnx_cb( sub { Mojo::Promise->resolve(0) } );
    {
        no warnings 'redefine';
        local *Urupam::URL::generate_short_code = sub {
            return Mojo::Promise->resolve('AbCdEf123456');
        };

        my ( $value, $error ) =
          wait_promise( $url->create_short_url('https://example.com') );
        is( $value, undef, 'retry exhaustion has no result' );
        like(
            $error,
            qr/Failed to generate unique short code after retry/,
            'retry exhaustion returns error'
        );
    }

    reset_db();
    $db->setnx_cb( sub { Mojo::Promise->resolve(1) } );
    my $calls = 0;
    {
        no warnings 'redefine';
        local *Urupam::URL::generate_short_code = sub {
            $calls++;
            return $calls == 1
              ? Mojo::Promise->reject('Database error: connection failed')
              : Mojo::Promise->resolve('AbCdEf123456');
        };

        my ( $value, $error ) =
          wait_promise( $url->create_short_url('https://example.com') );
        is( $error, undef,          'retry succeeds without error' );
        is( $value, 'AbCdEf123456', 'code returned after retry' );
        is( $calls, 2,              'retry invoked after database error' );
    }
};

subtest 'get_original_url' => sub {
    reset_db();
    my ( $value, $error ) =
      wait_promise( $url->get_original_url('AbCdEf123456') );
    is( $error, undef,                 'get_original_url has no error' );
    is( $value, 'https://example.com', 'returns stored URL' );
};

done_testing();
