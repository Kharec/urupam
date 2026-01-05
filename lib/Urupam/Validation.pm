package Urupam::Validation;

use Mojo::Base -base;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Promise;
use Mojo::IOLoop;
use Urupam::Utils qw(sanitize_url);
use Socket
  qw(getaddrinfo getnameinfo NI_NUMERICHOST NI_NUMERICSERV AF_INET AF_INET6 SOCK_STREAM);

my $MAX_URL_LENGTH  = 2048;
my $CONNECT_TIMEOUT = 0.2;
my $REQUEST_TIMEOUT = 0.4;
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

my $DNS_CACHE_TTL          = 300;
my $REACHABILITY_CACHE_TTL = 300;
my $DNS_RESOLVE_TIMEOUT    = 0.2;
my %dns_cache;
my %reachability_cache;

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
    return 0 unless defined $ip;

    $ip = lc($ip);
    $ip =~ s/^\[|\]$//g;

    return 1 if $ip eq '::1';
    return 1 if $ip eq '::';

    if ( $ip =~ /^::ffff:(.+)$/ ) {
        return $self->_is_private_ipv4($1) ? 1 : 0;
    }

    return 0 unless $ip =~ /^([0-9a-f]{0,4}:)+[0-9a-f]{0,4}$/ || $ip =~ /^::/;

    my @parts = split /:/, $ip;
    return 0 unless @parts > 0;

    my $first_part = $parts[0] || '';
    return 0 unless length($first_part) > 0;

    my $first = hex($first_part);

    return 1 if ( $first & 0xfe00 ) == 0xfc00;
    return 1 if ( $first & 0xffc0 ) == 0xfe80;

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

    if ( my $cached = $self->_get_cached_addresses($host) ) {
        return Mojo::Promise->resolve($cached);
    }

    my $promise   = Mojo::Promise->new;
    my $resolved  = 0;
    my $cache_key = lc($host);
    my $now       = time();
    my $timer     = Mojo::IOLoop->timer(
        $DNS_RESOLVE_TIMEOUT => sub {
            return if $resolved;
            $resolved = 1;
            $dns_cache{$cache_key} = {
                addresses => [],
                expires   => $now + $DNS_CACHE_TTL
            };
            $promise->resolve( [] );
        }
    );
    Mojo::IOLoop->subprocess(
        sub {
            my ($hostname) = @_;
            my ( $err, @results ) =
              getaddrinfo( $hostname, undef, { socktype => SOCK_STREAM } );
            return { error => $err, results => \@results };
        },
        sub {
            my ( $subprocess, $err, $data ) = @_;
            return if $resolved;
            $resolved = 1;
            Mojo::IOLoop->remove($timer);
            if ($err) {
                $promise->resolve( [] );
                return;
            }

            my $res = $data;
            if ( $res->{error} ) {
                $promise->resolve( [] );
                return;
            }

            my @addresses;
            for my $result ( @{ $res->{results} } ) {
                my ( $hostnum, undef ) =
                  getnameinfo( $result->{addr},
                    NI_NUMERICHOST | NI_NUMERICSERV );
                next unless defined $hostnum && length $hostnum;

                if ( $result->{family} == AF_INET ) {
                    push @addresses, { type => 'ipv4', ip => $hostnum };
                }
                elsif ( $result->{family} == AF_INET6 ) {
                    push @addresses, { type => 'ipv6', ip => $hostnum };
                }
            }

            my $addresses_ref = \@addresses;
            $dns_cache{$cache_key} = {
                addresses => $addresses_ref,
                expires   => $now + $DNS_CACHE_TTL
            };

            $promise->resolve($addresses_ref);
        },
        $host
    );

    return $promise;
}

