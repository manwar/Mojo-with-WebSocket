## Start the application

```bash
perl chat-server.pl daemon
```

## Chat Server v2

We need Redis running locally.

Luckily I had docker container running Valkey.

Start the server:

<br>

```bash
docker start valkey
```

<br>

Testing time for Valkey:

<br>

```bash
redis-cli -h 127.0.0.1 -p 6379 ping
```

<br>

## Terminal 1

<br>

```bash
perl chat-server-v2.pl daemon -l http://*:3000
```

## Terminal 2

<br>

```bash
perl chat-server-v2.pl daemon -l http://*:3001
```

<br>

Open browsers to both ports - users on different ports can now chat!
