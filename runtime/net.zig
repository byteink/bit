//! Non-blocking TCP, parked on the netpoller (#353, ABI.md §20).
//!
//! Every socket here is `O_NONBLOCK`. A green thread that would block does not
//! block its OS thread: it registers the fd with the scheduler's netpoller and
//! parks, and the worker runs somebody else. When the fd becomes ready the
//! poller unparks it and the syscall is retried. That is the whole trick behind
//! "one green thread per connection" — ten thousand idle connections cost ten
//! thousand `Task`s, not ten thousand OS threads.
//!
//! Poller registration is one-shot (`EPOLLONESHOT`/`EV_ONESHOT`), so every
//! `awaitReady` registers afresh. That is exactly the shape a retry loop wants.
//!
//! Raw syscalls, per-platform, for the same reason as `sched.zig`: this Zig's
//! `posix.zig` does not wrap the socket calls (it is mid-move to the new `Io`
//! interface, which this freestanding runtime does not depend on).
//!
//! No name resolution: an address is a dotted-quad IPv4 literal. DNS is its own
//! layer, above this one.

const std = @import("std");
const builtin = @import("builtin");
const sched = @import("sched.zig");

const linux = std.os.linux;
const posix = std.posix;
const fd_t = posix.fd_t;
const is_linux = builtin.os.tag == .linux;

/// Upper bound on consecutive would-block retries for one operation. A poller
/// that reports ready and then hands back `EAGAIN` forever is broken; failing
/// beats spinning (Power of 10: every loop is bounded).
const max_stalls = 1024;

pub const Error = error{
    Socket,
    Bind,
    Listen,
    Accept,
    Connect,
    BadAddress,
    Io,
    Poll,
};

// ---------------------------------------------------------------------------
// Parking on readiness
// ---------------------------------------------------------------------------

const PollWait = struct {
    fd: fd_t,
    interest: sched.Interest,
    failed: bool = false,
};

/// Runs on the worker thread once this task's context is saved and its state
/// published as `.parked` (see `sched.park`'s doc comment). Registering here —
/// rather than before the switch — is what stops another thread from resuming a
/// context that has not finished being written.
fn registerThenWait(t: *sched.Task, arg: ?*anyopaque) void {
    const pw: *PollWait = @ptrCast(@alignCast(arg.?));
    // Always a worker thread: `park` itself requires one.
    const s = sched.currentScheduler().?;
    s.poller.register(pw.fd, pw.interest, t) catch {
        // Nothing else will ever wake this task, so wake it here. `t` is
        // already `.parked`, so `unpark`'s CAS precondition holds.
        pw.failed = true;
        sched.unpark(s, t);
    };
}

/// Parks the calling green thread until `fd` is ready for `interest`.
fn awaitReady(fd: fd_t, interest: sched.Interest) Error!void {
    var pw: PollWait = .{ .fd = fd, .interest = interest };
    sched.park(registerThenWait, &pw);
    if (pw.failed) return Error.Poll;
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

/// Parses a dotted-quad IPv4 literal. Deliberately strict — no DNS, no IPv6, no
/// shorthand. A caller wanting a hostname resolves it first.
///
/// Hand-rolled rather than `std.mem.splitScalar` + `std.fmt.parseInt`: those go
/// through SIMD-accelerated `indexOfScalar`, whose vector constants our own
/// AArch64 linker currently mis-resolves — `indexOfScalar("127.0.0.1", '.')`
/// answers 0 instead of 3 in a linked Bit binary (task #1157). Four fields and
/// three digits do not need SIMD anyway, and a freestanding runtime is better
/// off not depending on it.
pub fn parseIpv4(host: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var i: usize = 0;
    for (0..4) |field| {
        var v: u32 = 0;
        var digits: usize = 0;
        while (i < host.len and host[i] != '.') : (i += 1) {
            const c = host[i];
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
            digits += 1;
            if (digits > 3 or v > 255) return null;
        }
        if (digits == 0) return null;
        out[field] = @intCast(v);
        if (field < 3) {
            if (i >= host.len or host[i] != '.') return null;
            i += 1; // step over the separator
        }
    }
    if (i != host.len) return null; // trailing junk, e.g. "1.2.3.4.5"
    return out;
}

fn addrIn(ip: [4]u8, port: u16) posix.sockaddr.in {
    return .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip),
    };
}

