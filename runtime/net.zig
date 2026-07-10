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

/// The dotted-quad of a `sockaddr.in`'s address, written into `buf` (which must
/// hold the longest form, "255.255.255.255" = 15 bytes). Returns the slice used.
pub fn formatIpv4(sa: *const posix.sockaddr.in, buf: *[15]u8) []const u8 {
    return formatOctets(@bitCast(sa.addr), buf);
}

/// The dotted-quad of four address octets, written into `buf`. Hand-rolled for
/// the same reason as `parseIpv4`: no `std.fmt` dependency on a freestanding hot
/// path.
pub fn formatOctets(octets: [4]u8, buf: *[15]u8) []const u8 {
    var n: usize = 0;
    for (octets, 0..) |o, i| {
        if (i != 0) {
            buf[n] = '.';
            n += 1;
        }
        if (o >= 100) {
            buf[n] = '0' + o / 100;
            n += 1;
        }
        if (o >= 10) {
            buf[n] = '0' + (o / 10) % 10;
            n += 1;
        }
        buf[n] = '0' + o % 10;
        n += 1;
    }
    return buf[0..n];
}

/// The port of a `sockaddr.in`, host byte order.
pub fn addrPort(sa: *const posix.sockaddr.in) u16 {
    return std.mem.bigToNative(u16, sa.port);
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

// ---------------------------------------------------------------------------
// UDP
// ---------------------------------------------------------------------------

fn sysSocketUdp() Error!fd_t {
    if (is_linux) {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (posix.errno(rc) != .SUCCESS) return Error.Socket;
        return @intCast(rc);
    }
    const rc = std.c.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    if (rc < 0) return Error.Socket;
    try setNonBlock(rc);
    return rc;
}

/// A datagram socket bound to `host:port`. `port == 0` lets the kernel pick one
/// (recover it with `localPort`, exactly like a TCP listener). Connectionless:
/// unlike TCP there is no listen/accept — send and receive straight off the fd.
pub fn bindUdp(host: []const u8, port: u16) Error!fd_t {
    const ip = parseIpv4(host) orelse return Error.BadAddress;
    const fd = try sysSocketUdp();
    errdefer sched.closeFd(fd);

    try sysSetReuseAddr(fd);
    const sa = addrIn(ip, port);
    try sysBind(fd, &sa);
    return fd;
}

/// Sends one datagram to `host:port`. Parks on writability if the socket buffer
/// is momentarily full. A datagram is all-or-nothing: a partial send is an
/// error, never a short count, so there is no write loop as there is for TCP.
pub fn sendTo(fd: fd_t, host: []const u8, port: u16, data: []const u8) Error!usize {
    const ip = parseIpv4(host) orelse return Error.BadAddress;
    const sa = addrIn(ip, port);
    const salen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    var stalls: u32 = 0;
    while (stalls < max_stalls) {
        const rc = if (is_linux)
            linux.sendto(fd, data.ptr, data.len, 0, @ptrCast(&sa), salen)
        else
            @as(usize, @bitCast(std.c.sendto(fd, data.ptr, data.len, 0, @ptrCast(&sa), salen)));
        const e = if (is_linux) posix.errno(rc) else posix.errno(@as(isize, @bitCast(rc)));
        if (e == .SUCCESS) return if (is_linux) rc else @bitCast(rc);
        if (wouldBlock(e)) {
            stalls += 1;
            try awaitReady(fd, .write);
            continue;
        }
        if (e == .INTR) continue;
        return Error.Io;
    }
    return Error.Io;
}

/// Receives one datagram into `buf`, parking until one arrives, and writes the
/// sender's address into `from`. Returns the byte count (a zero-length datagram
/// is legal, so `0` is not end-of-stream here — UDP has no stream to end).
pub fn recvFrom(fd: fd_t, buf: []u8, from: *posix.sockaddr.in) Error!usize {
    var stalls: u32 = 0;
    while (stalls < max_stalls) {
        var salen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const rc = if (is_linux)
            linux.recvfrom(fd, buf.ptr, buf.len, 0, @ptrCast(from), &salen)
        else
            @as(usize, @bitCast(std.c.recvfrom(fd, buf.ptr, buf.len, 0, @ptrCast(from), &salen)));
        const e = if (is_linux) posix.errno(rc) else posix.errno(@as(isize, @bitCast(rc)));
        if (e == .SUCCESS) return if (is_linux) rc else @bitCast(rc);
        if (wouldBlock(e)) {
            stalls += 1;
            try awaitReady(fd, .read);
            continue;
        }
        if (e == .INTR) continue;
        return Error.Io;
    }
    return Error.Io;
}

// ---------------------------------------------------------------------------
// DNS (A-record resolution)
// ---------------------------------------------------------------------------
//
// A minimal stub resolver: one A query to the first nameserver in
// /etc/resolv.conf over UDP/53, returning the first A record. No search domains,
// no caching, no AAAA, no TCP fallback for truncated replies — a hostname that
// needs any of those is out of scope for v1.
//
// ponytail: blocking socket with SO_RCVTIMEO + bounded retransmits, not the
// netpoller. It blocks the calling worker for up to `dns_timeout_ms` on a lost
// packet. DNS is an occasional, usually-millisecond cost, so this buys
// correctness (no hang, a real error on failure) without timer-driven poller
// wakes; move it onto the poller if resolution ever sits on a hot path.

const dns_timeout_ms = 2000;
const dns_retries = 3;

fn firstNameserver(buf: *[4]u8) Error!void {
    const fd = sched.openFd("/etc/resolv.conf", .read) catch return Error.Io;
    defer sched.closeFd(fd);
    var file: [4096]u8 = undefined;
    const n = sched.readFd(fd, &file) catch return Error.Io;
    var lines = std.mem.splitScalar(u8, file[0..n], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const key = "nameserver";
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = std.mem.trim(u8, trimmed[key.len..], " \t");
        if (parseIpv4(rest)) |ip| {
            buf.* = ip;
            return;
        }
    }
    return Error.BadAddress; // no usable nameserver line
}

/// Writes a DNS A-record query for `host` into `out` and returns the length. The
/// QNAME is `host` split on '.', each label length-prefixed, NUL-terminated.
fn buildQuery(out: []u8, host: []const u8, id: u16) Error!usize {
    if (host.len == 0 or host.len > 253) return Error.BadAddress;
    var n: usize = 0;
    // Header: id, flags=RD, qd=1, an=ns=ar=0.
    std.mem.writeInt(u16, out[0..2], id, .big);
    std.mem.writeInt(u16, out[2..4], 0x0100, .big);
    std.mem.writeInt(u16, out[4..6], 1, .big);
    @memset(out[6..12], 0);
    n = 12;
    // QNAME.
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return Error.BadAddress;
        if (n + 1 + label.len + 5 > out.len) return Error.BadAddress;
        out[n] = @intCast(label.len);
        n += 1;
        @memcpy(out[n..][0..label.len], label);
        n += label.len;
    }
    out[n] = 0; // root label
    n += 1;
    std.mem.writeInt(u16, out[n..][0..2], 1, .big); // QTYPE = A
    std.mem.writeInt(u16, out[n + 2 ..][0..2], 1, .big); // QCLASS = IN
    return n + 4;
}

