// SPDX-License-Identifier: Apache-2.0
//
// Native (Zephyr) flash support.

const std = @import("std");
const errno = @import("../zephyr/errno.zig");

const raw = struct {
    extern fn flash_area_open(id: u8, fa: **const FlashArea) c_int;
    extern fn flash_area_close(fa: *const FlashArea) void;
    extern fn flash_area_read(fa: *const FlashArea, off: usize, dst: [*]u8, len: usize) c_int;
    extern fn flash_area_erase(fa: *const FlashArea, off: usize, len: usize) c_int;
    extern fn flash_area_write(fa: *const FlashArea, off: usize, dst: [*]const u8, len: usize) c_int;
};

// Must match `struct flash_area` within Zephyr.
pub const FlashArea = extern struct {
    id: u8,
    device_id: u8,
    pad: u16,
    off: usize,
    size: usize,
    dev_name: [*:0]const u8,

    pub fn open(id: u8) !*const FlashArea {
        var result: *const FlashArea = undefined;
        const res = raw.flash_area_open(id, &result);
        return errno.mapError(res, result);
    }

    pub fn close(self: *const FlashArea) void {
        raw.flash_area_close(self);
    }

    pub fn read(self: *const FlashArea, off: usize, buf: []u8) !void {
        const result = raw.flash_area_read(self, off, buf.ptr, buf.len);
        return errno.mapError(result, {});
    }

    pub fn erase(self: *const FlashArea, off: usize, len: usize) !void {
        const result = raw.flash_area_erase(self, off, len);
        return errno.mapError(result, {});
    }

    pub fn write(self: *const FlashArea, off: usize, buf: []const u8) !void {
        const result = raw.flash_area_write(self, off, buf.ptr, buf.len);
        return errno.mapError(result, {});
    }
};
