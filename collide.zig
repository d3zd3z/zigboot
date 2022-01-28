// SPDX-License-Identifier: Apache-2.0
//
// Find hash collisions.
//
// Becuase we are using a fairly small hash, collisions are possible,
// although somewhat rare.  In order to test that we handle the
// collisions correctly, we need to search for data that does indeed
// collide.

const std = @import("std");
const mem = std.mem;
const stdout = std.io.getStdOut();
const print = stdout.writer().print;
const Sha256 = std.crypto.hash.sha2.Sha256;

// We will simulate this by having 512 bytes of data, with the prefix
// at the start, and adding 4 bytes of data to be hashed at the end.

pub fn main() !void {
    // The Sha256 run through all of the unchanging data.
    var hseed = Sha256.init(.{});

    var slow: u32 = 0;
    var fast: u32 = update(&hseed, slow);
    fast = update(&hseed, fast);

    var steps: usize = 1;
    while (true) : (steps += 1) {
        // try print("slow: ", .{});
        var slow2 = update(&hseed, slow);

        if (slow2 == fast) {
            try print("Collide1: {x} at {}\n", .{ slow2, steps });
            try print("{x} and {x}\n", .{ slow, fast });
            break;
        }

        // try print("fast: ", .{});
        var fast2 = update(&hseed, fast);

        if (slow2 == fast2) {
            try print("Collide2: {x} at {}\n", .{ slow2, steps });
            try print("{x} and {x}\n", .{ slow, fast });
            break;
        }

        if (slow == fast2) {
            try print("Collide2b: {x} at {}\n", .{ slow2, steps });
            try print("{x} and {x}\n", .{ slow, fast });
            break;
        }

        // try print("fast: ", .{});
        var fast3 = update(&hseed, fast2);

        // if (slow2 == fast3) {
        //     try print("Collide3: {x} at {}\n", .{ slow2, steps });
        //     try print("{x} and {x}\n", .{ slow, fast2 });
        //     break;
        // }

        slow = slow2;
        fast = fast3;

        if (steps % (1 << 20 - 1) == 0) {
            try print("Steps: {}\n", .{steps});
        }
    }
}

// Generate a Sha256 hash in-process run through the prefix, and the
// first 512 bytes of data.
fn genHashStart() Sha256 {
    var result = Sha256.init(.{});
    var buf: [512]u8 = undefined;
    mem.set(u8, buf, 0);
    buf[0] = 1; // Default prefix.
    result.update(buf);

    return result;
}

// Advance to the next hash.
fn update(hasher: *Sha256, value: u32) u32 {
    // Copy the hash state, and compute the next hash.
    var hh = hasher.*;
    hh.update(mem.asBytes(&value));
    var final: [32]u8 = undefined;
    hh.final(&final);

    var result: u32 = undefined;
    mem.copy(u8, mem.asBytes(&result), final[0..4]);
    // print("{x} -> {x}\n", .{ value, result }) catch {};
    return result;
}
