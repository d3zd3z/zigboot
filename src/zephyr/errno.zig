// SPDX-License-Identifier: Apache-2.0
// Error mapping from Zephyr world.
// Zephyr uses negative errno return codes.  We map these to Zig
// errors.

const std = @import("std");

pub fn mapError(code: c_int, result: anytype) !@TypeOf(result) {
    switch (code) {
        0 => return result,
        -2 => return error.ENOENT,
        else => {
            std.log.err("Unknown errno: {}", .{code});
            return error.UnknownErrno;
        },
    }
}
