// Status management.
//
// The update status is stored in different ways, depending on the
// whether the flash device has "small" or "medium" writes (1-16
// bytes, typically), or "large" writes, typically 512 bytes.  The
// large write devices generally have similarly sized erases.

const config = @import("config.zig");

pub const Self = switch (config.status) {
    .Paged => @import("status/paged.zig"),
    .InPlace => @import("status/inplace.zig"),
};
usingnamespace Self;

// Various tests of the status-based power recovery.
const testPower = struct {
    const std = @import("std");
    const testing = std.testing;
    const BootTest = @import("test.zig").BootTest;

    const Swap = @import("swap.zig").Swap;

    const page_size = Swap.page_size;

    const sizes = [2]usize{ 112 * page_size + 7, 105 * page_size + page_size - 1 };

    test "Status power recovery" {
        var bt = try BootTest.init(testing.allocator, BootTest.lpc55s69);
        defer bt.deinit();

        var state = try Self.init(try bt.sim.open(1));

        var swap: Swap = undefined;
        try swap.fakeHashes(sizes);

        // Write this out.
        swap.areas[0] = try bt.sim.open(0);
        swap.areas[1] = try bt.sim.open(1);
        try state.startStatus(&swap);

        std.log.warn("Counter: {}", .{bt.sim.counter});
    }
};

test {
    _ = @import("status/paged.zig");
    _ = @import("status/inplace.zig");
    _ = testPower;
}