test "parseIpv4 accepts a dotted quad and rejects the rest" {
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, parseIpv4("127.0.0.1").?);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, parseIpv4("0.0.0.0").?);
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("127.0.0"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("127.0.0.1.1"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("127.0.0.256"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("localhost"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("127.0..1"));
}

// ---------------------------------------------------------------------------
// Raw syscalls, per platform
// ---------------------------------------------------------------------------

/// `true` when the errno says "this would have blocked". Linux and Darwin both
/// define `EWOULDBLOCK == EAGAIN`, so there is exactly one value to test.
fn wouldBlock(e: posix.E) bool {
    return e == .AGAIN;
}

fn sysSocket() Error!fd_t {
    if (is_linux) {
        // NONBLOCK at creation: one syscall, and no window where the socket is
        // blocking. Darwin has no such flag, hence `setNonBlock` below.
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (posix.errno(rc) != .SUCCESS) return Error.Socket;
        return @intCast(rc);
    }
    const rc = std.c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    if (rc < 0) return Error.Socket;
    try setNonBlock(rc);
    return rc;
}

fn setNonBlock(fd: fd_t) Error!void {
    if (is_linux) {
        const flags = linux.fcntl(fd, posix.F.GETFL, 0);
        if (posix.errno(flags) != .SUCCESS) return Error.Socket;
        const rc = linux.fcntl(fd, posix.F.SETFL, flags | @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK")));
        if (posix.errno(rc) != .SUCCESS) return Error.Socket;
        return;
    }
    const flags = std.c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return Error.Socket;
    var o: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o.NONBLOCK = true;
    if (std.c.fcntl(fd, posix.F.SETFL, @as(c_int, @bitCast(@as(u32, @bitCast(o))))) < 0) return Error.Socket;
}

fn sysBind(fd: fd_t, sa: *const posix.sockaddr.in) Error!void {
    const len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (is_linux) {
        const rc = linux.bind(fd, @ptrCast(sa), len);
        if (posix.errno(rc) != .SUCCESS) return Error.Bind;
        return;
    }
    if (std.c.bind(fd, @ptrCast(sa), len) < 0) return Error.Bind;
}

fn sysListen(fd: fd_t, backlog: u31) Error!void {
    if (is_linux) {
        const rc = linux.listen(fd, backlog);
        if (posix.errno(rc) != .SUCCESS) return Error.Listen;
        return;
    }
    if (std.c.listen(fd, backlog) < 0) return Error.Listen;
}

fn sysSetReuseAddr(fd: fd_t) Error!void {
    const one: c_int = 1;
    const bytes = std.mem.asBytes(&one);
    if (is_linux) {
        const rc = linux.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, bytes.ptr, bytes.len);
        if (posix.errno(rc) != .SUCCESS) return Error.Bind;
        return;
    }
    if (std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, bytes.ptr, bytes.len) < 0) return Error.Bind;
}

/// The pending error on a socket, as `SO_ERROR`. Zero means the operation
/// succeeded.
fn sysSocketError(fd: fd_t) Error!u32 {
    var err: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    if (is_linux) {
        const rc = linux.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err), &len);
        if (posix.errno(rc) != .SUCCESS) return Error.Connect;
    } else {
        if (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err), &len) < 0) return Error.Connect;
    }
    return @intCast(err);
}

// ---------------------------------------------------------------------------
// TCP
// ---------------------------------------------------------------------------

/// A listening socket bound to `host:port`. `port == 0` lets the kernel pick
/// one; recover it with `localPort`.
///
/// `SO_REUSEADDR` so a restart is not refused while the previous socket's
/// connections sit in `TIME_WAIT`. Deliberately *not* `SO_REUSEPORT`, which
/// would let a second process silently steal traffic from this one.
pub fn listenTcp(host: []const u8, port: u16, backlog: u31) Error!fd_t {
    const ip = parseIpv4(host) orelse return Error.BadAddress;
    const fd = try sysSocket();
    errdefer sched.closeFd(fd);

    try sysSetReuseAddr(fd);
    const sa = addrIn(ip, port);
    try sysBind(fd, &sa);
    try sysListen(fd, backlog);
    return fd;
}

/// The port `fd` is actually bound to — the whole point of binding to port 0.
pub fn localPort(fd: fd_t) Error!u16 {
    var sa: posix.sockaddr.in = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    if (is_linux) {
        const rc = linux.getsockname(fd, @ptrCast(&sa), &len);
        if (posix.errno(rc) != .SUCCESS) return Error.Io;
    } else {
        if (std.c.getsockname(fd, @ptrCast(&sa), &len) < 0) return Error.Io;
    }
    return std.mem.bigToNative(u16, sa.port);
}

