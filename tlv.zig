// SPDX-License-Identifier: Apache-2.0
// TLV processing.

const std = @import("std");
const assert = std.debug.assert;

const zephyr = @import("zephyr.zig");
const FlashArea = zephyr.flash.FlashArea;
const image = @import("image.zig");
const Image = image.Image;

pub const TlvTag = enum(u16) {
    KeyHash = 0x01,
    PubKey = 0x02,
    Sha256 = 0x10,
    RSA2048_PSS = 0x20,
    ECDSA224 = 0x21,
    ECDSA256 = 0x22,
    RSA3072_PSS = 0x23,
    ED25519 = 0x24,
    Enc_RSA2048 = 0x30,
    Enc_KW = 0x31,
    Enc_EC256 = 0x32,
    Enc_X25519 = 0x33,
    Dependency = 0x40,
    Sec_Cnt = 0x50,
    Boot_Record = 0x60,
    Other = 0xffff,
};

pub fn showTlv(img: *Image) !void {
    var it = try TlvIter.init(img);
    while (try it.next()) |item| {
        zephyr.println("Tlv@{d}: t:{x:0>2}, len:{x:0>2}", .{ item.offset, item.tag, item.len });
    }
}

// Walk through the TLV, ensuring that all of the entries are valid.
// TODO: Ensure that the entries that should be protected are.
pub fn validateTlv(img: *Image) !void {
    var it = try TlvIter.init(img);
    while (try it.next()) |_| {}
}

pub const TlvIter = struct {
    const Self = @This();

    header: TlvHeader,
    base: u32,
    img: *Image,
    offset: u32,

    pub fn init(img: *Image) !TlvIter {
        const base = img.header.tlvBase();
        const header = try img.readStruct(TlvHeader, base);

        switch (header.magic) {
            TLV_INFO_MAGIC => {
                zephyr.println("Tlv magic: {} bytes", .{header.tlv_tot});
            },
            TLV_PROT_INFO_MAGIC => {
                // Not yet implemented.
                unreachable;
            },
            else => return error.InvalidTlv,
        }

        return TlvIter{
            .header = header,
            .base = base,
            .img = img,
            .offset = @sizeOf(TlvHeader),
        };
    }

    pub fn next(self: *Self) !?TlvItem {
        if (self.offset == self.header.tlv_tot) {
            return null;
        } else {
            const old_offset = self.offset;
            if (self.offset + @sizeOf(TlvEntry) > self.header.tlv_tot)
                return error.CorruptTlv;
            const entry = try self.img.readStruct(TlvEntry, self.base + self.offset);
            self.offset += @sizeOf(TlvEntry) + entry.len;
            if (self.offset > self.header.tlv_tot)
                return error.CorruptTlv;
            return TlvItem{
                .tag = entry.tag,
                .len = entry.len,
                .offset = old_offset,
            };
        }
    }

    pub fn readItem(self: *const Self, comptime T: type, item: *const TlvItem) !T {
        return self.img.readStruct(T, self.base + item.offset + @sizeOf(TlvEntry));
    }
};

pub const TlvItem = struct {
    tag: u16,
    len: u16,
    offset: u32,
};

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
