// SPDX-License-Identifier: Apache-2.0
// Page-based status.

const Self = @This();

// The status area we are currently using.
area: *sys.flash.FlashArea = undefined,

// We have a buffer for the last page and one for the other pages.
buf_last: LastPage = undefined,
buf_hash: HashPage = undefined,

last_seq: u32 = 0,

const std = @import("std");
const testing = std.testing;
const sys = @import("../../src/sys.zig");
const BootTest = @import("../test.zig").BootTest;

// TODO: This should be configured, not pulled from the swap code.
// const swap_hash = @import("../sim/swap-hash.zig");
const Swap = @import("../swap.zig").Swap;

const page_size = Swap.page_size;
const page_shift = Swap.page_shift;
const FlashArea = sys.flash.FlashArea;

/// The phase of the flash upgrade.
pub const Phase = enum(u8) {
    /// This doesn't appear to be in any identifiable state.  This
    /// could mean the magic number is not present, or hashes are
    /// incorrect.
    Unknown,

    /// An upgrade has been requested.  This is not directly written to
    /// the status page, but is indicated when the magic value has been
    /// written with no other data.
    Request,

    /// Sliding has started or is about to start.  This is the move of
    /// slot 0 down a single page.
    Slide,

    /// Swapping has started or is about to start.  This is the
    /// exchange of the swapped image to the new one.
    Swap,

    /// Indicates that we have completed everything, the images are
    /// swapped.
    Done,
};

pub fn init(fa: *sys.flash.FlashArea) !Self {
    return Self{
        .area = fa,
    };
}

/// Scan the contents of flash to determine what state we are in.
pub fn scan(self: *Self) !Phase {
    const ult = (self.area.size >> page_shift) - 1;
    const penult = ult - 1;

    // Zephyr's flash API will allow reads from unwritten data, even
    // on devices with ECC, and it just fakes the data being erased.
    // We want to use readStatus here first, because we want to make
    // it clear to the simulator that we are able to handle unwritten
    // data.  This only happens on the two status pages, so this
    // shouldn't be a performance issue.
    const ultStatus = try self.validMagic(ult);
    const penultStatus = try self.validMagic(penult);
    std.log.info("ult: {}, penult: {}", .{ ultStatus, penultStatus });

    // If neither area is readable, then we know we don't have any
    // data.
    if (!ultStatus and !penultStatus) {
        return .Unknown;
    }

    // Try reading the ultimate buffer (last page).
    var ultSeq: ?u32 = null;
    var penultSeq: ?u32 = null;
    if (ultStatus) {
        ultSeq = try self.validLast(ult);
    }
    if (penultStatus) {
        penultSeq = try self.validLast(penult);
    }

    // There are 4 combinations of the sequences being valid.
    var valid = false;
    if (ultSeq) |useq| {
        if (penultSeq) |puseq| {
            // Both are valid.  We should go with the earlier one.
            // The last read was of the penult one, so if the latest
            // one is newer, go back and reread the ultimate one.
            if (useq < puseq) {
                if ((try self.validLast(ult)) == null) {
                    // This should probably be checked, and just
                    // abort, it would indicate we couldn't read this
                    // data a second time.
                    unreachable;
                }
            }

            // The buf_last is now the current version of the last
            // data.
            valid = true;
        } else {
            // The ultimate one is valid, but we overwrote the buffer
            // when we read the penult.
            if (penultStatus) {
                if ((try self.validLast(ult)) == null) {
                    unreachable;
                }
            }
            valid = true;
        }
    } else {
        if (penultSeq) |_| {
            // The penultimate buffer is the only valid one, so just
            // use it.
            valid = true;
        } else {
            // Nothing is valid.
        }
    }

    if (valid) {
        return self.buf_last.phase;
    }

    // Otherwise, we have magic, but no valid state.
    return .Request;

    // if self.area.read(ult << page_shift, std.mem.asBytes(&buf_last));
    // if self.area.read(penult << page_shift, std.mem.asBytes(&buf_last));
}

