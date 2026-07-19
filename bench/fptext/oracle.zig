const std = @import("std");

var st: u64 = 0x243F6A8885A308D3;
fn rnd() u64 {
    st ^= st << 13;
    st ^= st >> 7;
    st ^= st << 17;
    return st;
}

fn emit(w: *std.Io.Writer, bits: u64, n: *usize) !void {
    const v: f64 = @bitCast(bits);
    if (std.math.isNan(v) or std.math.isInf(v)) return; // excluded by design
    try w.print("{x:0>16} {d}\n", .{ bits, v });
    n.* += 1;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1 << 16]u8 = undefined;
    var fw: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buf);
    const w = &fw.interface;
    var n: usize = 0;

    // class A: structural edges
    const edges = [_]u64{
        0x0000000000000000, // +0
        0x8000000000000000, // -0
        0x0000000000000001, // min denormal 5e-324
        0x000FFFFFFFFFFFFF, // max denormal
        0x0010000000000000, // min normal
        0x7FEFFFFFFFFFFFFF, // DBL_MAX
        0x3FF0000000000000, // 1.0
        0xBFF0000000000000, // -1.0
    };
    for (edges) |b| try emit(w, b, &n);

    // class B: every power of two, both signs
    var e: u64 = 0;
    while (e < 2047) : (e += 1) {
        const b = e << 52;
        try emit(w, b, &n);
        try emit(w, b | 0x8000000000000000, &n);
    }

    // class C: every representable power of ten, and its 1-ULP neighbours
    var p: i32 = -323;
    while (p <= 308) : (p += 1) {
        var tb: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&tb, "1e{d}", .{p});
        const v = std.fmt.parseFloat(f64, s) catch continue;
        const b: u64 = @bitCast(v);
        try emit(w, b, &n);
        if (b > 0) try emit(w, b - 1, &n);
        try emit(w, b +% 1, &n);
    }

    // class D: small integers and simple fractions
    var i: i64 = -10000;
    while (i <= 10000) : (i += 1) {
        try emit(w, @bitCast(@as(f64, @floatFromInt(i))), &n);
        try emit(w, @bitCast(@as(f64, @floatFromInt(i)) / 10.0), &n);
        try emit(w, @bitCast(@as(f64, @floatFromInt(i)) / 3.0), &n);
    }

    // class E: shortest-representation boundary stress — random short decimals
    var k: usize = 0;
    while (k < 150000) : (k += 1) {
        const digits = 1 + rnd() % 17;
        const ex = @as(i32, @intCast(rnd() % 60)) - 30;
        var db: [40]u8 = undefined;
        var m: usize = 0;
        var d: u64 = 0;
        while (d < digits) : (d += 1) {
            db[m] = '0' + @as(u8, @intCast(rnd() % 10));
            m += 1;
        }
        var sb: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&sb, "{s}e{d}", .{ db[0..m], ex });
        const v = std.fmt.parseFloat(f64, s) catch continue;
        const b: u64 = @bitCast(v);
        try emit(w, b, &n);
        try emit(w, b +% 1, &n);
    }

    // class F: large uniform random sweep over the full bit space
    while (n < 1_000_000) {
        try emit(w, rnd(), &n);
    }

    try w.flush();
    std.debug.print("emitted {d}\n", .{n});
}
