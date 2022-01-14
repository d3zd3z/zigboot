// SPDX-License-Identifier: Apache-2.0
// Zig main program

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const zephyr = @import("zephyr.zig");
const image = @import("image.zig");
const tlv = @import("tlv.zig");
const Image = image.Image;
const flashTest = @import("testing.zig").flashTest;

const FlashArea = zephyr.flash.FlashArea;

// Setup Zig logging to output through Zephyr.
pub const log_level: std.log.Level = .info;
pub const log = zephyr.log;

export fn main() void {
    std.log.info("Starting zigboot", .{});
    flashTest() catch |err| {
        std.log.err("Fatal: {}", .{err});
    };
}

// Arm executables start with this header.
pub const ArmHeader = extern struct {
    msp: u32,
    pc: u32,
};

// Execution help is in C.
extern fn chain_jump(vt: u32, msp: u32, pc: u32) noreturn;

fn core() !void {
    var img = try Image.init(@enumToInt(image.Slot.PrimarySecure));
    try image.dump_layout();

    {
        std.log.info("Hash benchmark", .{});
        const timer = Timer.start();
        try image.hash_bench(img.fa, 1000);
        timer.stamp("Hash time");
    }

    const arm_header = try img.readStruct(ArmHeader, img.header.imageStart());
    // var arm_header: ArmHeader = undefined;
    // var bytes = std.mem.asBytes(&arm_header);
    // try img.fa.read(img.header.imageStart(), bytes);

    const timer = Timer.start();
    var hash: [32]u8 = undefined;
    try image.hash_image(img.fa, &img.header, &hash);
    timer.stamp("Time for hash");

    try tlv.validateTlv(&img);
    // try tlv.showTlv(&img);
    try validateImage(&img, hash);

    chain_jump(img.fa.off, arm_header.msp, arm_header.pc);
}

// Go through the TLV, checking hashes and signatures to ensure that
// this image is valid.
fn validateImage(img: *Image, hash: [32]u8) !void {
    var iter = try tlv.TlvIter.init(img);
    while (try iter.next()) |item| {
        switch (item.tag) {
            @enumToInt(tlv.TlvTag.Sha256) => {
                std.log.warn("Checking hash", .{});
                const expectHash = try iter.readItem([32]u8, &item);
                std.log.info("Equal: {}", .{constEql(u8, expectHash[0..], hash[0..])});
            },
            else => |tag| {
                const etag = std.meta.intToEnum(tlv.TlvTag, tag) catch .Other;
                std.log.info("Tag: 0x{x:0>2} {}", .{ tag, etag });
            },
        }
    }
}

// Constant time comparison.  "T" must be a numeric type.
fn constEql(comptime T: type, a: []const T, b: []const T) bool {
    assert(a.len == b.len);
    var mismatch: T = 0;
    for (a) |aelt, i| {
        mismatch |= aelt ^ b[i];
    }
    return mismatch == 0;
}

// Timing utility.
const Timer = struct {
    const Self = @This();

    start: i64,

    fn start() Self {
        return Self{
            .start = zephyr.uptime(),
        };
    }

    fn stamp(self: *const Self, message: []const u8) void {
        const now = zephyr.uptime();
        zephyr.println("{s}: {}ms", .{ message, now - self.start });
    }
};