// Try reading the page, and return true if the page has a valid magic
// number in it.
fn validMagic(self: *Self, page: usize) !bool {
    if ((try self.area.getState(page << page_shift)) == .Written) {
        // TODO: Only really need to try reading the magic.
        // This read can fail, either if the device has ECC, or we are
        // in the simulator.
        if (self.area.read(page << page_shift, std.mem.asBytes(&self.buf_last))) |_| {
            return self.buf_last.magic.eql(&page_magic);
        } else |err| {
            if (err != error.ReadUnwritten)
                return err;
            return false;
        }
    }

    return false;
}

// Try reading the given page into the last buffer, and return its
// sequence number if the hash indicates it is valid.
fn validLast(self: *Self, page: usize) !?u32 {
    try self.area.read(page << page_shift, std.mem.asBytes(&self.buf_last));

    const hash = Swap.calcHash(std.mem.asBytes(&self.buf_last)[0 .. 512 - 20]);
    std.log.info("validLast (page {}): {s} and {s}", .{
        page,
        std.fmt.fmtSliceHexLower(hash[0..]),
        std.fmt.fmtSliceHexLower(self.buf_last.hash[0..]),
    });
    if (std.mem.eql(u8, self.buf_last.hash[0..], hash[0..])) {
        std.log.info("valid last: {}", .{self.buf_last.seq});
        return self.buf_last.seq;
    } else {
        std.log.info("invalid last", .{});
        return null;
    }
}

test "Status scanning" {
    var bt = try BootTest.init(testing.allocator, BootTest.lpc55s69);
    defer bt.deinit();

    const sizes = [2]usize{ 112 * page_size + 7, 105 * page_size + page_size - 1 };
    // const sizes = [2]usize{ 17 * page_size + 7, 14 * page_size + page_size - 1 };

    var state = try Self.init(try bt.sim.open(1));

    // Before initialization, status should come back
    var status = try state.scan();
    try std.testing.expectEqual(Phase.Unknown, status);

    // Write the magic, and make sure the status changes to Request.
    try state.writeMagic();
    status = try state.scan();
    try std.testing.expectEqual(Phase.Request, status);

    // Do a status write.  This should go into slot 0.
    var swap: Swap = undefined;
    try swap.fakeHashes(sizes);

    // Write this out.
    // We need to fill in enough to make this work.
    swap.areas[0] = try bt.sim.open(0);
    swap.areas[1] = try bt.sim.open(1);
    try state.startStatus(&swap);

    try swap.areas[0].save("status-scan0.bin");
    try swap.areas[1].save("status-scan1.bin");

    // Blow away the memory structure.
    std.mem.set(u8, std.mem.asBytes(&swap), 0xAA);
    swap.areas[0] = try bt.sim.open(0);
    swap.areas[1] = try bt.sim.open(1);

    const ph = try state.scan();
    try std.testing.expectEqual(Phase.Slide, ph);
    try state.loadStatus(&swap);

    try swap.checkFakeHashes(sizes);
}

// Write a magic page to the given area.  This is done in slot 1 to
// indicate that a swap should be initiated.
pub fn writeMagic(self: *Self) !void {
    const ult = (self.area.size >> page_shift) - 1;
    const penult = ult - 1;

    std.mem.set(u8, std.mem.asBytes(&self.buf_last), 0xFF);
    self.buf_last.magic = page_magic;

    // Erase both pages.
    try self.area.erase(ult << page_shift, page_size);
    try self.area.erase(penult << page_shift, page_size);

    try self.area.write(ult << page_shift, std.mem.asBytes(&self.buf_last));
}

