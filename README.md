## Table of Content
- [1. Chat Server with Mojo](#1-chat-server-with-mojo)
- [2. Chat Server with Redis](#2-chat-server-with-redis)
- [3. Chat Server with PostgreSQL](#3-chat-server-with-postgresql)
- [4. Chat Server with PAGI](#4-chat-server-with-pagi)
- [5. Chat Server with Thunderhorse](#5-chat-server-with-thunderhorse)

***

## 1. Chat Server with Mojo

Start chat server as below:

<br>

[**Source**](https://github.com/manwar/Mojo-with-WebSocket/blob/master/chat-server.pl)

```bash
$ perl chat-server.pl daemon
```

## 2. Chat Server with Redis

I was introduced to **JSON Virtual Frame** and **JSON Virtual Event** when I shared the previous version of chat server.

To be honest, I had no clue about any of them, so I dig deep and found this:

### JSON Virtual Frame

This is a special way to structure data when you send a message through a **WebSocket**. Instead of manually converting a Perl data structure into a **JSON** string, you use the **json** key in the hash you pass to the **send()** method.

**How it works?**

When you call **$tx->send({json => $data})**, the **build_message** method in [**Mojo::Transaction::WebSocket**](https://metacpan.org/pod/Mojo::Transaction::WebSocket) intercepts this. It automatically calls **Mojo::JSON::encode_json** to serialise your Perl **$data** into a **JSON** text string. It then sends this string as a standard **WebSocket** text frame.

**Why use it?**

It makes your sending code cleaner and less error-prone by removing the manual **encode_json** step.

**Example:**

```perl
# Instead of doing this manually:
use Mojo::JSON 'encode_json';
$tx->send({text => encode_json({message => 'Hello', user => 123})});

# You can do this directly:
$tx->send({json => {message => 'Hello', user => 123}});
```

### JSON Virtual Event

This is a special event you can listen for on the **WebSocket** transaction. When a complete **WebSocket** message arrives, if the **json** event has any subscribers (i.e., you have an **on(json => ...)** callback), the transaction will automatically attempt to decode the message payload from **JSON**.

**How it works?**

When a message is fully assembled (in **parse_message**), it checks if there are any subscribers for the **json** event. If there are, it passes the raw message through **Mojo::JSON::j()** (which is context-aware and decodes **JSON**). The decoded Perl data structure is then emitted to your callback.

**Note:** This event is only emitted if you are listening for it. This ensures you don't incur the performance cost of decoding **JSON** if you don't need it. It can decode both text and binary messages, as long as they contain valid **JSON**.

**Example:**

```perl
$tx->on(json => sub {
  my ($tx, $received_data) = @_;
  say "Received message: " . $received_data->{message};
});
```

I have applied both in this version.

For this version of chat server, we need **Redis** running locally. Luckily I had docker container running **Valkey**.

If you don't know **Valkey**, then I suggest you take a look at this [**blog post**](https://theweeklychallenge.org/blog/caching-in-perl) of mine.

First start the **Valkey** container as below:

<br>

```bash
$ docker start valkey
```

<br>

Testing time, make sure it reachable on default port as below:

<br>

```bash
$ redis-cli -h 127.0.0.1 -p 6379 ping
```

<br>

You should see **PONG** in response to the above command.

Time to start the chat server listening to port **3000** like below:

<br>

[**Source**](https://github.com/manwar/Mojo-with-WebSocket/blob/master/chat-server-v2.pl)

```bash
$ perl chat-server-v2.pl daemon -l http://*:3000
```

Let's start another chat server this time listening to port **3001** like below:

<br>

```bash
$ perl chat-server-v2.pl daemon -l http://*:3001
```

Now open browsers to both ports, users on different ports can now chat to each other.

<br>

## 3. Chat Server with PostgreSQL

Well, we need PostgreSQL database now and I am not willing to setup database from scratch.

The easy option is to create a docker container running the PostgreSQL database.

So here is the docker compose configuration file: **docker-compose.yml**

<br>

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    container_name: chat_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: chatuser
      POSTGRES_PASSWORD: chatpass
      POSTGRES_DB: chat_db
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chatuser -d chat_db"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
```

<br>

Start the container first as below:

<br>

```bash
$ docker-compose up -d
```

<br>

Check the status of the container as below:

<br>

```bash
$ docker-compose ps
```

<br>

Test the connection now as below:

<br>

```bash
$ docker exec -it chat_postgres psql -U chatuser -d chat_db
psql (16.11)
Type "help" for help.

chat_db=# LISTEN chat_messages;
LISTEN
chat_db=# NOTIFY chat_messages, '{"type":"test"}';
NOTIFY
Asynchronous notification "chat_messages" with payload "{"type":"test"}" received from server process with PID 2333.
chat_db=# \q
```

<br>

We have PostgreSQL up and running.

Let's start two chat servers listening to port **3000** and **3001**.

<br>

[**Source**](https://github.com/manwar/Mojo-with-WebSocket/blob/master/chat-server-v3.pl)

```bash
$ perl chat-server-v3.pl daemon -l http://*:3000
```

<br>

```bash
$ perl chat-server-v3.pl daemon -l http://*:3001
```

<br>

Once again, open browsers to both ports, users on different ports can now chat to each other.

<br>

## 4. Chat Server with PAGI

Start chat server as below:

<br>

[**Source**](https://github.com/manwar/Mojo-with-WebSocket/blob/master/chat-server-v4.pl)

```bash
$ perl chat-server-v4.pl
```

<br>

## 5. Chat Server with Thunderhorse

To run this server, we need **Perl v5.40** as enforced by [**Thunderhorse**](https://metacpan.org/dist/Thunderhorse),

You will also need [**PAGI**](https://metacpan.org/pod/PAGI).

<br>

[**Source**](https://github.com/manwar/Mojo-with-WebSocket/blob/master/chat-server-v5.pl)

```bash
$ pagi-server --port 3000 chat-server-v5.pl
```
