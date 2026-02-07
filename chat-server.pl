#!/usr/bin/env perl

use strict;
use warnings;

use Mojolicious::Lite;
use Mojo::JSON qw(decode_json encode_json);

my $clients = {};
my @history;

get '/' => sub {
    my $c = shift;

    $c->render(template => 'index', title => 'Online Chat App');
};

websocket '/chat' => sub {
    my $c  = shift;
    my $id = sprintf "%p", $c->tx;

    $clients->{$id} = { tx => $c->tx, name => 'Anonymous' };

    $c->on(message => sub {
        my ($self, $msg) = @_;

        my $data = eval { decode_json($msg) };
        if ($@ || !$data) {
            app->log->error("Bad JSON received: $@");
            return;
        }

        if ($data->{type} eq 'typing') {
            # Send the typing status to everyone EXCEPT the person typing
            broadcast({
                type     => 'typing',
                user     => $clients->{$id}{name},
                isTyping => $data->{isTyping}
            }, $id);
        }
        elsif ($data->{type} eq 'join') {
            $clients->{$id}{name} = $data->{name};

            # Send existing history ONLY to the user who just joined
            for my $old_msg (@history) {
                $c->send(encode_json($old_msg));
            }

            broadcast({ type => 'system', text => "$data->{name} joined" });
            send_user_list();
        }
        elsif ($data->{type} eq 'message') {
            my (undef, $min, $hour) = localtime();
            my $timestamp = sprintf("%02d:%02d", $hour, $min);
            my $msg_out   = {
                user      => $clients->{$id}{name},
                text      => $data->{text},
                timestamp => $timestamp
            };

            # Push to history and keep only the last 10
            push @history, $msg_out;
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

sub broadcast {
    my $msg = encode_json(shift);
    $_->{tx}->send($msg) for values %$clients;
}

sub send_user_list {
    my @names = sort map { $_->{name} } values %$clients;
    broadcast({ type => 'users', list => \@names });
}

app->start;
