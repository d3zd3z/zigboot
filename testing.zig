// SPDX-License-Identifier: Apache-2.0
// Some testing

const std = @import("std");

const zephyr = @import("zephyr.zig");
const sys = @import("src/sys.zig");
const FlashArea = sys.flash.FlashArea;
const image = @import("image.zig");

pub fn flashTest() !void {
    std.log.info("Running flash test", .{});

    var fa = try FlashArea.open(@enumToInt(image.Slot.PrimarySecure));

    // TODO: Query this from the device, once we have a meaningful API
    // to do this.
    const page_count = 272;
    const page_size = 512;

    var page: usize = 0;
    var buf = buffer1[0..];
    var buf2 = buffer2[0..];

    std.log.info("Erasing slot", .{});
    while (page < page_count) : (page += 1) {
        const offset = page * page_size;
        try fa.erase(offset, page_size);
    }
    std.log.info("Validating erase", .{});
    page = 0;
    while (page < page_count) : (page += 1) {
        const offset = page * page_size;
        std.mem.set(u8, buf, 0xAA);
        try fa.read(offset, buf);
        try isErased(buf);
    }

    std.log.info("Filling flash with patterns", .{});

    page = 0;
    while (page < page_count) : (page += 1) {
        const offset = page * page_size;
        fillBuf(buf, page);
        try fa.write(offset, buf);
    }

    std.log.info("Reading data back", .{});
    page = 0;
    while (page < page_count) : (page += 1) {
        fillBuf(buf, page);
        std.mem.set(u8, buf2, 0xAA);
        try fa.read(page * page_size, buf2);
        try expectEqualSlices(u8, buf, buf2);
    }

    std.log.info("Success", .{});
}

// Static buffers.
var buffer1: [512]u8 = undefined;
var buffer2: [512]u8 = undefined;

fn isErased(buf: []const u8) !void {
    for (buf) |ch, i| {
        if (ch != 0xFF) {
            std.log.err("Byte not erased at {} (value 0x{x})", .{ i, ch });
            return error.TestFailure;
        }
    }
}

// Similar to the testing one, but without a stdio dependency.
fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
    if (expected.len != actual.len) {
        std.log.err("slice lengths differ, expected {d}, found {d}", .{ expected.len, actual.len });
    }
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (!std.meta.eql(expected[i], actual[i])) {
            std.log.err("index {} incorrect. expected {any}, found {any}", .{ i, expected[i], actual[i] });
            return error.TestExpectedEqual;
        }
    }
}

fn fillBuf(buf: []u8, seed: u64) void {
    var rng = std.rand.DefaultPrng.init(seed);
    rng.fill(buf);
}
