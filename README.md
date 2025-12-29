# urupam

`urupam` is a lightweight URL shortener built with Perl and Mojolicious, and backed by Redis.

## Basic requirements

- Perl 5.42.0
- Carton (handles perl deps)
- Redis

## Installation

Run the installation script:

```sh
scripts/install.sh
```

Enable and start the systemd service:

```sh
sudo systemctl enable --now urupam
```

### Using docker

Build the image and use the `docker-compose` file:

```sh
cd docker
docker build -t urupam .
docker compose up -d
```

## Hacking

To run the application in development, you'll first need a Redis server.

The easiest way is to start a local Redis instance using Docker:

```sh
docker run --name mojo-redis -p 6379:6379 -d redis
```

Install Perl dependencies with [Carton](https://github.com/perl-carton/carton):

```sh
carton install
```

Add your changes and your tests, then start the application with `morbo`:

```sh
carton exec morbo bin/urupam
```

The application will listen on port `3000` by default.

## Running tests

As every perl project, tests are located in the `t` directory.

To run tests, use the `carton` command:

```sh
carton exec prove -lr t/
```

To run specific tests (like integration tests), use:

```sh
carton exec prove -lr t/integration.t
```

## License

This project is licensed under the GPLv3+ License. See the [LICENSE](LICENSE) file for details.
