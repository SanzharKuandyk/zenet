# zenet

> **Experimental** — API is unstable and subject to change.

game networking lib: provides a connection-oriented protocol with a challenge-response handshake on top of unreliable transport.
inspired by [renet](https://github.com/lucaspoffo/renet)

## Features

- Challenge-response handshake (HMAC-SHA256)
- Plain and secure connection modes (secure requires a signed connect token from a lobby/matchmaking server)
- Replay attack protection via nonce window
- Comptime-parameterized `Server` and `Client` — wire format, queue sizes, and max clients are all compile-time constants
- Transport-agnostic: pure state machine core; bring your own socket
- Built-in UDP transport (`TransportServer` / `TransportClient`) for the common case

## Requirements

Zig `0.15.2`

## Usage

Both sides share an `Options` struct — the wire format depends on it.

```zig
const opts: zenet.Options = .{
    .max_clients = 1024,
    .max_payload_size = 512,
};
```

### Transport wrapper (UDP, common case)

`TransportServer` / `TransportClient` own the socket and drive the I/O loop. Pass `void` as the second argument to use the built-in UDP transport.

```zig
const Srv = zenet.TransportServer(opts, void);

var srv = try Srv.init(allocator, config, try std.net.Address.parseIp4("0.0.0.0", 9000));
defer srv.deinit();

// each tick
srv.tick();

while (srv.pollEvent()) |ev| {
    switch (ev) {
        .ClientConnected    => |e| { _ = e.cid; },
        .ClientDisconnected => |e| { _ = e.cid; },
        .PayloadReceived    => |e| { _ = e.payload; },
    }
}
```

```zig
const Cli = zenet.TransportClient(opts, void);

var client = try Cli.init(.{ .protocol_id = 1, .server_addr = server_addr }, bind_addr);
defer client.deinit();

try client.connect();

// each tick
client.tick();

while (client.pollEvent()) |ev| {
    switch (ev) {
        .Connected       => {},
        .Disconnected    => {},
        .PayloadReceived => |p| { _ = p; },
    }
}
```

### Custom transport

Pass any type that satisfies the socket interface:

```zig
const MySocket = struct {
    pub fn open(addr: std.net.Address) !MySocket { ... }
    pub fn close(self: *MySocket) void { ... }
    pub fn recvfrom(self: *MySocket, buf: []u8) ?struct { addr: std.net.Address, len: usize } { ... }
    pub fn sendto(self: *MySocket, addr: std.net.Address, data: []const u8) void { ... }
};

const Srv = zenet.TransportServer(opts, MySocket);
```

Missing declarations produce a clear `@compileError`.

### Raw state machine (no transport)

`Server` / `Client` are untouched — you drive the socket yourself.

### Server

```zig
const Server = zenet.Server(opts);

var srv = try Server.init(allocator, zenet.ServerConfig.init(
    1,        // protocol_id
    5000,     // handshake_alive_ms
    10000,    // client_timeout_ms
    &.{},     // public_addresses
    false,    // secure
    key,
    null,
));
defer srv.deinit();

// each tick
srv.update(try std.time.Instant.now());

// feed incoming UDP datagrams
try srv.handlePacket(from_addr, buffer);

// drain outgoing
while (srv.pollOutgoing()) |out| {
    // send out.packet bytes to out.addr
}

// drain events
while (srv.pollEvent()) |ev| {
    switch (ev) {
        .ClientConnected    => |e| { _ = e.cid; },
        .ClientDisconnected => |e| { _ = e.cid; },
        .PayloadReceived    => |e| { _ = e.payload; },
    }
}
```

### Client

```zig
const Client = zenet.Client(opts);

var client = try Client.init(.{
    .protocol_id = 1,
    .server_addr = server_addr,
});

try client.connect();

// each tick
client.update(try std.time.Instant.now());

// feed incoming UDP datagrams from the server
try client.handlePacket(buffer);

// drain outgoing and send
while (client.pollOutgoing()) |out| {
    // send out.packet bytes to out.addr
}

// drain events
while (client.pollEvent()) |ev| {
    switch (ev) {
        .Connected       => {},
        .Disconnected    => {},
        .PayloadReceived => |p| { _ = p; },
    }
}
```

## Project structure

```
src/
  root.zig          — public API and Options
  packet.zig        — wire protocol
  handshake.zig     — HMAC tokens and DefaultConnectToken
  addr.zig          — address normalization (IPv4/IPv6)
  nonce.zig         — replay protection
  ring_buffer.zig   — fixed-size queue
  server/           — server state machine
  client/           — client state machine
  transport/
    udp.zig         — built-in non-blocking UDP socket
    server.zig      — TransportServer wrapper
    client.zig      — TransportClient wrapper
```

## License

TBD
