const std = @import("std");

const USER_DATA_SIZE = @import("root.zig").USER_DATA_SIZE;

pub const ConnectionState = enum {
    Disconnected,
    Pending,
    Connected,
};

pub const Connection = struct {
    cid: u64,
    addr: std.net.Address,
    last_recv: u64,
    last_send: u64,
    user_data: [USER_DATA_SIZE]u8,
};

pub const PendingConnection = struct {
    cid: u64,
    client_nonce: u64,
    sequence: u64,
    expires_at: u64,
    user_data: [USER_DATA_SIZE]u8,
};
