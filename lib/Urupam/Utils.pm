package Urupam::Utils;

use Mojo::Base -base;
use Mojo::URL;
use Mojo::Util qw(url_unescape);

sub sanitize_input {
    my ($input) = @_;
    return '' unless defined $input;
    $input =~ s/^\s+|\s+$//g;
    return $input;
}

sub get_error_status {
    my ($err) = @_;
    return $err =~ /SSL certificate|Cannot reach|DNS resolution|server error/i
      ? 422
      : 400;
}

sub sanitize_error_message {
    my ($err) = @_;
    return 'An error occurred' unless defined $err;
    my $sanitized = "$err";
    $sanitized =~ s/[^\w\s\.\-\:\/]//g;
    $sanitized =~ s/\s+/ /g;
    $sanitized =~ s/^\s+|\s+$//g;
    return
      length($sanitized) > 200
      ? substr( $sanitized, 0, 200 ) . '...'
      : $sanitized;
}

sub sanitize_url {
    my ($url) = @_;
    return undef unless defined $url;

    $url =~ s/^\s+|\s+$//g;
    return undef if length($url) == 0;

    unless ( $url =~ m{^https?://}i ) {
        return undef if $url =~ /[\@:]/;
        $url = 'http://' . $url;
    }

    my ($authority) = $url =~ m{^https?://([^/?#]*)}i;
    if ( defined $authority ) {
        return undef if $authority =~ /\@/;
        return undef if $authority =~ /[\s\x00-\x1F\x7F]/;

        my $hostport = ( split /\@/, $authority )[-1];
        my $host_raw;
        if ( $hostport =~ /^\[(.+)\](?::\d+)?$/ ) {
            $host_raw = $1;
        }
        else {
            $host_raw = $hostport;
            $host_raw =~ s/:(\d+)$//;
        }
        if ( $hostport =~ /[\[\]]/ ) {
            return undef
              unless $hostport =~ /^\[[0-9a-fA-F:.]+\](?::\d+)?$/;
        }
        return undef if $host_raw =~ /%[0-9a-f]{2}/i;
    }

    my $parsed = Mojo::URL->new($url);

    if ( $url =~ /%[0-9a-f]{2}/i ) {
        my $path = url_unescape( $parsed->path->to_string );
        $parsed->path($path);

        my $query = $parsed->query->to_string;
        $parsed->query( url_unescape($query) ) if length $query;

        my $fragment = $parsed->fragment;
        $parsed->fragment( url_unescape($fragment) ) if defined $fragment;

        $url = $parsed->to_string;
    }

    return $url;
}

1;