/// Accepts one connection, parking until a peer arrives. The returned socket is
/// non-blocking, like every socket here.
pub fn acceptTcp(lfd: fd_t) Error!fd_t {
    var stalls: u32 = 0;
    while (stalls < max_stalls) {
        const fd: fd_t = blk: {
            if (is_linux) {
                const rc = linux.accept4(lfd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
                const e = posix.errno(rc);
                if (e == .SUCCESS) break :blk @intCast(rc);
                if (wouldBlock(e)) {
                    stalls += 1;
                    try awaitReady(lfd, .read);
                    continue;
                }
                // A peer that vanished between the poll and the accept is
                // routine, and not this listener's problem.
                if (e == .CONNABORTED or e == .INTR) continue;
                return Error.Accept;
            }
            const rc = std.c.accept(lfd, null, null);
            if (rc >= 0) {
                try setNonBlock(rc);
                break :blk rc;
            }
            const e = posix.errno(rc);
            if (wouldBlock(e)) {
                stalls += 1;
                try awaitReady(lfd, .read);
                continue;
            }
            if (e == .CONNABORTED or e == .INTR) continue;
            return Error.Accept;
        };
        return fd;
    }
    return Error.Accept;
}

/// Connects to `host:port`, parking until the handshake finishes.
///
/// A non-blocking `connect` reports `EINPROGRESS` and finishes in the
/// background. The socket then becomes *writable* whether it succeeded or
/// failed, so the outcome has to be read back from `SO_ERROR`. Skipping that
/// read is the classic bug: a refused connection looks connected until some
/// later `write` fails far away from the cause.
pub fn dialTcp(host: []const u8, port: u16) Error!fd_t {
    const ip = parseIpv4(host) orelse return Error.BadAddress;
    const fd = try sysSocket();
    errdefer sched.closeFd(fd);

    const sa = addrIn(ip, port);
    const len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    const e = blk: {
        if (is_linux) break :blk posix.errno(linux.connect(fd, @ptrCast(&sa), len));
        const rc = std.c.connect(fd, @ptrCast(&sa), len);
        break :blk if (rc < 0) posix.errno(rc) else posix.E.SUCCESS;
    };

    switch (e) {
        .SUCCESS => return fd,
        .INPROGRESS, .AGAIN, .INTR => {
            try awaitReady(fd, .write);
            if (try sysSocketError(fd) != 0) return Error.Connect;
            return fd;
        },
        else => return Error.Connect,
    }
}

/// Reads up to `buf.len` bytes, parking until some arrive. `0` means the peer
/// closed: an orderly end of stream, not an error.
pub fn readSock(fd: fd_t, buf: []u8) Error!usize {
    var stalls: u32 = 0;
    while (stalls < max_stalls) {
        const rc = if (is_linux) linux.read(fd, buf.ptr, buf.len) else @as(usize, @bitCast(std.c.read(fd, buf.ptr, buf.len)));
        const e = if (is_linux) posix.errno(rc) else posix.errno(@as(isize, @bitCast(rc)));
        if (e == .SUCCESS) return if (is_linux) rc else @bitCast(rc);
        if (wouldBlock(e)) {
            stalls += 1;
            try awaitReady(fd, .read);
            continue;
        }
        if (e == .INTR) continue;
        // A reset peer has no more bytes for us. Report end of stream, so a
        // caller's read loop terminates instead of erroring.
        if (e == .CONNRESET) return 0;
        return Error.Io;
    }
    return Error.Io;
}

/// Writes all of `buf`, parking whenever the send buffer is full. A short write
/// is normal on a socket and is not an error — hence the loop.
pub fn writeSock(fd: fd_t, buf: []const u8) Error!usize {
    var off: usize = 0;
    var stalls: u32 = 0;
    while (off < buf.len and stalls < max_stalls) {
        const chunk = buf[off..];
        const rc = if (is_linux) linux.write(fd, chunk.ptr, chunk.len) else @as(usize, @bitCast(std.c.write(fd, chunk.ptr, chunk.len)));
        const e = if (is_linux) posix.errno(rc) else posix.errno(@as(isize, @bitCast(rc)));
        if (e == .SUCCESS) {
            const n = if (is_linux) rc else @as(usize, @bitCast(rc));
            if (n == 0) break;
            off += n;
            stalls = 0; // progress: the bound is on consecutive stalls, not writes
            continue;
        }
        if (wouldBlock(e)) {
            stalls += 1;
            try awaitReady(fd, .write);
            continue;
        }
        if (e == .INTR) continue;
        return Error.Io;
    }
    if (off < buf.len) return Error.Io;
    return off;
}
