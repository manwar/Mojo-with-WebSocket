#!/usr/bin/env perl

# REQUIRED RUNTIME SETUP - READ BEFORE RUNNING
#
# This app uses Mojo::Pg in non-blocking mode, which runs on Mojo::IOLoop,
# a different reactor from the IO::Async::Loop this app (and pagi-server)
# run on. Without both of the following, every DB call hangs forever and
# the app fails after PAGI::Server's 30s lifespan-startup timeout:
#
#   1. Install IO::Async::Loop::EV:
#        cpanm IO::Async::Loop::EV
#      (plain EV being installed is NOT enough, IO::Async::Loop->new does
#      not auto-prefer EV on its own; it must be told to, via #2 below.)
#
#   2. Set IO_ASYNC_LOOP=EV for the whole process when you launch it:
#        IO_ASYNC_LOOP=EV pagi-server chat-server-v6.pl
#      This is required even though pagi-server, not this script, is what
#      actually constructs the IO::Async::Loop, the env var is what steers
#      pagi-server's own choice of reactor too.
#
# See PAGI::FastAPI's "MIXING WITH OTHER EVENT LOOPS" documentation section
# for the full explanation.

use v5.36;
use Encode qw(encode);
use EV;

# Fail fast with a clear message rather than hanging for 30s and dying with
# an opaque lifespan-timeout error if someone runs this without the env var.
die <<'MSG' unless ($ENV{IO_ASYNC_LOOP} // '') eq 'EV';
FATAL: IO_ASYNC_LOOP=EV is not set.

This app's Mojo::Pg calls will hang forever without it, see the comment
block at the top of this file for why, and re-run as:

    IO_ASYNC_LOOP=EV pagi-server chat-server-v6.pl
MSG

use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use PAGI::App::File;
use PAGI::FastAPI;
use Mojo::Pg;
use Mojo::JSON qw(encode_json decode_json);

my $app = PAGI::FastAPI->new(
    title   => 'PAGI::FastAPI Chat Server',
    version => '1.0.0',
);

my $loop   = IO::Async::Loop->new;
my $pg     = Mojo::Pg->new('postgresql://chatuser:chatpass@localhost/chat_db');
my $pubsub = $pg->pubsub;

my $clients    = {};
my @history    = ();
my $process_id = sprintf "%p", \$pg;
my $cleanup_timer;

# Mojo::Pg non-blocking query bridge: wraps the callback-style
# $pg->db->query($sql, @binds, sub {...})  API in a Future, so
# it can be awaited like any other async call.
# Requires the shared EV reactor set up above, see the comment
# there.

async sub pg_query {
    my @args = @_;
    my $f = Future->new;
    $pg->db->query(@args, sub {
        my ($db, $err, $results) = @_;
        if ($err) { $f->fail($err) }
        else      { $f->done($results) }
    });
    return await $f;
}

$app->mount('/css', PAGI::App::File->new(root => './public/css')->to_app);
$app->mount('/js',  PAGI::App::File->new(root => './public/js')->to_app);

$app->get('/',
    handler => async sub ($c) {
        open my $fh, '<', './templates/index.html.ep'
            or die "Cannot open template: $!";
        my $template = do { local $/; <$fh> };
        close $fh;

        $template =~ s/<%= \$title %>/PAGI::FastAPI Online Chat/g;

        $c->set_header('content-type', 'text/html; charset=utf-8');
        return encode('UTF-8', $template);
    }
);

$app->websocket('/chat',
    handler => async sub ($ws, $deps) {
        await $ws->accept;

        my $id = "$ws";
        $clients->{$id} = { ws => $ws, name => 'Anonymous' };

        # Heartbeat timer (30 seconds)
        my $heartbeat_timer = IO::Async::Timer::Periodic->new(
            interval => 30,
            on_tick  => sub {
                return unless $clients->{$id};
                # on_tick is a plain (non-async) callback, so we can't await
                # here directly, fire the query and swallow any failure.
                (async sub {
                    await pg_query(q{
                        UPDATE chat_users
                        SET last_seen = NOW()
                        WHERE session_id = ?
                    }, $id);
                })->()->else(sub { Future->done })->retain;
            }
        );
        $loop->add($heartbeat_timer);
        $heartbeat_timer->start;

        # Handle incoming messages
        while (1) {
            my $msg_text = await $ws->receive_text;
            last unless defined $msg_text;

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

                await pg_query(q{
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
                my $msg_out = {
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
        await pg_query(q{DELETE FROM chat_users WHERE session_id = ?}, $id);
        await broadcast({ type => 'system', text => "$name left" });
        await send_user_list();
    }
);

$app->on_startup(async sub {
    print "Server starting up...\n";

    await pg_query(q{
        CREATE TABLE IF NOT EXISTS chat_users (
            session_id TEXT PRIMARY KEY,
            username   TEXT NOT NULL,
            last_seen  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    });

    $cleanup_timer = IO::Async::Timer::Periodic->new(
        interval => 60,
        on_tick  => sub {
            (async sub {
                await pg_query(q{
                    DELETE FROM chat_users
                    WHERE last_seen < NOW() - INTERVAL '2 minutes'
                });
            })->()->else(sub { Future->done })->retain;
        }
    );
    $loop->add($cleanup_timer);
    $cleanup_timer->start;

    # Cross-process fan-out: other server processes publish here too, so a
    # message sent to the server on :3000 reaches clients connected to :3001.
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
            eval { $client->{ws}->send_json($data) };
        }
    });
});

$app->on_shutdown(async sub {
    print "Server shutting down...\n";

    $cleanup_timer->stop if $cleanup_timer;
    $loop->remove($cleanup_timer) if $cleanup_timer;
    eval { $pubsub->unlisten('chat_messages') };
    eval { $pg->db->disconnect };
});

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
        await pg_query(q{
            DELETE FROM chat_users
            WHERE last_seen < NOW() - INTERVAL '2 minutes'
        });

        my $results = await pg_query(q{
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

$app->to_app;
