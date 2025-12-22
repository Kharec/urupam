package Urupam::Validation;

use Mojo::Base -base;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(url_unescape);
use Mojo::Promise;

my $MAX_URL_LENGTH = 2048;

my @BLOCKED_DOMAINS = qw(
  localhost 127.0.0.1 0.0.0.0 ::1
);

has ua => sub {
    Mojo::UserAgent->new(
        connect_timeout => 10,
        request_timeout => 10,
        max_redirects   => 3,
        insecure        => 0
    );
};

sub _parse_url {
    my ( $self, $url ) = @_;
    return eval { Mojo::URL->new($url) };
}

sub is_valid_url {
    my ( $self, $url ) = @_;
    return 0 unless defined $url && length($url) > 0;

    my $parsed = $self->_parse_url($url);
    return 0 unless $parsed;
    return 0 unless $parsed->scheme && $parsed->scheme =~ /^https?$/i;
    return 0 unless $parsed->host;

    return 1;
}

sub is_valid_url_length {
    my ( $self, $url ) = @_;
    return defined $url && length($url) <= $MAX_URL_LENGTH;
}

sub is_blocked_url {
    my ( $self, $url ) = @_;
    return 0 unless defined $url;

    my $parsed = $self->_parse_url($url);
    return 0 unless $parsed;

    my $host = lc( $parsed->host // '' );
    $host =~ s/:.*$//;

    for my $blocked (@BLOCKED_DOMAINS) {
        return 1 if $host eq $blocked;
    }

    return 1
      if $host =~ /^(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/;

    return 0;
}

sub check_url_reachable {
    my ( $self, $url ) = @_;

    return Mojo::Promise->reject('URL is required')
      unless defined $url && length($url) > 0;

    return $self->ua->head_p($url)->then(
        sub {
            my $tx   = shift;
            my $code = $tx->result->code;

            return 1 if $code >= 200 && $code < 400;
            return Mojo::Promise->reject("URL returned $code error")
              if $code >= 400;
            return Mojo::Promise->reject(
                "URL returned unexpected status: $code");
        }
    )->catch(
        sub {
            my $err     = shift;
            my $err_str = "$err";
            if ( $err_str =~ /SSL|certificate|TLS/i ) {
                return Mojo::Promise->reject("SSL certificate error: $err_str");
            }
            if ( $err_str =~ /Connection refused|Can't connect|timeout/i ) {
                return Mojo::Promise->reject("Cannot reach URL: $err_str");
            }
            return Mojo::Promise->reject("URL validation failed: $err_str");
        }
    );
}

sub check_ssl_certificate {
    my ( $self, $url ) = @_;

    return Mojo::Promise->reject('URL is required')
      unless defined $url && length($url) > 0;

    my $parsed = $self->_parse_url($url);
    return Mojo::Promise->resolve(1)
      unless $parsed && $parsed->scheme && $parsed->scheme eq 'https';

    return $self->ua->head_p($url)->then( sub { return 1; } )->catch(
        sub {
            my $err     = shift;
            my $err_str = "$err";
            if ( $err_str =~ /SSL|certificate|TLS|verification failed/i ) {
                return Mojo::Promise->reject(
                    "Invalid SSL certificate: $err_str");
            }
            return Mojo::Promise->reject("SSL check failed: $err_str");
        }
    );
}

sub is_valid_short_code {
    my ( $self, $code ) = @_;
    return defined $code && length($code) > 0 && $code =~ /^[0-9a-zA-Z]+$/;
}

sub sanitize_url {
    my ( $self, $url ) = @_;
    return undef unless defined $url;

    $url =~ s/^\s+|\s+$//g;
    $url = url_unescape($url) if $url =~ /%[0-9A-Fa-f]{2}/;

    $url = 'http://' . $url unless $url =~ m{^https?://}i;

    return $url;
}

sub validate_url_with_checks {
    my ( $self, $url ) = @_;

    return Mojo::Promise->reject('URL is required')
      unless defined $url && length($url) > 0;

    my $sanitized = $self->sanitize_url($url);
    return Mojo::Promise->reject('Invalid URL format')
      unless $self->is_valid_url($sanitized);
    return Mojo::Promise->reject(
        "URL exceeds maximum length of $MAX_URL_LENGTH characters")
      unless $self->is_valid_url_length($sanitized);
    return Mojo::Promise->reject(
        'This URL cannot be shortened (blocked domain or local address)')
      if $self->is_blocked_url($sanitized);

    my $parsed = $self->_parse_url($sanitized);
    return Mojo::Promise->reject('Invalid URL format') unless $parsed;

    my $ssl_check =
        $parsed->scheme eq 'https'
      ? $self->check_ssl_certificate($sanitized)
      : Mojo::Promise->resolve(1);

    return $ssl_check->then(
        sub { return $self->check_url_reachable($sanitized); } )
      ->then( sub { return $sanitized; } );
}

1;
