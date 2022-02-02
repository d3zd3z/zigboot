// Printable hexdump.
//
// Prints a hexdump in the style of 'hexdump -C'.
// 00000000  db f6 30 1c d7 87 b6 a8  27 bd 65 3d 0b d7 8f 4e  |..0.....'.e=...N|
// 00000010  c4 24 64 25 5a 97 fb b9  b6 86 07 a8 ce 75 09 53  |.$d%Z........u.S|
// 00000020  6c 7f db 2e ca 6d 08 cc  88 c0 aa f6 ef ec 60 45  |l....m........`E|
// 00000030  0a df f6 89                                       |....|
//
// Notably: the numbers are output on the left, and there is an
// ascii-ish chart of the readable data, with dots substituted for the
// data.

const std = @import("std");

// The buffer needed for the hex values.  This includes two spaces at the
// beginning, and the extra space in the middle.
const hex_size = 3 * 16 + 2;
const ascii_size = 16;
const HexBuf = std.BoundedArray(u8, hex_size);
const AsciiBuf = std.BoundedArray(u8, ascii_size);

// Convenience function to just print a bunch of stuff.
pub fn pdump(data: []const u8) !void {
    try (try HexPrinter.init()).dump(data);
}

pub const HexPrinter = struct {
    const Self = @This();

    count: usize,
    total_count: usize,
    hex: HexBuf,
    ascii: AsciiBuf,

    fn init() !HexPrinter {
        return Self{
            .count = 0,
            .total_count = 0,
            .hex = try HexBuf.init(0),
            .ascii = try AsciiBuf.init(0),
        };
    }

    pub fn dump(self: *Self, data: []const u8) !void {
        for (data) |ch| {
            try self.addByte(ch);
        }
        try self.ship();
    }

    fn addByte(self: *Self, ch: u8) !void {
        if (self.count == 16) {
            try self.ship();
        }
        if (self.count == 8) {
            try self.hex.append(' ');
        }
        var buf: [3]u8 = undefined;
        const hex = try std.fmt.bufPrint(&buf, " {x:0>2}", .{ch});
        try self.hex.appendSlice(hex);

        const printable = if (' ' <= ch and ch <= '~') ch else '.';
        try self.ascii.append(printable);
        self.count += 1;
    }

    fn ship(self: *Self) !void {
        if (self.count == 0)
            return;

        // TODO: Generalize the printer.
        std.log.info("{x:0>6} {s:<49}  |{s}|", .{ self.total_count, self.hex.slice(), self.ascii.slice() });

        self.hex.len = 0;
        self.ascii.len = 0;
        self.total_count += 16;
        self.count = 0;
    }
};

pub fn main() !void {
    var buf: [57]u8 = undefined;
    for (buf) |*ch, i| {
        ch.* = @truncate(u8, i);
    }
    var hp = try HexPrinter.init();
    try hp.dump(&buf);
    try hp.dump(&buf);
    try pdump(&buf);
}
