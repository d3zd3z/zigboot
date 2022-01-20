// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const sys = @import("sys.zig");
const status = @import("status.zig");
const SimFlash = sys.flash.SimFlash;
const Swap = @import("swap.zig").Swap;

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

    var sstate = try Swap.init(&sim, .{ sizeA, sizeB }, 1);
    var fa = try sim.open(0);
    var stat = try status.init(fa);

    _ = sstate;
    _ = stat;

    //try sstate.computeHashes();
    //try sstate.workSlide0();
    //try sstate.workSwap();
    //try stat.startStatus(&sstate);
    //try sstate.performWork();

    //try sim.verifyImages(.{ sizeB, sizeA });

    //try status.writeMagic(&stat);
    //try fa.save("flash-0.bin");

    //var fb = try sim.open(1);
    //try fb.save("flash-1.bin");
}

test {
    _ = @import("sys.zig");
    _ = @import("flash.zig");
    _ = @import("status.zig");
    _ = @import("swap.zig");
}
