// SPDX-License-Identifier: Apache-2.0
//
// Testing framework for Zigboot.

// Testing based around an emulated flash device.  This test framework
// has its own state, and runs the test on various types of supported
// flash devices.  It has support for creating images and verifying
// that specific things have happened within the device.
//
// This testing happens off target, so we're going to freely use
// allocators.

const std = @import("std");
const mem = std.mem;
const sys = @import("sys.zig");
const SimFlash = sys.flash.SimFlash;

pub const BootTest = struct {
    const Self = @This();

    allocator: mem.Allocator,
    sim: SimFlash,

    pub fn init(allocator: mem.Allocator, layout: Layout) !Self {
        return Self{
            .allocator = allocator,
            .sim = try SimFlash.init(allocator, layout.sector_size, layout.sectors),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sim.deinit();
    }

    pub const Layout = struct {
        sector_size: usize = 512,
        sectors: usize = 128,
    };

    pub const lpc55s69 = Layout{
        .sector_size = 512,
        .sectors = 128,
    };
};
