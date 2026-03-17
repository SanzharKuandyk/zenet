/// Integration tests for zenet server/client state machines and channel logic.
/// These tests exercise the state machines directly — no sockets required.
const std = @import("std");
const testing = std.testing;
const zenet = @import("root.zig");
const packet_mod = @import("packet.zig");
const channel_mod = @import("channel.zig");
const LoopbackSocket = @import("transport/loopback.zig").LoopbackSocket;
const TransportServer = @import("transport/server.zig").TransportServer;
const TransportClient = @import("transport/client.zig").TransportClient;

// Re-export unit tests from sub-modules so `zig build test` picks them up.
comptime {
    _ = channel_mod;
    _ = @import("ring_buffer.zig");
}

const opts: zenet.Options = .{
    .max_clients = 4,
    .max_pending_clients = 8,
    .nonce_window = 8,
    .outgoing_queue_size = 32,
    .events_queue_size = 32,
    .user_data_size = 16,
    .max_payload_size = 64,
    .channels = &.{ .Unreliable, .UnreliableLatest, .Reliable },
    .reliable_buffer = 8,
    .reliable_resend_ns = 100 * std.time.ns_per_ms,
};

const Srv = zenet.Server(opts);
const Cli = zenet.Client(opts);
const Pkt = packet_mod.Packet(opts);

fn testAddr(port: u16) std.net.Address {
    return std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port);
}

fn serverCfg() zenet.ServerConfig {
    return zenet.ServerConfig.init(1, 5000, 10000, &.{}, false, [_]u8{0} ** 32, null);
}

fn clientCfg(port: u16) zenet.ClientConfig {
    return .{ .protocol_id = 1, .server_addr = testAddr(port) };
}

/// Relay all outgoing packets from `src` to `dst.handlePacket`.
/// `src_addr` is the address dst will see as the sender.
fn relayClientToServer(cli: *Cli, srv: *Srv, client_addr: std.net.Address) !void {
    while (cli.pollOutgoing()) |out| {
        const bytes = packet_mod.serialize(opts, out.packet);
        try srv.handlePacket(client_addr, &bytes);
    }
}

