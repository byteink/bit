//! SPEC §11.7's Darwin half of the `extern function` predicate (#1634).
//!
//! On a Linux triple the question "can this symbol be resolved?" has one
//! source of truth — membership in the linked `libbitrt.a` — because the ELF
//! output is fully static and there is nothing else in the image. Darwin has
//! two: the same archive, plus the `/usr/lib/libSystem.B.dylib` every Mac
//! carries, which the Mach-O writer records as `LC_LOAD_DYLIB` and dyld binds
//! at load. §11.7 exists precisely for that second source, since Apple
//! publishes no stable syscall numbers.
//!
//! Before this module the Darwin arm answered "always yes", so a name in
//! NEITHER source built clean and aborted at dyld load — the failure mode this
//! codebase has the worst record with, and the one `emit.firstUnpinnedImport`
//! already names as its own reason to exist. The fix is not to require archive
//! membership (that would reject the whole `runtime/**/darwin/**` surface),
//! but to admit both sources and reject what is in neither.
//!
//! ## Why a table and not the host's dynamic linker
//!
//! `dlsym(RTLD_DEFAULT, name)` would answer exactly this question — for the
//! HOST. The predicate must be a pure function of the TARGET: `bit build
//! --target aarch64-macos` has to give the same verdict from a Linux CI box as
//! from a Mac, and the dyld shared cache is neither present nor readable
//! there. It is also not a file on disk any more: since macOS 11 there is no
//! `/usr/lib/libSystem.B.dylib` to parse, only a host-architecture cache.
//!
//! So the accepted libSystem surface is DATA the compiler carries, the same
//! shape a real toolchain's `.tbd` stub serves. Every name in `libsystem`
//! below was verified to resolve through `dlsym(RTLD_DEFAULT, …)` on
//! aarch64-macOS 25.5 rather than recalled; a name that is genuinely exported
//! and missing here is a one-line addition (in both compilers), and its
//! absence is a clear compile-time diagnostic rather than a crash at launch.

const std = @import("std");
const Allocator = std.mem.Allocator;

const archive = @import("archive.zig");
const macho_reader = @import("macho_reader.zig");

/// True if `symbol` (the undecorated Bit name) is **defined** by some member of
/// the Mach-O `ar` archive `bytes`. The Darwin twin of `link.archiveDefines`,
/// and deliberately the same notion of "defined": a global-binding *atom*, which
/// is what `strip.resolveGlobals` keys the whole-link table on. A member that
/// merely calls the symbol does not define it.
///
/// Mach-O decorates C symbols with a leading underscore, so the archive holds
/// `_bit_rt_map_pages` for the Bit-visible `bit_rt_map_pages`; the decoration is
/// applied here so callers keep passing the source-level name.
///
/// An empty or malformed archive answers **false**, never an error — the same
/// collapse `link.archiveDefines` makes, so "undecidable" stays one caller's
/// decision rather than two.
pub fn archiveDefines(gpa: Allocator, bytes: []const u8, symbol: []const u8) bool {
    if (bytes.len == 0) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const decorated = std.fmt.allocPrint(arena, "_{s}", .{symbol}) catch return false;
    const members = archive.parse(arena, bytes) catch return false;
    for (members) |m| {
        const mod = macho_reader.read(arena, m.name, m.data) catch continue;
        for (mod.atoms) |atom| {
            if (atom.binding != .global) continue;
            if (std.mem.eql(u8, atom.name, decorated)) return true;
        }
    }
    return false;
}

/// True if `symbol` is one of the libSystem exports Bit admits as an
/// `extern function` on Darwin.
///
/// A LINEAR scan, deliberately, even though the table is sorted: the mirror in
/// `selfhost/machosyms.bit` has to compute the identical answer, and Bit's
/// string ordering operators do not work (#1664 — `<` on `string` compares
/// backing-buffer ADDRESSES in the seed and does not lower at all in the
/// self-hosted compiler, so a binary search there silently answers "absent" for
/// every entry). Equality is exact in both languages. The cost is ~200 short
/// `memcmp`s per `extern function` declaration, once per build.
pub fn libsystemDefines(symbol: []const u8) bool {
    for (libsystem) |name| {
        if (std.mem.eql(u8, name, symbol)) return true;
    }
    return false;
}

