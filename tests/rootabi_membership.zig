//! ABI-membership gate (#1662), split out of `rootabi.zig` under #1674 — see
//! that file's header for how this relates to the other two runtime-ABI
//! gates. Anchored into the `rootabi.zig` test binary via `_ = @import(...)`
//! there, following this repo's existing anchor idiom (see
//! `tests/testroots.zig`).

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

const shared = @import("rootabi_shared.zig");
const max_source_bytes = shared.max_source_bytes;
const pin_prefix = shared.pin_prefix;
const abi_prefix = shared.abi_prefix;
const SigMap = shared.SigMap;
const collectBitPins = shared.collectBitPins;

// ---------------------------------------------------------------------------
// 3. ABI MEMBERSHIP (#1662)
// ---------------------------------------------------------------------------
//
// G3 drops every `runtime/*.zig` from the build and assembles `libbitrt.a` from
// Bit objects alone, so any `bit_rt_*` symbol only the Zig half defines becomes
// an undefined symbol in EVERY link at that moment. #1641/#1642 added two such
// seams (`bit_rt_unmap_pages`, `bit_rt_oom`) and could only supply the Zig side;
// #1662 added the Bit providers.
//
// This check has now been got wrong TWICE BY HAND, GREEN both times with the
// hole open: the first audit read only `export fn` and missed `bit_rt_safepoint`
// (exported through `comptime { @export(...) }`), which cost a full G3 attempt;
// the second read only `runtime/root.zig` and missed `bit_rt_unmap_pages`
// (`runtime/alloc.zig`), reporting a 1-symbol gap where the real gap was 2. So
// it is gated rather than remembered, over BOTH export forms across EVERY
// `runtime/*.zig`. One-way on purpose: every Zig export needs a Bit provider,
// but a Bit pin with no Zig counterpart is fine — the port-internal
// `bit_rt_port_*` names were never in the ABI.
//
// Read with Zig's own TOKENIZER rather than by regex: `export fn NAME` and the
// `.name = "bit_rt_..."` an `@export` carries are both lexical facts, and the
// tokenizer is the thing that decides where a token ends.
//
// THE SECOND FORM IS MATCHED ON ITS `.name =` PREFIX, NOT ON THE LITERAL ALONE.
// "any `bit_rt_*` string literal is an export name" is the obvious rule and it
// is FALSE — `runtime/root.zig` also contains
// `fatal("bit_rt_string_from_float: float text exceeds buffer")` and a
// `test "bit_rt_gc_alloc: ..."` name. Both were reported as missing providers
// on the first run of this gate. A false positive here is not harmless noise:
// it is an unsatisfiable demand that would push someone to weaken the check.

/// Lower bound on the Zig exports found, against today's 103. Guards the
/// vacuous pass — a scan that finds nothing trivially satisfies a subset test.
const min_zig_abi_symbols = 90;

/// Lower bound on the Bit pins found, against today's 277.
const min_bit_abi_pins = 200;