/// Advances past a DNS name at `msg[off]`, following the length-prefix labels
/// and stopping at the root label or a compression pointer (0xC0). Returns the
/// offset just past the name. Compression is only *skipped* here, never
/// followed — the caller does not need the name's text, only its length.
fn skipName(msg: []const u8, off: usize) Error!usize {
    var i = off;
    while (i < msg.len) {
        const len = msg[i];
        if (len == 0) return i + 1;
        if (len & 0xC0 == 0xC0) return i + 2; // pointer: 2 bytes, name ends here
        i += 1 + len;
    }
    return Error.Io; // ran off the end
}

/// Parses a DNS response and writes the first A record into `out`. Verifies the
/// transaction id and a non-error RCODE, skips the question, then walks answers.
fn parseAnswer(msg: []const u8, want_id: u16, out: *[4]u8) Error!void {
    if (msg.len < 12) return Error.Io;
    if (std.mem.readInt(u16, msg[0..2], .big) != want_id) return Error.Io;
    const flags = std.mem.readInt(u16, msg[2..4], .big);
    if (flags & 0x000F != 0) return Error.Io; // RCODE != 0 (NXDOMAIN, SERVFAIL, …)
    const qd = std.mem.readInt(u16, msg[4..6], .big);
    const an = std.mem.readInt(u16, msg[6..8], .big);

    var off: usize = 12;
    var q: usize = 0;
    while (q < qd) : (q += 1) {
        off = try skipName(msg, off);
        off += 4; // QTYPE + QCLASS
    }
    var a: usize = 0;
    while (a < an) : (a += 1) {
        off = try skipName(msg, off);
        if (off + 10 > msg.len) return Error.Io;
        const rtype = std.mem.readInt(u16, msg[off..][0..2], .big);
        const rdlen = std.mem.readInt(u16, msg[off + 8 ..][0..2], .big);
        off += 10;
        if (off + rdlen > msg.len) return Error.Io;
        if (rtype == 1 and rdlen == 4) {
            out.* = msg[off..][0..4].*;
            return;
        }
        off += rdlen;
    }
    return Error.Io; // no A record in the answer
}

