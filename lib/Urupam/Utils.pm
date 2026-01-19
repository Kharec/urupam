package Urupam::Utils;

use strict;
use warnings;
use Exporter 'import';
use Mojo::URL;
use Mojo::Path;
use Mojo::Util qw(url_unescape decode);

our @EXPORT_OK = qw(
  sanitize_input
  get_error_status
  sanitize_error_message
  sanitize_url
);

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
    $sanitized =~ s/[^\p{L}\p{N}_\s\.\-\:\/]//gu;
    $sanitized =~ s/\s+/ /g;
    $sanitized =~ s/^\s+|\s+$//g;
    return length($sanitized) > 200
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
        return undef unless defined $hostport && length $hostport;
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
        $path = decode( 'UTF-8', $path ) if length $path;
        $parsed->path( Mojo::Path->new($path) );

        my $query = $parsed->query->to_string;
        if ( length $query ) {
            my $decoded_query = url_unescape($query);
            $decoded_query = decode( 'UTF-8', $decoded_query )
              if length $decoded_query;
            $parsed->query($decoded_query);
        }

        my $fragment = $parsed->fragment;
        if ( defined $fragment ) {
            my $decoded_fragment = url_unescape($fragment);
            $decoded_fragment = decode( 'UTF-8', $decoded_fragment )
              if length $decoded_fragment;
            $parsed->fragment($decoded_fragment);
        }

        $url = $parsed->to_string;
    }

    return $url;
}

1;
