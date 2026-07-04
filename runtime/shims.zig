//! The two C-runtime symbols this project's Zig-compiled runtime references
//! but that neither a libc (there is none — `CLAUDE.md`: "zero external
//! toolchain", static binaries with zero runtime dependency) nor compiler-rt
//! supplies: `strlen` and `getauxval`.
//!
//! The classic `memcpy`/`memset`/`memmove` builtins and `__divti3` (128-bit
//! signed division `std`'s checked i128 arithmetic lowers to) come from
//! compiler-rt, bundled into `libbitrt.a` by `build.zig`'s
//! `bundle_compiler_rt = true`. Hand-rolling `memcpy` here would recurse — a
//! naive Zig `memcpy` calls `@memcpy`, which the backend lowers straight back
//! into a `memcpy` call — so we defer to compiler-rt's correct, idiom-safe
//! implementations instead of reimplementing them.
//!
//! `getauxval` reads the REAL auxv this process's kernel handed it at startup,
//! captured once by `root.zig`'s `rtStartMain` into `setTable` below — not a
//! stub returning 0 for everything, since `std.os.linux.tls`'s TLS bootstrap
//! (also wired from `rtStartMain`) and other std-lib startup paths genuinely
//! need real `AT_PHDR`/`AT_PAGESZ`/etc. values, not placeholders.
//!
//! Linux only: this project's Mach-O linker (a later phase) links against the
//! macOS `libbitrt.a`, which is built with PIC and pulls in no such undefined
//! symbols — there is nothing for a Darwin variant of this file to shim.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux) @compileError("runtime/shims.zig is Linux-only — see its module doc comment");
}

// ---------------------------------------------------------------------------
// strlen — a libc symbol, not a compiler-rt one, so compiler-rt cannot supply
// it. `std.mem.len` is a plain sentinel scan; keep an eye on it not being
// idiom-recognized back into a `strlen` call under ReleaseSmall (verified by
// disassembling the built archive — it lowers to an inline scan, not a call).
// ---------------------------------------------------------------------------

export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    return std.mem.len(s);
}

// ---------------------------------------------------------------------------
// getauxval
// ---------------------------------------------------------------------------

/// The real auxv table for this process, captured once by `root.zig`'s
/// `rtStartMain` from the initial stack (standard Linux ABI layout — see
/// that file's doc comment). Null until `setTable` runs; `getauxval` treats
/// "not yet captured" the same as "key absent" (returns 0), matching
/// glibc's own contract for an unrecognized `AT_*` key.
var g_auxv: ?[*]const std.elf.Auxv = null;

/// Called exactly once, by `root.zig`'s `rtStartMain`, before anything else
/// in the runtime can need `getauxval`.
pub fn setTable(table: [*]const std.elf.Auxv) void {
    g_auxv = table;
}

pub fn getauxval(kind: usize) callconv(.c) usize {
    const table = g_auxv orelse return 0;
    var i: usize = 0;
    while (table[i].a_type != std.elf.AT_NULL) : (i += 1) { // bounded: a real auxv is always AT_NULL-terminated
        if (table[i].a_type == kind) return table[i].a_un.a_val;
    }
    return 0;
}

comptime {
    // Export the linker-visible `getauxval` symbol only outside a test build.
    // In a test, the test runner's root declares `main`, so std.os.linux
    // already weak-exports "getauxval" (see its `extern_getauxval` block), and
    // a second export of the same name is a compile-time collision. The real
    // `libbitrt.a` build has no such root `main`, so std stays silent and this
    // strong export is the one the final link resolves against.
    if (!builtin.is_test) @export(&getauxval, .{ .name = "getauxval", .linkage = .strong });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "strlen matches libc semantics" {
    const s: [*:0]const u8 = "hello";
    try testing.expectEqual(@as(usize, 5), strlen(s));
    const empty: [*:0]const u8 = "";
    try testing.expectEqual(@as(usize, 0), strlen(empty));
}

test "getauxval: returns captured value, 0 for unknown key or before capture" {
    g_auxv = null;
    try testing.expectEqual(@as(usize, 0), getauxval(std.elf.AT_PAGESZ));

    const table = [_]std.elf.Auxv{
        .{ .a_type = std.elf.AT_PAGESZ, .a_un = .{ .a_val = 4096 } },
        .{ .a_type = std.elf.AT_NULL, .a_un = .{ .a_val = 0 } },
    };
    setTable(&table);
    defer g_auxv = null;
    try testing.expectEqual(@as(usize, 4096), getauxval(std.elf.AT_PAGESZ));
    try testing.expectEqual(@as(usize, 0), getauxval(std.elf.AT_PHDR));
}
