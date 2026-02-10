#!/usr/bin/env perl

use strict;
use warnings;

use Mojo::Redis;
use Mojolicious::Lite -signatures;

my $redis  = Mojo::Redis->new('redis://localhost:6379');
my $pubsub = $redis->pubsub;

my $clients = {};
my @history = ();

my $process_id = sprintf "%p", \$redis;

$pubsub->json('chat:messages')
       ->listen('chat:messages' => sub {
            my ($pubsub, $data, $channel) = @_;

            my $from_process = delete $data->{_process_id};
            return if defined $from_process
                              && $from_process eq $process_id;

            if ($data->{type} eq 'message') {
                push @history, $data;
                shift @history if @history > 10;
            }

            for my $client (values %$clients) {
                $client->{tx}->send({json => $data});
            }
       });

get '/' => sub ($c) {
    $c->render(template => 'index', title => 'Online Chat App');
};

websocket '/chat' => sub ($c) {
    my $id = sprintf "%p", $c->tx;

    $clients->{$id} = { tx => $c->tx, name => 'Anonymous' };

    $c->on(json => sub ($self, $data) {
        if ($data->{type} eq 'typing') {
            broadcast({
                type     => 'typing',
                user     => $clients->{$id}{name},
                isTyping => $data->{isTyping}
            }, $id);
        }
        elsif ($data->{type} eq 'join') {
            $clients->{$id}{name} = $data->{name};

            for my $old_msg (@history) {
                $c->send({json => $old_msg});
            }

            broadcast({ type => 'system', text => "$data->{name} joined" });
            send_user_list();
        }
        elsif ($data->{type} eq 'message') {
            my (undef, $min, $hour) = localtime();
            my $timestamp = sprintf("%02d:%02d", $hour, $min);
            my $msg_out   = {
                type      => 'message',
                user      => $clients->{$id}{name},
                text      => $data->{text},
                timestamp => $timestamp
            };

            push  @history, $msg_out;
            shift @history if @history > 10;

            broadcast($msg_out);
        }
    });

    $c->on(finish => sub {
        my $name = $clients->{$id}{name};
        delete $clients->{$id};
        broadcast({ type => 'system', text => "$name left" });
        send_user_list();
    });
};

sub broadcast ($msg, $exclude_id = undef) {
    my $payload = { %$msg, _process_id => $process_id };

    $pubsub->notify('chat:messages' => $payload);

    for my $id (keys %$clients) {
        next if defined $exclude_id && $id eq $exclude_id;
        $clients->{$id}{tx}->send({json => $msg});
    }
}

sub send_user_list {
    my @names = sort map { $_->{name} } values %$clients;
    broadcast({ type => 'users', list => \@names });
}

app->start;