// Write out the initial status page(s) indicating we are starting
// work.
pub fn startStatus(self: *Self, st: *Swap) !void {
    // Compute how many extra pages are needed.
    var extras: usize = 0;
    const total_hashes = asPages(st.sizes[0]) + asPages(st.sizes[1]);

    // TODO: Use buf_last
    var last: LastPage = undefined;
    std.mem.set(u8, std.mem.asBytes(&last), 0xFF);

    const ult = (self.area.size >> page_shift) - 1;
    const penult = ult - 1;

    if (total_hashes > last.hashes.len) {
        var remaining = total_hashes - last.hashes.len;
        while (remaining > 0) {
            extras += 1;
            var count = self.buf_hash.hashes.len;
            if (count > remaining)
                count = remaining;
            remaining -= count;
        }
    }

    // The ordering/layout of the hash pages is a little "weird" but
    // designed to be simplier to write and read.  The hashes are
    // written starting with the first hash page, then decrementing
    // through memory, with the final remaining pieces in the 'last'
    // page.
    //
    // The hash pages need to be written first, because the recover
    // code assumes that if the lastpage is readable, the hashes have
    // already been written.
    var srcIter = st.iterHashes();
    var dst: usize = 0;
    const old_extras = extras;
    var hash_page = penult - 1;
    while (extras > 0) : (extras -= 1) {
        std.mem.set(u8, std.mem.asBytes(&self.buf_hash), 0);

        dst = 0;
        while (dst < self.buf_hash.hashes.len) : (dst += 1) {
            if (srcIter.next()) |src| {
                self.buf_hash.hashes[dst] = src.*;

                // const srcv = std.mem.bytesToValue(u32, src[0..]);
                // std.log.warn("Write {x:0>8} to page:{} at {}", .{ srcv, hash_page, dst });
            } else {
                // Math above was incorrect.
                unreachable;
            }
        }

        // Update the hash.
        const thehash = Swap.calcHash(std.mem.asBytes(&self.buf_hash)[0 .. 512 - 4]);
        std.mem.copy(u8, self.buf_hash.hash[0..], thehash[0..]);

        try self.area.erase(hash_page << page_shift, page_size);
        try self.area.write(hash_page << page_shift, std.mem.asBytes(&self.buf_hash));

        hash_page -= 1;
    }
    extras = old_extras;

    last.sizes[0] = @intCast(u32, st.sizes[0]);
    last.sizes[1] = @intCast(u32, st.sizes[1]);
    std.mem.copy(u8, last.prefix[0..], st.prefix[0..]);
    last.phase = .Slide;
    last.swap_info = 0;
    last.copy_done = 0;
    last.image_ok = 0;
    last.seq = 1;

    dst = 0;
    while (dst < last.hashes.len) : (dst += 1) {
        if (srcIter.next()) |src| {
            std.mem.copy(u8, last.hashes[dst][0..], src[0..]);
        } else {
            break;
        }
    }

    // TODO: Write out the other pages.

    // Update the hash.
    const lasthash = Swap.calcHash(std.mem.asBytes(&last)[0 .. 512 - 20]);
    std.mem.copy(u8, last.hash[0..], lasthash[0..]);
    last.magic = page_magic;

    try self.area.erase(ult << page_shift, page_size);
    try self.area.erase(penult << page_shift, page_size);
    try self.area.write(ult << page_shift, std.mem.asBytes(&last));

    std.log.info("Writing initial status: {} hash pages", .{total_hashes});
    std.log.info("2 pages at end + {} extra pages", .{extras});
}