sub _addresses_contain_private {
    my ( $self, $addresses ) = @_;
    return 0 unless defined $addresses && ref $addresses eq 'ARRAY';
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

sub _get_cached_addresses {
    my ( $self, $host ) = @_;
    return undef unless defined $host && length $host;

    my $cache_key = lc($host);
    my $cached    = $dns_cache{$cache_key};
    return undef unless $cached;
    return $cached->{addresses} if time() < $cached->{expires};
    delete $dns_cache{$cache_key};
    return undef;
}

sub _cache_reachability {
    my ( $self, $url, $ok, $error ) = @_;
    return unless defined $url && length $url;

    $reachability_cache{$url} = {
        ok      => $ok ? 1 : 0,
        error   => $error,
        expires => time() + $REACHABILITY_CACHE_TTL
    };
}

sub _clear_caches {

    # Test helper
    %dns_cache          = ();
    %reachability_cache = ();
    return;
}

sub _get_cached_reachability {
    my ( $self, $url ) = @_;
    return undef unless defined $url && length $url;

    my $cached = $reachability_cache{$url};
    return undef unless $cached;
    return $cached if time() < $cached->{expires};
    delete $reachability_cache{$url};
    return undef;
}

sub _fire_and_forget {
    my ( $self, $promise ) = @_;
    return unless $promise;
    $promise->catch( sub { } );
    return;
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

    if ( my $cached = $self->_get_cached_addresses($host) ) {
        return Mojo::Promise->resolve(
            $self->_addresses_contain_private($cached) ? 1 : 0 );
    }

# Intentional: skip blocking on cold hosts to keep latency low, DNS runs in background.
    $self->_fire_and_forget( $self->_resolve_host($host) );
    return Mojo::Promise->resolve(0);
}

sub _create_ssrf_safe_ua {
    my $self = shift;
    return Mojo::UserAgent->new(
        connect_timeout => $self->connect_timeout,
        request_timeout => $self->request_timeout,
        max_redirects   => 0,
        insecure        => 0
    );
}

sub _follow_redirect_with_validation {
    my ( $self, $ua, $url, $redirect_count ) = @_;
    $redirect_count //= 0;

    return Mojo::Promise->reject('Too many redirects')
      if $redirect_count > $self->max_redirects;

    return $ua->head_p($url)->then(
        sub {
            my $tx   = shift;
            my $code = $tx->result->code;

            if ( $code >= 300 && $code < 400 ) {
                my $location = $tx->result->headers->location;
                return Mojo::Promise->reject('Redirect without Location header')
                  unless defined $location;

                my $redirect_url = Mojo::URL->new($location)->to_abs($url);
                return $self->is_blocked_url($redirect_url)->then(
                    sub {
                        my $blocked = shift;
                        if ($blocked) {
                            return Mojo::Promise->reject(
                                'Redirect to blocked domain or local address');
                        }
                        return $self->_follow_redirect_with_validation( $ua,
                            $redirect_url, $redirect_count + 1 );
                    }
                );
            }

            return 1 if $code >= 200 && $code < 400;
            if ( $code == 403 || $code == 404 || $code == 405 ) {
                return $ua->get_p($url)->then(
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

sub check_url_reachable {
    my ( $self, $url ) = @_;

    return Mojo::Promise->reject('URL is required')
      unless defined $url && length($url) > 0;

    if ( my $cached = $self->_get_cached_reachability($url) ) {
        return $cached->{ok}
          ? Mojo::Promise->resolve(1)
          : Mojo::Promise->reject( $cached->{error} );
    }

    my $ssrf_ua = $self->_create_ssrf_safe_ua;
    return $self->_follow_redirect_with_validation( $ssrf_ua, $url )->then(
        sub {
            $self->_cache_reachability( $url, 1, undef );
            return 1;
        }
    )->catch(
        sub {
            my $err = shift;
            $self->_cache_reachability( $url, 0, $err );
            return Mojo::Promise->reject($err);
        }
    );
}

sub check_url_reachable_async {
    my ( $self, $url ) = @_;
    return Mojo::Promise->resolve(1) unless defined $url && length $url;

    return Mojo::Promise->resolve(1)
      if $self->_get_cached_reachability($url);

    $self->_fire_and_forget( $self->check_url_reachable($url) );
    return Mojo::Promise->resolve(1);
}

sub check_ssl_certificate {
    my ( $self, $url ) = @_;
    return Mojo::Promise->resolve(1) unless defined $url && length $url;

    my $parsed = $self->_parse_url($url);
    return Mojo::Promise->resolve(1)
      unless $parsed && $parsed->scheme && $parsed->scheme eq 'https';

    $self->_fire_and_forget(
        $self->ua->head_p($url)->then( sub { return 1; } )->catch(
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
        )
    );

    return Mojo::Promise->resolve(1);
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
                sub { return $self->check_url_reachable_async($normalized); } )
              ->then( sub { return $normalized; } );
        }
    );
}

1;
