// SPDX-License-Identifier: Apache-2.0
// TLV processing.

const std = @import("std");
const assert = std.debug.assert;

const zephyr = @import("zephyr.zig");
const FlashArea = zephyr.flash.FlashArea;
const image = @import("image.zig");
const Image = image.Image;

pub fn showTlv(img: *Image) !void {
    const tlv_base = img.header.tlvBase();

    var tlv_header: TlvHeader = undefined;
    var bytes = std.mem.asBytes(&tlv_header);
    try img.fa.read(tlv_base, bytes);

    switch (tlv_header.magic) {
        TLV_INFO_MAGIC => {
            zephyr.println("Tlv magic: {} bytes", .{tlv_header.tlv_tot});
        },
        TLV_PROT_INFO_MAGIC => {
            zephyr.println("Tlv prot magic: {} bytes", .{tlv_header.tlv_tot});
        },
        else => return error.InvalidTlv,
    }

    var offset: u32 = @sizeOf(TlvHeader);
    while (offset < tlv_header.tlv_tot) {
        var entry: TlvEntry = undefined;
        var entryBytes = std.mem.asBytes(&entry);
        try img.fa.read(tlv_base + offset, entryBytes);

        zephyr.println("Tlv@{d}: t:{x:0>2}, len:{x:0>2}", .{ offset, entry.tag, entry.len });

        // Note that there is overflow checking here.
        offset += @sizeOf(TlvEntry) + entry.len;
        if (offset > tlv_header.tlv_tot) {
            return error.CorruptTlv;
        }
    }
}

const TLV_INFO_MAGIC = 0x6907;
const TLV_PROT_INFO_MAGIC = 0x6908;

const TlvHeader = extern struct {
    magic: u16,
    tlv_tot: u16,
};
comptime {
    assert(@sizeOf(TlvHeader) == 4);
}

// This header can be misaligned.  Arm allows these loads, but this
// may be an issue on other targets.
const TlvEntry = extern struct {
    tag: u16,
    len: u16,
};
comptime {
    assert(@sizeOf(TlvEntry) == 4);
}
