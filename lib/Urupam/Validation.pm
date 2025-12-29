package Urupam::Validation;

use Mojo::Base -base;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Promise;
use Urupam::Utils qw(sanitize_url);
use Socket
  qw(getaddrinfo getnameinfo NI_NUMERICHOST NI_NUMERICSERV AF_INET AF_INET6 SOCK_STREAM);

my $MAX_URL_LENGTH  = 2048;
my $CONNECT_TIMEOUT = 10;
my $REQUEST_TIMEOUT = 10;
my $MAX_REDIRECTS   = 3;

my $DNS_ERROR_PATTERN =
qr/Name or service not known|getaddrinfo failed|Could not resolve|DNS|hostname|Name resolution|nodename nor servname provided/i;
my $SSL_ERROR_PATTERN        = qr/SSL|certificate|TLS|verification failed/i;
my $CONNECTION_ERROR_PATTERN = qr/Connection refused|Can't connect|timeout/i;

my $PRIVATE_IP_PATTERN =
  qr/^(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/;

my @BLOCKED_DOMAINS = qw(
  localhost 127.0.0.1 0.0.0.0 ::1
);

has ua => sub {
    my $self = shift;
    Mojo::UserAgent->new(
        connect_timeout => $self->connect_timeout,
        request_timeout => $self->request_timeout,
        max_redirects   => $self->max_redirects,
        insecure        => 0
    );
};

has connect_timeout => sub { $CONNECT_TIMEOUT };
has request_timeout => sub { $REQUEST_TIMEOUT };
has max_redirects   => sub { $MAX_REDIRECTS };

sub _parse_url {
    my ( $self, $url ) = @_;
    return undef unless defined $url;
    my $parsed;
    eval { $parsed = Mojo::URL->new($url); 1 } or return undef;
    return $parsed;
}

sub _classify_error {
    my ( $self, $err_str ) = @_;

    return 'ssl'        if $err_str =~ $SSL_ERROR_PATTERN;
    return 'dns'        if $err_str =~ $DNS_ERROR_PATTERN;
    return 'connection' if $err_str =~ $CONNECTION_ERROR_PATTERN;
    return 'unknown';
}

sub _format_error_message {
    my ( $self, $error_type, $err_str ) = @_;

    return "SSL certificate error: $err_str" if $error_type eq 'ssl';
    return "DNS resolution failed: $err_str" if $error_type eq 'dns';
    return "Cannot reach URL: $err_str"      if $error_type eq 'connection';
    return "URL validation failed: $err_str";
}

sub is_valid_url_length {
    my ( $self, $url ) = @_;
    return 0 unless defined $url && length($url) > 0;
    return length($url) <= $MAX_URL_LENGTH;
}

sub _is_valid_ipv4 {
    my ( $self, $ip ) = @_;
    return 0 unless defined $ip;
    return 0 unless $ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/;
    my ( $a, $b, $c, $d ) = ( $1, $2, $3, $4 );
    return
         $a >= 0
      && $a <= 255
      && $b >= 0
      && $b <= 255
      && $c >= 0
      && $c <= 255
      && $d >= 0
      && $d <= 255;
}

sub _is_private_ipv4 {
    my ( $self, $ip ) = @_;
    return 0 unless $self->_is_valid_ipv4($ip);
    return $ip =~ $PRIVATE_IP_PATTERN;
}

sub _is_private_ipv6 {
    my ( $self, $ip ) = @_;
    $ip = lc($ip);
    $ip =~ s/^\[|\]$//g;

    return 1 if $ip eq '::1';
    return 1 if $ip eq '::';
    return 1
      if $ip =~ /^::ffff:(127\.|192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/;

    if ( $ip =~ /^([0-9a-f]{0,4}:)+[0-9a-f]{0,4}$/ || $ip =~ /^::/ ) {
        my @parts      = split /:/, $ip;
        my $first_part = $parts[0] || '';

        if ( length($first_part) > 0 ) {
            my $first = hex($first_part);
            if ( $first >= 0xfc && $first <= 0xfd ) {
                return 1;
            }
            if ( $first == 0xfe && @parts > 1 ) {
                my $second_part = $parts[1] || '';
                if ( length($second_part) > 0 ) {
                    my $second = hex($second_part);
                    if ( $second >= 0x80 && $second <= 0xbf ) {
                        return 1;
                    }
                }
            }
        }

        if ( $ip =~ /^fc[0-9a-f]{2}:/i || $ip =~ /^fd[0-9a-f]{2}:/i ) {
            return 1;
        }
        if ( $ip =~ /^fe[89ab][0-9a-f]:/i ) {
            return 1;
        }
    }

    return 0;
}

sub _resolve_host {
    my ( $self, $host ) = @_;
    return Mojo::Promise->resolve( [] )
      unless defined $host && length($host) > 0;

    if ( $self->_is_valid_ipv4($host) ) {
        return Mojo::Promise->resolve( [ { type => 'ipv4', ip => $host } ] );
    }

    my $ipv6_host = $host;
    $ipv6_host =~ s/^\[|\]$//g;
    if ( $self->_is_private_ipv6($ipv6_host) ) {
        return Mojo::Promise->resolve(
            [ { type => 'ipv6', ip => $ipv6_host } ] );
    }

    if (   $ipv6_host =~ /^([0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}$/i
        || $ipv6_host =~ /^::/ )
    {
        return Mojo::Promise->resolve(
            [ { type => 'ipv6', ip => $ipv6_host } ] );
    }

    my ( $err, @results ) =
      getaddrinfo( $host, undef, { socktype => SOCK_STREAM } );
    return Mojo::Promise->resolve( [] ) if $err;

    my @addresses;
    for my $res (@results) {
        my ( $hostnum, undef ) =
          getnameinfo( $res->{addr}, NI_NUMERICHOST | NI_NUMERICSERV );
        next unless defined $hostnum && length $hostnum;

        if ( $res->{family} == AF_INET ) {
            push @addresses, { type => 'ipv4', ip => $hostnum };
        }
        elsif ( $res->{family} == AF_INET6 ) {
            push @addresses, { type => 'ipv6', ip => $hostnum };
        }
    }

    return Mojo::Promise->resolve( \@addresses );
}

sub is_blocked_url {
    my ( $self, $url ) = @_;
    return Mojo::Promise->resolve(0) unless defined $url;

    my $parsed = $self->_parse_url($url);
    return Mojo::Promise->resolve(0) unless $parsed;

    my $host = lc( $parsed->host // '' );
    return Mojo::Promise->resolve(0) unless length($host) > 0;

    for my $blocked (@BLOCKED_DOMAINS) {
        return Mojo::Promise->resolve(1) if $host eq $blocked;
    }

    if ( $self->_is_private_ipv4($host) ) {
        return Mojo::Promise->resolve(1);
    }

    if ( $self->_is_private_ipv6($host) ) {
        return Mojo::Promise->resolve(1);
    }

    return $self->_resolve_host($host)->then(
        sub {
            my $addresses = shift;
            for my $addr (@$addresses) {
                if (   $addr->{type} eq 'ipv4'
                    && $self->_is_private_ipv4( $addr->{ip} ) )
                {
                    return 1;
                }
                if (   $addr->{type} eq 'ipv6'
                    && $self->_is_private_ipv6( $addr->{ip} ) )
                {
                    return 1;
                }
            }
            return 0;
        }
    );
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
            if ( $code == 403 || $code == 404 || $code == 405 ) {
                return $self->ua->get_p($url)->then(
                    sub {
                        my $get_tx   = shift;
                        my $get_code = $get_tx->result->code;
                        return 1 if $get_code >= 200 && $get_code < 400;
                        return 1
                          if $get_code == 403
                          || $get_code == 404
                          || $get_code == 405;
                        return Mojo::Promise->reject(
                            "URL returned $get_code error")
                          if $get_code >= 400;
                        return Mojo::Promise->reject(
                            "URL returned unexpected status: $get_code");
                    }
                );
            }
            return Mojo::Promise->reject("URL returned $code error")
              if $code >= 400;
            return Mojo::Promise->reject(
                "URL returned unexpected status: $code");
        }
    )->catch(
        sub {
            my $err        = shift;
            my $err_str    = "$err";
            my $error_type = $self->_classify_error($err_str);
            return Mojo::Promise->reject(
                $self->_format_error_message( $error_type, $err_str ) );
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
            my $err        = shift;
            my $err_str    = "$err";
            my $error_type = $self->_classify_error($err_str);

            if ( $error_type eq 'ssl' ) {
                return Mojo::Promise->reject(
                    "Invalid SSL certificate: $err_str");
            }

            return Mojo::Promise->reject(
                $self->_format_error_message( $error_type, $err_str ) );
        }
    );
}

sub validate_short_code {
    my ( $self, $code ) = @_;
    return defined $code && length($code) == 12 && $code =~ /^[0-9a-zA-Z\-_]+$/;
}

sub validate_url_with_checks {
    my ( $self, $url ) = @_;

    return Mojo::Promise->reject('URL is required')
      unless defined $url && length($url) > 0;

    my $sanitized = sanitize_url($url);
    return Mojo::Promise->reject('Invalid URL format')
      unless defined $sanitized;

    my $parsed = $self->_parse_url($sanitized);
    return Mojo::Promise->reject('Invalid URL format') unless $parsed;
    return Mojo::Promise->reject('Invalid URL format')
      unless $parsed->scheme && $parsed->scheme =~ /^https?$/i;
    return Mojo::Promise->reject('Invalid URL format') unless $parsed->host;

    my $normalized = $parsed->to_string;

    return Mojo::Promise->reject(
        "URL exceeds maximum length of $MAX_URL_LENGTH characters")
      unless $self->is_valid_url_length($normalized);

    return $self->is_blocked_url($normalized)->then(
        sub {
            my $blocked = shift;
            return Mojo::Promise->reject(
                'This URL cannot be shortened (blocked domain or local address)'
            ) if $blocked;

            my $ssl_check =
                $parsed->scheme eq 'https'
              ? $self->check_ssl_certificate($normalized)
              : Mojo::Promise->resolve(1);

            return $ssl_check->then(
                sub { return $self->check_url_reachable($normalized); } )
              ->then( sub { return $normalized; } );
        }
    );
}

1;
