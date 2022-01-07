// Flash memory.
//
// This simulates the flash operations used by nswap.  This flash
// meets the 5 requirements in the docs.

const std = @import("std");
const mem = std.mem;

// A simplified hash
pub const Hash = u32;

// A counter to disrupt flash operations.  This is loaned to each
// flash device so that the counts are shared across multiple
// partitions/devices.
pub const Counter = struct {
    const Self = @This();

    // The number of operations remaining.  When this reaches zero,
    // any flash operations will return error.Expired.
    current: usize,
    limit: ?usize,

    pub fn init(limit: usize) Counter {
        return .{
            .current = 0,
            .limit = limit,
        };
    }

    // Reset the current count.
    pub fn reset(self: *Self) void {
        self.current = 0;
    }

    // Perform an action.  Decrements the counter if possible.  If the
    // counter has expired, returns error.Expired.
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

    // Set a limit.  May return error.Expired if the new value exceeds
    // the limit.
    pub fn setLimit(self: *Self, limit: usize) !void {
        self.limit = limit;
        if (self.current >= limit)
            return error.Expired;
    }

    // Set no limit.
    pub fn noLimit(self: *Self) void {
        self.limit = null;
    }
};

// States that a given sector can be in.
pub const StateType = enum {
    // Unsafe indicates the flash should appear erased, but that it
    // wasn't completed.
    Unsafe,

    // Unwritten indicates that a write was interrupted.
    Unwritten,

    // Erased is a normal completed erase.
    Erased,

    // Written is a normal completed write.
    Written,
};

pub const State = union(StateType) {
    Unsafe: void,
    Unwritten: Hash,
    Erased: void,
    Written: Hash,
};

// All operations are done at a sector level.  Real devices would
// likely perform multiple writes within each erase, but we only care
// about state
pub const Flash = struct {
    const Self = @This();

    allocator: mem.Allocator,
    state: []State,
    counter: *Counter,

    pub fn init(allocator: mem.Allocator, total_sectors: usize, counter: *Counter) !Flash {
        var state = try allocator.alloc(State, total_sectors);
        mem.set(State, state, .Unsafe);
        return Flash{
            .allocator = allocator,
            .state = state,
            .counter = counter,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.state);
    }

    // Retrieve the given state, it is safe to read this state.
    pub fn readState(self: *const Self, sector: usize) State {
        switch (self.state[sector]) {
            .Unsafe => return .Erased,
            .Unwritten => |h| return .{ .Written = h },
            else => |st| return st,
        }
    }

    // Perform an erase operation.
    pub fn erase(self: *Self, sector: usize) !void {
        self.state[sector] = .Unsafe;
        try self.counter.act();
        self.state[sector] = .Erased;
    }

    // Perform a write operation.
    pub fn write(self: *Self, sector: usize, hash: Hash) !void {
        if (self.state[sector] != .Erased) {
            return error.InvalidWrite;
        }
        self.state[sector] = .{ .Unwritten = hash };
        try self.counter.act();
        self.state[sector] = .{ .Written = hash };
    }

    // Perform a read operation.
    pub fn read(self: *Self, sector: usize) !Hash {
        switch (self.state[sector]) {
            .Written => |hash| return hash,
            else => return error.InvalidRead,
        }
    }
};