fn dnsSocket() Error!fd_t {
    // Blocking on purpose (see the section note): a bounded SO_RCVTIMEO gives a
    // real timeout without poller machinery.
    const fd = if (is_linux) blk: {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
        if (posix.errno(rc) != .SUCCESS) return Error.Socket;
        break :blk @as(fd_t, @intCast(rc));
    } else blk: {
        const rc = std.c.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        if (rc < 0) return Error.Socket;
        break :blk rc;
    };
    errdefer sched.closeFd(fd);
    const tv: posix.timeval = .{ .sec = dns_timeout_ms / 1000, .usec = (dns_timeout_ms % 1000) * 1000 };
    const tvb = std.mem.asBytes(&tv);
    if (is_linux) {
        if (posix.errno(linux.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, tvb.ptr, tvb.len)) != .SUCCESS) return Error.Socket;
    } else {
        if (std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, tvb.ptr, tvb.len) < 0) return Error.Socket;
    }
    return fd;
}

/// Resolves `host` to an IPv4 address. A dotted quad passes straight through; a
/// hostname is looked up via the first nameserver in /etc/resolv.conf.
pub fn resolve(host: []const u8) Error![4]u8 {
    if (parseIpv4(host)) |ip| return ip;

    var ns: [4]u8 = undefined;
    try firstNameserver(&ns);

    // A fixed transaction id is fine: the socket is connectionless and used for
    // exactly one exchange, so there is nothing to correlate against.
    const id: u16 = 0x1B17;
    var query: [512]u8 = undefined;
    const qlen = try buildQuery(&query, host, id);

    const fd = try dnsSocket();
    defer sched.closeFd(fd);

    const sa = addrIn(ns, 53);
    const salen: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    var attempt: u32 = 0;
    while (attempt < dns_retries) : (attempt += 1) {
        const sent = if (is_linux)
            linux.sendto(fd, &query, qlen, 0, @ptrCast(&sa), salen)
        else
            @as(usize, @bitCast(std.c.sendto(fd, &query, qlen, 0, @ptrCast(&sa), salen)));
        if ((if (is_linux) posix.errno(sent) else posix.errno(@as(isize, @bitCast(sent)))) != .SUCCESS) continue;

        var reply: [512]u8 = undefined;
        const got = if (is_linux)
            linux.recvfrom(fd, &reply, reply.len, 0, null, null)
        else
            @as(usize, @bitCast(std.c.recvfrom(fd, &reply, reply.len, 0, null, null)));
        const e = if (is_linux) posix.errno(got) else posix.errno(@as(isize, @bitCast(got)));
        if (e == .AGAIN or e == .INTR) continue; // timed out or interrupted: retransmit
        if (e != .SUCCESS) return Error.Io;
        const n = if (is_linux) got else @as(usize, @bitCast(got));

        var out: [4]u8 = undefined;
        parseAnswer(reply[0..n], id, &out) catch continue; // malformed/no-answer: retry
        return out;
    }
    return Error.Io;
}

