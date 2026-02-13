package ChatApp;

use v5.40;

use Encode qw(encode);
use Future::AsyncAwait;

use Mooish::Base;
use Thunderhorse::App;

use Mojo::Pg;
use Mojo::JSON qw(encode_json decode_json);

extends 'Thunderhorse::App';

has pg      => (
    is      => 'lazy',
    builder => sub {
        Mojo::Pg->new('postgresql://chatuser:chatpass@localhost/chat_db')
    },
);

has pubsub  => (
    is      => 'lazy',
    builder => sub { shift->pg->pubsub },
);

has clients => (
    is      => 'ro',
    default => sub { {} },
);

has history => (
    is      => 'ro',
    default => sub { [] },
);

has process_id => (
    is         => 'lazy',
    builder    => sub { sprintf "%p", \$_[0] },
);

sub init_db ($self) {
    $self->pg->db->query(q{
        CREATE TABLE IF NOT EXISTS chat_users (
            session_id TEXT PRIMARY KEY,
            username   TEXT NOT NULL,
            last_seen  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    });
}

sub build ($self) {
    my $router = $self->router;

    $self->init_db;

    # Serve CSS files
    $router->add('/css/*path' => {
        action => 'http.get',
        to     => sub {
            my ($self, $ctx, $path) = @_;
            $path =~ s{\.\./}{}g;
            $path =~ s{^/}{};
            my $file = "public/css/$path";

            if (-f $file && -r $file) {
                if (open my $fh, '<', $file) {
                    my $content = do { local $/; <$fh> };
                    close $fh;
                    $ctx->res->content_type('text/css');
                    $ctx->res->header('Cache-Control' => 'max-age=3600');
                    return $content;
                }
            }

            $ctx->res->status(404);
            return "CSS file not found: $path";
        },
    });

    # Serve JS files
    $router->add('/js/*path' => {
        action => 'http.get',
        to     => sub {
            my ($self, $ctx, $path) = @_;
            $path =~ s{\.\./}{}g;
            $path =~ s{^/}{};
            my $file = "public/js/$path";

            if (-f $file && -r $file) {
                if (open my $fh, '<', $file) {
                    my $content = do { local $/; <$fh> };
                    close $fh;
                    $ctx->res->content_type('application/javascript');
                    $ctx->res->header('Cache-Control' => 'max-age=3600');
                    return $content;
                }
            }

            $ctx->res->status(404);
            return "JS file not found: $path";
        },
    });

    # Main page
    $router->add('/' => {
        action => 'http.get',
        to     => sub {
            my ($self, $ctx) = @_;

            open my $fh, '<', './templates/index.html.ep'
                or die "Cannot open template: $!";
            my $template = do { local $/; <$fh> };
            close $fh;

            $template =~ s/<%= \$title %>/Thunderhorse Chat/g;

            $ctx->res->content_type('text/html; charset=utf-8');
            return Encode::encode('UTF-8', $template);
        },
    });

    # WebSocket endpoint
    $router->add('/chat' => {
        action => 'websocket',
        to     => async sub {
            my ($app, $ctx_facade) = @_;

            my $ctx = $ctx_facade->{context};
            my $ws  = $ctx->ws;

            await $ws->accept;

            my $id = sprintf "%p", \$ws;
            my $pagi_send = $ctx->{pagi}[2];

            $app->clients->{$id} = {
                ws        => $ws,
                name      => 'Anonymous',
                pagi_send => $pagi_send
            };

            while (1) {
                my $event = await $ws->receive;
                last unless defined $event;

                my $msg_text = $event->{text};
                next unless defined $msg_text;

                # Handle join messages
                my $data = decode_json($msg_text);
                if ($data->{type} eq 'join') {
                    $app->clients->{$id}{name} = $data->{name};

                    # Send history to the new joiner
                    foreach my $old_msg (@{$app->history}) {
                        await $pagi_send->({
                            type => 'websocket.send',
                            text => encode_json($old_msg)
                        });
                    }

                    # Send welcome message to joiner
                    await $pagi_send->({
                        type => 'websocket.send',
                        text => encode_json({
                            type => 'system',
                            text => "Welcome $data->{name}!"
                        })
                    });

                    # Broadcast join to others
                    foreach my $cid (keys %{$app->clients}) {
                        next if $cid eq $id;

                        my $other_pagi = $app->clients->{$cid}{pagi_send};
                        if ($other_pagi) {
                            await $other_pagi->({
                                type => 'websocket.send',
                                text => encode_json({
                                    type => 'system',
                                    text => "$data->{name} joined"
                                })
                            });
                        }
                    }

                    # Send user list to ALL clients
                    my @names = sort map { $app->clients->{$_}{name} } keys %{$app->clients};

                    foreach my $cid (keys %{$app->clients}) {
                        my $client_pagi = $app->clients->{$cid}{pagi_send};
                        if ($client_pagi) {
                            await $client_pagi->({
                                type => 'websocket.send',
                                text => encode_json({
                                    type => 'users',
                                    list => \@names
                                })
                            });
                        }
                    }
                }
                # Handle chat messages
                elsif ($data->{type} eq 'message') {
                    my (undef, $min, $hour) = localtime();
                    my $timestamp = sprintf("%02d:%02d", $hour, $min);

                    my $msg_out = {
                        type      => 'message',
                        user      => $app->clients->{$id}{name},
                        text      => $data->{text},
                        timestamp => $timestamp
                    };

                    # Add to history (keep last 10)
                    push @{$app->history}, $msg_out;
                    shift @{$app->history} if @{$app->history} > 10;

                    # Broadcast to all clients
                    foreach my $cid (keys %{$app->clients}) {
                        my $client_pagi = $app->clients->{$cid}{pagi_send};
                        if ($client_pagi) {
                            await $client_pagi->({
                                type => 'websocket.send',
                                text => encode_json($msg_out)
                            });
                        }
                    }
                }
                # Handle typing indicator
                elsif ($data->{type} eq 'typing') {
                    # Broadcast to all except sender
                    foreach my $cid (keys %{$app->clients}) {
                        next if $cid eq $id;

                        my $client_pagi = $app->clients->{$cid}{pagi_send};
                        if ($client_pagi) {
                            await $client_pagi->({
                                type => 'websocket.send',
                                text => encode_json({
                                    type     => 'typing',
                                    user     => $app->clients->{$id}{name},
                                    isTyping => $data->{isTyping}
                                })
                            });
                        }
                    }
                }
            }

            my $name = $app->clients->{$id}{name};
            delete $app->clients->{$id};

            my @names = sort map {
                $app->clients->{$_}{name}
            } keys %{$app->clients};

            # Notify others of disconnect and send updated user list
            foreach my $cid (keys %{$app->clients}) {
                my $client_pagi = $app->clients->{$cid}{pagi_send};
                if ($client_pagi) {
                    # Send disconnect notification
                    await $client_pagi->({
                        type => 'websocket.send',
                        text => encode_json({
                            type => 'system',
                            text => "$name left"
                        })
                    });

                    # Send updated user list
                    await $client_pagi->({
                        type => 'websocket.send',
                        text => encode_json({
                            type => 'users',
                            list => \@names
                        })
                    });
                }
            }

            return;
        },
    });
}

package main;

ChatApp->new->run;