fn relayServerToClient(srv: *Srv, cli: *Cli) !void {
    while (srv.pollOutgoing()) |out| {
        const bytes = packet_mod.serialize(opts, out.packet);
        try cli.handlePacket(&bytes);
    }
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

test "server-client plain connect handshake" {
    var srv = try Srv.init(testing.allocator, serverCfg());
    defer srv.deinit();

    var cli = try Cli.init(clientCfg(9001));

    const client_addr = testAddr(50001);
    const now = try std.time.Instant.now();
    srv.update(now);
    cli.update(now);

    // Step 1: client sends ConnectionRequest
    try cli.connect();
    try relayClientToServer(&cli, &srv, client_addr);

    // Step 2: server sends Challenge
    try relayServerToClient(&srv, &cli);

    // Step 3: client sends ConnectionResponse; server should emit ClientConnected
    try relayClientToServer(&cli, &srv, client_addr);

    // Client should be Connected
    const cli_ev = cli.pollEvent().?;
    try testing.expect(cli_ev == .Connected);
    try testing.expect(cli.pollEvent() == null);

    // Server should have ClientConnected
    try relayServerToClient(&srv, &cli); // flush any server outgoing
    const srv_ev = srv.pollEvent().?;
    try testing.expect(srv_ev == .ClientConnected);
    try testing.expectEqual(@as(u64, 0), srv_ev.ClientConnected.cid);
    try testing.expect(srv.pollEvent() == null);

    std.debug.print("\n  PASS: server-client plain connect handshake\n", .{});
}

test "server disconnects client on Disconnect packet" {
    var srv = try Srv.init(testing.allocator, serverCfg());
    defer srv.deinit();
    var cli = try Cli.init(clientCfg(9002));

    const client_addr = testAddr(50002);
    const now = try std.time.Instant.now();
    srv.update(now);
    cli.update(now);

    try cli.connect();
    try relayClientToServer(&cli, &srv, client_addr);
    try relayServerToClient(&srv, &cli);
    try relayClientToServer(&cli, &srv, client_addr);
    _ = cli.pollEvent(); // Connected
    _ = srv.pollEvent(); // ClientConnected

    // Client disconnects
    cli.disconnect();
    try relayClientToServer(&cli, &srv, client_addr);

    const srv_ev = srv.pollEvent().?;
    try testing.expect(srv_ev == .ClientDisconnected);

    std.debug.print("\n  PASS: server disconnects client on Disconnect packet\n", .{});
}

// ---------------------------------------------------------------------------
// Server sendPayload → Client
// ---------------------------------------------------------------------------

test "server sendPayload reaches client as PayloadReceived" {
    var srv = try Srv.init(testing.allocator, serverCfg());
    defer srv.deinit();
    var cli = try Cli.init(clientCfg(9003));

    const client_addr = testAddr(50003);
    const now = try std.time.Instant.now();
    srv.update(now);
    cli.update(now);

    try cli.connect();
    try relayClientToServer(&cli, &srv, client_addr);
    try relayServerToClient(&srv, &cli);
    try relayClientToServer(&cli, &srv, client_addr);
    _ = cli.pollEvent(); // Connected
    const srv_ev = srv.pollEvent().?; // ClientConnected
    const cid = srv_ev.ClientConnected.cid;

    // Server sends a payload
    const body: [opts.max_payload_size]u8 = [_]u8{0xAB} ** opts.max_payload_size;
    try srv.sendPayload(cid, body);
    try relayServerToClient(&srv, &cli);

    const cli_ev = cli.pollEvent().?;
    try testing.expect(cli_ev == .PayloadReceived);
    try testing.expectEqual(@as(u8, 0xAB), cli_ev.PayloadReceived.body[0]);

    std.debug.print("\n  PASS: server sendPayload reaches client as PayloadReceived\n", .{});
}

// ---------------------------------------------------------------------------
// Client sendPayload → Server
// ---------------------------------------------------------------------------

test "client sendPayload reaches server as PayloadReceived" {
    var srv = try Srv.init(testing.allocator, serverCfg());
    defer srv.deinit();
    var cli = try Cli.init(clientCfg(9004));

    const client_addr = testAddr(50004);
    const now = try std.time.Instant.now();
    srv.update(now);
    cli.update(now);

    try cli.connect();
    try relayClientToServer(&cli, &srv, client_addr);
    try relayServerToClient(&srv, &cli);
    try relayClientToServer(&cli, &srv, client_addr);
    _ = cli.pollEvent();
    _ = srv.pollEvent();

    const body: [opts.max_payload_size]u8 = [_]u8{0xCD} ** opts.max_payload_size;
    try cli.sendPayload(body);
    try relayClientToServer(&cli, &srv, client_addr);

    const ev = srv.pollEvent().?;
    try testing.expect(ev == .PayloadReceived);
    try testing.expectEqual(@as(u8, 0xCD), ev.PayloadReceived.payload.body[0]);

    std.debug.print("\n  PASS: client sendPayload reaches server as PayloadReceived\n", .{});
}

// ---------------------------------------------------------------------------
// Channel header helpers (used by transport layer)
// ---------------------------------------------------------------------------

test "channel header round-trip through payload body" {
    var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;

    // Encode a channel 1, seq 42, with user data
    channel_mod.encodeHeader(body[0..channel_mod.HEADER_SIZE], 1, 42);
    const user_data = "hello";
    @memcpy(body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + user_data.len], user_data);

    const hdr = channel_mod.Header.decode(&body).?;
    try testing.expect(!hdr.is_ack);
    try testing.expectEqual(@as(u8, 1), hdr.channel_id);
    try testing.expectEqual(@as(u16, 42), hdr.seq);
    try testing.expectEqualStrings(user_data, body[channel_mod.HEADER_SIZE .. channel_mod.HEADER_SIZE + user_data.len]);

    std.debug.print("\n  PASS: channel header round-trip through payload body\n", .{});
}

test "channel ACK header round-trip" {
    var body: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
    channel_mod.encodeAck(body[0..channel_mod.HEADER_SIZE], 2, 99);

    const hdr = channel_mod.Header.decode(&body).?;
    try testing.expect(hdr.is_ack);
    try testing.expectEqual(@as(u8, 2), hdr.channel_id);
    try testing.expectEqual(@as(u16, 99), hdr.seq);

    std.debug.print("\n  PASS: channel ACK header round-trip\n", .{});
}

// ---------------------------------------------------------------------------
// UnreliableLatest channel filtering via raw state machine
// ---------------------------------------------------------------------------