test "buildQuery encodes header and QNAME" {
    var buf: [512]u8 = undefined;
    const n = try buildQuery(&buf, "a.bc", 0x1234);
    // 12 header + [1]'a'[2]'b''c'[0] (6) + QTYPE+QCLASS (4) = 22
    try std.testing.expectEqual(@as(usize, 22), n);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, buf[0..2], .big));
    try std.testing.expectEqual(@as(u16, 0x0100), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 'a', 2, 'b', 'c', 0 }, buf[12..18]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[18..20], .big)); // A
}

test "parseAnswer extracts the first A record past a compressed name" {
    const id: u16 = 0xABCD;
    // Header: id, flags RD+RA rcode 0, qd=1, an=1.
    var msg = [_]u8{0} ** 64;
    std.mem.writeInt(u16, msg[0..2], id, .big);
    std.mem.writeInt(u16, msg[2..4], 0x8180, .big);
    std.mem.writeInt(u16, msg[4..6], 1, .big);
    std.mem.writeInt(u16, msg[6..8], 1, .big);
    // Question at 12: "x" root, A, IN.
    var o: usize = 12;
    msg[o] = 1;
    msg[o + 1] = 'x';
    msg[o + 2] = 0;
    o += 3;
    std.mem.writeInt(u16, msg[o..][0..2], 1, .big);
    std.mem.writeInt(u16, msg[o + 2 ..][0..2], 1, .big);
    o += 4;
    // Answer: compressed name (ptr to 12), type A, class IN, ttl, rdlen 4, 1.2.3.4.
    msg[o] = 0xC0;
    msg[o + 1] = 12;
    o += 2;
    std.mem.writeInt(u16, msg[o..][0..2], 1, .big); // A
    std.mem.writeInt(u16, msg[o + 2 ..][0..2], 1, .big); // IN
    std.mem.writeInt(u32, msg[o + 4 ..][0..4], 300, .big); // TTL
    std.mem.writeInt(u16, msg[o + 8 ..][0..2], 4, .big); // RDLENGTH
    o += 10;
    msg[o] = 1;
    msg[o + 1] = 2;
    msg[o + 2] = 3;
    msg[o + 3] = 4;
    o += 4;

    var out: [4]u8 = undefined;
    try parseAnswer(msg[0..o], id, &out);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, out);
}

test "parseAnswer rejects a mismatched id and a SERVFAIL rcode" {
    var msg = [_]u8{0} ** 12;
    std.mem.writeInt(u16, msg[0..2], 0x1111, .big);
    std.mem.writeInt(u16, msg[4..6], 0, .big);
    var out: [4]u8 = undefined;
    try std.testing.expectError(Error.Io, parseAnswer(&msg, 0x2222, &out)); // id mismatch
    std.mem.writeInt(u16, msg[0..2], 0x2222, .big);
    std.mem.writeInt(u16, msg[2..4], 0x8182, .big); // rcode 2 = SERVFAIL
    try std.testing.expectError(Error.Io, parseAnswer(&msg, 0x2222, &out));
}

test "formatIpv4 round-trips parseIpv4" {
    const cases = [_][]const u8{ "127.0.0.1", "0.0.0.0", "255.255.255.255", "1.2.3.4", "10.0.0.255" };
    for (cases) |c| {
        const ip = parseIpv4(c).?;
        const sa = addrIn(ip, 0);
        var buf: [15]u8 = undefined;
        try std.testing.expectEqualStrings(c, formatIpv4(&sa, &buf));
    }
}
