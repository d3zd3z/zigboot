// SPDX-License-Identifier: Apache-2.0
// Error mapping from Zephyr world.
// Zephyr uses negative errno return codes.  We map these to Zig
// errors.

pub fn mapError(code: c_int, result: anytype) !@TypeOf(result) {
    switch (code) {
        0 => return result,
        else => return error.UnknownErrno,
    }
}
