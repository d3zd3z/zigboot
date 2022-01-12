const std = @import("std");
const builtin = @import("builtin");

const SimFlash = @import("flash.zig").SimFlash;

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

            var fa = try sim.open(0);
            // Just a pointer, area is owned by the 'sim'.
            _ = fa;
        }
    },
    else => @compileError("Unsupported platform"),
};

pub const main = Platform.main;

test {
    _ = @import("flash.zig");
}
