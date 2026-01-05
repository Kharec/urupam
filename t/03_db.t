use Test::More;
use Test::MockObject;
use Mojo::Promise;
use Urupam::DB;

use_ok('Urupam::DB');

sub wait_promise {
    my ($promise) = @_;
    my ( $value, $error );
    $promise->then( sub { $value = shift } )
      ->catch( sub { $error = shift } )
      ->wait;
    return ( $value, $error );
}

sub mock_redis_method {
    my ( $method, $err, $result ) = @_;
    my $mock_redis = Test::MockObject->new;
    $mock_redis->mock(
        $method,
        sub {
            my ( $self, @args ) = @_;
            my $cb = pop @args;
            $cb->( $self, $err, $result );
        }
    );
    return $mock_redis;
}

sub test_method {
    my ( $name, $method, $args, $success_cases, $error_cases ) = @_;
    my $db = Urupam::DB->new;

    for my $case (@$success_cases) {
        my ( $expected, $err, $result, $desc ) = @$case;
        my $mock_redis = mock_redis_method( $method, $err, $result );
        $db->redis($mock_redis);
        my ( $value, $error ) = wait_promise( $db->$method(@$args) );
        is( $value, $expected, "$name success: $desc" );
        is( $error, undef,     "$name success: no error" );
    }

    for my $case (@$error_cases) {
        my ( $err, $desc ) = @$case;
        my $mock_redis = mock_redis_method( $method, $err, undef );
        $db->redis($mock_redis);
        my ( $value, $error ) = wait_promise( $db->$method(@$args) );
        is( $value, undef, "$name error: $desc" );
        is( $error, $err,  "$name error: error returned" );
    }
}

subtest 'get' => sub {
    test_method(
        'get',
        'get',
        ['test_key'],
        [ [ 'test_value', undef, 'test_value', 'returns correct value' ] ],
        [ [ 'Connection error', 'error is returned' ] ]
    );
};

subtest 'setnx' => sub {
    test_method(
        'setnx', 'setnx',
        [ 'test_key', 'test_value' ],
        [
            [ 1, undef, 1, 'returns 1 when key is set' ],
            [ 0, undef, 0, 'returns 0 when key already exists' ],
        ],
        [ [ 'Setnx error', 'error is returned' ] ]
    );
};

subtest 'ping' => sub {
    test_method(
        'ping', 'ping', [],
        [ [ 'PONG', undef, 'PONG', 'returns PONG' ] ],
        [ [ 'Connection lost', 'error is returned' ] ]
    );
};

subtest 'redis attribute' => sub {
    my $new_db = Urupam::DB->new;
    ok( $new_db->redis, 'redis attribute is initialized' );
    isa_ok( $new_db->redis, 'Mojo::Redis2',
        'redis is a Mojo::Redis2 instance' );

    my $custom_redis = Test::MockObject->new;
    my $custom_db    = Urupam::DB->new( redis => $custom_redis );
    is( $custom_db->redis, $custom_redis, 'custom redis instance is set' );
};

done_testing();
