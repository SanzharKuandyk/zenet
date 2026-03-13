const std = @import("std");
const zenet = @import("zenet");
const ServerConfig = zenet.ServerConfig;

// zig build run
pub fn main() !void {
    const page_alloc = std.heap.page_allocator;
    const cfg = ServerConfig.init(
        1,
        5000,
        10000,
        null,
    );
    var server = try zenet.server.Server.init(page_alloc, cfg);
    try server.update();
}
