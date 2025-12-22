package Urupam::URL;

use Mojo::Base -base;
use Mojo::Promise;
use Mojo::Util qw(b64_encode);

has db => sub { die 'db attribute required' };

my $URL_PREFIX   = 'urupam:url:';
my $CODE_LENGTH  = 12;
my $MAX_RETRIES  = 3;
my $CODE_PATTERN = qr/^[0-9a-zA-Z\-_]+$/;
my $CHARSET =
  '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_';
my $MAX_URL_LENGTH = 2048;

sub _validate_short_code {
    my ( $self, $code ) = @_;
    return
         defined $code
      && length($code) == $CODE_LENGTH
      && $code =~ $CODE_PATTERN;
}

sub _validate_url {
    my ( $self, $url ) = @_;
    return
         defined $url
      && length($url) > 0
      && length($url) <= $MAX_URL_LENGTH;
}

sub _generate_random_code {
    my ($self) = @_;
    my $code = '';
    for ( 1 .. $CODE_LENGTH ) {
        $code .= substr( $CHARSET, int( rand( length($CHARSET) ) ), 1 );
    }
    return $code;
}

sub _generate_code_from_url {
    my ( $self, $original_url ) = @_;

    my $encoded = b64_encode( $original_url, '' );
    $encoded =~ s/\+/-/g;
    $encoded =~ s/\//_/g;
    $encoded =~ s/=//g;
    $encoded =~ s/[^0-9a-zA-Z\-_]//g;

    return undef if length($encoded) == 0;

    if ( length($encoded) < $CODE_LENGTH ) {
        $encoded = $encoded x int( ( $CODE_LENGTH / length($encoded) ) + 1 );
    }

    my $max_start = length($encoded) - $CODE_LENGTH;
    my $start_pos = int( rand( ( $max_start > 0 ? $max_start : 0 ) + 1 ) );

    return substr( $encoded, $start_pos, $CODE_LENGTH );
}

sub generate_short_code {
    my ( $self, $original_url, $use_pure_random ) = @_;

    unless ( $self->_validate_url($original_url) ) {
        return Mojo::Promise->reject(
            length( $original_url // '' ) > $MAX_URL_LENGTH
            ? "URL exceeds maximum length of $MAX_URL_LENGTH characters"
            : 'Original URL is required'
        );
    }

    my $short_code =
        $use_pure_random
      ? $self->_generate_random_code()
      : ( $self->_generate_code_from_url($original_url)
          // $self->_generate_random_code() );

    return Mojo::Promise->resolve($short_code);
}

sub _try_set_code {
    my ( $self, $short_code, $original_url ) = @_;
    my $key = $URL_PREFIX . $short_code;
    return $self->db->setnx( $key, $original_url )->then(
        sub {
            my $success = shift;
            return $success ? $short_code : undef;
        }
    );
}

sub create_short_url {
    my ( $self, $original_url, $custom_code ) = @_;

    unless ( $self->_validate_url($original_url) ) {
        return Mojo::Promise->reject(
            length( $original_url // '' ) > $MAX_URL_LENGTH
            ? "URL exceeds maximum length of $MAX_URL_LENGTH characters"
            : 'Original URL is required'
        );
    }

    if ($custom_code) {
        unless ( $self->_validate_short_code($custom_code) ) {
            return Mojo::Promise->reject('Invalid short code format');
        }
        return $self->_try_set_code( $custom_code, $original_url )->then(
            sub {
                my $code = shift;
                return $code
                  ? $code
                  : Mojo::Promise->reject('Short code already exists');
            }
        )->catch(
            sub {
                my $err = shift;
                return Mojo::Promise->reject("Database error: $err");
            }
        );
    }

    my $retry_count = 0;

    my $attempt_create;
    $attempt_create = sub {
        return $self->generate_short_code( $original_url, $retry_count > 0 )
          ->then(
            sub {
                my $attempt_code = shift;
                return $self->_try_set_code( $attempt_code, $original_url )
                  ->then(
                    sub {
                        my $code = shift;
                        if ($code) {
                            return $code;
                        }

                        $retry_count++;
                        if ( $retry_count <= $MAX_RETRIES ) {
                            return $attempt_create->();
                        }

                        return Mojo::Promise->reject(
                            'Failed to generate unique short code after retry');
                    }
                  );
            }
          )->catch(
            sub {
                my $err = shift;
                if (   $retry_count < $MAX_RETRIES
                    && $err =~ /database|connection|timeout/i )
                {
                    $retry_count++;
                    return $attempt_create->();
                }
                return Mojo::Promise->reject(
                    "Failed to create short URL: $err");
            }
          );
    };

    return $attempt_create->();
}

sub get_original_url {
    my ( $self, $short_code ) = @_;

    unless ( $self->_validate_short_code($short_code) ) {
        return Mojo::Promise->reject('Invalid short code format');
    }

    return $self->db->get( $URL_PREFIX . $short_code );
}

1;

