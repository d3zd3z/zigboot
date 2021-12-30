// SPDX-License-Identifier: Apache-2.0
// Zig main program

const std = @import("std");
const zephyr = @import("zephyr.zig");

// Setup Zig logging to output through Zephyr.
pub const log_level: std.log.Level = .info;
pub const log = zephyr.log;

export fn main() void {
    std.log.info("Hello from Zig", .{});
}