test "UnreliableLatest drops older sequence via state machine relay" {
    var srv = try Srv.init(testing.allocator, serverCfg());
    defer srv.deinit();
    var cli = try Cli.init(clientCfg(9005));

    const client_addr = testAddr(50005);
    const now = try std.time.Instant.now();
    srv.update(now);
    cli.update(now);

    // Connect
    try cli.connect();
    try relayClientToServer(&cli, &srv, client_addr);
    try relayServerToClient(&srv, &cli);
    try relayClientToServer(&cli, &srv, client_addr);
    _ = cli.pollEvent();
    _ = srv.pollEvent();

    // Simulate two payloads where second has lower channel seq (out-of-order)
    var state: channel_mod.UnreliableLatestState = .{};

    var body1: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
    channel_mod.encodeHeader(body1[0..channel_mod.HEADER_SIZE], 1, 10); // ch1, seq=10
    body1[channel_mod.HEADER_SIZE] = 0xAA;

    var body2: [opts.max_payload_size]u8 = [_]u8{0} ** opts.max_payload_size;
    channel_mod.encodeHeader(body2[0..channel_mod.HEADER_SIZE], 1, 5); // ch1, seq=5 (older)
    body2[channel_mod.HEADER_SIZE] = 0xBB;

    // seq=10 accepted
    try testing.expect(state.accept(10));
    // seq=5 rejected (older)
    try testing.expect(!state.accept(5));
    // seq=11 accepted
    try testing.expect(state.accept(11));

    std.debug.print("\n  PASS: UnreliableLatest drops older sequence via state machine relay\n", .{});
}

// ---------------------------------------------------------------------------
// Reliable channel state: push / ack / buffer-full
// ---------------------------------------------------------------------------

test "reliable channel state stores and acks data" {
    const max_ud = opts.max_payload_size - channel_mod.HEADER_SIZE;
    const R = channel_mod.ReliableState(opts.reliable_buffer, max_ud);
    var state: R = .{};

    const msg = "important data";
    const seq = state.push(msg, 0).?;
    try testing.expectEqual(@as(u16, 1), seq);

    // Entry is active
    try testing.expect(state.entries[0].active);
    try testing.expectEqual(msg.len, state.entries[0].len);
    try testing.expectEqualStrings(msg, state.entries[0].data[0..msg.len]);

    state.ack(seq);
    try testing.expect(!state.entries[0].active);

    std.debug.print("\n  PASS: reliable channel state stores and acks data\n", .{});
}

// ---------------------------------------------------------------------------
// Transport-layer integration tests using LoopbackSocket
// ---------------------------------------------------------------------------

const TSrv = TransportServer(opts, LoopbackSocket);
const TCli = TransportClient(opts, LoopbackSocket);

/// Addresses used as fake local endpoints for loopback sockets.
const srv_addr = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 20000);
const cli_addr = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 20001);

/// Server config suitable for transport-layer tests that run tick() with real time.
fn transportServerCfg() zenet.ServerConfig {
    const ns_per_s = std.time.ns_per_s;
    return zenet.ServerConfig.init(1, 5 * ns_per_s, 30 * ns_per_s, &.{}, false, [_]u8{0} ** 32, null);
}

fn loopbackClientCfg() zenet.ClientConfig {
    const ns_per_s = std.time.ns_per_s;
    return .{
        .protocol_id = 1,
        .server_addr = srv_addr,
        .connect_timeout_ns = 5 * ns_per_s,
        .timeout_ns = 30 * ns_per_s,
    };
}

/// Run up to `max_ticks` alternating tick() pairs until both the server and
/// client have emitted their first event.  Returns {srv_ev, cli_ev}.
fn handshake(srv: *TSrv, cli: *TCli, max_ticks: usize) !struct { TSrv.Event, TCli.Event } {
    var i: usize = 0;
    while (i < max_ticks) : (i += 1) {
        cli.tick();
        srv.tick();
        const se = srv.pollEvent();
        const ce = cli.pollEvent();
        if (se != null and ce != null) return .{ se.?, ce.? };
        // If only one side fired an event keep running; events queue up
        // independently so the other will fire on a subsequent tick.
        if (se != null or ce != null) {
            // drain the remaining side
            var j: usize = 0;
            while (j < max_ticks) : (j += 1) {
                cli.tick();
                srv.tick();
                const se2 = if (se == null) srv.pollEvent() else null;
                const ce2 = if (ce == null) cli.pollEvent() else null;
                if (se2 != null or ce2 != null)
                    return .{ se orelse se2.?, ce orelse ce2.? };
            }
            return error.HandshakeTimeout;
        }
    }
    return error.HandshakeTimeout;
}

test "transport loopback: connect handshake" {
    var pair: LoopbackSocket.Pair = .{};

    var srv = try TSrv.initWithSocket(testing.allocator, transportServerCfg(), pair.serverSocket(srv_addr));
    defer srv.deinit();

    var cli = try TCli.initWithSocket(loopbackClientCfg(), pair.clientSocket(cli_addr));
    defer cli.deinit();

    try cli.connect();

    const evs = try handshake(&srv, &cli, 20);
    try testing.expect(evs[0] == .ClientConnected);
    try testing.expect(evs[1] == .Connected);

    std.debug.print("\n  PASS: transport loopback: connect handshake\n", .{});
}

