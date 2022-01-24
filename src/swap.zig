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

    pub const max_work: usize = max_pages;

    /// Hashes are stored with this type.
    pub const hash_bytes = 4;
    pub const Hash = [hash_bytes]u8;
    const WorkArray = std.BoundedArray(Work, max_work);

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

    /// The built up work.
    work: [2]WorkArray,

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
            .work = .{ try WorkArray.init(0), try WorkArray.init(0) },
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
        } else if (st1 == .Request and (st0 == .Slide or st0 == .Swap)) {
            // The swap operation was interrupted, load the status so
            // that we can then try to recover where we left off.
            try self.status[0].loadStatus(self);
        } else {
            std.log.err("Unsupport status config {},{}", .{ st0, st1 });
            return error.StateError;
        }

        // Build the work data.
        try self.workSlide0();
        try self.workSwap();

        // TODO: Start from the beginning.
        try self.performWork();
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

    // Compute the work for sliding slot 0 down by one.
    pub fn workSlide0(self: *Self) !void {
        const bound = self.calcBound(0);

        // Pos is the destination of each page.
        var pos: usize = bound.last;
        while (pos > 0) : (pos -= 1) {
            const size = bound.getSize(pos);

            if (pos < bound.last and try self.validateSame(.{ 0, 0 }, .{ pos - 1, pos }, size))
                continue;

            try self.work[0].append(.{
                .src_slot = 0,
                .dest_slot = 0,
                .size = @intCast(u16, size),
                .src_page = pos - 1,
                .dest_page = pos,
                .hash = self.hashes[0][pos - 1],
            });
        }
    }

    // Compute the work for swapping the two images.  For a layout
    // such as this:
    //   slot 0 | slot 1
    //     X    |   A1
    //     A0   |   B1
    //     B0   |   C1
    //     C0   |   D1
    // we want to move A1 to slot 0, and A0 to slot 1.  This
    // continues, stopping either the left or right movement when we
    // have exceeded the size for that side.
    fn workSwap(self: *Self) !void {
        const bound0 = self.calcBound(0);
        const bound1 = self.calcBound(1);

        // std.log.warn("bound0: {}", .{bound0});
        // std.log.warn("bound1: {}", .{bound1});

        // At a given pos, we move slot1,pos to slot0,pos, and
        // slot0,pos+1 to slot1.pos.
        var pos: usize = 0;
        while (pos < bound0.last or pos < bound1.last) : (pos += 1) {
            // Move slot 1 to 0.
            if (pos < bound1.last) {
                const size = bound1.getSize(pos);

                if (pos < bound0.last and try self.validateSame(.{ 1, 0 }, .{ pos, pos }, size))
                    continue;
                try self.work[1].append(.{
                    .src_slot = 1,
                    .dest_slot = 0,
                    .size = @intCast(u16, size),
                    .src_page = pos,
                    .dest_page = pos,
                    .hash = self.hashes[1][pos],
                });
            }

            // Move slot 0 to 1.
            if (pos < bound0.last) {
                const size = bound0.getSize(pos);

                if (pos < bound1.last and try self.validateSame(.{ 0, 1 }, .{ pos + 1, pos }, size))
                    continue;

                try self.work[1].append(.{
                    .src_slot = 0,
                    .dest_slot = 1,
                    .size = @intCast(u16, size),
                    .src_page = pos + 1,
                    .dest_page = pos,
                    .hash = self.hashes[0][pos],
                });
            }
        }
    }

    /// Perform the work we've set ourselves to do.
    fn performWork(self: *Self) !void {
        for (self.work) |work| {
            for (work.constSlice()) |*item| {
                std.log.warn("Work: {}", .{item});
                try self.areas[item.dest_slot].erase(item.dest_page << page_shift, page_size);
                try self.areas[item.src_slot].read(item.src_page << page_shift, self.tmp[0..]);
                try self.areas[item.dest_slot].write(item.dest_page << page_shift, self.tmp[0..]);
            }
        }
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

    const Bound = struct {
        // The last page to be moved in the given region.
        last: usize,
        // The number of bytes in the last page.  Will be page_size if
        // this image is a multiple of the page size.
        partial: usize,

        fn getSize(self: *const Bound, page: usize) usize {
            var size = page_size;
            if (page == self.last)
                size = self.partial;
            return size;
        }
    };
    fn calcBound(self: *const Self, slot: usize) Bound {
        const last = (self.sizes[slot] + (page_size - 1)) >> page_shift;
        var partial = self.sizes[slot] & (page_size - 1);
        if (partial == 0)
            partial = page_size;
        // std.log.warn("Bound: size: {}, last: {}, partial: {}", .{ self.sizes[slot], last, partial });
        return Bound{
            .last = last,
            .partial = partial,
        };
    }

    // Ensure that two pages that have the same hash are actually the
    // same.  Returns error.HashCollision if they differ, which will
    // result in higher-level code retrying with a different prefix.
    fn validateSame(self: *Self, slots: [2]u8, pages: [2]usize, len: usize) !bool {
        if (std.mem.eql(
            u8,
            self.hashes[slots[0]][pages[0]][0..],
            self.hashes[slots[1]][pages[1]][0..],
        )) {
            // If the hashes match, compare the page contents.
            std.log.err("TODO: Page comparison slots {any}, pages {any}", .{ slots, pages });
            _ = len;
            unreachable;
        } else {
            return false;
        }
    }
};

/// A unit of work describes the move of one page of data in flash.
const Work = struct {
    src_slot: u8,
    dest_slot: u8,
    size: u16,
    src_page: usize,
    dest_page: usize,

    // The hash we're intending to move.
    hash: Swap.Hash,
};

test "Swap recovery" {
    const testing = std.testing;
    const BootTest = @import("test.zig").BootTest;
    var bt = try BootTest.init(testing.allocator, BootTest.lpc55s69);
    defer bt.deinit();

    // These are just sizes we will use for testing.
    const sizes = [2]usize{ 112 * Swap.page_size + 7, 105 * Swap.page_size + Swap.page_size - 1 };
    // const sizes = [2]usize{ 2 * Swap.page_size + 7, 1 * Swap.page_size + Swap.page_size - 1 };

    var limit: usize = 1000;

    while (true) : (limit += 1) {
        // Fill in the images.
        try bt.sim.installImages(sizes);

        var swap = try Swap.init(&bt.sim, sizes, 1);

        // Writing the magic to slot 1 initiates an upgrade.
        try swap.status[1].writeMagic();

        // Set our limit, stopping after that many flash steps.
        bt.sim.counter.reset();
        try bt.sim.counter.setLimit(limit);

        // TODO: Handle hash collision, restarting as appropriate.
        if (swap.startup()) |_| {
            break;
        } else |err| {
            if (err != error.Expired)
                return err;
        }

        // Retry the startup, as if we reached a fresh start.
        bt.sim.counter.reset();
        swap = try Swap.init(&bt.sim, sizes, 1);

        // Check that the swap completed.
        try bt.sim.verifyImages(sizes);

        try swap.startup();
    }

    // Write out the swap status.
    try (try bt.sim.open(0)).save("swap-0.bin");
    try (try bt.sim.open(1)).save("swap-1.bin");
}
