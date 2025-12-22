package Urupam::Utils;

use Mojo::Base -base;
use Mojo::Util qw(url_unescape);

sub sanitize_input {
    my ($input) = @_;
    return '' unless defined $input;
    $input =~ s/^\s+|\s+$//g;
    return $input;
}

sub get_error_status {
    my ($err) = @_;
    return $err =~ /SSL certificate|Cannot reach|DNS resolution|server error/i ? 422 : 400;
}

sub sanitize_error_message {
    my ($err) = @_;
    return 'An error occurred' unless defined $err;
    my $sanitized = "$err";
    $sanitized =~ s/[^\w\s\.\-\:\/]//g;
    $sanitized =~ s/\s+/ /g;
    $sanitized =~ s/^\s+|\s+$//g;
    return length($sanitized) > 200 ? substr($sanitized, 0, 200) . '...' : $sanitized;
}

sub sanitize_url {
    my ($url) = @_;
    return undef unless defined $url;

    $url =~ s/^\s+|\s+$//g;
    return undef if length($url) == 0;

    if ( $url =~ /%[0-9a-f]{2}/i ) {
        $url = url_unescape($url);
    }

    unless ( $url =~ m{^https?://}i ) {
        return undef if $url =~ /[\@:]/;
        $url = 'http://' . $url;
    }

    return $url;
}

1;

