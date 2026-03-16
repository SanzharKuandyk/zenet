const std = @import("std");

pub const ClientConfig = struct {
    protocol_id: u64,
    server_addr: std.net.Address,
    connect_timeout_ms: u64 = 5000,
    timeout_ms: u64 = 10000,
};
