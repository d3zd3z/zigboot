// SPDX-License-Identifier: Apache-2.0
// Zig main program

const std = @import("std");
const zephyr = @import("zephyr.zig");

const FlashArea = zephyr.flash.FlashArea;

// Setup Zig logging to output through Zephyr.
pub const log_level: std.log.Level = .info;
pub const log = zephyr.log;

export fn main() void {
    std.log.info("Hello from Zig", .{});
    core() catch |err| {
        std.log.err("Fatal: {}", .{err});
    };
}

fn core() !void {
    // Try opening a flash area.
    const p0 = try FlashArea.open(0);
    defer p0.close();
    std.log.info("Opened area: {}", .{p0});
}