test "every bit_rt_* symbol runtime/*.zig exports has a Bit provider" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = Io.Threaded.global_single_threaded.io();

    // The Bit side: every `@symbol("bit_rt_...")` under runtime/, with G2's
    // rename applied (`bit_rt_root_x` -> `bit_rt_x`), which is the name the Bit
    // definition claims once #1583 lands.
    var provided = std.StringHashMap(void).init(gpa);
    {
        var pins = SigMap.init(gpa);
        try collectBitPins(gpa, &pins, abi_prefix);
        var it = pins.keyIterator();
        while (it.next()) |k| {
            const n = k.*;
            const abi = if (std.mem.startsWith(u8, n, pin_prefix))
                try std.mem.concat(gpa, u8, &.{ abi_prefix, n[pin_prefix.len..] })
            else
                n;
            try provided.put(abi, {});
        }
    }
    if (provided.count() < min_bit_abi_pins) {
        std.debug.print(
            "rootabi: found only {d} `@symbol(\"bit_rt_*\")` pins under runtime/ " ++
                "(expected at least {d}). The membership check is reading nothing.\n",
            .{ provided.count(), min_bit_abi_pins },
        );
        return error.VacuousBitPinScan;
    }

    // The Zig side: every runtime/*.zig, both export forms.
    var exported = std.StringHashMap([]const u8).init(gpa);
    {
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, "runtime" });
        var dir = try Dir.cwd().openDir(io, abs, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(max_source_bytes));
            const where = try std.fmt.allocPrint(gpa, "runtime/{s}", .{entry.name});
            try collectZigAbiSymbols(gpa, source, where, &exported);
        }
    }
    if (exported.count() < min_zig_abi_symbols) {
        std.debug.print(
            "rootabi: found only {d} `bit_rt_*` exports across runtime/*.zig " ++
                "(expected at least {d}). The membership check is reading nothing — " ++
                "note it must cover BOTH `export fn` and `@export(.{{ .name = ... }})`.\n",
            .{ exported.count(), min_zig_abi_symbols },
        );
        return error.VacuousZigAbiScan;
    }

    var missing: usize = 0;
    var it = exported.iterator();
    while (it.next()) |e| {
        if (provided.contains(e.key_ptr.*)) continue;
        std.debug.print(
            "rootabi: '{s}' is exported by {s} but NO Bit pin provides it. " ++
                "G3 drops that file from the build, at which point this is an " ++
                "undefined symbol in every link. Add a provider pinned " ++
                "`bit_rt_root_{s}` (the `_root` placeholder, NOT the bare name — " ++
                "that is a DuplicateSymbol against the still-live Zig, #1624).\n",
            .{ e.key_ptr.*, e.value_ptr.*, e.key_ptr.*[abi_prefix.len..] },
        );
        missing += 1;
    }
    if (missing != 0) {
        std.debug.print("rootabi: {d} ABI symbol(s) have no Bit provider.\n", .{missing});
        return error.AbiSymbolHasNoBitProvider;
    }
}

/// Every `bit_rt_*` symbol `source` exports, by either form, into `out`
/// (symbol -> the file that exports it).
fn collectZigAbiSymbols(
    gpa: std.mem.Allocator,
    source: []const u8,
    where: []const u8,
    out: *std.StringHashMap([]const u8),
) !void {
    const src = try gpa.allocSentinel(u8, source.len, 0);
    @memcpy(src, source);

    // A three-token lookbehind, which is all either form needs: `export fn
    // NAME` and `. name = "NAME"`. `[0]` is the token immediately before the
    // current one.
    const Seen = struct { tag: std.zig.Token.Tag, text: []const u8 };
    var back = [_]Seen{.{ .tag = .invalid, .text = "" }} ** 3;

    var tz = std.zig.Tokenizer.init(src);
    var guard: usize = 0;
    while (true) {
        guard += 1;
        // Provably bounded (Power of 10 rule 2): a tokenizer emits at most one
        // token per byte plus the final `.eof`.
        if (guard > source.len + 2) return error.TokenizerDidNotTerminate;
        const tok = tz.next();
        if (tok.tag == .eof) break;

        const text = src[tok.loc.start..tok.loc.end];
        switch (tok.tag) {
            .identifier => if (back[0].tag == .keyword_fn and back[1].tag == .keyword_export) {
                if (std.mem.startsWith(u8, text, abi_prefix)) {
                    try out.put(try gpa.dupe(u8, text), where);
                }
            },
            .string_literal => {
                // `.name = "..."`: the literal's span covers the quotes, and an
                // ABI symbol name carries no escapes, so the enclosed slice is
                // the name verbatim.
                const named = back[0].tag == .equal and
                    back[1].tag == .identifier and
                    std.mem.eql(u8, back[1].text, "name") and
                    back[2].tag == .period;
                if (named and text.len >= 2 and text[0] == '"') {
                    const name = text[1 .. text.len - 1];
                    if (std.mem.startsWith(u8, name, abi_prefix)) {
                        try out.put(try gpa.dupe(u8, name), where);
                    }
                }
            },
            else => {},
        }
        back[2] = back[1];
        back[1] = back[0];
        back[0] = .{ .tag = tok.tag, .text = text };
    }
}