/// The libSystem export surface Bit admits. Sorted and duplicate-free for
/// readability and for the maintenance test below; the lookup does not depend
/// on the order. Verified against a live `dlsym(RTLD_DEFAULT, …)` on
/// aarch64-macOS, not recalled. `selfhost/machosyms.bit` carries the identical
/// list — extending one means extending the other.
pub const libsystem = [_][]const u8{
    "_NSGetExecutablePath",
    "__error",
    "__ulock_wait",
    "__ulock_wake",
    "_exit",
    "abort",
    "accept",
    "access",
    "arc4random",
    "arc4random_buf",
    "arc4random_uniform",
    "atexit",
    "bind",
    "calloc",
    "chdir",
    "chmod",
    "chown",
    "clock_getres",
    "clock_gettime",
    "close",
    "closedir",
    "connect",
    "creat",
    "dlclose",
    "dlerror",
    "dlopen",
    "dlsym",
    "dup",
    "dup2",
    "execv",
    "execve",
    "execvp",
    "exit",
    "fchdir",
    "fchmod",
    "fchown",
    "fcntl",
    "fdatasync",
    "flock",
    "fork",
    "free",
    "fstat",
    "fstatat",
    "fsync",
    "ftruncate",
    "futimes",
    "getcwd",
    "getegid",
    "getentropy",
    "getenv",
    "geteuid",
    "getgid",
    "gethostname",
    "getitimer",
    "getpagesize",
    "getpeername",
    "getpgrp",
    "getpid",
    "getppid",
    "getpriority",
    "getrlimit",
    "getrusage",
    "getsockname",
    "getsockopt",
    "gettimeofday",
    "getuid",
    "ioctl",
    "isatty",
    "kevent",
    "kevent64",
    "kill",
    "kqueue",
    "lchown",
    "link",
    "listen",
    "lseek",
    "lstat",
    "mach_absolute_time",
    "mach_continuous_time",
    "mach_task_self_",
    "mach_timebase_info",
    "madvise",
    "malloc",
    "malloc_size",
    "memchr",
    "memcmp",
    "memcpy",
    "memmove",
    "memset",
    "mkdir",
    "mkfifo",
    "mkstemp",
    "mlock",
    "mmap",
    "mprotect",
    "mremap_encrypted",
    "msync",
    "munlock",
    "munmap",
    "nanosleep",
    "open",
    "openat",
    "opendir",
    "pathconf",
    "pause",
    "pipe",
    "poll",
    "posix_madvise",
    "posix_memalign",
    "posix_spawn",
    "pread",
    "pthread_attr_destroy",
    "pthread_attr_init",
    "pthread_attr_setdetachstate",
    "pthread_attr_setstacksize",
    "pthread_cond_broadcast",
    "pthread_cond_destroy",
    "pthread_cond_init",
    "pthread_cond_signal",
    "pthread_cond_timedwait",
    "pthread_cond_wait",
    "pthread_create",
    "pthread_detach",
    "pthread_equal",
    "pthread_exit",
    "pthread_get_stackaddr_np",
    "pthread_get_stacksize_np",
    "pthread_getspecific",
    "pthread_join",
    "pthread_key_create",
    "pthread_key_delete",
    "pthread_kill",
    "pthread_mutex_destroy",
    "pthread_mutex_init",
    "pthread_mutex_lock",
    "pthread_mutex_trylock",
    "pthread_mutex_unlock",
    "pthread_once",
    "pthread_self",
    "pthread_setspecific",
    "pthread_sigmask",
    "pthread_threadid_np",
    "pwrite",
    "raise",
    "read",
    "readdir",
    "readdir_r",
    "readlink",
    "readv",
    "realloc",
    "realpath",
    "recv",
    "recvfrom",
    "recvmsg",
    "rename",
    "rmdir",
    "sched_yield",
    "select",
    "send",
    "sendmsg",
    "sendto",
    "setenv",
    "setitimer",
    "setpgid",
    "setpriority",
    "setrlimit",
    "setsid",
    "setsockopt",
    "shutdown",
    "sigaction",
    "sigaddset",
    "sigaltstack",
    "sigdelset",
    "sigemptyset",
    "sigfillset",
    "sigismember",
    "signal",
    "sigprocmask",
    "sigsuspend",
    "sleep",
    "socket",
    "socketpair",
    "stat",
    "strerror",
    "strlen",
    "strncmp",
    "symlink",
    "sync",
    "sysconf",
    "sysctl",
    "sysctlbyname",
    "sysctlnametomib",
    "tcgetattr",
    "tcsetattr",
    "time",
    "truncate",
    "umask",
    "uname",
    "unlink",
    "unlinkat",
    "unsetenv",
    "usleep",
    "utimes",
    "wait",
    "wait4",
    "waitpid",
    "write",
    "writev",
};

test "the libSystem table is sorted and duplicate-free" {
    // Not a correctness precondition of the lookup — a maintenance one. A
    // duplicate or a misfiled name is how the two compilers' copies drift.
    for (libsystem[1..], 1..) |name, i| {
        try std.testing.expect(std.mem.order(u8, libsystem[i - 1], name) == .lt);
    }
    // The cross-language tripwire: `selfhost/machosyms.bit` asserts the same
    // count, so extending one table without the other reddens a test instead of
    // silently making the two compilers disagree about what links.
    try std.testing.expectEqual(@as(usize, 208), libsystem.len);
}

test "libsystemDefines finds every entry and nothing else" {
    // Scored on the whole table, not a sample.
    for (libsystem) |name| try std.testing.expect(libsystemDefines(name));
    try std.testing.expect(!libsystemDefines("definitelyNotInTheRuntimeArchive1234"));
    try std.testing.expect(!libsystemDefines(""));
    // Near-misses of real entries: a prefix/suffix match must not count.
    try std.testing.expect(!libsystemDefines("mmap_"));
    try std.testing.expect(!libsystemDefines("mma"));
    try std.testing.expect(!libsystemDefines("_NSGetExecutablePat"));
    try std.testing.expect(!libsystemDefines("writevv"));
}

test "archiveDefines answers false for an unreadable archive rather than erroring" {
    const gpa = std.testing.allocator;
    try std.testing.expect(!archiveDefines(gpa, "", "mmap"));
    try std.testing.expect(!archiveDefines(gpa, "not an ar archive at all", "mmap"));
}