// Assuming that the buf_last has been loaded with the correct image
// of the last page, update the swap_status structure with the sizes
// and hash information from the in-progress operation.
pub fn loadStatus(self: *Self, st: *Swap) !void {
    st.sizes[0] = @as(usize, self.buf_last.sizes[0]);
    st.sizes[1] = @as(usize, self.buf_last.sizes[1]);
    st.prefix = self.buf_last.prefix;

    // TODO: Consolidate this from the startStatus function.
    var extras: usize = 0;
    const total_hashes = asPages(st.sizes[0]) + asPages(st.sizes[1]);

    if (total_hashes > self.buf_last.hashes.len) {
        var remaining = total_hashes - self.buf_last.hashes.len;
        while (remaining > 0) {
            extras += 1;
            var count = self.buf_hash.hashes.len;
            if (count > remaining)
                count = remaining;
            remaining -= count;
        }
    }

    // Load the extras pages to get our hashes.
    var src: usize = 0;
    var dstIter = st.iterHashes();

    var hash_page = (self.area.size >> page_shift) - 3;

    // Replicate the behavior from the load.  Hash failures here are
    // not easily recoverable.
    while (extras > 0) : (extras -= 1) {
        try self.area.read(hash_page << page_shift, std.mem.asBytes(&self.buf_hash));

        // Verify the hash.
        const thehash = Swap.calcHash(std.mem.asBytes(&self.buf_hash)[0 .. 512 - 4]);
        if (!std.mem.eql(u8, self.buf_hash.hash[0..], thehash[0..])) {
            std.log.err("Hash failure on hash page", .{});
            @panic("Unrecoverable error");
        }

        // Copy the pages out.
        src = 0;
        while (src < self.buf_hash.hashes.len) : (src += 1) {
            if (dstIter.next()) |dst| {
                std.mem.copy(u8, dst[0..], self.buf_hash.hashes[src][0..]);

                // const dstv = std.mem.bytesToValue(u32, dst[0..]);
                // std.log.warn("Read {x:0>8} from page:{} at {}", .{ dstv, hash_page, src });
            } else {
                // Calculations above were incorrect.
                unreachable;
            }
        }
    }

    // Extract the hashes.
    src = 0;
    while (src < self.buf_last.hashes.len) : (src += 1) {
        if (dstIter.next()) |dst| {
            std.mem.copy(u8, dst[0..], self.buf_last.hashes[src][0..]);
        } else {
            break;
        }
    }
}

// Flash layout.
//
// The status area is written in the last few pages of the flash
// device.  To preserve compatibility with the previous flash code, we
// will place the magic value in the last 16 bytes (although we will
// use a different magic value).
// The last page is written, possibly duplicated, in the last two
// pages of the device.  We can toggle between these for updates,
// which is done the following way:
// - Update any data.
// - Generate a new sequence number.
// - Write to the unused page.
// - Erase the other page.
//
// Upon startup, we scan both pages.  If there is only a magic number
// present, we take this to indicate we should start an update.
// Otherwise, the page will contain an internal consistency check.  If
// we see two pages present, we use the one with the *lower* sequence
// number, as we don't know if the other page was written fully.
//
// The last two pages are in this format.  Note that since this mode
// always writes fully, there are no alignment concerns within this
// data, beyond normal CPU alignment issues.
const LastPage = extern struct {
    // The first block of hashes
    hashes: [(512 - 72) / 4][Swap.hash_bytes]u8,

    // The sizes of the two regions (in bytes) used for swap.
    sizes: [2]u32,

    // Encryption keys used when encrypting.
    keys: [2][16]u8,

    // The prefix used for the hashes.
    prefix: [4]u8,

    // The sequence number of this page.
    seq: u32,

    // Status of the operation.
    phase: Phase,
    swap_info: u8,
    copy_done: u8,
    image_ok: u8,

    // The first 4 bytes of the SHA1 hash of the data up until this
    // point.
    hash: [4]u8,

    // The page ends with a magic value.
    magic: Magic,
};

// Pages before these two are used to hold any additional hashes.
const HashPage = extern struct {
    // As many hashes as we need.
    hashes: [(512 - 4) / 4][Swap.hash_bytes]u8,

    // The first 4 bytes of the SHA1 hash of the hashes array before
    // this.
    hash: [4]u8,
};

// The magic value is determined by a configuration value of
// BOOT_MAX_ALIGN.

const Magic = extern union {
    val: [16]u8,
    modern: extern struct {
        alignment: u16,
        magic: [14]u8,
    },

    fn eql(self: *const Magic, other: *const Magic) bool {
        return std.mem.eql(u8, self.val[0..], other.val[0..]);
    }
};

// The page based status always uses different magic values.
const page_magic = Magic{
    .modern = .{
        .alignment = 512,
        .magic = .{ 0x3e, 0x04, 0xec, 0x53, 0xa0, 0x40, 0x45, 0x39, 0x4a, 0x6e, 0x00, 0xd5, 0xa2, 0xb3 },
    },
};

comptime {
    std.debug.assert(@sizeOf(LastPage) == 512);
    std.debug.assert(@sizeOf(HashPage) == 512);
}

fn asPages(value: usize) usize {
    return (value + page_size - 1) >> page_shift;
}

test {
    std.testing.refAllDecls(Self);
}
