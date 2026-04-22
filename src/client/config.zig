const std = @import("std");

pub const ClientConfig = struct {
    protocol_id: u32,
    server_addr: std.Io.net.IpAddress,
    connect_retry_ns: u64 = 500 * std.time.ns_per_ms,
    connect_timeout_ns: u64 = 5 * std.time.ns_per_s,
    timeout_ns: u64 = 10 * std.time.ns_per_s,
};
