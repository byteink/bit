//! Abstract syntax tree — index-based, struct-of-arrays (spec/SPEC.md §9–§18).
//!
//! There are no node pointers. Every node lives in one `MultiArrayList` column
//! set and is named by a `u32` index; child links are indices into a single flat
//! `extra` pool. Index `0` is the reserved `.none` sentinel (an absent optional
//! child), so a real node is never index `0`. This layout is the shared contract
//! for the checker, formatter, and LSP: cheap to store, cache-friendly to walk,
//! and trivially serializable.
//!
//! Node shape is uniform: a `tag`, a source `span`, a tag-specific scalar `main`
//! (an operator `lexer.Kind`, or unused), and one contiguous run of child indices
//! `[kids_start, kids_start + kids_len)` in `extra`. Optional children occupy a
//! fixed slot filled with `.none`. Variable-length groups (a block's statements,
//! a call's arguments) are their own list-tagged nodes. Because every child is
//! just an index in `kids`, the s-expression dumper is a single regular walk.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Span = diagnostics.Span;
const Kind = lexer.Kind;

/// Node handle. `none` (0) is the absent-optional-child sentinel.
pub const Index = u32;
pub const none: Index = 0;

pub const Node = struct {
    tag: Tag,
    span: Span,
    /// Tag-specific scalar. For `binary`/`unary`/`assign` it holds the operator
    /// `@intFromEnum(lexer.Kind)`; otherwise unused (0).
    main: u32 = 0,
    /// First child index in `Tree.extra`.
    kids_start: u32 = 0,
    /// Child count.
    kids_len: u32 = 0,
};

pub const Tag = enum {
    /// Reserved sentinel at index 0; never a real node.
    none,

    // ---- leaves: text is the source slice under `span` -------------------
    ident,
    int_lit,
    float_lit,
    string_lit,
    raw_string_lit,
    rune_lit,
    bool_lit,
    nil_lit,
    str_part, // one literal chunk of an interpolated string

    // ---- top level & declarations ----------------------------------------
    program, // [top_decl...]
    import_decl, // [body, path_string]
    import_ns, // [name_ident]         `import io from ...`
    import_star, // [name_ident]         `import * as io from ...`
    import_group, // [import_item...]     `import { a, b as c } from ...`
    import_item, // [name_ident, alias_or_none]
    let_decl, // [binding...]
    const_decl, // [binding...]
    binding, // [pattern, type_or_none, init_or_none]
    tuple_pat, // [pat...]
    type_alias, // [name_ident, generics_or_none, type]
    func_decl, // [recv_or_none, name_ident, generics_or_none, params, result_or_none, body]
    receiver, // [name_ident, type]
    params, // [param...]
    param, // [name_ident, type]
    param_rest, // [name_ident, type]      variadic `...name: T`
    struct_decl, // [name_ident, generics_or_none, field_list]
    field_list, // [field...]
    field, // [name_ident, type]
    interface_decl, // [name_ident, generics_or_none, method_sig_list]
    method_sig_list, // [method_sig...]
    method_sig, // [name_ident, params, result_or_none]
    generic_params, // [generic_param...]
    generic_param, // [name_ident, constraint_or_none]
    constraint, // [type_name...]          interface bounds joined by `&`
    @"export", // [decl]                  visibility wrapper
    fallible, // [type, err_or_none]       result carrying `!`

    // ---- types -----------------------------------------------------------
    slice_type, // [elem_type]
    array_type, // [size_int, elem_type]
    map_type, // [key_type, val_type]
    tuple_type, // [type, type, ...]        two or more
    func_type, // [type_list, result]
    type_list, // [type...]
    chan_type, // [elem_type]
    generic_inst, // [name_ident, type_args]
    type_args, // [type...]

    // ---- statements ------------------------------------------------------
    block, // [statement...]            a lexical scope
    stmt_list, // [statement...]         a case/clause body (no new scope)
    assign, // main=op; [lhs_list, rhs_list]
    lhs_list, // [lhs_expr...]
    expr_list, // [expr...]
    inc_stmt, // [lhs]                   `x++`
    dec_stmt, // [lhs]                   `x--`
    expr_stmt, // [expr]
    send_stmt, // [chan_expr, value_expr] `ch <- v`
    return_stmt, // [expr...]
    fail_stmt, // [expr]
    break_stmt, // []
    continue_stmt, // []
    spawn_stmt, // [call_expr]
    defer_stmt, // [call_expr]
    if_stmt, // [cond, then_block, else_or_none]
    while_stmt, // [cond, body]
    for_c, // [init_or_none, cond_or_none, post_or_none, body]
    for_of, // [binder, iter_expr, body]
    for_in, // [name_ident, iter_expr, body]
    for_inf, // [body]
    switch_stmt, // [subject_or_none, case_list]
    case_list, // [switch_case|switch_default...]
    switch_case, // [expr_list, stmt_list]
    switch_default, // [stmt_list]
    select_stmt, // [comm_case|comm_default...]
    comm_case, // [comm, stmt_list]        comm = send_stmt | recv_bind
    comm_default, // [stmt_list]
    recv_bind, // [binder_or_none, chan_expr]

    // ---- expressions -----------------------------------------------------
    binary, // main=op; [lhs, rhs]
    unary, // main=op; [operand]
    catch_default, // [expr, default_expr]
    catch_bind, // [expr, err_ident, block]
    arrow_fn, // [arrow_params, body]
    arrow_params, // [arrow_p...]
    arrow_p, // [name_ident, type_or_none]
    call, // [callee, type_args_or_none, args]
    args, // [arg|arg_spread...]
    arg, // [expr]
    arg_spread, // [expr]                   `...expr`
    index, // [recv, index_expr]
    slice_expr, // [recv, lo_or_none, hi_or_none]
    member, // [recv, name_ident]           `.name`
    tuple_index, // [recv, int_lit]          `.0`
    type_assert, // [recv, type]             `.(T)`
    try_expr, // [expr]                      postfix `?`
    composite_lit, // [type, init]           init = field_inits|args|map_entries
    field_inits, // [field_init...]
    field_init, // [name_ident, expr]
    map_entries, // [map_entry...]
    map_entry, // [key_expr, val_expr]
    slice_lit, // [arg...]                   bare `[ ... ]`
    str_interp, // [str_part|expr...]        interpolated string
};

