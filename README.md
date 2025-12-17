# urupam

`urupam` is a small URL shortener written in Perl with Mojolicious, using Redis for storage.

## Requirements

- Perl 5.42.0
- Mojolicious 9.42

## Roadmap

- [ ] connect to redis
- [ ] create dummy API endpoints
- [ ] decide how to handle short url generation
- [ ] avoid collisions in short urls
- [ ] redirect to the original url
- [ ] validate URLs and handle errors
- [ ] create a simple and clean UI
- [ ] manage/delete short urls
- [ ] create `Makefile.PL`
- [ ] create systemd service
- [ ] create `Dockerfile`
- [ ] create `docker-compose.yml`
- [ ] add unit tests along the way

## How to run

### Dev

To run the application in development, you'll first need a Redis server. The easiest way is to start a local Redis instance using Docker:

```sh
docker run --name mojo-redis -p 6379:6379 -d redis
```

Install Perl dependencies with [Carton](https://github.com/perl-carton/carton):

```sh
carton install
```

Start the application with `morbo`:

```sh
carton exec morbo bin/urupam
```

Open [http://127.0.0.1:3000](http://127.0.0.1:3000) in your browser.

### Install

Use the provided `Makefile.pl`:

```sh
perl Makefile.PL
make
make test
sudo make install
```

Activate/enable the systemd service:

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

## License

This project is licensed under the GPLv3+ License. See the [LICENSE](LICENSE) file for details.
