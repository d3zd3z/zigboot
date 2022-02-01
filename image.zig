// SPDX-License-Identifier: Apache-2.0
// MCUboot image management.

const std = @import("std");
const assert = std.debug.assert;
const Sha256 = std.crypto.hash.sha2.Sha256;

const zephyr = @import("zephyr.zig");
const sys = @import("src/sys.zig");

const FlashArea = sys.flash.FlashArea;

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

    // Read a structure from flash at the given offset.
    pub fn readStruct(self: *Self, comptime T: type, offset: u32) !T {
        var data: T = undefined;
        var bytes = std.mem.asBytes(&data);
        try self.fa.read(offset, bytes);
        return data;
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
pub fn hash_image(fa: *const FlashArea, header: *const ImageHeader, hash: *[32]u8) !void {
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
    h.final(hash[0..]);
    zephyr.print("Hash: ", .{});
    for (hash) |ch| {
        zephyr.print("{x:>2}", .{ch});
    }
    zephyr.print("\n", .{});
}

// Hashing benchmark, with SHA256.
pub fn hash_bench(fa: *const FlashArea, count: usize) !void {
    try hash_core(struct {
        const Self = @This();
        pub const size = 32;
        state: Sha256,
        pub fn init() Self {
            return .{
                .state = Sha256.init(.{}),
            };
        }
        pub fn update(self: *Self, buf: []const u8) void {
            self.state.update(buf);
        }
        pub fn final(self: *Self, out: *[size]u8) void {
            self.state.final(out);
        }
    }, fa, count);
}

pub fn null_bench(fa: *const FlashArea, count: usize) !void {
    try hash_core(struct {
        const Self = @This();
        pub const size = 4;
        state: u32,
        pub fn init() Self {
            return .{ .state = 42 };
        }
        pub fn update(self: *Self, buf: []const u8) void {
            _ = self;
            _ = buf;
        }
        pub fn final(self: *Self, out: *[size]u8) void {
            _ = self;
            std.mem.copy(u8, out, std.mem.asBytes(&self.state));
        }
    }, fa, count);
}

pub fn murmur_bench(fa: *const FlashArea, count: usize) !void {
    try hash_core(struct {
        const Self = @This();
        pub const size = 4;
        state: ?u32,
        pub fn init() Self {
            return .{ .state = null };
        }
        pub fn update(self: *Self, buf: []const u8) void {
            if (self.state) |state| {
                // This really isn't right, since it can't be chained
                // like this.
                self.state = std.hash.Murmur2_32.hashWithSeed(buf, state);
            } else {
                self.state = std.hash.Murmur2_32.hash(buf);
            }
        }
        pub fn final(self: *Self, out: *[size]u8) void {
            if (self.state) |state| {
                _ = out;
                _ = state;
                std.mem.copy(u8, out, std.mem.asBytes(&state));
            } else {
                unreachable;
            }
        }
    }, fa, count);
}

pub fn sip_bench(fa: *const FlashArea, count: usize) !void {
    const Sip = std.crypto.hash.sip.SipHash64(2, 4);

    try hash_core(struct {
        const Self = @This();
        pub const size = Sip.mac_length;
        state: Sip,
        pub fn init() Self {
            var key: [Sip.key_length]u8 = undefined;
            std.mem.set(u8, &key, 0);
            key[0] = 1;
            return .{ .state = Sip.init(&key) };
        }
        pub fn update(self: *Self, buf: []const u8) void {
            self.state.update(buf);
        }
        pub fn final(self: *Self, out: *[size]u8) void {
            self.state.final(out);
        }
    }, fa, count);
}

fn hash_core(Core: anytype, fa: *const FlashArea, count: usize) !void {
    const BUFSIZE = 128;
    const PAGESIZE = 512;
    var buf: [BUFSIZE]u8 = undefined;
    var hash: [Core.size]u8 = undefined;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var h = Core.init();
        var pos: u32 = 0;
        while (pos < PAGESIZE) {
            var todo = PAGESIZE - pos;
            if (todo > BUFSIZE)
                todo = BUFSIZE;
            _ = fa;
            // try fa.read(0 + pos, buf[0..todo]);
            h.update(buf[0..todo]);
            pos += todo;
        }
        h.final(&hash);

        std.mem.doNotOptimizeAway(&hash[0]);
    }
}

// A small hashing benchmarking.  Hashes a single page 'n' times.
fn hash_bench2(fa: *const FlashArea, count: usize) !void {
    const BUFSIZE = 128;
    const PAGESIZE = 512;
    var buf: [BUFSIZE]u8 = undefined;
    var hash: [32]u8 = undefined;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var h = Sha256.init(.{});
        var pos: u32 = 0;
        while (pos < PAGESIZE) {
            var todo = PAGESIZE - pos;
            if (todo > BUFSIZE)
                todo = BUFSIZE;
            try fa.read(0 + pos, buf[0..todo]);
            h.update(buf[0..todo]);
            pos += todo;
        }
        h.final(hash[0..]);
    }
}