/// A parsed tree. Owns its node table and child pool; borrows the source (needed
/// only for rendering leaf text). `deinit` frees the owned storage.
pub const Tree = struct {
    gpa: Allocator,
    nodes: std.MultiArrayList(Node) = .{},
    extra: std.ArrayList(u32) = .empty,
    root: Index = none,

    pub fn init(gpa: Allocator) !Tree {
        var t = Tree{ .gpa = gpa };
        // Reserve index 0 as the `.none` sentinel.
        try t.nodes.append(gpa, .{ .tag = .none, .span = Span.point(@enumFromInt(0), 0) });
        return t;
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        self.* = undefined;
    }

    /// Appends a node whose children are `kids` (copied into `extra`) and returns
    /// its index. `main` is the tag-specific scalar (0 when unused).
    pub fn add(self: *Tree, tag: Tag, span: Span, main: u32, kids: []const Index) !Index {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.gpa, kids);
        const idx: u32 = @intCast(self.nodes.len);
        try self.nodes.append(self.gpa, .{
            .tag = tag,
            .span = span,
            .main = main,
            .kids_start = start,
            .kids_len = @intCast(kids.len),
        });
        return idx;
    }

    /// Convenience for a childless leaf (identifier or literal).
    pub fn addLeaf(self: *Tree, tag: Tag, span: Span) !Index {
        return self.add(tag, span, 0, &.{});
    }

    pub fn get(self: *const Tree, idx: Index) Node {
        return self.nodes.get(idx);
    }

    /// Child indices of `idx` as a slice into the shared pool.
    pub fn kids(self: *const Tree, idx: Index) []const Index {
        const n = self.nodes.get(idx);
        return self.extra.items[n.kids_start .. n.kids_start + n.kids_len];
    }
};

