const std = @import("std");

pub const areion = @import("areion");

pub const MAX_CLIENTS = 1024;

pub const SECRET_KEY_SIZE = 32;
pub const NONCE_WINDOW = 256;
pub const CHALLENGE_KEY_SIZE = 32;

pub const USER_DATA_SIZE = 256;
pub const MAX_PAYLOAD_SIZE = 1024;

pub const server = @import("server.zig");
pub const ServerConfig = @import("config.zig").ServerConfig;
