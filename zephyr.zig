// SPDX-License-Identifier: Apache-2.0
// Bindings to things in Zephyr.

const std = @import("std");

const raw = struct {
    extern fn zig_log_message(msg: [*:0]const u8) void;
    extern fn printk(msg: [*:0]const u8, data: u8) void;

    extern fn uptime_ticks() i64;
};

// Get the uptime in ticks.
pub fn uptime() i64 {
    return raw.uptime_ticks();
}

// Use: `pub const log = zephyr.log;` in the root of the project to enable
// Zig logging to output to the console in Zephyr.
// `pub const log_level: std.log.Level = .info;` to set the logging
// level at compile time.
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = "[" ++ level.asText() ++ "] ";

    std.fmt.format(Writer{ .context = &CharWriter{} }, prefix ++ format ++ "\n", args) catch return;
}

// A regular print function.
pub fn println(
    comptime format: []const u8,
    args: anytype,
) void {
    std.fmt.format(Writer{ .context = &CharWriter{} }, format ++ "\n", args) catch return;
}

// A regular print function.
pub fn print(
    comptime format: []const u8,
    args: anytype,
) void {
    std.fmt.format(Writer{ .context = &CharWriter{} }, format, args) catch return;
}

// Newlib's putchar is simple, but adds about 4k to the size of the
// image, so we are probably better of more slowly outputting a
// character at a time through printk.  Even better would be to add
// just a putchar equivalent to Zephyr.

const Writer = std.io.Writer(*const CharWriter, WriteError, outwrite);
const WriteError = error{WriteError};
const Context = void;

// To make this work, we need to buffer a message until we're done,
// then we can send it to the Zephyr logging subsystem.
fn outwrite(_: *const CharWriter, bytes: []const u8) WriteError!usize {
    // zig_log_message(bytes);
    // printk("chunk: %d bytes\n", @intCast(u8, bytes.len));
    for (bytes) |byte| {
        // _ = putchar(byte);
        raw.printk("%c", byte);
    }
    return bytes.len;
}

const CharWriter = struct {};
