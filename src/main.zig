const std = @import("std");
const zenet = @import("zenet");

const opts: zenet.Options = .{
    .max_clients = 64,
    .user_data_size = 256,
    .max_payload_size = 512,
};

const Srv = zenet.TransportServer(opts, void);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const challenge_key = [_]u8{0} ** 32;
    const cfg = zenet.ServerConfig.init(
        1,
        5000,
        10000,
        &.{},
        false,
        challenge_key,
        null,
    );

    const bind = try std.net.Address.parseIp4("0.0.0.0", 9000);
    var srv = try Srv.init(allocator, cfg, bind);
    defer srv.deinit();

    srv.tick();

    while (srv.pollEvent()) |event| {
        switch (event) {
            .ClientConnected => |e| std.debug.print("connected: {}\n", .{e.cid}),
            .ClientDisconnected => |e| std.debug.print("disconnected: {}\n", .{e.cid}),
        }
    }

    while (srv.pollMessage()) |msg| {
        std.debug.print("msg from {} on ch{}: {} bytes\n", .{ msg.cid, msg.channel_id, msg.len });
    }
}
