#!/usr/bin/env perl

use strict;
use warnings;

use Mojo::Pg;
use Mojo::JSON qw(encode_json decode_json);
use Mojolicious::Lite -signatures;

my $pg     = Mojo::Pg->new('postgresql://chatuser:chatpass@localhost/chat_db');
my $pubsub = $pg->pubsub;

$pg->db->query(q{
    CREATE TABLE IF NOT EXISTS chat_users (
        session_id TEXT PRIMARY KEY,
        username   TEXT NOT NULL,
        last_seen  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
});

my $clients = {};
my @history = ();

my $process_id = sprintf "%p", \$pg;

# Periodic cleanup: remove stale users every 60 seconds
Mojo::IOLoop->recurring(60 => sub {
    # Remove users who haven't been seen in 2 minutes
    $pg->db->query(q{
        DELETE FROM chat_users
        WHERE last_seen < NOW() - INTERVAL '2 minutes'
    });
});

$pubsub->listen('chat_messages' => sub {
    my ($pubsub, $payload) = @_;

    my $data = ref($payload) eq 'HASH' ? $payload : decode_json($payload);

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
        return unless $clients->{$id};
        $pg->db->query(
            'UPDATE chat_users SET last_seen = NOW() WHERE session_id = ?',
            $id
        );
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

            # Add user to database
            $pg->db->query(
                'INSERT INTO chat_users (session_id, username, last_seen) VALUES (?, ?, NOW())
                 ON CONFLICT (session_id) DO UPDATE SET username = EXCLUDED.username, last_seen = NOW()',
                $id, $data->{name}
            );

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

        # Remove user from database
        $pg->db->query('DELETE FROM chat_users WHERE session_id = ?', $id);

        broadcast({ type => 'system', text => "$name left" });
        send_user_list();
    });
};

sub broadcast ($msg, $exclude_id = undef) {
    my $payload = { %$msg, _process_id => $process_id };

    $pubsub->notify('chat_messages' => encode_json($payload));

    for my $id (keys %$clients) {
        next if defined $exclude_id && $id eq $exclude_id;
        $clients->{$id}{tx}->send({json => $msg});
    }
}

sub send_user_list {
    # Clean up stale users (not seen in last 2 minutes)
    $pg->db->query(q{
        DELETE FROM chat_users
        WHERE last_seen < NOW() - INTERVAL '2 minutes'
    });

    # Get all active users from database (across all processes)
    my $results = $pg->db->query(q{
        SELECT DISTINCT username
        FROM chat_users
        ORDER BY username
    });

    my @names = map { $_->{username} } $results->hashes->each;

    broadcast({ type => 'users', list => \@names });
}

app->start;
