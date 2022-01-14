// SPDX-License-Identifier: Apache-2.0
// hash-based swap
//
// This could also be called a unified swap, as it attempts to unify
// the way swap works across all of the flash devices we support in
// MCUboot.
//
// Throughout this code, we will be consistent with our terms:
//
//   - sector: The erasable unit of the device
//   - write alignment: The size of units needed to write to flash.
//   - page: Used to describe both on devices where they are the same
//     size.
//
// This algorithm makes some assumptions about flash memory:
//
// 1.  Flash is somewhat conventional, there are erasable units, which
//     may be large, and writable units that may be smaller.  We
//     support two main classes of devices: traditional, where we have
//     large erase devices.  These have relatively large sectors
//     (typically between 4k and 128k), and a fairly small write
//     alignment.  Notably, it is possible to write to the individual
//     write units of flash separately from the units they are erased
//     in.
//
// 2.  The other type of flash supported we will call "page based"
//     flash.  With these devices, a given value, usually 512, is both
//     the sector size and the write alignment.  The status will be
//     stored differently on these devices, because we cannot
//     partially write to a page.

// This implementation supports the page based devices.

const std = @import("std");
const flash = @import("flash.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

// For now, the sizes are all hard coded.
pub const page_size = @as(usize, flash.page_size);
pub const page_shift = std.math.log2_int(usize, page_size);

// The largest number of pages the image portion of the data can be.
pub const max_pages = flash.max_pages;

// The largest number of work steps for a given phase of work.  The
// latest amount of work is the swap, which has two operations per
// page of data.
const max_work = 2 * flash.max_pages;

// The number of hash bytes to use.  This value is a tradeoff.
// Collisions will require all of the data to be recomputed.  Only
// pages that will occupy the same location are of concern, which
// means adjacent pages in slot 0, and page-n and page-n+1 in slot 0
// compared with page-n in slot 1.  This means for a 32-bit hash (4
// bytes), we would expect a collision about every '2^32/(3*max_page)'
// erase operations.  This is better than 1 in a million, which means
// it is rare, but probably will happen at some point.
pub const hash_bytes = 4;

const Hash = [hash_bytes]u8;

// This is the state for a flash operation.  This contains all of the
// buffers for our data, along with the work and state of this work.
// On-target, there will be generally one of these, as multi-image
// updates will happen sequentially, and will use the same state.
pub const State = struct {
    const Self = @This();

    // A temporary buffer, used to read data.
    tmp: [page_size]u8 = undefined,
    tmp2: [page_size]u8 = undefined,

    // The sizes of the pertinent images.
    sizes: [2]usize,

    // The flash areas themselves.
    areas: [2]*flash.Area,

    // These are all of the hashes.
    hashes: [2][max_pages]Hash = undefined,

    // This is a prefix, used before each hash operation.  If we
    // perform the hashes and have a collision, we can start over with
    // a different prefix.
    prefix: [4]u8,

    // The work itself.  The first index is the phase, and the second
    // is the work itself.
    work: [2][max_work]Work = undefined,
    work_len: [2]usize = .{ 0, 0 },

    // Initialze this state.  The sim must outlive this struct.  The
    // prefix is used as a seed to the hash function.  If the
    // operations detect a hash collision, this can be restarted with
    // a different prefix, which will possibly remove the collision.
    pub fn init(sim: *flash.SimFlash, sizeA: usize, sizeB: usize, prefix: u32) !State {
        var a = try sim.open(0); // TODO: Better numbers.
        var b = try sim.open(1);
        var bprefix: [4]u8 = undefined;
        std.mem.copy(u8, bprefix[0..], std.mem.asBytes(&prefix));
        return State{
            .areas = [2]*flash.Area{ a, b },
            .sizes = [2]usize{ sizeA, sizeB },
            .prefix = bprefix,
        };
    }

    // On an initial run, compute the hashes.  The hash of the last
    // possibly partial page is only partially computed.
    pub fn computeHashes(self: *Self) !void {
        try self.oneHash(0);
        try self.oneHash(1);
    }

    fn oneHash(self: *Self, index: usize) !void {
        var pos: usize = 0;
        var page: usize = 0;
        while (pos < self.sizes[index]) : (pos += page_size) {
            var hh = Sha256.init(.{});
            hh.update(self.prefix[0..]);
            var count: usize = page_size;
            if (count > self.sizes[index] - pos)
                count = self.sizes[index] - pos;
            try self.areas[index].read(pos, self.tmp[0..count]);
            hh.update(self.tmp[0..count]);
            var hash: [32]u8 = undefined; // TODO: magic number
            hh.final(hash[0..]);
            std.mem.copy(u8, self.hashes[index][page][0..], hash[0..hash_bytes]);
            // std.log.info("hash: {} 0x{any}", .{ page, self.hashes[index][page] });

            page += 1;
        }
    }

    // Compute the work for sliding slot 0 down by one.
    pub fn workSlide0(self: *Self) !void {
        const bound = self.calcBound(0);

        // pos is the destination of each page.
        var pos: usize = bound.last;
        while (pos > 0) : (pos -= 1) {
            var size = page_size;
            if (pos == bound.last)
                size = bound.partial;

            if (pos < bound.last and try self.validateSame(.{ 0, 0 }, .{ pos - 1, pos }, size))
                continue;

            try self.workPush(0, .{
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
    // we want to move A1 to slot 0, and A0 to slot 1.  This continues
    // stopping either the left or right movement when we have
    // exceeded the size for that side.
    pub fn workSwap(self: *Self) !void {
        const bound0 = self.calcBound(0);
        const bound1 = self.calcBound(1);

        std.log.info("---- Phase 2 ----", .{});

        // At a given pos, we move slot 1,pos to slot 0,pos, and slot
        // 0,pos+1 to slot1,pos.
        var pos: usize = 0;
        while (pos < bound0.last or pos < bound1.last) : (pos += 1) {
            // Move slot 1 to 0.
            if (pos < bound1.last) {
                var size = page_size;
                if (pos == bound1.last)
                    size = bound1.partial;

                if (pos < bound0.last and try self.validateSame(.{ 1, 0 }, .{ pos, pos }, size))
                    continue;

                try self.workPush(1, .{
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
                var size = page_size;
                if (pos == bound0.last)
                    size = bound0.partial;

                if (pos < bound1.last and try self.validateSame(.{ 0, 1 }, .{ pos + 1, pos }, size))
                    continue;

                try self.workPush(1, .{
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

    // Perform the work.
    pub fn performWork(self: *Self) !void {
        std.log.info("---- Running work ----", .{});
        for (self.work) |work, i| {
            for (work[0..self.work_len[i]]) |*item| {
                // std.log.info("do: {any}", .{item});
                try self.areas[item.dest_slot].erase(item.dest_page << page_shift, page_size);
                try self.areas[item.src_slot].read(item.src_page << page_shift, self.tmp[0..]);
                try self.areas[item.dest_slot].write(item.dest_page << page_shift, self.tmp[0..]);
            }
        }
    }

    fn workPush(self: *Self, phase: usize, work: Work) !void {
        if (self.work_len[phase] >= self.work[phase].len)
            return error.WorkOverflow;

        // std.log.info("push work {}: {any}", .{ self.work_len[phase], work });
        self.work[phase][self.work_len[phase]] = work;
        self.work_len[phase] += 1;
    }

    const Bound = struct {
        // The last page to be moved in the given region.
        last: usize,
        // The number of bytes in the last page.  Will be page_size if
        // this image is a multiple of the page size.
        partial: usize,
    };
    fn calcBound(self: *const Self, slot: usize) Bound {
        const last = (self.sizes[slot] + page_size - 1) >> page_shift;
        var partial = self.sizes[slot] & (page_size - 1);
        if (partial == 0)
            partial = page_size;
        std.log.info("slot:{}, bytes:{}, last:{}, partial:{}", .{
            slot,
            self.sizes[slot],
            last,
            partial,
        });
        return Bound{
            .last = last,
            .partial = partial,
        };
    }

    // Ensure that two pages that have the same hash are actually the
    // same.  Returns error.HashCollision if the differ, which will
    // result in the top level code retrying with a different prefix.
    fn validateSame(self: *Self, slots: [2]u8, pages: [2]usize, len: usize) !bool {
        // std.log.info("Compare: {any} with {any} {any} {any}", .{
        //     slots,                           pages, self.hashes[slots[0]][pages[0]],
        //     self.hashes[slots[1]][pages[1]],
        // });
        if (std.mem.eql(
            u8,
            self.hashes[slots[0]][pages[0]][0..],
            self.hashes[slots[1]][pages[1]][0..],
        )) {
            // If the hashes match, compare the page contents.
            _ = len;
            unreachable;
        } else {
            return false;
        }
    }

    // Return an iterator over all of the hashes.
    pub fn iterHashes(self: *const Self) HashIter {
        return .{
            .state = self,
            .phase = 0,
            .pos = 0,
        };
    }
};

pub const HashIter = struct {
    const Self = @This();

    state: *const State,
    phase: usize,
    pos: usize,

    pub fn next(self: *Self) ?*const [hash_bytes]u8 {
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
        //std.log.info("returning: {any} (phase:{}, pos:{}, sizes:{any})", .{
        //    result.*,
        //    self.phase,
        //    self.pos,
        //    self.state.sizes[self.phase],
        //});
        self.pos += 1;
        return result;
    }
};

fn asPages(value: usize) usize {
    return (value + page_size - 1) >> page_shift;
}

// Calculate the has of a given block of data, returning the shortened
// version.
pub fn calcHash(data: []const u8) [hash_bytes]u8 {
    var hh = Sha256.init(.{});
    hh.update(data);
    var hash: [32]u8 = undefined;
    hh.final(hash[0..]);
    var result: [hash_bytes]u8 = undefined;
    std.mem.copy(u8, result[0..], hash[0..4]);
    return result;
}

// A single unit of work.
// Zig theoretically will reorder structures for better padding, but
// this doesn't appear to be happening, so this is ordered to make it
// compact.
// This describes the move of one page of data.  It describes an erase
// of the destination, and a copy of the data from the source into
// that dest.  The hash should match the data in the src slot.
// size will normally be page_size, except for the final page, where
// it may be smaller, as we don't has data past the extent of the real
// image.
const Work = struct {
    src_slot: u8,
    dest_slot: u8,
    size: u16,
    src_page: usize,
    dest_page: usize,

    hash: Hash,
};
