//! `bit doc` — the public surface of a module, straight from the checker (#356).
//!
//! Documentation drifts. A hand-maintained list of "what `std/strings` exports"
//! is wrong the moment somebody adds an export and forgets the page. So the list
//! is not maintained: it is *derived*, from the same `exports` table the resolver
//! builds and the same signatures the checker infers.
//!
//! Two consumers, one implementation:
//!
//!   - `bit doc --json <dir>` prints it, for tooling and for humans.
//!   - `tests/stdlib_docs.zig` diffs it against `docs/stdlib/*.md` and fails the
//!     build when an exported symbol has no documentation.
//!
//! Methods are reported against their receiver (`File.readAll`), because that is
//! how they are called and how a reader looks them up.

const std = @import("std");
const Io = std.Io;

const check = @import("check.zig");
const diagnostics = @import("diagnostics.zig");
const resolve = @import("resolve.zig");

const Allocator = std.mem.Allocator;

/// Upper bound on symbols reported for one module — keeps the walk provably
/// bounded (Power of 10). A stdlib module nowhere near approaches it.
const max_symbols = 1024;

pub const Kind = enum {
    function,
    method,
    constant,
    @"struct",
    @"enum",
    interface,
    type_alias,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .function => "function",
            .method => "method",
            .constant => "const",
            .@"struct" => "struct",
            .@"enum" => "enum",
            .interface => "interface",
            .type_alias => "type",
        };
    }
};

pub const Symbol = struct {
    /// Bare name (`toUpper`), or `Receiver.name` for a method (`File.readAll`).
    name: []const u8,
    kind: Kind,
    /// Rendered type: `(string) => string` for a function, `int` for a constant,
    /// the type's own name for a declaration.
    type_text: []const u8,
};

/// A module's exported symbols, sorted by name. Owns every string it hands out.
pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    symbols: []Symbol,

    pub fn deinit(self: *Doc) void {
        self.arena.deinit();
    }
};

fn lessByName(_: void, a: Symbol, b: Symbol) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Loads and checks the module rooted at `root_abs`, then reports what it
/// exports. Returns null if it does not compile; diagnostics go to `err_out`.
pub fn moduleDoc(
    gpa: Allocator,
    io: Io,
    root_abs: []const u8,
    std_root: ?[]const u8,
    err_out: *Io.Writer,
) !?Doc {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var project = try resolve.loadProject(gpa, io, &diags, &sm, root_abs, std_root, .{});
    defer project.deinit();
    if (diags.hasErrors()) return try renderNull(&diags, err_out);

    var ctx = try check.TypeContext.init(gpa);
    defer ctx.deinit();

    const n = project.modules.items.len;
    const checked = try gpa.alloc(check.CheckedModule, n);
    var built: usize = 0;
    defer {
        for (checked[0..built]) |*c| c.deinit();
        gpa.free(checked);
    }
    for (0..n) |i| {
        checked[i] = try check.checkModule(gpa, &diags, &ctx, project.module_files.items[i], &project.modules.items[i], @enumFromInt(i), project.modules.items, false);
        built += 1;
        if (diags.hasErrors()) return try renderNull(&diags, err_out);
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = project.root;
    const rmod = &project.modules.items[@intFromEnum(root)];
    const nc: check.NameCtx = .{
        .gpa = a,
        .ctx = &ctx,
        .module_id = root,
        .module = rmod,
        .all_modules = project.modules.items,
    };

    var out: std.ArrayList(Symbol) = .empty;
    errdefer out.deinit(a);

    var it = rmod.exports.iterator();
    while (it.next()) |e| {
        if (out.items.len >= max_symbols) break;
        const sid = e.value_ptr.*;
        const gs: check.GlobalSymbol = .{ .module = root, .id = sid };
        const sym = rmod.symbols.items[@intFromEnum(sid)];
        const name = try a.dupe(u8, e.key_ptr.*);

        switch (sym.kind) {
            .func => {
                const shape = ctx.func_sigs.get(gs.pack()) orelse continue;
                const fty = try ctx.funcType(shape);
                try out.append(a, .{ .name = name, .kind = .function, .type_text = try check.describeType(nc, fty) });
            },
            .const_binding => {
                const ty = ctx.const_types.get(gs.pack()) orelse continue;
                try out.append(a, .{ .name = name, .kind = .constant, .type_text = try check.describeType(nc, ty) });
            },
            .struct_type, .interface_type, .enum_type, .type_alias => {
                const ty = ctx.decl_memo.get(gs.pack()) orelse continue;
                const kind: Kind = switch (sym.kind) {
                    .struct_type => .@"struct",
                    .interface_type => .interface,
                    .enum_type => .@"enum",
                    else => .type_alias,
                };
                try out.append(a, .{ .name = name, .kind = kind, .type_text = try check.describeType(nc, ty) });
                try appendMethods(a, &ctx, nc, &out, name, ty);
            },
            else => {},
        }
    }

    const symbols = try out.toOwnedSlice(a);
    std.mem.sort(Symbol, symbols, {}, lessByName);
    return .{ .arena = arena, .symbols = symbols };
}

/// A receiver's *exported* methods, reported as `Recv.name`. A method set also
/// holds the type's private methods — interface satisfaction needs them — and
/// those are no part of a module's public surface. Bounded by the bucket size.
fn appendMethods(
    a: Allocator,
    ctx: *check.TypeContext,
    nc: check.NameCtx,
    out: *std.ArrayList(Symbol),
    recv_name: []const u8,
    recv: check.TypeId,
) !void {
    const bucket = ctx.methodsOf(recv) orelse return;
    var it = bucket.iterator();
    while (it.next()) |m| {
        if (out.items.len >= max_symbols) return;
        const method = m.value_ptr.*;
        if (!method.exported) continue;
        const fty = try ctx.funcType(.{ .params = method.params, .variadic = method.variadic, .result = method.result });
        try out.append(a, .{
            .name = try std.fmt.allocPrint(a, "{s}.{s}", .{ recv_name, method.name }),
            .kind = .method,
            .type_text = try check.describeType(nc, fty),
        });
    }
}

fn renderNull(diags: *diagnostics.Diagnostics, err_out: *Io.Writer) !?Doc {
    try diags.renderAll(err_out);
    return null;
}

/// A rendered type never contains a control character, but it can contain `"`
/// (never today) and `\` — escape both rather than rely on that staying true.
fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// One JSON object per line is deliberate: `bit doc --json | grep` works, and a
/// diff of two dumps is a diff of the symbols that changed.
pub fn writeJson(doc: Doc, w: *Io.Writer) !void {
    try w.writeAll("[\n");
    for (doc.symbols, 0..) |s, i| {
        try w.writeAll("  {\"name\": ");
        try writeJsonString(w, s.name);
        try w.writeAll(", \"kind\": ");
        try writeJsonString(w, s.kind.text());
        try w.writeAll(", \"type\": ");
        try writeJsonString(w, s.type_text);
        try w.writeAll("}");
        if (i + 1 < doc.symbols.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("]\n");
}
