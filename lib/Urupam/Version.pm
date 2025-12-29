package Urupam::Version;

use Mojo::Base -base;

has version => sub { '0.1.0' };

sub get_version {
    my $self = shift;
    return $self->version;
}

1;