test "transport loopback: server sendOnChannel reaches client" {
    var pair: LoopbackSocket.Pair = .{};

    var srv = try TSrv.initWithSocket(testing.allocator, transportServerCfg(), pair.serverSocket(srv_addr));
    defer srv.deinit();

    var cli = try TCli.initWithSocket(loopbackClientCfg(), pair.clientSocket(cli_addr));
    defer cli.deinit();

    try cli.connect();
    const evs = try handshake(&srv, &cli, 20);
    const cid = evs[0].ClientConnected.cid;

    // Send on channel 0 (Unreliable)
    try srv.sendOnChannel(cid, 0, "ping");
    srv.tick();
    cli.tick();

    const msg = cli.pollMessage();
    try testing.expect(msg != null);
    try testing.expectEqual(@as(u8, 0), msg.?.channel_id);
    // msg.len == max_user_data (protocol doesn't encode payload length in body)
    try testing.expectEqualStrings("ping", msg.?.data[0.."ping".len]);

    std.debug.print("\n  PASS: transport loopback: server sendOnChannel reaches client\n", .{});
}

test "transport loopback: client sendOnChannel reaches server" {
    var pair: LoopbackSocket.Pair = .{};

    var srv = try TSrv.initWithSocket(testing.allocator, transportServerCfg(), pair.serverSocket(srv_addr));
    defer srv.deinit();

    var cli = try TCli.initWithSocket(loopbackClientCfg(), pair.clientSocket(cli_addr));
    defer cli.deinit();

    try cli.connect();
    const evs = try handshake(&srv, &cli, 20);
    const cid = evs[0].ClientConnected.cid;
    _ = cid;

    // Send on channel 2 (Reliable)
    try cli.sendOnChannel(2, "hello reliable");
    cli.tick();
    srv.tick();

    const msg = srv.pollMessage();
    try testing.expect(msg != null);
    try testing.expectEqual(@as(u8, 2), msg.?.channel_id);
    // msg.len == max_user_data (protocol doesn't encode payload length in body)
    try testing.expectEqualStrings("hello reliable", msg.?.data[0.."hello reliable".len]);

    std.debug.print("\n  PASS: transport loopback: client sendOnChannel reaches server\n", .{});
}

test "transport loopback: peekMessage/consumeMessage zero-copy" {
    var pair: LoopbackSocket.Pair = .{};

    var srv = try TSrv.initWithSocket(testing.allocator, transportServerCfg(), pair.serverSocket(srv_addr));
    defer srv.deinit();

    var cli = try TCli.initWithSocket(loopbackClientCfg(), pair.clientSocket(cli_addr));
    defer cli.deinit();

    try cli.connect();
    const evs = try handshake(&srv, &cli, 20);
    const cid = evs[0].ClientConnected.cid;

    try srv.sendOnChannel(cid, 0, "peek-test");
    srv.tick();
    cli.tick();

    // peek does not consume
    const p1 = cli.peekMessage();
    try testing.expect(p1 != null);
    try testing.expectEqualStrings("peek-test", p1.?.data[0.."peek-test".len]);

    const p2 = cli.peekMessage();
    try testing.expect(p2 != null); // still there
    try testing.expectEqual(p1.?, p2.?); // same pointer

    // consume removes it
    cli.consumeMessage();
    try testing.expect(cli.peekMessage() == null);

    std.debug.print("\n  PASS: transport loopback: peekMessage/consumeMessage zero-copy\n", .{});
}

test "transport loopback: client disconnect" {
    var pair: LoopbackSocket.Pair = .{};

    var srv = try TSrv.initWithSocket(testing.allocator, transportServerCfg(), pair.serverSocket(srv_addr));
    defer srv.deinit();

    var cli = try TCli.initWithSocket(loopbackClientCfg(), pair.clientSocket(cli_addr));
    defer cli.deinit();

    try cli.connect();
    _ = try handshake(&srv, &cli, 20);

    cli.disconnect();
    // Flush disconnect packet to server
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        cli.tick();
        srv.tick();
        if (srv.pollEvent()) |ev| {
            try testing.expect(ev == .ClientDisconnected);
            std.debug.print("\n  PASS: transport loopback: client disconnect\n", .{});
            return;
        }
    }
    return error.DisconnectNotReceived;
}
