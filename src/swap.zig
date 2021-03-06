// SPDX-License-Identifier: Apache-2.0
//
// Swap operations.

const std = @import("std");
const mem = std.mem;

// Bytes of changeable prefix.  This doesn't need to be large, as we
// aren't really using it as a key (it will almost always just be
// '1').
const prefix_length = 4;

// We can use a Sha hasher by appending the prefix to the init.
// For Siphash, the prefix will be used as the prefix of the data.
const Sha256Hasher = struct {
    pub const T = std.crypto.hash.sha2.Sha256;
    pub const digest_length = T.digest_length;
    pub fn init(prefix: *const [prefix_length]u8) T {
        var hh = T.init(.{});
        hh.update(prefix);
        return hh;
    }
};
const SipHasher = struct {
    pub const T = std.crypto.auth.siphash.SipHash64(2, 4);
    pub const digest_length = T.mac_length;
    pub fn init(prefix: *const [prefix_length]u8) T {
        var buf: [T.key_length]u8 = @splat(T.key_length, @as(u8, 0));
        mem.copy(u8, buf[0..prefix_length], prefix);
        return T.init(&buf);
    }
};
pub const Hasher = if (false) Sha256Hasher else SipHasher;

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
        // std.log.info("--- Running startup", .{});
        const st0 = try self.status[0].scan();
        const st1 = try self.status[1].scan();

        var initial = false;
        if (st0 == .Unknown and st1 == .Request) {
            // Initial request for work.  Compute hashes over all of
            // the data.
            try self.oneHash(0);
            try self.oneHash(1);

            // Write this status out, which should move us on to the
            // first phase.
            // std.log.info("Writing initial status", .{});
            try self.status[0].startStatus(self);
            initial = true;
        } else if (st1 == .Request and (st0 == .Slide or st0 == .Swap)) {
            // The swap operation was interrupted, load the status so
            // that we can then try to recover where we left off.
            try self.status[0].loadStatus(self);
        } else {
            std.log.err("Unsupport status config {},{}", .{ st0, st1 });
            return error.StateError;
        }

        // std.log.warn("Recover at state: {}", .{st0});

        // Build the work data.
        try self.workSlide0(initial);
        try self.workSwap(initial);

        // If we didn't just start from "Request", we need to recover
        // our state.
        var restart = Recovered{ .work = 0, .step = 0 };
        if (st0 == .Slide or st0 == .Swap) {
            restart = try self.recover(st0);
        }

        try self.performWork(restart);
    }

    const Recovered = struct {
        work: usize,
        step: usize,
    };

    // Perform recovery.  The initial state will tell us what work
    // phase we are in, and we will consider that work to be partially
    // completed.  Within that phase, we scan the work list, looking
    // for the first item that clearly has not been performed
    // (destination does not match).  Once we've found that, back up
    // on, if possible, since we don't know if the one we found was
    // partially done, or just not done at all.
    fn recover(self: *Self, phase: Status.Phase) !Recovered {
        const workNo = try phase.whichWork();
        // std.log.info("Recovering work: {}", .{workNo});

        // Scan through the work list, stopping at the first entry
        // where the destination doesn't appear to have been written.
        var i: usize = 0;
        while (i < self.work[workNo].len) : (i += 1) {
            const item = &self.work[workNo].buffer[i];
            const wstate = self.areas[item.dest_slot].getState(item.dest_page << page_shift) catch {
                break;
            };
            if (wstate != .Written) {
                // If it doesn't look written, assume not, and this is
                // valid.
                break;
            }

            // If it is written, check if it has the correctly written
            // hash.
            // std.log.info("Page {} is {}", .{ i, wstate });
            // std.log.info("  work: {s}", .{fmtWork(item)});
            var hash: [hash_bytes]u8 = undefined;
            if (self.hashPage(&hash, item.dest_slot, item.dest_page << page_shift, item.size)) |_| {} else |_| {
                // Consider read errors as just the data not being
                // valid.  Whether a given page will read as an error
                // or not depends on the device.
                break;
            }
            if (!mem.eql(u8, &hash, &item.hash)) {
                break;
            }
        }

        // At this point, unless we are on the first work item, go
        // backwards one work step, and redo that, if the source is
        // still present.
        // std.log.info("Recover at {}", .{i});
        if (i > 0) {
            const item = &self.work[workNo].buffer[i - 1];
            if (self.areas[item.src_slot].getState(item.src_page << page_shift)) |rstate| {
                if (rstate != .Written) {
                    // Unreadable, don't back up.
                } else {
                    var hash: [hash_bytes]u8 = undefined;
                    if (self.hashPage(&hash, item.src_slot, item.src_page << page_shift, item.size)) |_| {
                        // Only stay back on if the hash didn't work
                        // out.
                        if (mem.eql(u8, &hash, &item.hash)) {
                            i -= 1;
                        }
                    } else |_| {}
                }
            } else |_| {
                // Unreadable, don't back up.
            }
            // std.log.info("  moved to {}", .{i});
        }

        return Recovered{ .work = workNo, .step = i };
    }

    fn oneHash(self: *Self, slot: usize) !void {
        var pos: usize = 0;
        var page: usize = 0;
        while (pos < self.sizes[slot]) : (pos += page_size) {
            const count = std.math.min(self.sizes[slot] - pos, page_size);
            try self.hashPage(self.hashes[slot][page][0..], slot, pos, count);
            // std.log.info("Hashed: slot {}, page {}, {s} ({} bytes)", .{
            //     slot,                                                   page,
            //     std.fmt.fmtSliceHexLower(self.hashes[slot][page][0..]), count,
            // });

            page += 1;
        }
    }

    // Checking for internal testing.
    fn checkHash(self: *Self, item: *const Work, buf: []const u8) !void {
        var dest: [Hasher.digest_length]u8 = undefined;
        var hh = Hasher.init(&self.prefix);
        hh.update(buf[0..item.size]);
        hh.final(dest[0..]);
        if (std.testing.expectEqualSlices(u8, &item.hash, dest[0..hash_bytes])) |_| {} else |err| {
            std.log.warn("Hash mismatch, expect: {s}, got: {s} ({} bytes)", .{
                std.fmt.fmtSliceHexLower(item.hash[0..]),
                std.fmt.fmtSliceHexLower(dest[0..hash_bytes]),
                item.size,
            });
            return err;
        }
    }

    fn hashPage(self: *Self, dest: []u8, slot: usize, offset: usize, count: usize) !void {
        var hh = Hasher.init(&self.prefix);
        try self.areas[slot].read(offset, self.tmp[0..count]);
        hh.update(self.tmp[0..count]);
        var hash: [Hasher.digest_length]u8 = undefined;
        hh.final(hash[0..]);
        mem.copy(u8, dest[0..], hash[0..hash_bytes]);
    }

    // This is used by the status code to verify its contents.  We
    // just use an empty prefix.
    pub fn calcHash(data: []const u8) [hash_bytes]u8 {
        const prefix: [prefix_length]u8 = @splat(prefix_length, @as(u8, 0));
        var hh = Hasher.init(&prefix);
        hh.update(data);
        var hash: [Hasher.digest_length]u8 = undefined;
        hh.final(hash[0..]);
        var result: [hash_bytes]u8 = undefined;
        mem.copy(u8, result[0..], hash[0..4]);
        return result;
    }

    // Compute the work for sliding slot 0 down by one.
    pub fn workSlide0(self: *Self, initial: bool) !void {
        const bound = self.calcBound(0);

        // Pos is the destination of each page.
        var pos: usize = bound.count;
        while (pos > 0) : (pos -= 1) {
            const size = bound.getSize(pos - 1);

            if (pos < bound.count and try self.validateSame(.{ 0, 0 }, .{ pos - 1, pos }, size, initial))
                continue;

            try self.work[0].append(.{
                .src_slot = 0,
                .dest_slot = 0,
                .size = @intCast(u16, size),
                .src_page = pos - 1,
                .dest_page = pos,
                .hash = self.hashes[0][pos - 1],
            });
            // self.hashes[0][pos] = self.hashes[0][pos - 1];
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
    fn workSwap(self: *Self, initial: bool) !void {
        const bound0 = self.calcBound(0);
        const bound1 = self.calcBound(1);

        // std.log.warn("bound0: {}", .{bound0});
        // std.log.warn("bound1: {}", .{bound1});

        // At a given pos, we move slot1,pos to slot0,pos, and
        // slot0,pos+1 to slot1.pos.
        var pos: usize = 0;
        while (pos < bound0.count or pos < bound1.count) : (pos += 1) {
            // Move slot 1 to 0.
            if (pos < bound1.count) {
                const size = bound1.getSize(pos);
                // std.log.info("1->0 {}, {}", .{ pos, size });

                if (pos < bound0.count and try self.validateSame(.{ 1, 0 }, .{ pos, pos }, size, initial))
                    continue;
                try self.work[1].append(.{
                    .src_slot = 1,
                    .src_page = pos,
                    .dest_slot = 0,
                    .dest_page = pos,
                    .size = @intCast(u16, size),
                    .hash = self.hashes[1][pos],
                });
                // self.hashes[0][pos] = self.hashes[1][pos];
            }

            // Move slot 0 to 1.
            if (pos < bound0.count) {
                const size = bound0.getSize(pos);

                if (pos < bound1.count and try self.validateSame(.{ 0, 1 }, .{ pos + 1, pos }, size, initial))
                    continue;

                try self.work[1].append(.{
                    .src_slot = 0,
                    .src_page = pos + 1,
                    .dest_slot = 1,
                    .dest_page = pos,
                    .size = @intCast(u16, size),
                    .hash = self.hashes[0][pos],
                });
                // self.hashes[1][pos] = self.hashes[0][pos + 1];
            }
        }
    }

    /// Perform the work we've set ourselves to do.
    fn performWork(self: *Self, next: Recovered) !void {
        // std.log.warn("Performing work", .{});
        var i: usize = next.work;
        while (i < self.work.len) : (i += 1) {
            const work = &self.work[i];
            // std.log.warn("Work, phase: {}", .{i});
            var step: usize = 0;
            if (i == next.work) {
                step = next.step;
            }
            while (step < work.len) : (step += 1) {
                const item = &work.buffer[step];
                // std.log.warn("Work: {s}", .{fmtWork(item)});
                try self.areas[item.dest_slot].erase(item.dest_page << page_shift, page_size);
                try self.areas[item.src_slot].read(item.src_page << page_shift, self.tmp[0..]);
                try self.checkHash(item, self.tmp[0..]);
                try self.areas[item.dest_slot].write(item.dest_page << page_shift, self.tmp[0..]);
            }

            // If we finish Sliding, we need to write a new status
            // page.
            if (i == 0) {
                try self.status[0].updateStatus(.Swap);
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
                var hh = Hasher.init(&self.prefix);
                const num: usize = slot * max_pages * page_size + pos;
                hh.update(std.mem.asBytes(&num));
                var hash: [Hasher.digest_length]u8 = undefined;
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
                var hh = Hasher.init(&self.prefix);
                const num: usize = slot * max_pages * page_size + pos;
                hh.update(std.mem.asBytes(&num));
                var hash: [Hasher.digest_length]u8 = undefined;
                hh.final(hash[0..]);
                // std.log.warn("Checking: {} in slot {}", .{ page, slot });
                try std.testing.expectEqualSlices(u8, hash[0..hash_bytes], self.hashes[slot][page][0..]);

                page += 1;
            }
        }
    }

    const Bound = struct {
        // This is the number of pages in the region to move.
        count: usize,
        // The number of bytes in the last page.  Will be page_size if
        // this image is a multiple of the page size.
        partial: usize,

        fn getSize(self: *const Bound, page: usize) usize {
            var size = page_size;
            if (page == self.count - 1)
                size = self.partial;
            // std.log.info("getSize: bound:{}, page:{} -> {}", .{ self, page, size });
            return size;
        }
    };
    fn calcBound(self: *const Self, slot: usize) Bound {
        const count = (self.sizes[slot] + (page_size - 1)) >> page_shift;
        var partial = self.sizes[slot] & (page_size - 1);
        if (partial == 0)
            partial = page_size;
        // std.log.warn("Bound: size: {}, count: {}, partial: {}", .{ self.sizes[slot], count, partial });
        return Bound{
            .count = count,
            .partial = partial,
        };
    }

    // Ensure that two pages that have the same hash are actually the
    // same.  Returns error.HashCollision if they differ, which will
    // result in higher-level code retrying with a different prefix.
    fn validateSame(self: *Self, slots: [2]u8, pages: [2]usize, len: usize, initial: bool) !bool {
        if (std.mem.eql(
            u8,
            self.hashes[slots[0]][pages[0]][0..],
            self.hashes[slots[1]][pages[1]][0..],
        )) {
            if (initial)
                return true;

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

/// Wrap work with a nicer formatter.
fn fmtWork(w: *const Work) std.fmt.Formatter(formatWork) {
    return .{ .data = w };
}

fn formatWork(
    data: *const Work,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = data;
    _ = fmt;
    _ = options;
    _ = writer;
    try std.fmt.format(writer, "Work{{src:{:>3}/{:>3}, dest:{:>3}/{:>3}, size:{:>3}, hash:{}}}", .{
        data.src_slot,
        data.src_page,
        data.dest_slot,
        data.dest_page,
        data.size,
        std.fmt.fmtSliceHexLower(data.hash[0..]),
    });
}

const RecoveryTest = struct {
    const Self = @This();
    const testing = std.testing;
    const BootTest = @import("test.zig").BootTest;

    // These are just sizes we will use for testing.
    const testSizes = if (true)
        [2]usize{ 112 * Swap.page_size + 7, 105 * Swap.page_size + Swap.page_size - 1 }
    else
        [2]usize{ 2 * Swap.page_size + 7, 1 * Swap.page_size + Swap.page_size - 1 };

    bt: BootTest,

    fn init() !RecoveryTest {
        var bt = try BootTest.init(testing.allocator, BootTest.lpc55s69);
        errdefer bt.deinit();

        return Self{
            .bt = bt,
        };
    }

    fn deinit(self: *Self) void {
        self.bt.deinit();
    }

    fn single(self: *Self, limit: usize, sizes: [2]usize) !void {
        var lim: usize = limit;
        while (true) : (lim += 1) {
            std.log.info("##### Testing limit {} #####", .{lim});
            try self.bt.sim.installImages(sizes);

            var swap = try Swap.init(&self.bt.sim, sizes, 1);

            // Writing the magic to slot 1 initiates an upgrade.
            try swap.status[1].writeMagic();

            // Set our limit, stopping after that many flash steps.
            self.bt.sim.counter.reset();
            try self.bt.sim.counter.setLimit(lim);

            // TODO: Handle hash collision, restarting as appropriate.
            var interrupted = false;
            if (swap.startup()) |_| {
                std.log.info("Counter reset after {} steps", .{self.bt.sim.counter.current});
            } else |err| {
                if (err != error.Expired)
                    return err;
                interrupted = true;
                // std.log.info("---------------------- Interrupt --------------------", .{});
            }

            if (interrupted) {
                // Retry the startup, as if we reached a fresh start.
                self.bt.sim.counter.reset();
                swap = try Swap.init(&self.bt.sim, sizes, 1);

                // Run a new startup.  This should always run to completion.
                try swap.startup();
            }

            // Check that the swap completed.
            // std.log.info("Verifying flash", .{});
            try self.bt.sim.verifyImages(sizes);

            if (!interrupted)
                break;
        }
    }
};

test "Swap recovery" {
    std.testing.log_level = .info;
    var tt = try RecoveryTest.init();
    defer tt.deinit();
    try tt.single(1, RecoveryTest.testSizes);

    // Write out the swap status.
    try (try tt.bt.sim.open(0)).save("swap-0.bin");
    try (try tt.bt.sim.open(1)).save("swap-1.bin");
}
