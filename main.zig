// SPDX-License-Identifier: Apache-2.0
// Zig main program

const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const zephyr = @import("zephyr.zig");
const image = @import("image.zig");
const tlv = @import("tlv.zig");
const Image = image.Image;

const FlashArea = zephyr.flash.FlashArea;

// Setup Zig logging to output through Zephyr.
pub const log_level: std.log.Level = .info;
pub const log = zephyr.log;

export fn main() void {
    std.log.info("Starting zigboot", .{});
    core() catch |err| {
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

    var arm_header: ArmHeader = undefined;
    var bytes = std.mem.asBytes(&arm_header);
    try img.fa.read(img.header.imageStart(), bytes);
    try image.hash_image(img.fa, &img.header);

    try tlv.showTlv(&img);

    chain_jump(img.fa.off, arm_header.msp, arm_header.pc);
}
