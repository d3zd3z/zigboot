// SPDX-License-Identifier: Apache-2.0
// Flash API unified between simulator and on-target.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// TODO: These shouldn't be hard coded.
pub const page_size = 512;
pub const max_pages = 1024;

// A simulated flash device.  We only simulate parts of flash that
// have consisten sized sectors.  The simulated flash is significantly
// more restrictive than regular flash, including the following:
// - write alignment is strictly enforced
// - cannot read across sector boundaries
// - interrupted operations fail on read
// - interrupted operations return worst-case status on "check" (in
//   other words, the interrupted operation looks like it completed,
//   but will fail the test later.
pub const SimFlash = struct {
    const Self = @This();

    allocator: mem.Allocator,
    areas: []FlashArea,

    counter: *Counter,

    /// Construct a new flash simulator.  There will be two areas
    /// created, the first will be one sector larger than the other.
    /// TODO: Add support for 4 regions with upgrades.
    pub fn init(allocator: mem.Allocator, sector_size: usize, sectors: usize) !SimFlash {
        var counter = try allocator.create(Counter);
        counter.* = Counter.init(null);
        errdefer allocator.destroy(counter);

        var base: usize = 128 * 1024;
        var primary = try FlashArea.init(allocator, counter, .{
            .base = base,
            .sectors = sectors + 1,
            .sector_size = sector_size,
        });
        errdefer primary.deinit();
        base += (sectors + 1) * sector_size;
        var secondary = try FlashArea.init(allocator, counter, .{
            .base = base,
            .sectors = sectors,
            .sector_size = sector_size,
        });
        errdefer secondary.deinit();
        var areas = try allocator.alloc(FlashArea, 2);
        areas[0] = primary;
        areas[1] = secondary;

        return Self{
            .allocator = allocator,
            .areas = areas,
            .counter = counter,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.areas) |*area| {
            area.deinit();
        }
        self.allocator.free(self.areas);
        self.allocator.destroy(self.counter);
    }

    /// Open the given numbered area.
    pub fn open(self: *const Self, id: u8) !*FlashArea {
        if (id < self.areas.len) {
            return &self.areas[id];
        } else {
            return error.InvalidArea;
        }
    }

    /// Install test images in the two slots.  There are no headers
    /// (yet), just semi-random data.
    pub fn installImages(self: *Self, sizes: [2]usize) !void {
        // Always off target, large stack buffer is fine.
        var buf: [page_size]u8 = undefined;

        for (sizes) |size, id| {
            var area = try self.open(@intCast(u8, id));
            area.reset();

            var pos: usize = 0;
            while (pos < size) {
                const count = std.math.min(size - pos, page_size);

                // Generate some random data.
                std.mem.set(u8, buf[0..], 0xFF);
                fillBuf(buf[0..count], id * max_pages + pos);

                // std.log.warn("Write slot {}, page {} (size {})", .{ id, pos / page_size, size });
                try area.erase(pos, page_size);
                try area.write(pos, buf[0..]);

                pos += count;
            }
        }
    }

    // Verify the images in the slots (assuming they are reversed).
    pub fn verifyImages(self: *Self, sizes: [2]usize) !void {
        var buf: [page_size]u8 = undefined;
        var buf_exp: [page_size]u8 = undefined;

        for (sizes) |size, id| {
            var area = try self.open(@intCast(u8, id));

            var pos: usize = 0;
            while (pos < size) {
                var count = size - pos;
                if (count > page_size)
                    count = page_size;

                std.mem.set(u8, buf_exp[0..], 0xFF);
                fillBuf(buf_exp[0..count], (1 - id) * max_pages + pos);

                try area.read(pos, buf[0..]);
                std.log.info("verify: slot {}, page {}", .{ id, pos / page_size });
                try std.testing.expectEqualSlices(u8, buf_exp[0..], buf[0..]);

                pos += count;
            }
        }
    }
};

