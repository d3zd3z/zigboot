// SPDX-License-Identifier: Apache-2.0
//
// Flash API

// This API uses the native flash API on target, and the simulator off
// target.

const builtin = @import("builtin");

usingnamespace switch (builtin.os.tag) {
    .freestanding => @import("flash/native.zig"),
    .linux => @import("flash/sim.zig"),
    else => @compileError("Unsupported platform"),
};

test {
    _ = @import("flash/native.zig");
    _ = @import("flash/sim.zig");
}
