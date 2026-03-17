const std = @import("std");
const root = @import("../root.zig");
const packet_mod = @import("../packet.zig");
const server_mod = @import("../server/server.zig");
const UdpSocket = @import("udp.zig").UdpSocket;

pub fn TransportServer(comptime opts: root.Options, comptime SocketType: type) type {
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

    const Srv = server_mod.Server(opts);
    const Pkt = packet_mod.Packet(opts);
    const pkt_size = @sizeOf(Pkt);

    return struct {
        const Self = @This();

        pub const Event = Srv.Event;

        srv: Srv,
        socket: Socket,

        pub fn init(allocator: std.mem.Allocator, config: root.ServerConfig, bind_addr: std.net.Address) !Self {
            const socket = try Socket.open(bind_addr);
            errdefer {
                var s = socket;
                s.close();
            }
            const srv = try Srv.init(allocator, config);
            return .{ .srv = srv, .socket = socket };
        }

        pub fn deinit(self: *Self) void {
            self.srv.deinit();
            self.socket.close();
        }

        pub fn tick(self: *Self) void {
            const now = std.time.Instant.now() catch return;
            self.srv.update(now);

            // Drain recv -> state machine
            var buf: [pkt_size]u8 = undefined;
            while (self.socket.recvfrom(&buf)) |result| {
                if (result.len >= pkt_size) {
                    self.srv.handlePacket(result.addr, &buf) catch {};
                }
            }

            // Drain state machine -> send
            while (self.srv.pollOutgoing()) |out| {
                const bytes = packet_mod.serialize(opts, out.packet);
                self.socket.sendto(out.addr, &bytes);
            }
        }

        pub fn pollEvent(self: *Self) ?Event {
            return self.srv.pollEvent();
        }

        pub fn getStateMachine(self: *Self) *Srv {
            return &self.srv;
        }
    };
}