pub const FlashArea = struct {
    const Self = @This();

    allocator: mem.Allocator,

    // These fields are shared with the real implementation.
    off: usize,
    size: usize,

    sectors: usize,
    sector_size: usize,
    log2_ssize: std.math.Log2Int(usize),

    // The data contents of the flash.
    data: []u8,
    state: []State,

    // The parent sim.
    counter: *Counter,

    pub const AreaInit = struct {
        base: usize,
        sectors: usize,
        sector_size: usize,
    };

    pub fn init(allocator: mem.Allocator, counter: *Counter, info: AreaInit) !FlashArea {
        std.debug.assert(std.math.isPowerOfTwo(info.sector_size));
        const log2 = std.math.log2_int(usize, info.sector_size);

        var state = try allocator.alloc(State, info.sectors);
        mem.set(State, state, .Unsafe);
        return FlashArea{
            .off = info.base,
            .sectors = info.sectors,
            .sector_size = info.sector_size,
            .data = try allocator.alloc(u8, info.sectors * info.sector_size),
            .state = state,
            .allocator = allocator,
            .log2_ssize = log2,
            .size = info.sectors * info.sector_size,
            .counter = counter,
        };
    }

    /// Reset the simulated flash to an uninitialized state.
    pub fn reset(self: *Self) void {
        mem.set(State, self.state, .Unsafe);
        mem.set(u8, self.data, 0xAA);
        self.counter.reset();
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.data);
        self.allocator.free(self.state);
    }

    // Read a section of data from this area.  These are restricted
    // to be within a single sector.
    pub fn read(self: *Self, offset: usize, buf: []u8) !void {
        // Ensure we are in bounds.
        if (offset + buf.len > self.data.len) {
            return error.FlashBound;
        }

        const page = offset >> self.log2_ssize;

        // Ensure we remain entirely within a sector.
        if (page != ((offset + buf.len - 1) >> self.log2_ssize)) {
            return error.BeyondSector;
        }

        switch (self.state[page]) {
            .Unsafe => return error.ReadUnsafe,
            .Unwritten => return error.ReadUnwritten,
            .Erased => return error.ReadErased,
            .Written => {},
        }

        std.mem.copy(u8, buf, self.data[offset .. offset + buf.len]);
    }

    // Erase a sector.  The passed data must correspond exactly with
    // one or more sectors.
    pub fn erase(self: *Self, off: usize, len: usize) !void {
        // TODO: We're relying on the Zig bounds check here.  This
        // is insecure with "ReleaseFast".
        if (off + len > self.data.len) {
            return error.FlashBound;
        }
        var page = off >> self.log2_ssize;
        if ((page << self.log2_ssize) != off) {
            return error.EraseMisaligned;
        }
        var count = len >> self.log2_ssize;
        if ((count << self.log2_ssize) != len) {
            return error.EraseMisaligned;
        }

        while (count > 0) {
            self.state[page] = .Unsafe;
            mem.set(u8, self.data[page << self.log2_ssize .. (page + 1) << self.log2_ssize], 0xFF);

            try self.counter.act();

            self.state[page] = .Erased;

            page += 1;
            count -= 1;
        }
    }

    // Write data to a page.  Writes must always be an entire page,
    // and exactly one page.
    pub fn write(self: *Self, off: usize, buf: []const u8) !void {
        // TODO: Relying on bounds check.
        if (off + buf.len > self.data.len) {
            return error.FlashBound;
        }
        const page = off >> self.log2_ssize;
        if ((page << self.log2_ssize) != off) {
            return error.WriteMisaligned;
        }
        if (buf.len != self.sector_size) {
            return error.WriteMisaligned;
        }

        switch (self.state[page]) {
            .Unsafe => return error.WriteUnsafe,
            .Unwritten => return error.WriteUnwritten,
            .Erased => {},
            .Written => return error.WriteWritten,
        }

        self.state[page] = .Unwritten;
        mem.copy(u8, self.data[off .. off + self.sector_size], buf);

        try self.counter.act();

        self.state[page] = .Written;
    }

    // Try to determine the state of flash.  This tries to make it
    // look like partially completed operations have finished, since
    // real flash can behave like that.
    pub fn getState(self: *Self, off: usize) !State {
        if (off > self.data.len) {
            return error.FlashBound;
        }
        const page = off >> self.log2_ssize;
        if ((page << self.log2_ssize) != off) {
            return error.GetStateMisaligned;
        }

        switch (self.state[page]) {
            .Unsafe, .Erased => return .Erased,
            .Written, .Unwritten => return .Written,
        }
    }

    // Save the contents of flash (useful for debugging).
    pub fn save(self: *const Self, path: []const u8) !void {
        var fd = try std.fs.cwd().createFile(path, .{});
        defer fd.close();
        try fd.writeAll(self.data);
    }
};

