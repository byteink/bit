//! Parsing helpers shared by the three runtime-ABI gates (`rootabi.zig`,
//! `rootabi_pollfree.zig`, `rootabi_membership.zig`). Split out of a single
//! 955-line `rootabi.zig` under #1674 — see that file's header for what each
//! gate proves; this file carries only the two things more than one gate
//! reads: a parsed `runtime/*.bit` pin (`collectBitPins` and its helpers) and
//! the shared bounds/prefixes both the register-class and ABI-membership
//! gates key their scans on.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on a single source file this gate will read. `runtime/root.zig`
/// is the largest at ~60 KiB.
pub const max_source_bytes = 1 << 22;

/// The ABI prefix a ported runtime symbol will claim when #1369/G2 drops the
/// `_root` infix. Mirrors `tests/rootpins.zig`'s rename.
pub const pin_prefix = "bit_rt_root_";
pub const abi_prefix = "bit_rt_";

/// Upper bound on the runtime source files walked — keeps the walk provably
/// bounded (Power of 10 rule 2). An order of magnitude above today's ~130.
pub const max_bit_files = 1024;

pub const Sig = struct {
    /// Type expressions, in declaration order. Owned by the caller's arena.
    params: []const []const u8,
    /// The result type expression; `"void"` when the declaration names none.
    ret: []const u8,
    /// Where the declaration lives, for the failure message.
    where: []const u8,
};

pub const SigMap = std.StringHashMap(Sig);

/// Reads every `@symbol("<prefix>*")`-pinned function under `runtime/` with the
/// seed's own Bit parser. `prefix` is `pin_prefix` for the register-class gate
/// (which compares against `root.zig`'s post-rename names) and `abi_prefix` for
/// the membership gate (which wants every pin, port-internal ones included).
pub fn collectBitPins(gpa: std.mem.Allocator, out: *SigMap, prefix: []const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const root = try std.fs.path.join(gpa, &.{ build_options.repo_root, "runtime" });
    var dir = try Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".bit")) continue;
        files += 1;
        if (files > max_bit_files) return error.TooManyRuntimeFiles;

        const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_source_bytes));
        const rel = try std.fs.path.join(gpa, &.{ "runtime", entry.path });
        try collectPinsInFile(gpa, out, rel, source, prefix);
    }
}

fn collectPinsInFile(
    gpa: std.mem.Allocator,
    out: *SigMap,
    rel: []const u8,
    source: []const u8,
    prefix: []const u8,
) !void {
    const d = bit.diagnostics;
    var sm = d.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(rel, source);

    var diags = d.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var tree = try bit.ast.Tree.init(gpa);
    defer tree.deinit();
    try bit.parser.parse(gpa, &tree, &diags, file, source);
    if (diags.hasErrors()) {
        std.debug.print("rootabi: '{s}' does not parse as Bit.\n", .{rel});
        return error.BitParseFailed;
    }

    // `func_decl` kids: [recv, name, generics, params, result, body, attrs].
    const kid_params = 3;
    const kid_result = 4;
    const kid_attrs = 6;

    for (tree.kids(tree.root)) |top| {
        // Every pin is exported, and `export` is a wrapper node ([decl]) rather
        // than a flag on the declaration — so the `func_decl` is one level down.
        // Missing this is what made the first cut of this gate find 2 pins
        // instead of 112; the `min_bit_pins` floor is what surfaced it.
        const decl = if (tree.get(top).tag == .@"export") blk: {
            const wrapped = tree.kids(top);
            if (wrapped.len != 1) continue;
            break :blk wrapped[0];
        } else top;
        if (tree.get(decl).tag != .func_decl) continue;
        const kids = tree.kids(decl);
        if (kids.len <= kid_attrs) continue;

        const name = pinSymbol(&tree, source, kids[kid_attrs]) orelse continue;
        if (!std.mem.startsWith(u8, name, prefix)) continue;

        var params: std.ArrayList([]const u8) = .empty;
        if (kids[kid_params] != bit.ast.none) {
            for (tree.kids(kids[kid_params])) |p| {
                const pk = tree.kids(p);
                // `param` kids: [name_ident, type]. A parameter with no written
                // type cannot reach a pin (§11.9 requires full annotation), so
                // treat its absence as a gate failure rather than skipping it.
                if (pk.len < 2) return error.UnexpectedParamShape;
                try params.append(gpa, nodeText(&tree, source, pk[1]));
            }
        }

        const ret = if (kids[kid_result] != bit.ast.none)
            nodeText(&tree, source, kids[kid_result])
        else
            "void";

        try out.put(try gpa.dupe(u8, name), .{
            .params = params.items,
            .ret = ret,
            .where = try gpa.dupe(u8, rel),
        });
    }
}

/// The string literal of a `@symbol("...")` attribute in `attrs`, or null when
/// the declaration carries no such attribute.
fn pinSymbol(tree: *const bit.ast.Tree, source: []const u8, attrs: bit.ast.Index) ?[]const u8 {
    if (attrs == bit.ast.none) return null;
    for (tree.kids(attrs)) |a| {
        if (tree.get(a).tag != .attr) continue;
        const ak = tree.kids(a);
        // `attr` kids: [name_ident, arg_string_lit?]. `@naked`/`@nosplit` have
        // no argument.
        if (ak.len < 2) continue;
        if (!std.mem.eql(u8, nodeText(tree, source, ak[0]), "symbol")) continue;
        const lit = nodeText(tree, source, ak[1]);
        // The span covers the quotes; the symbol is what they enclose. Bit's
        // ABI symbols contain no escapes, so the slice is the name verbatim.
        if (lit.len < 2 or lit[0] != '"' or lit[lit.len - 1] != '"') return null;
        return lit[1 .. lit.len - 1];
    }
    return null;
}

pub fn nodeText(tree: *const bit.ast.Tree, source: []const u8, idx: bit.ast.Index) []const u8 {
    const span = tree.get(idx).span;
    return source[span.start..span.end];
}
