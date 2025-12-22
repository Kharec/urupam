package Urupam::Validation;

use Mojo::Base -base;
use Mojo::URL;
use Mojo::Util qw(url_unescape);

sub is_valid_url {
    my ( $self, $url ) = @_;
    return 0 unless defined $url && length($url) > 0;

    $url = url_unescape($url) if $url =~ /%[0-9A-Fa-f]{2}/;

    return 0 unless $url =~ m{^https?://}i;

    my $parsed = eval { Mojo::URL->new($url) };
    return 0 unless $parsed;

    return 0 unless $parsed->scheme && $parsed->host;

    return 1;
}

sub is_valid_short_code {
    my ( $self, $code ) = @_;
    return 0 unless defined $code && length($code) > 0;

    return 0 if length($code) > 20;

    return 0 unless $code =~ /^[0-9a-zA-Z]+$/;

    return 1;
}

sub sanitize_url {
    my ( $self, $url ) = @_;
    return undef unless defined $url;

    $url =~ s/^\s+|\s+$//g;
    $url = url_unescape($url) if $url =~ /%[0-9A-Fa-f]{2}/;

    unless ( $url =~ m{^https?://}i ) {
        $url = 'http://' . $url;
    }

    return $url;
}

1;

