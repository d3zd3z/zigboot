// The core of the swap algorithm.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const ArrayList = std.ArrayList;
const testing = std.testing;
const stdout = std.io.getStdOut();
const print = stdout.writer().print;

const flash = @import("flash.zig");

const Work = struct {
    src_slot: usize,
    src_page: usize,
    dest_slot: usize,
    dest_page: usize,

    // The hash we're intending to move.
    hash: flash.Hash,
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
        // We track the contents of flash as we build work, and use
        // this to skip work that isn't needed.  In a real device,
        // this will be build by hashing the images before starting
        // the upgrades.
        var track = try Tracker.init(self.allocator, self.slots[0..]);
        defer track.deinit(self.allocator);

        var i: usize = 0;
        const size = self.slots[0].state.len - 2;
        while (i < size) : (i += 1) {
            for (self.slots) |*slot, slt| {
                try slot.erase(i);
                const h = hash(slt, i);
                try slot.write(i, h);
                track.set(slt, i, h);
            }
        }

        self.work.clearRetainingCapacity();

        // Move slot 0 down.
        i = size;
        while (i > 0) : (i -= 1) {
            try track.tryMove(&self.work, Work{
                .src_slot = 0,
                .dest_slot = 0,
                .src_page = i - 1,
                .dest_page = i,
                .hash = hash(0, i - 1),
            });
        }

        // The following moves will happen to the same region as the
        // above, so we need a barrier.
        //try self.work.append(Work{
        //    .kind = .Barrier,
        //    .slot = 0,
        //    .page = 0,
        //});

        try track.show();
        i = 0;
        while (i < size) : (i += 1) {
            // TODO: Skip the move if the destination already matches.

            // Move slot 1 into the empty space now in slot 0.
            try track.tryMove(&self.work, Work{
                .src_slot = 1,
                .src_page = i,
                .dest_slot = 0,
                .dest_page = i,
                .hash = hash(1, i),
            });

            // Move the shifted slot 0 value into slot 1's final
            // destination.
            try track.tryMove(&self.work, Work{
                .src_slot = 0,
                .src_page = i + 1,
                .dest_slot = 1,
                .dest_page = i,
                .hash = hash(0, i),
            });
        }

        // Finally, we should erase the last page after the shift.
        // This doesn't have anything to do with a correct shift,
        // though.
        //try self.work.append(Work{
        //    .kind = .Erase,
        //    .slot = 0,
        //    .page = size,
        //});
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

        for (self.work.items) |item| {
            try print("run: {}\n", .{item});
            const h = try self.slots[item.src_slot].read(item.src_page);
            assert(h == item.hash);
            try self.slots[item.dest_slot].erase(item.dest_page);
            try self.slots[item.dest_slot].write(item.dest_page, h);
        }
    }

    // Perform recovery, looking for where we can do work.
    pub fn recover(self: *Self) !void {
        try print("----------\n", .{});
        var i: usize = 0;
        var first_i: ?usize = null;
        while (i < self.work.items.len) : (i += 1) {
            const item = &self.work.items[i];
            const rstate = self.slots[item.src_slot].readState(item.src_page);
            var status = "    ";
            switch (rstate) {
                .Written => |h| {
                    if (h == item.hash) {
                        status = "good";
                        if (first_i) |_| {} else {
                            first_i = i;
                        }
                    }
                },
                else => {},
            }
            try print("{s} {}\n", .{ status, item });
        }

        try print("---Recovery---\n", .{});
        if (first_i) |fi| {
            i = fi;
        } else {
            // Presumably we are finished.
            return;
        }
        while (i < self.work.items.len) : (i += 1) {
            const item = &self.work.items[i];
            try print("run: {}\n", .{item});
            const h = try self.slots[item.src_slot].read(item.src_page);
            assert(h == item.hash);
            try self.slots[item.dest_slot].erase(item.dest_page);
            try self.slots[item.dest_slot].write(item.dest_page, h);
        }
    }

    // Check that, post recovery, the swap is completed.
    pub fn check(self: *Self) !void {
        var i: usize = 0;
        while (i < self.slots[0].state.len - 2) : (i += 1) {
            const h0 = try self.slots[0].read(i);
            if (h0 != hash(1, i)) {
                return error.TestMismatch;
            }
            const h1 = try self.slots[1].read(i);
            if (h1 != hash(0, i)) {
                return error.TestMismatch;
            }
            assert(h1 == hash(0, i));
        }
    }

    // Run the entire state through a tested interruption.  Returns
    // 'true' if the test ran to the end without being interrupted.
    pub fn testAt(self: *Self, stopAt: usize) !bool {
        try print("stop at: {}\n", .{stopAt});
        try self.setup();
        self.counter.reset();
        try self.counter.setLimit(stopAt);
        if (self.run()) |_| {
            // All operations completed, so we are done.
            return true;
        } else |err| {
            if (err != error.Expired)
                return err;
        }
        try self.show();
        self.counter.noLimit();
        try self.recover();
        try self.show();
        try self.check();

        return false;
    }
};

// Tracker, used for building up the state.
const Tracker = struct {
    const Self = @This();
    state: [2][]flash.State,

    fn init(allocator: mem.Allocator, slots: []flash.Flash) !Tracker {
        var state = [2][]flash.State{
            try allocator.alloc(flash.State, slots[0].state.len),
            try allocator.alloc(flash.State, slots[1].state.len),
        };
        mem.set(flash.State, state[0], .{ .Unsafe = {} });
        mem.set(flash.State, state[1], .{ .Unsafe = {} });
        return Tracker{
            .state = state,
        };
    }

    fn deinit(self: *Self, allocator: mem.Allocator) void {
        allocator.free(self.state[0]);
        allocator.free(self.state[1]);
    }

    fn set(self: *Self, slot: usize, page: usize, h: flash.Hash) void {
        self.state[slot][page] = .{ .Written = h };
    }

    // Try moving appropriately, creates work if that is appropriate.
    fn tryMove(self: *Self, work: *ArrayList(Work), w: Work) !void {
        try print("tryMove: {}\n   {}\n   {}\n", .{
            w,
            self.state[w.src_slot][w.src_page],
            self.state[w.dest_slot][w.dest_page],
        });
        if (self.state[w.src_slot][w.src_page].sameHash(&self.state[w.dest_slot][w.dest_page])) {
            try print("Skipping: {}\n", .{w});
        }
        self.state[w.dest_slot][w.dest_page] = self.state[w.src_slot][w.src_page];
        // self.state[w.src_slot][w.src_page] = .{ .Unsafe = {} };
        try work.append(w);
    }

    fn show(self: *const Self) !void {
        for (self.state[0]) |st0, i| {
            const st1 = self.state[1][i];
            try print("  track: {} {}\n", .{ st0, st1 });
        }
    }
};

// Compute a "hash".  These are just indicators to make it easier to
// tell what is happening.
fn hash(slot: usize, sector: usize) flash.Hash {
    // return @intCast(flash.Hash, slot * 1000 + sector + 1);
    return @intCast(flash.Hash, slot * 0 + sector + 1);
}

test "Swap" {
    var state = try SwapState.init(testing.allocator, 10);
    defer state.deinit();
    _ = try state.testAt(16);
    //var stopAt: usize = 1;
    //while (true) : (stopAt += 1) {
    //    if (try state.testAt(stopAt))
    //        break;
    //}
}
