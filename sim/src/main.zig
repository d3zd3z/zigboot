const std = @import("std");
const builtin = @import("builtin");

const status = @import("status-page.zig");
const SimFlash = @import("flash.zig").SimFlash;
const SwapState = @import("swap-hash.zig").State;

// This is 'main' for the off-target testing.
// When running on .freestanding, we assume that we are on the Zephyr
// platform.
const Platform = switch (builtin.os.tag) {
    .freestanding => struct {
        export fn main() void {
            std.log.info("Linux main", .{});
        }
    },
    .linux => struct {
        pub fn main() !void {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            var alloc = gpa.allocator();
            std.log.info("Linux main", .{});

            var sim = try SimFlash.init(alloc, 512, 1024);
            defer sim.deinit();

            const sizeA = 512 * 1000 + 17;
            const sizeB = 512 * 907 + 104;
            // const sizeA = 512 * 4 + 17;
            // const sizeB = 512 * 5 + 104;
            try sim.installImages(.{ sizeA, sizeB });

            var sstate = try SwapState.init(&sim, sizeA, sizeB, 1);
            try sstate.computeHashes();
            try sstate.workSlide0();
            try sstate.workSwap();
            try status.startStatus(&sstate);
            try sstate.performWork();

            try sim.verifyImages(.{ sizeB, sizeA });

            var fa = try sim.open(0);
            try status.writeMagic(fa);
            try fa.save("flash-0.bin");

            var fb = try sim.open(1);
            try fb.save("flash-1.bin");
        }
    },
    else => @compileError("Unsupported platform"),
};

pub const main = Platform.main;

test {
    _ = @import("flash.zig");
    _ = @import("status-page.zig");
}
