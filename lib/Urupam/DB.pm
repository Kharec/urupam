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

sub set {
    my ( $self, $key, $value ) = @_;
    my $promise = Mojo::Promise->new;
    $self->redis->set(
        $key => $value,
        sub {
            my ( $redis, $err, $result ) = @_;
            $err ? $promise->reject($err) : $promise->resolve($result);
        }
    );
    return $promise;
}

1;
