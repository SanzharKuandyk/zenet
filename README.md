# zenet

> **Experimental** — API is unstable and subject to change.

Connection-oriented game networking library for Zig. Provides a
challenge-response handshake (HMAC-SHA256) and a channel system on top of
unreliable UDP. Inspired by [renet](https://github.com/lucaspoffo/renet).

**Requires Zig 0.15.2**

---

## Contents

- [Quick start](#quick-start)
- [Options](#options)
- [Channels](#channels)
- [TransportServer / TransportClient](#transportserver--transportclient)
- [Custom socket](#custom-socket)
- [Secure connections / ConnectToken](#secure-connections--connecttoken)
- [Raw state machines](#raw-state-machines)
- [Testing with LoopbackSocket](#testing-with-loopbacksocket)
- [Project structure](#project-structure)

---

## Quick start

```zig
const zenet = @import("zenet");
const std   = @import("std");

const opts: zenet.Options = .{
    .max_clients     = 64,
    .max_payload_size = 512,
    .channels        = &.{ .Unreliable, .UnreliableLatest, .Reliable },
};

// --- server ---

const Srv = zenet.TransportServer(opts, void); // void = built-in UDP

var srv = try Srv.init(allocator, zenet.ServerConfig.init(
    1,                          // protocol_id
    5  * std.time.ns_per_s,     // handshake_alive_ns
    30 * std.time.ns_per_s,     // client_timeout_ns
    &.{},                       // public addresses (secure mode only)
    false,                      // secure
    [_]u8{0} ** 32,             // challenge key
    null,                       // secret key (secure mode only)
), try std.net.Address.parseIp4("0.0.0.0", 9000));
defer srv.deinit();

// game loop
while (running) {
    srv.tick();

    while (srv.pollEvent()) |ev| switch (ev) {
        .ClientConnected    => |e| std.debug.print("connected cid={}\n",    .{e.cid}),
        .ClientDisconnected => |e| std.debug.print("disconnected cid={}\n", .{e.cid}),
    };

    // zero-copy: pointer into the ring buffer — no data[] copy
    while (srv.peekMessage()) |msg| {
        std.debug.print("ch={} data={s}\n", .{ msg.channel_id, msg.data[0..msg.len] });
        // echo back
        try srv.sendOnChannel(msg.cid, msg.channel_id, msg.data[0..msg.len]);
        srv.consumeMessage();
    }
}

// --- client ---

const Cli = zenet.TransportClient(opts, void);

var cli = try Cli.init(
    .{ .protocol_id = 1, .server_addr = server_addr },
    try std.net.Address.parseIp4("0.0.0.0", 0),
);
defer cli.deinit();

try cli.connect();

while (running) {
    cli.tick();

    while (cli.pollEvent()) |ev| switch (ev) {
        .Connected    => std.debug.print("connected\n",    .{}),
        .Disconnected => std.debug.print("disconnected\n", .{}),
    };

    // zero-copy: pointer into the ring buffer — no data[] copy
    while (cli.peekMessage()) |msg| {
        std.debug.print("from server ch={} data={s}\n",
            .{ msg.channel_id, msg.data[0..msg.len] });
        cli.consumeMessage();
    }

    // send on channel 2 (Reliable)
    try cli.sendOnChannel(2, "hello");
}
```

---

## Options

Both sides must use the **same** `Options` value — the wire format depends on it.

```zig
const opts: zenet.Options = .{
    // Connection limits
    .max_clients          = 1024,  // max simultaneous connected clients
    .max_pending_clients  = null,  // defaults to max_clients * 2; must be power of 2

    // Wire format
    .max_payload_size     = 1024,  // bytes per payload (includes 3-byte channel header)
    .user_data_size       = 256,   // bytes carried in ConnectToken.user_data

    // Channels  (index = channel_id passed to sendOnChannel)
    .channels             = &.{ .Unreliable, .UnreliableLatest, .Reliable },

    // Reliable channel tuning
    .reliable_buffer      = 64,    // unACKed send slots per channel per peer
    .reliable_resend_ns   = 100 * std.time.ns_per_ms,  // retransmit interval

    // Queue sizes
    .outgoing_queue_size  = 256,
    .events_queue_size    = 256,
    .messages_queue_size  = 256,
    .nonce_window         = 256,   // replay-protection window

    // Optional custom ConnectToken type (void = use built-in default)
    .ConnectToken         = void,
};
```

---

## Channels

Every message is sent on a numbered channel (index into `opts.channels`).
Three kinds are available:

| Kind              | Delivery              | Ordering | Use for                       |
|-------------------|-----------------------|----------|-------------------------------|
| `Unreliable`      | fire-and-forget       | none     | audio, debug overlays         |
| `UnreliableLatest`| fire-and-forget       | drops older | positions, orientations    |
| `Reliable`        | ACK + retransmit      | arrival  | game events, chat             |

```zig
// opts.channels = &.{ .Unreliable, .UnreliableLatest, .Reliable }
//                         0               1                2

// send from client
try cli.sendOnChannel(0, "fire-and-forget");
try cli.sendOnChannel(1, &std.mem.toBytes(player_position));
try cli.sendOnChannel(2, "must arrive");

// receive on server
while (srv.peekMessage()) |msg| {
    switch (msg.channel_id) {
        0 => ..., // Unreliable
        1 => ..., // UnreliableLatest — older packets already dropped
        2 => ..., // Reliable
        else => {},
    }
    srv.consumeMessage();
}
```

`sendOnChannel` returns `error.ReliableBufferFull` when all `reliable_buffer`
slots are occupied by unACKed messages for that peer. Back off and retry on the
next tick.

---

## TransportServer / TransportClient

The transport wrappers own a socket and drive the full I/O loop for you.
Pass `void` as the second type argument to use the built-in UDP socket.

### TransportServer

```zig
const Srv = zenet.TransportServer(opts, void);

// init
var srv = try Srv.init(allocator, server_config, bind_address);
defer srv.deinit();

// --- per-tick ---
srv.tick(); // recv → state machine → send → retransmit reliable

// lifecycle events
while (srv.pollEvent()) |ev| {
    switch (ev) {
        .ClientConnected => |e| {
            // e.cid       : u64           — stable slot index, 0-based
            // e.addr      : std.net.Address
            // e.user_data : ?[opts.user_data_size]u8  (null if plain connect)
        },
        .ClientDisconnected => |e| {
            // e.cid, e.addr
        },
    }
}

// incoming messages — zero-copy (preferred for large payloads)
while (srv.peekMessage()) |msg| {
    // msg : *const Message — points into ring buffer, no copy of data[]
    // msg.cid        : u64
    // msg.channel_id : u8
    // msg.data       : [max_message_size]u8   (first msg.len bytes are valid)
    // msg.len        : usize
    _ = msg.data[0..msg.len];
    srv.consumeMessage(); // advance the ring buffer
}
// or copy-out variant (simpler, fine for small payloads)
while (srv.pollMessage()) |msg| {
    _ = msg.data[0..msg.len]; // msg is a value copy
}

// outgoing
try srv.sendOnChannel(cid, channel_id, data_slice);

// disconnect a client
srv.getStateMachine().sendPayload(cid, disconnect_body) catch {};
```

### TransportClient

```zig
const Cli = zenet.TransportClient(opts, void);

var cli = try Cli.init(client_config, bind_address);
defer cli.deinit();

try cli.connect();         // plain
// try cli.connectSecure(token); // with ConnectToken

// --- per-tick ---
cli.tick();

while (cli.pollEvent()) |ev| {
    switch (ev) {
        .Connected    => {},
        .Disconnected => {},
    }
}

// zero-copy (preferred for large payloads)
while (cli.peekMessage()) |msg| {
    // msg : *const Message — points into ring buffer, no copy of data[]
    _ = msg.data[0..msg.len];
    cli.consumeMessage();
}
// or copy-out variant
while (cli.pollMessage()) |msg| {
    _ = msg.data[0..msg.len];
}

try cli.sendOnChannel(channel_id, data_slice);

cli.disconnect(); // graceful
```

### ServerConfig

```zig
const cfg = zenet.ServerConfig.init(
    protocol_id,          // u64  — must match client
    handshake_alive_ns,   // u64  — ns; pending handshake lifetime
    client_timeout_ns,    // u64  — ns; idle disconnect threshold
    public_addresses,     // []const std.net.Address  (secure mode)
    secure,               // bool — require signed ConnectToken
    challenge_key,        // [32]u8
    secret_key,           // ?[32]u8  (required when secure = true)
);
```

### ClientConfig

```zig
const cfg: zenet.ClientConfig = .{
    .protocol_id        = 1,
    .server_addr        = server_address,
    .connect_timeout_ns = 5  * std.time.ns_per_s,  // ns
    .timeout_ns         = 30 * std.time.ns_per_s,
};
```

---

## Custom socket

Pass any type as the second argument to `TransportServer` / `TransportClient`.
The type must satisfy the following interface exactly — the compiler checks every
parameter type and return type and emits a focused `@compileError` if anything
is wrong:

```zig
const MySocket = struct {
    // Called by TransportServer/Client.init to bind the socket.
    pub fn open(addr: std.net.Address) !MySocket { ... }

    // Called by deinit.
    pub fn close(self: *MySocket) void { ... }

    // Non-blocking receive.  Return null when no datagram is available.
    // The returned struct must have exactly these two fields with these types.
    pub fn recvfrom(self: *MySocket, buf: []u8) ?struct {
        addr: std.net.Address,
        len:  usize,
    } { ... }

    // Fire-and-forget send.
    pub fn sendto(self: *MySocket, addr: std.net.Address, data: []const u8) void { ... }
};

const Srv = zenet.TransportServer(opts, MySocket);
```

What the compiler checks (examples of the errors you get when wrong):

```
Socket missing: pub fn open(std.net.Address) !MySocket
Socket.open parameter must be std.net.Address, got u16
Socket.open error-union payload must be MySocket, got void
Socket.close must return void, got u32
Socket.recvfrom must return an optional (?RecvResult)
Socket.recvfrom result .addr must be std.net.Address
Socket.sendto third parameter must be []const u8, got []u8
```

When a custom socket is provided, `TransportServer` and `TransportClient` also
expose `initWithSocket` for use-cases where you construct the socket yourself
(e.g. in tests):

```zig
var srv = try zenet.TransportServer(opts, MySocket)
    .initWithSocket(allocator, server_config, my_socket_value);

var cli = try zenet.TransportClient(opts, MySocket)
    .initWithSocket(client_config, my_socket_value);
```

---

## Secure connections / ConnectToken

When `ServerConfig.secure = true`, the server requires every `ConnectionRequest`
to carry a signed token issued by a trusted matchmaking server.

### Using the built-in DefaultConnectToken

```zig
// matchmaking server — has the secret key
const token = zenet.handshake.DefaultConnectToken(opts.user_data_size).create(
    client_id,
    expires_at,       // absolute ns timestamp
    public_addresses, // []const std.net.Address
    user_data,        // [opts.user_data_size]u8
    &secret_key,
);

// client — receives token over HTTPS/TCP and uses it
try cli.connectSecure(token);
```

### Custom ConnectToken

Set `opts.ConnectToken = MyToken` and implement the interface below.
The compiler validates the signatures precisely:

```zig
const MyToken = struct {
    // Arbitrary fields (sig, metadata, …)
    user_data: [opts.user_data_size]u8, // required field, exact type

    // Called by the server on every ConnectionRequest.
    //   now        — current time in ns (from Instant.since)
    //   secret_key — server's 32-byte secret
    // Return true if the token is valid and unexpired.
    pub fn verify(
        self:       *const MyToken,
        now:        u64,
        secret_key: *const [32]u8,
    ) bool { ... }
};
```

Errors emitted when the interface is wrong:

```
ConnectToken must have: pub fn verify(*const @This(), u64, *const [32]u8) bool
ConnectToken.verify param[0] must be *const @This(), got *MyToken
ConnectToken.verify must return bool, got void
ConnectToken.user_data must be [opts.user_data_size]u8
```

---

## Raw state machines

`zenet.Server` and `zenet.Client` are pure state machines with no I/O — drive
the socket yourself if you need full control over when packets are sent.

### Server

```zig
const Srv = zenet.Server(opts);

var srv = try Srv.init(allocator, config);
defer srv.deinit();

// each tick
srv.update(try std.time.Instant.now());

// feed a received datagram
try srv.handlePacket(source_addr, datagram_bytes);

// drain outgoing — send each packet to its address
while (srv.pollOutgoing()) |out| {
    udp_send(out.addr, std.mem.asBytes(&out.packet));
}

// drain events
while (srv.pollEvent()) |ev| {
    switch (ev) {
        .ClientConnected    => |e| { _ = e.cid; _ = e.user_data; },
        .ClientDisconnected => |e| { _ = e.cid; },
        .PayloadReceived    => |e| { _ = e.cid; _ = e.payload.body; },
    }
}

// send a raw payload to a connected client
try srv.sendPayload(cid, payload_body); // payload_body: [opts.max_payload_size]u8
```

### Client

```zig
const Cli = zenet.Client(opts);

var cli = try Cli.init(.{ .protocol_id = 1, .server_addr = server_addr });

try cli.connect(); // or cli.connectSecure(token)

// each tick
cli.update(try std.time.Instant.now());

try cli.handlePacket(datagram_bytes);

while (cli.pollOutgoing()) |out| {
    udp_send(out.addr, std.mem.asBytes(&out.packet));
}

while (cli.pollEvent()) |ev| {
    switch (ev) {
        .Connected       => {},
        .Disconnected    => {},
        .PayloadReceived => |p| { _ = p.body; },
    }
}

try cli.sendPayload(payload_body);

cli.disconnect();
```

---

## Testing with LoopbackSocket

`zenet.LoopbackSocket` is an in-memory socket backed by two fixed-size queues.
Create a `Pair`, get the two socket endpoints from it, and pass them to
`initWithSocket` — no OS network stack involved.

```zig
const LoopbackSocket = zenet.LoopbackSocket;

var pair: LoopbackSocket.Pair = .{};

const srv_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9000);
const cli_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9001);

var srv = try zenet.TransportServer(opts, LoopbackSocket)
    .initWithSocket(allocator, server_config, pair.serverSocket(srv_addr));
defer srv.deinit();

var cli = try zenet.TransportClient(opts, LoopbackSocket)
    .initWithSocket(client_config, pair.clientSocket(cli_addr));
defer cli.deinit();

try cli.connect();

// drive the handshake — packets flow through the shared queues
for (0..10) |_| { cli.tick(); srv.tick(); }

const ev = srv.pollEvent().?;
std.debug.assert(ev == .ClientConnected);
```

The `Pair` must remain alive on the stack for the lifetime of both transport
objects, because the sockets hold interior pointers into it.

---

## Project structure

```
src/
  root.zig              public API re-exports and Options
  packet.zig            wire-format serialization/deserialization
  channel.zig           channel header encoding, UnreliableLatest state,
                        ReliableState send buffer
  handshake.zig         HMAC challenge tokens, DefaultConnectToken,
                        validateConnectTokenInterface
  addr.zig              address normalization for hash-map keys
  nonce.zig             sliding-window replay protection
  ring_buffer.zig       fixed-capacity queue (no allocator)
  tests.zig             state-machine integration tests + loopback transport tests

  server/
    server.zig          Server state machine (handlePacket, pollEvent, …)
    config.zig          ServerConfig
    connection.zig      per-client connection state
    error.zig           ServerError

  client/
    client.zig          Client state machine
    config.zig          ClientConfig
    error.zig           ClientError

  transport/
    socket.zig          RecvResult type + validateSocketInterface
    udp.zig             built-in non-blocking UDP socket (Windows + POSIX)
    loopback.zig        in-memory LoopbackSocket + Pair for testing
    server.zig          TransportServer — owns socket, drives I/O loop
    client.zig          TransportClient — owns socket, drives I/O loop
```

---

## License

MIT
