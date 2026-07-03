//! Bounded mutation-based fuzz driver (task #334).
//!
//! `zig build fuzz` runs this: it mutates seed corpus entries (tests/cases/*.bit)
//! and feeds each mutant through `guard.call`, which enforces the actual
//! invariant under test — the lexer+parser never crashes or hangs — and
//! auto-saves any triggering input to tests/fuzz/crashes/ (see guard.zig).
//!
//! This is a plain random-mutation loop, not coverage-guided: Zig 0.16.0's
//! native coverage-guided engine (`-ffuzz` + `std.testing.fuzz` +
//! `zig build --fuzz`) segfaults inside its own runtime whenever a fuzz test
//! seeds a non-empty corpus (upstream ziglang/zig#26040, open as of this
//! writing, 0.16.0 still the latest stable). `fuzz.zig`'s "fuzz lexer+parser"
//! test already exercises the correct, forward-compatible `std.testing.fuzz`
//! API under `zig build test`'s plain (non-instrumented) build; swap this
//! driver back out once the upstream bug is fixed and `--fuzz` runs clean.
//!
//! Bounded by wall-clock deadline (first argv, seconds; default 60 — matches
//! the CI smoke pass) plus a hard iteration backstop (Power of 10: no loop
//! runs on an unproven bound alone, in case the clock misbehaves).

const std = @import("std");
const build_options = @import("build_options");
const guard = @import("guard.zig");

const Io = std.Io;

/// Hard backstop independent of the wall-clock deadline.
const max_iterations = 50_000_000;

/// Mutations applied per generated input; small and fixed (Power of 10).
const max_mutations_per_input = 8;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const fuzz_seconds: i64 = if (argv.len >= 2)
        std.fmt.parseInt(i64, argv[1], 10) catch return error.InvalidSeconds
    else
        60;

    var buf: [256]u8 = undefined;
    var stdout_w: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &stdout_w.interface;

    const seeds = try guard.readBitFiles(gpa, io, build_options.cases_dir);
    defer guard.freeBitFiles(gpa, seeds);

    const start = Io.Timestamp.now(io, .awake);
    const deadline = start.addDuration(.fromSeconds(fuzz_seconds));

    const now_ns: i96 = Io.Timestamp.now(io, .real).nanoseconds;
    var prng: std.Random.DefaultPrng = .init(@truncate(@as(u96, @bitCast(now_ns))));
    const rng = prng.random();

    var mutated: [guard.max_input_len]u8 = undefined;
    var iterations: u64 = 0;
    while (iterations < max_iterations and
        Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) : (iterations += 1)
    {
        const seed: []const u8 = if (seeds.len == 0) &.{} else seeds[rng.uintLessThan(usize, seeds.len)];
        const len = mutate(rng, seed, &mutated);
        guard.call(gpa, mutated[0..len]) catch |err| {
            try out.print("crash after {d} iterations: error.{t} (input saved under tests/fuzz/crashes/)\n", .{ iterations, err });
            try out.flush();
            return err;
        };

        if (iterations % 5000 == 0) {
            try out.print("{d} iterations, 0 crashes\n", .{iterations});
            try out.flush();
        }
    }

    try out.print("done: {d} iterations, 0 crashes\n", .{iterations});
    try out.flush();
}

/// Copies `seed` into `buf` (truncated to `buf.len`) and applies a small,
/// bounded number of random point mutations (byte flip / insert / delete).
/// Returns the resulting length. An empty seed still yields a 1-byte input.
fn mutate(rng: std.Random, seed: []const u8, buf: *[guard.max_input_len]u8) usize {
    var len = @min(seed.len, buf.len);
    @memcpy(buf[0..len], seed[0..len]);
    if (len == 0) {
        buf[0] = rng.int(u8);
        len = 1;
    }

    const n = 1 + rng.uintLessThan(u32, max_mutations_per_input);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        switch (rng.uintLessThan(u8, 3)) {
            0 => buf[rng.uintLessThan(usize, len)] = rng.int(u8),
            1 => if (len < buf.len) {
                const pos = rng.uintLessThan(usize, len + 1);
                std.mem.copyBackwards(u8, buf[pos + 1 .. len + 1], buf[pos..len]);
                buf[pos] = rng.int(u8);
                len += 1;
            },
            else => if (len > 1) {
                const pos = rng.uintLessThan(usize, len);
                std.mem.copyForwards(u8, buf[pos .. len - 1], buf[pos + 1 .. len]);
                len -= 1;
            },
        }
    }
    return len;
}
