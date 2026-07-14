//! Cryptographic entropy at the Zig↔Bit boundary (#1159, ABI.md §21).
//!
//! Two primitives that cannot be written in pure Bit: OS-CSPRNG entropy and an
//! optimizer-proof buffer wipe. Both are plain Zig APIs here; `root.zig` wraps
//! them in the `bit_rt_*` C-ABI exports, exactly as it does for `net.zig`.
//!
//! Raw per-platform syscalls, for the same reason as `net.zig`/`sched.zig`: this
//! Zig's `posix.zig` is mid-move to the new `Io` interface, which a freestanding
//! runtime does not depend on.
//!
//! **Entropy policy is deliberately strict.** Fill only from the OS CSPRNG —
//! never a userspace PRNG, never a weak or zero fallback. On OS failure `fill`
//! returns `error.Entropy`, which its one caller turns into a fatal panic:
//! silently handing back predictable "random" bytes is a security defect far
//! worse than a crash.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const os_tag = builtin.os.tag;

comptime {
    switch (os_tag) {
        .linux, .macos, .windows => {},
        else => @compileError("runtime/rand.zig supports Linux, macOS, and Windows only"),
    }
}

pub const Error = error{Entropy};

// Windows: the system-preferred CSPRNG, so no algorithm handle to open/close.
// Declared here rather than pulled from std, which exposes no BCrypt wrapper.
const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x0000_0002;
extern "bcrypt" fn BCryptGenRandom(
    hAlgorithm: ?*anyopaque,
    pbBuffer: [*]u8,
    cbBuffer: u32,
    dwFlags: u32,
) callconv(.winapi) std.os.windows.NTSTATUS;

/// Fills all of `buf` with cryptographically-secure random bytes drawn from the
/// OS CSPRNG. Returns `error.Entropy` on OS failure — never partial or weak
/// data. The buffer is untouched on error (the caller aborts).
pub fn fill(buf: []u8) Error!void {
    if (buf.len == 0) return;
    switch (os_tag) {
        .linux => try fillLinux(buf),
        // arc4random_buf is always present on Darwin and is a CSPRNG there
        // (ChaCha20, seeded from the kernel). It cannot fail.
        .macos => std.c.arc4random_buf(buf.ptr, buf.len),
        .windows => try fillWindows(buf),
        else => comptime unreachable, // gated by the comptime switch above
    }
}

fn fillLinux(buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) { // bounded: every branch either advances off or returns
        // flags = 0: draw from the same pool as /dev/urandom and *block* until it
        // has been seeded. Never GRND_RANDOM (drains the blocking pool for no
        // security gain) nor GRND_NONBLOCK (would fail early rather than wait).
        const rc = linux.getrandom(buf.ptr + off, buf.len - off, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc, // may be a short draw; the loop finishes it
            .INTR => continue, // a signal interrupted the wait for entropy: retry
            .NOSYS => return fillUrandom(buf), // pre-3.17 kernel: fall back
            else => return Error.Entropy, // EFAULT/EINVAL here would be our bug
        }
    }
}

/// Pre-3.17 fallback: `/dev/urandom`, the same CSPRNG source `getrandom(0)`
/// wraps. Only reached when the syscall itself is absent (`ENOSYS`).
fn fillUrandom(buf: []u8) Error!void {
    const fd_rc = linux.open("/dev/urandom", .{ .CLOEXEC = true }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return Error.Entropy;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < buf.len) { // bounded by buf.len (every non-retry branch advances)
        const rc = linux.read(fd, buf.ptr + off, buf.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return Error.Entropy; // unexpected EOF on the device
                off += rc;
            },
            .INTR => continue,
            else => return Error.Entropy,
        }
    }
}

fn fillWindows(buf: []u8) Error!void {
    // `cbBuffer` is a ULONG (u32); chunk a larger buffer so the length never
    // truncates. Each call fully fills its chunk or returns a non-SUCCESS status.
    var off: usize = 0;
    while (off < buf.len) { // bounded by buf.len
        const chunk: u32 = @intCast(@min(buf.len - off, @as(usize, std.math.maxInt(u32))));
        const status = BCryptGenRandom(null, buf.ptr + off, chunk, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        if (status != .SUCCESS) return Error.Entropy;
        off += chunk;
    }
}

/// Zeroes `bytes`, then a compiler barrier so the write cannot be elided. A
/// plain `@memset` may be dropped by dead-store elimination once the optimizer
/// proves the buffer is unused afterwards — the classic way a "cleared" key
/// survives in memory. The barrier tells the compiler memory was clobbered,
/// which forbids that. Backs `cryptoSecureZero`, for wiping key material.
pub fn secureZero(bytes: []u8) void {
    @memset(bytes, 0);
    asm volatile ("" ::: .{ .memory = true });
}

// ---------------------------------------------------------------------------
// Tests (run natively under `root.zig`'s test module — macOS arc4random path).
// ---------------------------------------------------------------------------

test "fill produces the requested length and is not a constant" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    try fill(&a);
    try fill(&b);
    // Two independent draws must differ (a 4 KiB collision is astronomically
    // unlikely), and neither can be all-zero (the weak-fallback failure mode).
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.allEqual(u8, &a, 0));
}

test "fill on an empty slice is a no-op" {
    var empty: [0]u8 = undefined;
    try fill(&empty);
}

test "secureZero wipes every byte" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0xAB);
    secureZero(&buf);
    for (buf) |c| try std.testing.expectEqual(@as(u8, 0), c);
}
