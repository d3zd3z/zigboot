// The core of the swap algorithm.

const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const testing = std.testing;
const stdout = std.io.getStdOut();
const print = stdout.writer().print;

const flash = @import("flash.zig");

const WorkKind = enum {
    Erase,
    Read,
    Write,
};

const Work = struct {
    kind: WorkKind,
    slot: usize,
    page: usize,
};

pub const SwapState = struct {
    const Self = @This();

    allocator: mem.Allocator,

    // Allocated, and owned by us.  Pointer shared so we don't have to
    // worry about moves.
    counter: *flash.Counter,

    slots: [2]flash.Flash,
    work: ArrayList(Work),

    pub fn init(allocator: mem.Allocator, total_sectors: usize) !SwapState {
        const counter = try allocator.create(flash.Counter);
        errdefer allocator.destroy(counter);
        counter.* = flash.Counter.init(std.math.maxInt(usize));

        var primary = try flash.Flash.init(allocator, total_sectors, counter);
        var secondary = try flash.Flash.init(allocator, total_sectors, counter);
        var work = ArrayList(Work).init(allocator);

        return SwapState{
            .allocator = allocator,
            .counter = counter,
            .slots = [2]flash.Flash{ primary, secondary },
            .work = work,
        };
    }

    pub fn deinit(self: *Self) void {
        self.slots[0].deinit();
        self.slots[1].deinit();
        self.allocator.destroy(self.counter);
        self.work.deinit();
    }

    // Set up the initial flash, and the work indicator.
    pub fn setup(self: *Self) !void {
        var i: usize = 0;
        const size = self.slots[0].state.len - 2;
        while (i < size) : (i += 1) {
            for (self.slots) |*slot, slt| {
                try slot.erase(i);
                try slot.write(i, hash(slt, i));
            }
        }

        // Move slot 0 down.
        i = size;
        while (i > 0) : (i -= 1) {
            try self.work.append(Work{
                .kind = .Erase,
                .slot = 0,
                .page = i,
            });
            try self.work.append(Work{
                .kind = .Read,
                .slot = 0,
                .page = i - 1,
            });
            try self.work.append(Work{
                .kind = .Write,
                .slot = 0,
                .page = i,
            });
        }
        i = 0;
        while (i < size) : (i += 1) {
            const actions = [_]WorkKind{ .Erase, .Read, .Write, .Erase, .Read, .Write };
            const slots = [_]usize{ 0, 1, 0, 1, 0, 1 };
            const pages = [_]usize{ 0, 0, 0, 0, 1, 0 };
            var j: usize = 0;
            while (j < actions.len) : (j += 1) {
                try self.work.append(Work{
                    .kind = actions[j],
                    .slot = slots[j],
                    .page = pages[j] + i,
                });
            }
        }
        // And a single straggling erase.
        try self.work.append(Work{
            .kind = .Erase,
            .slot = 0,
            .page = size,
        });
    }

    // Show our current state.
    pub fn show(self: *Self) !void {
        try print("Swap state:\n", .{});
        var i: usize = 0;
        while (i < self.slots[0].state.len) : (i += 1) {
            try print("{:3} {} {}\n", .{
                i,
                self.slots[0].state[i],
                self.slots[1].state[i],
            });
        }
        if (false) {
            try print("\n", .{});
            for (self.work.items) |item| {
                try print("{}\n", .{item});
            }
        }
    }

    // Run the work.
    pub fn run(self: *Self) !void {
        try print("Running {} steps\n", .{self.work.items.len});

        var h: flash.Hash = undefined;

        for (self.work.items) |item| {
            try print("{}\n", .{item});
            switch (item.kind) {
                .Read => {
                    h = try self.slots[item.slot].read(item.page);
                },
                .Write => {
                    try self.slots[item.slot].write(item.page, h);
                },
                .Erase => {
                    try self.slots[item.slot].erase(item.page);
                },
            }
        }
    }
};

// Compute a "hash".  These are just indicators to make it easier to
// tell what is happening.
fn hash(slot: usize, sector: usize) flash.Hash {
    return @intCast(flash.Hash, slot * 1000 + sector);
}

test "Swap" {
    var state = try SwapState.init(testing.allocator, 10);
    defer state.deinit();
    try state.setup();
    // try state.counter.setLimit(51);
    state.run() catch |err| {
        if (err != error.Expired)
            return err;
    };
    try state.show();
}
