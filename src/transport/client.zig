const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const client_mod = @import("../client/client.zig");
const UdpSocket = @import("udp.zig").UdpSocket;

pub fn TransportClient(comptime opts: root.Options, comptime SocketType: type) type {
    const Socket = if (SocketType == void) UdpSocket else SocketType;

    comptime {
        if (SocketType != void) {
            if (!@hasDecl(SocketType, "open"))
                @compileError("Socket must have: pub fn open(std.net.Address) !@This()");
            if (!@hasDecl(SocketType, "close"))
                @compileError("Socket must have: pub fn close(*@This()) void");
            if (!@hasDecl(SocketType, "recvfrom"))
                @compileError("Socket must have: pub fn recvfrom(*@This(), []u8) ?Recv");
            if (!@hasDecl(SocketType, "sendto"))
                @compileError("Socket must have: pub fn sendto(*@This(), std.net.Address, []const u8) void");
        }
    }

    const Cli = client_mod.Client(opts);
    const Pkt = packet_mod.Packet(opts);
    const pkt_size = @sizeOf(Pkt);

    const ConnectTokenType = if (opts.ConnectToken == void)
        @import("../handshake.zig").DefaultConnectToken(opts.user_data_size)
    else
        opts.ConnectToken;

    return struct {
        const Self = @This();

        pub const Event = Cli.Event;

        cli: Cli,
        socket: Socket,

        pub fn init(config: root.ClientConfig, bind_addr: std.net.Address) !Self {
            const socket = try Socket.open(bind_addr);
            errdefer {
                var s = socket;
                s.close();
            }
            const cli = try Cli.init(config);
            return .{ .cli = cli, .socket = socket };
        }

        pub fn deinit(self: *Self) void {
            self.socket.close();
        }

        pub fn tick(self: *Self) void {
            const now = std.time.Instant.now() catch return;
            self.cli.update(now);

            // Drain outgoing first (e.g. connect request queued before tick)
            while (self.cli.pollOutgoing()) |out| {
                const bytes = packet_mod.serialize(opts, out.packet);
                self.socket.sendto(out.addr, &bytes);
            }

            // Drain recv -> state machine
            var buf: [pkt_size]u8 = undefined;
            while (self.socket.recvfrom(&buf)) |result| {
                if (result.len >= pkt_size) {
                    self.cli.handlePacket(&buf) catch {};
                }
            }

            // Drain outgoing again (handlePacket may have queued responses)
            while (self.cli.pollOutgoing()) |out| {
                const bytes = packet_mod.serialize(opts, out.packet);
                self.socket.sendto(out.addr, &bytes);
            }
        }

        pub fn connect(self: *Self) !void {
            try self.cli.connect();
        }

        pub fn connectSecure(self: *Self, token: ConnectTokenType) !void {
            try self.cli.connectSecure(token);
        }

        pub fn sendPayload(self: *Self, body: [opts.max_payload_size]u8) !void {
            try self.cli.sendPayload(body);
        }

        pub fn disconnect(self: *Self) void {
            self.cli.disconnect();
        }

        pub fn pollEvent(self: *Self) ?Event {
            return self.cli.pollEvent();
        }

        pub fn getStateMachine(self: *Self) *Cli {
            return &self.cli;
        }
    };
}
