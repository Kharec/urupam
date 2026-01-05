package Urupam::DB;

use Mojo::Base -base;
use Mojo::Promise;
use Mojo::Redis2;

has redis => sub {
    Mojo::Redis2->new( url => $ENV{REDIS_URL} || 'redis://localhost:6379' );
};

sub get {
    my ( $self, $key ) = @_;
    my $promise = Mojo::Promise->new;
    $self->redis->get(
        $key => sub {
            my ( $redis, $err, $value ) = @_;
            $err ? $promise->reject($err) : $promise->resolve($value);
        }
    );
    return $promise;
}

sub setnx {
    my ( $self, $key, $value ) = @_;
    my $promise = Mojo::Promise->new;
    $self->redis->setnx(
        $key => $value,
        sub {
            my ( $redis, $err, $result ) = @_;
            if ($err) {
                $promise->reject($err);
            }
            else {
                $promise->resolve( $result ? 1 : 0 );
            }
        }
    );
    return $promise;
}

sub ping {
    my $self    = shift;
    my $promise = Mojo::Promise->new;
    $self->redis->ping(
        sub {
            my ( $redis, $err, $result ) = @_;
            $err ? $promise->reject($err) : $promise->resolve($result);
        }
    );
    return $promise;
}

1;
