const std = @import("std");
const Options = @import("root.zig").Options;

pub const ClientId = usize;

pub fn Connection(comptime opts: Options) type {
    return struct {
        cid: ClientId,
        addr: std.net.Address,
        last_recv: u64,
        last_send: u64,
        user_data: ?[opts.user_data_size]u8,
    };
}

pub fn PendingConnection(comptime opts: Options) type {
    return struct {
        cid: ClientId,
        client_nonce: u64,
        sequence: u64,
        expires_at: u64,
        user_data: ?[opts.user_data_size]u8,
    };
}
