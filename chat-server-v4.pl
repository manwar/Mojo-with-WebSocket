#!/usr/bin/env perl

use strict;
use warnings;

use Encode qw(encode);
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;

use PAGI::Server;
use PAGI::WebSocket;
use PAGI::App::File;
use PAGI::App::Router;

use Mojo::Pg;
use Mojo::JSON qw(encode_json decode_json);
use feature 'signatures';

my $router       = PAGI::App::Router->new;
my $css_app      = PAGI::App::File->new(root => './public/css')->to_app;
my $js_app       = PAGI::App::File->new(root => './public/js')->to_app;

my $loop         = IO::Async::Loop->new;
my $pg           = Mojo::Pg->new('postgresql://chatuser:chatpass@localhost/chat_db');
my $pubsub       = $pg->pubsub;

my $clients      = {};
my @history      = ();
my $process_id   = sprintf "%p", \$pg;
my $cleanup_timer;

$pg->db->query(q{
    CREATE TABLE IF NOT EXISTS chat_users (
        session_id TEXT PRIMARY KEY,
        username   TEXT NOT NULL,
        last_seen  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
});

$router->mount('/css' => $css_app);
$router->mount('/js'  => $js_app);

$router->get('/' => async sub {
    my ($scope, $receive, $send) = @_;

    open my $fh, '<', './templates/index.html.ep'
        or die "Cannot open template: $!";
    my $template = do { local $/; <$fh> };
    close $fh;

    $template =~ s/<%= \$title %>/PAGI Online Chat/g;

    my $body = encode('UTF-8', $template);

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            ['content-type', 'text/html; charset=utf-8'],
        ]
    });

    await $send->({
        type => 'http.response.body',
        body => $body,
    });
});

$router->websocket('/chat' => async sub {
    my ($scope, $receive, $send) = @_;

    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    await $ws->accept;

    my $id = sprintf "%p", \$ws;
    $clients->{$id} = { ws => $ws, name => 'Anonymous' };

    # Heartbeat timer (30 seconds)
    my $heartbeat_timer = IO::Async::Timer::Periodic->new(
        interval => 30,
        on_tick  => sub {
            return unless $clients->{$id};

            eval {
                $pg->db->query(q{
                    UPDATE chat_users
                       SET last_seen = NOW()
                     WHERE session_id = ?
                }, $id);
            };
        }
    );

    $loop->add($heartbeat_timer);
    $heartbeat_timer->start;

    # Handle incoming messages
    while (1) {
        my $event = await $ws->receive;
        last unless defined $event;

        my $msg_text = $event->{text} // $event->{bytes};
        next unless defined $msg_text;

        my $data = eval { decode_json($msg_text) };
        next unless $data;

        if ($data->{type} eq 'typing') {
            await broadcast({
                type     => 'typing',
                user     => $clients->{$id}{name},
                isTyping => $data->{isTyping} ? 1 : 0
            }, $id);
        }
        elsif ($data->{type} eq 'join') {
            $clients->{$id}{name} = $data->{name};

            $pg->db->query(q{
                INSERT INTO chat_users (session_id, username, last_seen)
                VALUES (?, ?, NOW())
                ON CONFLICT (session_id)
                DO UPDATE SET username  = EXCLUDED.username,
                              last_seen = NOW()
            }, $id, $data->{name});

            # Send history to new user
            foreach my $old_msg (@history) {
                await $ws->send_text(encode_json($old_msg));
            }

            await broadcast({
                type => 'system',
                text => "$data->{name} joined"
            });

            await send_user_list();
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

            push @history, $msg_out;
            shift @history if @history > 10;

            await broadcast($msg_out);
        }
    }

    # Cleanup on disconnect
    my $name = $clients->{$id}{name};
    delete $clients->{$id};

    $heartbeat_timer->stop;
    $loop->remove($heartbeat_timer);

    $pg->db->query(q{DELETE FROM chat_users WHERE session_id = ?}, $id);

    await broadcast({ type => 'system', text => "$name left" });
    await send_user_list();
});

my $app = $router->to_app;

my $app_with_lifespan = sub {
    my ($scope, $receive, $send) = @_;

    # Handle lifespan scope
    if ($scope->{type} eq 'lifespan') {
        return handle_lifespan($scope, $receive, $send);
    }

    return $app->($scope, $receive, $send);
};

async sub handle_lifespan {
    my ($scope, $receive, $send) = @_;

    while (my $event = await $receive->()) {
        if ($event->{type} eq 'lifespan.startup') {
            print "Server starting up...\n";

            # Initialise cleanup timer
            $cleanup_timer = IO::Async::Timer::Periodic->new(
                interval => 60,
                on_tick  => sub {
                    eval {
                        $pg->db->query(q{
                            DELETE FROM chat_users
                            WHERE last_seen < NOW() - INTERVAL '2 minutes'
                        });
                    };
                }
            );

            $loop->add($cleanup_timer);
            $cleanup_timer->start;

            # Setup PostgreSQL LISTEN/NOTIFY
            $pubsub->listen('chat_messages' => sub {
                my ($pubsub, $payload) = @_;

                my $data = ref($payload) eq 'HASH'
                    ? $payload
                    : eval { decode_json($payload) };

                return unless $data;

                my $from_process = delete $data->{_process_id};
                return if defined $from_process && $from_process eq $process_id;

                if ($data->{type} eq 'message') {
                    push @history, $data;
                    shift @history if @history > 10;
                }

                foreach my $client (values %$clients) {
                    eval {
                        $client->{ws}->send_json($data);
                    };
                }
            });

            await $send->({
                type => 'lifespan.startup.complete'
            });
        }
        elsif ($event->{type} eq 'lifespan.shutdown') {
            print "Server shutting down...\n";

            # Cleanup resources
            $cleanup_timer->stop if $cleanup_timer;
            $loop->remove($cleanup_timer) if $cleanup_timer;

            eval { $pubsub->unlisten('chat_messages') };
            eval { $pg->db->disconnect };

            await $send->({
                type => 'lifespan.shutdown.complete'
            });

            last;
        }
    }
}

async sub broadcast ($msg, $exclude_id = undef) {
    my $payload = { %$msg, _process_id => $process_id };
    eval { $pubsub->notify('chat_messages' => encode_json($payload)) };

    foreach my $id (keys %$clients) {
        next if defined $exclude_id && $id eq $exclude_id;
        eval {
            await $clients->{$id}{ws}->send_text(encode_json($msg));
        };
    }
}

async sub send_user_list {
    eval {
        $pg->db->query(q{
            DELETE FROM chat_users
             WHERE last_seen < NOW() - INTERVAL '2 minutes'
        });

        my $results = $pg->db->query(q{
            SELECT DISTINCT username
              FROM chat_users
             ORDER BY username
        });

        my @names = map { $_->{username} } $results->hashes->each;

        await broadcast({
            type => 'users',
            list => \@names,
        });
    };
}

my $server = PAGI::Server->new(
    app  => $app_with_lifespan,
    host => '127.0.0.1',
    port => 3000,
);

$loop->add($server);
$server->listen->get;

$loop->run;