pub const State = enum {
    // Flash is in an unknown state.  Reads and writes will fail,
    // status check will return erased.
    Unsafe,

    // Partially written data.  Reads and writes will fail, status
    // check will return written data.
    Unwritten,

    // A completed erase.  Writes are allowed, read will return fail
    // (simulating ECC devices).  Status check will return written.
    Erased,

    // A completed write.  Reads will succeed, Writes will fail.
    // Status check returns written.
    Written,
};

// A counter to disrupt flash operations.  The is loaned to each flash
// device so that the counts are shared across multiple
// partitions/devices.
pub const Counter = struct {
    const Self = @This();

    // Number of operations, and the limit.
    current: usize,
    limit: ?usize,

    pub fn init(limit: ?usize) Counter {
        return .{
            .current = 0,
            .limit = limit,
        };
    }

    // Reset the current count.
    pub fn reset(self: *Self) void {
        self.current = 0;
        self.limit = null;
    }

    // Perform an action.  Bumps the counter, if possible.  If
    // expired, returns error.Expired.
    pub fn act(self: *Self) !void {
        if (self.limit) |limit| {
            if (self.current < limit) {
                self.current += 1;
            } else {
                return error.Expired;
            }
        } else {
            self.current += 1;
        }
    }

    // Set a limit.  May return error.Expired if the current value
    // would exceed the limit.  Limit of 'null' means to have no
    // limit.
    pub fn setLimit(self: *Self, limit: ?usize) !void {
        self.limit = limit;
        if (self.limit) |lim| {
            if (self.current >= lim)
                return error.Expired;
        }
    }
};

test "Flash operations" {
    // Predictable prng for testing.

    const page_count = 256;

    var sim = try SimFlash.init(testing.allocator, page_size, page_count);
    defer sim.deinit();

    var buf = try testing.allocator.alloc(u8, page_size);
    defer testing.allocator.free(buf);

    var buf2 = try testing.allocator.alloc(u8, page_size);
    defer testing.allocator.free(buf2);

    var area = try sim.open(0);

    // The initial data should appear erased, but then fail to read or
    // write.
    try testing.expectEqual(State.Erased, try area.getState(0));
    try testing.expectError(error.ReadUnsafe, area.read(0, buf));
    try testing.expectError(error.WriteUnsafe, area.write(0, buf));

    // Write data into flash.
    var page: usize = 0;
    while (page < page_count) : (page += 1) {
        const offset = page * page_size;
        try area.erase(offset, page_size);
        fillBuf(buf, page);
        try area.write(offset, buf);
    }

    // Make sure it can all read back.
    page = 0;
    while (page < page_count) : (page += 1) {
        fillBuf(buf, page);
        std.mem.set(u8, buf2, 0xAA);
        try area.read(page * page_size, buf2);
        try testing.expectEqualSlices(u8, buf, buf2);
    }
}

// Fill a buffer with random bytes, using the given seed.
fn fillBuf(buf: []u8, seed: u64) void {
    var rng = std.rand.DefaultPrng.init(seed);
    rng.fill(buf);
}