// ---- s-expression dump (golden-test target) -------------------------------

/// Renders the tree rooted at `tree.root` as a single-line s-expression.
/// Leaves print their source text; operator nodes print the operator glyph;
/// every other node prints `(tag child...)`. `.none` children print as `_`.
pub fn dump(gpa: Allocator, tree: *const Tree, source: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dumpNode(&out.writer, tree, source, tree.root, 0);
    return gpa.dupe(u8, out.written());
}

/// Recursion cap mirrors the parser's nesting guard: a well-formed tree from this
/// parser is far shallower, so hitting it means a malformed tree — fail loudly
/// rather than overflow the stack (Power of 10: bounded).
const max_depth = 256;

fn dumpNode(w: *Writer, tree: *const Tree, source: []const u8, idx: Index, depth: u32) !void {
    if (idx == none) {
        try w.writeAll("_");
        return;
    }
    if (depth >= max_depth) return error.TreeTooDeep;
    const n = tree.get(idx);

    // Leaves render as their source text (str_part is quoted so empty chunks show).
    switch (n.tag) {
        .ident, .int_lit, .float_lit, .string_lit, .raw_string_lit, .rune_lit, .bool_lit, .nil_lit => {
            try w.writeAll(source[n.span.start..n.span.end]);
            return;
        },
        .str_part => {
            try w.print("\"{s}\"", .{source[n.span.start..n.span.end]});
            return;
        },
        else => {},
    }

    try w.print("({s}", .{@tagName(n.tag)});
    // Operator-bearing nodes print the glyph right after the tag.
    switch (n.tag) {
        .binary, .unary, .assign => try w.print(" {s}", .{opSymbol(@enumFromInt(n.main))}),
        else => {},
    }
    for (tree.kids(idx)) |child| {
        try w.writeAll(" ");
        try dumpNode(w, tree, source, child, depth + 1);
    }
    try w.writeAll(")");
}

/// Source glyph for an operator token kind (used in dumps and diagnostics).
pub fn opSymbol(k: Kind) []const u8 {
    return switch (k) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .percent => "%",
        .amp => "&",
        .pipe => "|",
        .caret => "^",
        .shl => "<<",
        .shr => ">>",
        .tilde => "~",
        .amp_amp => "&&",
        .pipe_pipe => "||",
        .bang => "!",
        .eq_eq => "==",
        .bang_eq => "!=",
        .lt => "<",
        .lt_eq => "<=",
        .gt => ">",
        .gt_eq => ">=",
        .eq => "=",
        .plus_eq => "+=",
        .minus_eq => "-=",
        .star_eq => "*=",
        .slash_eq => "/=",
        .percent_eq => "%=",
        .amp_eq => "&=",
        .pipe_eq => "|=",
        .caret_eq => "^=",
        .shl_eq => "<<=",
        .shr_eq => ">>=",
        .arrow_left => "<-",
        else => "?",
    };
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "tree reserves node 0 as the none sentinel" {
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.nodes.len);
    try testing.expectEqual(Tag.none, tree.get(none).tag);
}

test "uniform dump: leaves, optional slots, and operators" {
    const gpa = testing.allocator;
    const src = "x1"; // one identifier's worth of text is all the dump needs
    var tree = try Tree.init(gpa);
    defer tree.deinit();

    const id = try tree.addLeaf(.ident, .{ .file = @enumFromInt(0), .start = 0, .end = 2 });
    // (binding x1 _ (unary - x1))  — exercises a leaf, a none slot, and an operator.
    const neg = try tree.add(.unary, .{ .file = @enumFromInt(0), .start = 0, .end = 2 }, @intFromEnum(Kind.minus), &.{id});
    const bind = try tree.add(.binding, .{ .file = @enumFromInt(0), .start = 0, .end = 2 }, 0, &.{ id, none, neg });
    tree.root = bind;

    const got = try dump(gpa, &tree, src);
    defer gpa.free(got);
    try testing.expectEqualStrings("(binding x1 _ (unary - x1))", got);
}
