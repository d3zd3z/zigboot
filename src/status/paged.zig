// SPDX-License-Identifier: Apache-2.0
// Page-based status.

const Self = @This();

// The status area we are currently using.
area: *sys.flash.FlashArea = undefined,

// We have a buffer for the last page and one for the other pages.
buf_last: LastPage = undefined,
buf_hash: HashPage = undefined,

const std = @import("std");
const testing = std.testing;
const sys = @import("../../src/sys.zig");
const BootTest = @import("../test.zig").BootTest;

// TODO: This should be configured, not pulled from the swap code.
const swap_hash = @import("../sim/swap-hash.zig");

const page_size = swap_hash.page_size;
const page_shift = swap_hash.page_shift;
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

    if (ultStatus or penultStatus) {
        return .Request;
    }

    return .Unknown;

    // if self.area.read(ult << page_shift, std.mem.asBytes(&buf_last));
    // if self.area.read(penult << page_shift, std.mem.asBytes(&buf_last));
}

// Try reading the page, and return true if the page has a valid magic
// number in it.
fn validMagic(self: *Self, page: usize) !bool {
    if ((try self.area.getState(page << page_shift)) == .Written) {
        try self.area.read(page << page_shift, std.mem.asBytes(&self.buf_last));

        return self.buf_last.magic.eql(&page_magic);
    }

    return false;
}

test "Status scanning" {
    var bt = try BootTest.init(testing.allocator, BootTest.lpc55s69);
    defer bt.deinit();

    var state = try Self.init(try bt.sim.open(1));

    // Before initialization, status should come back
    var status = try state.scan();
    try std.testing.expectEqual(Phase.Unknown, status);

    // Write the magic, and make sure the status changes to Request.
    try state.writeMagic();
    status = try state.scan();
    try std.testing.expectEqual(Phase.Request, status);
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
pub fn startStatus(st: *swap_hash.State) !void {
    // Compute how many extra pages are needed.
    var extras: usize = 0;
    const total_hashes = asPages(st.sizes[0]) + asPages(st.sizes[1]);

    var last: LastPage = undefined;
    std.mem.set(u8, std.mem.asBytes(&last), 0xFF);

    var hp: HashPage = undefined;

    if (total_hashes > last.hashes.len) {
        var remaining = total_hashes - last.hashes.len;
        while (remaining > 0) {
            extras += 1;
            var count = hp.hashes.len;
            if (count > remaining)
                count = remaining;
            remaining -= count;
        }
    }

    last.sizes[0] = @intCast(u32, st.sizes[0]);
    last.sizes[1] = @intCast(u32, st.sizes[1]);
    std.mem.copy(u8, last.prefix[0..], st.prefix[0..]);
    last.phase = .Slide;
    last.swap_info = 0;
    last.copy_done = 0;
    last.image_ok = 0;

    var srcIter = st.iterHashes();
    var dst: usize = 0;
    while (dst < last.hashes.len) : (dst += 1) {
        if (srcIter.next()) |src| {
            std.mem.copy(u8, last.hashes[dst][0..], src[0..]);
        } else {
            break;
        }
    }

    // TODO: Write out the other pages.

    const fa = st.areas[1];
    const ult = (fa.size >> page_shift) - 1;
    const penult = ult - 1;

    // Update the hash.
    const lasthash = swap_hash.calcHash(std.mem.asBytes(&last)[0 .. 512 - 20]);
    std.mem.copy(u8, last.hash[0..], lasthash[0..]);
    last.magic = page_magic;

    try fa.erase(ult << page_shift, page_size);
    try fa.erase(penult << page_shift, page_size);
    try fa.write(ult << page_shift, std.mem.asBytes(&last));

    std.log.info("Writing initial status: {} hash pages", .{total_hashes});
    std.log.info("2 pages at end + {} extra pages", .{extras});
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
    hashes: [(512 - 72) / 4][swap_hash.hash_bytes]u8,

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
    hashes: [(512 - 4) / 4][swap_hash.hash_bytes]u8,

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
