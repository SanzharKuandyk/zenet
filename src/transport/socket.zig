const std = @import("std");

/// Canonical result type returned by recvfrom.  Custom socket implementations
/// may define their own struct, but it must expose `.addr: std.net.Address`
/// and `.len: usize` fields (checked by validateSocketInterface).
pub const RecvResult = struct {
    addr: std.net.Address,
    len: usize,
};
