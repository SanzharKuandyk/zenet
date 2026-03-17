const std = @import("std");

pub const ClientConfig = struct {
    protocol_id: u64,
    server_addr: std.net.Address,
    connect_timeout_ns: u64 = 5 * std.time.ns_per_s,
    timeout_ns: u64 = 10 * std.time.ns_per_s,
};
