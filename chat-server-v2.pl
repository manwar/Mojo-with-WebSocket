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

# Periodic cleanup: remove stale users every 60 seconds
Mojo::IOLoop->recurring(60 => sub {
    # Remove users who haven't been seen in 2 minutes
    my $cutoff = time - 120;
    my $db = $redis->db;

    # Get all user session IDs
    $db->hgetall('chat:users' => sub {
        my ($db, $err, $result) = @_;
        return if $err;

        my $user_hash = $result || {};
        for my $session_id (keys %$user_hash) {
            my $data = Mojo::JSON::decode_json($user_hash->{$session_id});
            if ($data->{last_seen} < $cutoff) {
                $redis->db->hdel('chat:users', $session_id);
            }
        }
    });
});

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

    # Heartbeat: update every 30 seconds
    my $heartbeat = Mojo::IOLoop->recurring(30 => sub {
        return unless $clients->{$id};  # User disconnected

        my $user_data = Mojo::JSON::encode_json({
            username  => $clients->{$id}{name},
            last_seen => time
        });

        $redis->db->hset('chat:users', $id, $user_data);
    });

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

            # Add user to Redis
            my $user_data = Mojo::JSON::encode_json({
                username  => $data->{name},
                last_seen => time
            });

            $redis->db->hset('chat:users', $id, $user_data);

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

        # Remove heartbeat timer
        Mojo::IOLoop->remove($heartbeat);

        # Remove user from Redis
        $redis->db->hdel('chat:users', $id);

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
    # Get all active users from Redis (across all processes)
    $redis->db->hgetall('chat:users' => sub {
        my ($db, $err, $result) = @_;

        if ($err) {
            warn "Error fetching users: $err";
            return;
        }

        my %seen_names;
        my $cutoff    = time - 120;
        my $user_hash = $result || {};

        for my $session_id (keys %$user_hash) {
            my $data = Mojo::JSON::decode_json($user_hash->{$session_id});

            # Skip stale users
            next if $data->{last_seen} < $cutoff;

            # Deduplicate by username
            $seen_names{$data->{username}} = 1;
        }

        my @names = sort keys %seen_names;

        broadcast({ type => 'users', list => \@names });
    });
}

app->start;
