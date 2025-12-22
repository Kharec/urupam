requires 'Mojo::Base';
requires 'Mojo::Promise';
requires 'Mojo::Redis2';
requires 'Mojo::URL';
requires 'Mojo::UserAgent';
requires 'Mojo::Util';
requires 'Mojolicious';

on test => sub {
    requires 'Test::Mojo';
    requires 'Test::More';
};
