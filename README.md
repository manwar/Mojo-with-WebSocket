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

For this, We need Redis running locally. Luckily I had docker container running Valkey.

First start the Valkey container as below:

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
