const std = @import("std");

/// Canonical result type returned by recvfrom.  Custom socket implementations
/// may define their own struct, but it must expose `.addr: std.net.Address`
/// and `.len: usize` fields (checked by validateSocketInterface).
pub const RecvResult = struct {
    addr: std.net.Address,
    len: usize,
};

/// Deep compile-time validation that T implements the socket interface with the
/// correct signatures:
///
///   open(std.net.Address) !T
///   close(*T) void
///   recvfrom(*T, []u8) ?{addr: std.net.Address, len: usize}
///   sendto(*T, std.net.Address, []const u8) void
///
/// Call this inside a `comptime { }` block.  Each check emits a focused
/// @compileError if the requirement is not met, so the user sees exactly which
/// method is wrong and why.
pub fn validateSocketInterface(comptime T: type) void {
    checkOpen(T);
    checkClose(T);
    checkRecvfrom(T);
    checkSendto(T);
}

// ---------------------------------------------------------------------------
// Per-method checks
// ---------------------------------------------------------------------------

fn checkOpen(comptime T: type) void {
    if (!@hasDecl(T, "open"))
        @compileError("Socket missing: pub fn open(std.net.Address) !" ++ @typeName(T));
    switch (@typeInfo(@TypeOf(T.open))) {
        .@"fn" => |fi| {
            if (fi.params.len != 1)
                @compileError("Socket.open must take exactly one parameter (std.net.Address)");
            const p0 = fi.params[0].type orelse
                @compileError("Socket.open parameter must be a concrete type (std.net.Address)");
            if (p0 != std.net.Address)
                @compileError("Socket.open parameter must be std.net.Address, got " ++ @typeName(p0));
            const ret = fi.return_type orelse
                @compileError("Socket.open return type must be !" ++ @typeName(T) ++ ", not anytype");
            switch (@typeInfo(ret)) {
                .error_union => |eu| {
                    if (eu.payload != T)
                        @compileError("Socket.open error-union payload must be " ++ @typeName(T) ++ ", got " ++ @typeName(eu.payload));
                },
                else => @compileError("Socket.open must return an error union (!" ++ @typeName(T) ++ ")"),
            }
        },
        else => @compileError("Socket.open must be a function"),
    }
}

fn checkClose(comptime T: type) void {
    if (!@hasDecl(T, "close"))
        @compileError("Socket missing: pub fn close(*" ++ @typeName(T) ++ ") void");
    switch (@typeInfo(@TypeOf(T.close))) {
        .@"fn" => |fi| {
            if (fi.params.len != 1)
                @compileError("Socket.close must take exactly one parameter (*" ++ @typeName(T) ++ ")");
            const p0 = fi.params[0].type orelse
                @compileError("Socket.close parameter must be a concrete type (*" ++ @typeName(T) ++ ")");
            if (p0 != *T)
                @compileError("Socket.close parameter must be *" ++ @typeName(T) ++ ", got " ++ @typeName(p0));
            const ret = fi.return_type orelse
                @compileError("Socket.close return type must be void, not anytype");
            if (ret != void)
                @compileError("Socket.close must return void, got " ++ @typeName(ret));
        },
        else => @compileError("Socket.close must be a function"),
    }
}

fn checkRecvfrom(comptime T: type) void {
    if (!@hasDecl(T, "recvfrom"))
        @compileError("Socket missing: pub fn recvfrom(*" ++ @typeName(T) ++ ", []u8) ?RecvResult");
    switch (@typeInfo(@TypeOf(T.recvfrom))) {
        .@"fn" => |fi| {
            if (fi.params.len != 2)
                @compileError("Socket.recvfrom must take exactly 2 parameters (*T, []u8)");
            const p0 = fi.params[0].type orelse
                @compileError("Socket.recvfrom first parameter must be *" ++ @typeName(T));
            if (p0 != *T)
                @compileError("Socket.recvfrom first parameter must be *" ++ @typeName(T) ++ ", got " ++ @typeName(p0));
            const p1 = fi.params[1].type orelse
                @compileError("Socket.recvfrom second parameter must be []u8");
            if (p1 != []u8)
                @compileError("Socket.recvfrom second parameter must be []u8, got " ++ @typeName(p1));
            const ret = fi.return_type orelse
                @compileError("Socket.recvfrom return type must be ?RecvResult, not anytype");
            switch (@typeInfo(ret)) {
                .optional => |opt| {
                    const R = opt.child;
                    if (!@hasField(R, "addr"))
                        @compileError("Socket.recvfrom return type must have field 'addr: std.net.Address'");
                    if (!@hasField(R, "len"))
                        @compileError("Socket.recvfrom return type must have field 'len: usize'");
                    if (@FieldType(R, "addr") != std.net.Address)
                        @compileError("Socket.recvfrom result .addr must be std.net.Address");
                    if (@FieldType(R, "len") != usize)
                        @compileError("Socket.recvfrom result .len must be usize");
                },
                else => @compileError("Socket.recvfrom must return an optional (?RecvResult)"),
            }
        },
        else => @compileError("Socket.recvfrom must be a function"),
    }
}

fn checkSendto(comptime T: type) void {
    if (!@hasDecl(T, "sendto"))
        @compileError("Socket missing: pub fn sendto(*" ++ @typeName(T) ++ ", std.net.Address, []const u8) void");
    switch (@typeInfo(@TypeOf(T.sendto))) {
        .@"fn" => |fi| {
            if (fi.params.len != 3)
                @compileError("Socket.sendto must take exactly 3 parameters (*T, std.net.Address, []const u8)");
            const p0 = fi.params[0].type orelse
                @compileError("Socket.sendto first parameter must be *" ++ @typeName(T));
            if (p0 != *T)
                @compileError("Socket.sendto first parameter must be *" ++ @typeName(T) ++ ", got " ++ @typeName(p0));
            const p1 = fi.params[1].type orelse
                @compileError("Socket.sendto second parameter must be std.net.Address");
            if (p1 != std.net.Address)
                @compileError("Socket.sendto second parameter must be std.net.Address, got " ++ @typeName(p1));
            const p2 = fi.params[2].type orelse
                @compileError("Socket.sendto third parameter must be []const u8");
            if (p2 != []const u8)
                @compileError("Socket.sendto third parameter must be []const u8, got " ++ @typeName(p2));
            const ret = fi.return_type orelse
                @compileError("Socket.sendto return type must be void, not anytype");
            if (ret != void)
                @compileError("Socket.sendto must return void, got " ++ @typeName(ret));
        },
        else => @compileError("Socket.sendto must be a function"),
    }
}
