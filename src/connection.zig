const std = @import("std");

const USER_DATA_BYTES = 256;

pub const ConnectionState = enum {
    Disconnected,
    Pending,
    Connected,
};

pub const Connection = struct {
    valid: bool,
    // Client Id
    cid: u64,
    state: ConnectionState,
    addr: std.net.Address,
    expires_at: u64,
    user_data: [USER_DATA_BYTES]u8,
};
