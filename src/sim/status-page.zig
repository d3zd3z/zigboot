// SPDX-License-Identifier: Apache-2.0
// Page-based status.

const Self = @This();

const std = @import("std");
const sys = @import("../../src/sys.zig");
const swap_hash = @import("swap-hash.zig");

const page_size = swap_hash.page_size;
const page_shift = swap_hash.page_shift;
const Area = sys.flash.Area;

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

const Phase = enum(u8) {
    Sliding,
    Swapping,
    Done,
};

// Write a magic page to the given area.  This is done in slot 1 to
// indicate that a swap should be initiated.
pub fn writeMagic(fa: *Area) !void {
    const ult = (fa.size >> page_shift) - 1;
    const penult = ult - 1;

    // TODO: Needs to be target static.
    var buf: LastPage = undefined;
    std.mem.set(u8, std.mem.asBytes(&buf), 0xFF);
    buf.magic = page_magic;

    // Erase both pages.
    try fa.erase(ult << page_shift, page_size);
    try fa.erase(penult << page_shift, page_size);

    try fa.write(ult << page_shift, std.mem.asBytes(&buf));
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
    last.phase = .Sliding;
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

fn asPages(value: usize) usize {
    return (value + page_size - 1) >> page_shift;
}

test {
    std.testing.refAllDecls(Self);
}
