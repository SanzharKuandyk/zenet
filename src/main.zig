const std = @import("std");
const zenet = @import("zenet");

const opts: zenet.Options = .{
    .max_clients = 64,
    .user_data_size = 256,
    .max_payload_size = 512,
};

const Server = zenet.Server(opts);

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

    var srv = try Server.init(allocator, cfg);
    defer srv.deinit();

    const now = try std.time.Instant.now();
    try srv.update(now);
}
