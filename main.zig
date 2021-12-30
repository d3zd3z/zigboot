// SPDX-License-Identifier: Apache-2.0
// Zig main program

const std = @import("std");
const assert = std.debug.assert;
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

// For testing on the LPC, with Debug enabled, this code is easily
// larger than 32k.  Rather than change the partition table, we will
// just use slots 2 and 4 (and 5 as scratch).  Scratch is kind of
// silly, since there is no support for swap on this target yet.
const Slot = enum(u8) {
    PrimarySecure = 1,
    PrimaryNS = 2,
    UpgradeSecure = 3,
    UpgradeNS = 4,
};

// The image header.
const ImageHeader = extern struct {
    const Self = @This();

    magic: u32,
    load_addr: u32,
    hdr_size: u16,
    protect_tlv_size: u16,
    img_size: u32,
    flags: u32,
    ver: ImageVersion,
    pad1: u32,

    fn imageStart(self: *const Self) u32 {
        return self.hdr_size;
    }
};
comptime {
    assert(@sizeOf(ImageHeader) == 32);
}

// The version (non-semantic).
const ImageVersion = extern struct {
    major: u8,
    minor: u8,
    revision: u16,
    build_num: u32,
};

const IMAGE_MAGIC = 0x96f3b83d;

// Arm executables start with this header.
const ArmHeader = extern struct {
    msp: u32,
    pc: u32,
};

// Execution help is in C.
extern fn chain_jump(vt: u32, msp: u32, pc: u32) noreturn;

fn core() !void {
    // try dump_layout();
    const header = try load_header(@enumToInt(Slot.PrimarySecure));

    var arm_header: ArmHeader = undefined;
    var bytes = std.mem.asBytes(&arm_header);
    const fa = try FlashArea.open(@enumToInt(Slot.PrimarySecure));
    defer fa.close();
    try fa.read(header.imageStart(), bytes);
    // std.log.info("Arm header: {any}", .{arm_header});

    chain_jump(fa.off, arm_header.msp, arm_header.pc);
}

// Load the header from the given slot.
fn load_header(id: u8) !ImageHeader {
    var header: ImageHeader = undefined;
    var bytes = std.mem.asBytes(&header);
    const fa = try FlashArea.open(id);
    defer fa.close();
    try fa.read(0, bytes);
    // std.log.info("Header: {any}", .{header});
    if (header.magic != IMAGE_MAGIC)
        return error.InvalidImage;
    return header;
}

fn dump_layout() !void {
    // Show all of the flash areas.
    var id: u8 = 0;
    while (true) : (id += 1) {
        const p0 = FlashArea.open(id) catch |err| {
            if (err == error.ENOENT)
                break;
            return err;
        };
        defer p0.close();
        std.log.info("Partition {} 0x{x:8} (size 0x{x:8})", .{ p0.id, p0.off, p0.size });
    }
}
