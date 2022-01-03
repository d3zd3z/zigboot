// SPDX-License-Identifier: Apache-2.0
// MCUboot image management.

const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const zephyr = @import("zephyr.zig");

const FlashArea = zephyr.flash.FlashArea;

// An open image.
pub const Image = struct {
    const Self = @This();

    id: u8,
    header: ImageHeader,
    fa: *const FlashArea,

    pub fn init(id: u8) !Image {
        const fa = try FlashArea.open(id);
        errdefer fa.close();

        var header: ImageHeader = undefined;
        var bytes = std.mem.asBytes(&header);
        try fa.read(0, bytes);
        if (header.magic != IMAGE_MAGIC)
            return error.InvalidImage;
        return Self{
            .id = id,
            .header = header,
            .fa = fa,
        };
    }

    pub fn deinit(self: *Self) void {
        self.fa.close();
    }
};

// For testing on the LPC, with Debug enabled, this code is easily
// larger than 32k.  Rather than change the partition table, we will
// just use slots 2 and 4 (and 5 as scratch).  Scratch is kind of
// silly, since there is no support for swap on this target yet.
pub const Slot = enum(u8) {
    PrimarySecure = 1,
    PrimaryNS = 2,
    UpgradeSecure = 3,
    UpgradeNS = 4,
};

// The image header.
pub const ImageHeader = extern struct {
    const Self = @This();

    magic: u32,
    load_addr: u32,
    hdr_size: u16,
    protect_tlv_size: u16,
    img_size: u32,
    flags: u32,
    ver: ImageVersion,
    pad1: u32,

    pub fn imageStart(self: *const Self) u32 {
        return self.hdr_size;
    }

    pub fn tlvBase(self: *const Self) u32 {
        return @as(u32, self.hdr_size) + self.img_size;
    }

    pub fn protectedSize(self: *const Self) u32 {
        return @as(u32, self.hdr_size) + self.img_size + self.protect_tlv_size;
    }
};
comptime {
    assert(@sizeOf(ImageHeader) == 32);
}

// The version (non-semantic).
pub const ImageVersion = extern struct {
    major: u8,
    minor: u8,
    revision: u16,
    build_num: u32,
};

pub const IMAGE_MAGIC = 0x96f3b83d;

// Load the header from the given slot.
pub fn load_header(id: u8) !ImageHeader {
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

pub fn dump_layout() !void {
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

// Hash the image.
pub fn hash_image(fa: *const FlashArea, header: *const ImageHeader) !void {
    std.log.info("Hashing image, tlv: {x:>8}", .{header.tlvBase()});
    var buf: [256]u8 = undefined;
    var h = Sha256.init(.{});

    const len = header.protectedSize();
    var pos: u32 = 0;
    while (pos < len) {
        var count = len - pos;
        if (count > buf.len)
            count = buf.len;
        try fa.read(0 + pos, buf[0..count]);
        h.update(buf[0..count]);
        pos += count;
    }
    var out: [32]u8 = undefined;
    h.final(out[0..]);
    zephyr.print("Hash: ", .{});
    for (out) |ch| {
        zephyr.print("{x:>2}", .{ch});
    }
    zephyr.print("\n", .{});
}
