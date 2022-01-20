// SPDX-License-Identifier: Apache-2.0
//
// Swap operations.

const std = @import("std");
const mem = std.mem;
const Sha256 = std.crypto.hash.sha2.Sha256;

const config = @import("config.zig");
const sys = @import("sys.zig");
const SimFlash = sys.flash.SimFlash;
const Status = @import("status.zig").Self;

/// Swap manages the operation and progress of the swap operation.
/// This struct is intended to be maintained statically, and the init
/// function initializes an uninitialized variant of the struct.
pub const Swap = struct {
    const Self = @This();

    /// For now, the page size is shared.  If the devices have
    /// differing page sizes, this should be set to the larger value.
    pub const page_size: usize = 512;
    pub const page_shift: std.math.Log2Int(usize) = std.math.log2_int(usize, page_size);
    pub const max_pages: usize = config.max_pages;

    /// Hashes are stored with this type.
    pub const hash_bytes = 4;
    pub const Hash = [hash_bytes]u8;

    /// Temporary buffers.
    tmp: [page_size]u8 = undefined,
    tmp2: [page_size]u8 = undefined,

    /// The sizes of the two images.  This includes all of the data
    /// that needs to be copied: header, image, and TLV/manifest.
    sizes: [2]usize,

    /// Pointers to the flash areas.
    areas: [2]*sys.flash.FlashArea,

    /// Local storage for the hashes.
    hashes: [2][max_pages]Hash = undefined,

    /// To handle hash collisions, this value is prefixed the the data
    /// hashed.  If we detect a collision, this can be changed, and we
    /// restart the operation.
    prefix: [4]u8,

    /// The manager for the status.
    status: [2]Status,

    /// TODO: work, etc.
    /// Like 'init', but initializes an already allocated value.
    pub fn init(sim: *sys.flash.SimFlash, sizes: [2]usize, prefix: u32) !Self {
        var a = try sim.open(0); // TODO: Better numbers.
        var b = try sim.open(1);

        var bprefix: [4]u8 = undefined;
        mem.copy(u8, bprefix[0..], mem.asBytes(&prefix));

        return Self{
            .areas = [2]*sys.flash.FlashArea{ a, b },
            .sizes = sizes,
            .prefix = bprefix,
            .status = [2]Status{ try Status.init(a), try Status.init(b) },
        };
    }

    /// Starting process.  This attempts to determine what needs to be
    /// done based on the status pages.
    pub fn startup(self: *Self) !void {
        const st0 = try self.status[0].scan();
        const st1 = try self.status[1].scan();

        if (st0 == .Unknown and st1 == .Request) {
            // Initial request for work.  Compute hashes over all of
            // the data.
            try self.oneHash(0);
            try self.oneHash(1);

            // Write this status out, which should move us on to the
            // first phase.
            try self.status[0].startStatus(self);
        } else {
            std.log.err("Unsupport status config {},{}", .{ st0, st1 });
        }
    }

    fn oneHash(self: *Self, slot: usize) !void {
        var pos: usize = 0;
        var page: usize = 0;
        while (pos < self.sizes[slot]) : (pos += page_size) {
            const count = std.math.min(self.sizes[slot] - pos, page_size);
            try self.hashPage(self.hashes[slot][page][0..], slot, pos, count);

            page += 1;
        }
    }

    fn hashPage(self: *Self, dest: []u8, slot: usize, offset: usize, count: usize) !void {
        var hh = Sha256.init(.{});
        hh.update(self.prefix[0..]);
        try self.areas[slot].read(offset, self.tmp[0..count]);
        hh.update(self.tmp[0..count]);
        var hash: [32]u8 = undefined; // TODO: magic number
        hh.final(hash[0..]);
        mem.copy(u8, dest[0..], hash[0..hash_bytes]);
    }

    pub fn calcHash(data: []const u8) [hash_bytes]u8 {
        var hh = Sha256.init(.{});
        hh.update(data);
        var hash: [32]u8 = undefined;
        hh.final(hash[0..]);
        var result: [hash_bytes]u8 = undefined;
        mem.copy(u8, result[0..], hash[0..4]);
        return result;
    }

    /// Return an iterator over all of the hashes.
    pub fn iterHashes(self: *Self) HashIter {
        return .{
            .state = self,
            .phase = 0,
            .pos = 0,
        };
    }

    pub const HashIter = struct {
        const HSelf = @This();

        state: *Self,
        phase: usize,
        pos: usize,

        pub fn next(self: *HSelf) ?*[hash_bytes]u8 {
            while (true) {
                if (self.phase >= 2)
                    return null;

                if (self.pos >= asPages(self.state.sizes[self.phase])) {
                    self.pos = 0;
                    self.phase += 1;
                } else {
                    break;
                }
            }

            const result = &self.state.hashes[self.phase][self.pos];
            self.pos += 1;
            return result;
        }
    };

    fn asPages(value: usize) usize {
        return (value + page_size - 1) >> page_shift;
    }

    // For testing, set 'sizes' and fill in some hashes for the given
    // image "sizes".
    pub fn fakeHashes(self: *Self, sizes: [2]usize) !void {
        self.sizes = sizes;

        self.prefix = [4]u8{ 1, 2, 3, 4 };

        var slot: usize = 0;

        while (slot < 2) : (slot += 1) {
            var pos: usize = 0;
            var page: usize = 0;
            while (pos < self.sizes[slot]) : (pos += page_size) {
                var hh = Sha256.init(.{});
                hh.update(self.prefix[0..]);
                const num: usize = slot * max_pages * page_size + pos;
                hh.update(std.mem.asBytes(&num));
                var hash: [32]u8 = undefined; // TODO: magic number
                hh.final(hash[0..]);
                std.mem.copy(u8, self.hashes[slot][page][0..], hash[0..hash_bytes]);
                // std.log.warn("hash: {} 0x{any}", .{ page, self.hashes[slot][page] });

                page += 1;
            }
        }
    }

    // For testing, compare the generated sizes and hashes to make
    // sure they have been recovered correctly.
    pub fn checkFakeHashes(self: *Self, sizes: [2]usize) !void {
        try std.testing.expectEqualSlices(usize, sizes[0..], self.sizes[0..]);
        try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, self.prefix);

        var slot: usize = 0;
        while (slot < 2) : (slot += 1) {
            var pos: usize = 0;
            var page: usize = 0;
            while (pos < self.sizes[slot]) : (pos += page_size) {
                var hh = Sha256.init(.{});
                hh.update(self.prefix[0..]);
                const num: usize = slot * max_pages * page_size + pos;
                hh.update(std.mem.asBytes(&num));
                var hash: [32]u8 = undefined;
                hh.final(hash[0..]);
                // std.log.warn("Checking: {} in slot {}", .{ page, slot });
                try std.testing.expectEqualSlices(u8, hash[0..hash_bytes], self.hashes[slot][page][0..]);

                page += 1;
            }
        }
    }
};

test "Swap recovery" {
    const testing = std.testing;
    const BootTest = @import("test.zig").BootTest;
    var bt = try BootTest.init(testing.allocator, BootTest.lpc55s69);
    defer bt.deinit();

    // These are just sizes we will use for testing.
    const sizes = [2]usize{ 112 * Swap.page_size + 7, 105 * Swap.page_size + Swap.page_size - 1 };

    // Fill in the images.
    try bt.sim.installImages(sizes);

    var swap = try Swap.init(&bt.sim, sizes, 1);

    // Writing the magic to slot 1 initiates an upgrade.
    try swap.status[1].writeMagic();

    // Try the normal startup.
    // TODO: Handle hash collision, restarting as appropriate.
    try swap.startup();

    // Write out the swap status.
    try (try bt.sim.open(0)).save("swap-0.bin");
    try (try bt.sim.open(1)).save("swap-1.bin");
}
