//! Canonical formatter (`bitc fmt`): AST -> source text, gofmt philosophy —
//! one true style, zero configuration, idempotent (spec/SPEC.md §9-§18 is the
//! grammar this mirrors; see ast.zig's Tag doc comments for child order).
//!
//! Style choices (there is exactly one, by design):
//!   * 2-space indent (TypeScript-flavored syntax; gofmt's tab doesn't fit
//!     the "easy to write" pillar as cleanly as the common TS convention).
//!   * Trailing `;` is omitted wherever the lexer's automatic-semicolon
//!     insertion (§7) would supply one — i.e. when the statement's last token
//!     is an ASI "terminator" (lexer.isTerminator) — and kept only where ASI
//!     would NOT fire (e.g. a statement ending in a generic type's `>` or a
//!     bare `!` result type). This matches the semicolon-free house style of
//!     the sample corpus while keeping re-parsing byte-exact.
//!   * A brace block whose sole content is one simple statement prints inline
//!     as `{ stmt }` at the two spots the house style keeps compact — match-arm
//!     bodies and function bodies — but never for control-flow bodies (if /
//!     while / for always stack). A comment inside the braces forces the
//!     multi-line form so it can't be swallowed.
//!   * Struct/interface/import bodies always print with commas (the source
//!     may use `;`, commaList accepts either) — one separator, not two.
//!   * Arrow function parameters always print parenthesized, even when
//!     written as a bare `x => ...` — both forms parse to the identical
//!     `arrow_params` shape (parser.zig's parseExpression bare-ident case),
//!     so this is a lossless canonicalization, and it sidesteps a bare arrow
//!     ever needing to be re-parenthesized when it appears as a call callee.
//!
//! Comments are trivia the lexer discards (lexer.zig skipLineComment /
//! skipBlockComment never emit a token for them), so they're re-derived by a
//! second, independent pass that re-lexes the same source and scans the byte
//! gaps *between* consecutive real tokens for `//`/`/*`. A gap between two
//! tokens is, by the lexer's own contract, pure trivia — it can never contain
//! string/rune content — so this can't misfire on a string literal like
//! `"a // b"`. That keeps the formatter fully self-contained: no sink needs
//! threading through the shared, heavily-tested lexer.
//!
//! Every comment is guaranteed to eventually print (verified by the golden
//! corpus test: comment count in == out) because the outermost container
//! (`program`) does a final sweep from the last token to end-of-file. Exact
//! *position* is only best-effort for a comment buried inside a single
//! expression with no enclosing list (e.g. between a binary operator and its
//! right operand) — it surfaces at the next statement/list boundary instead
//! of exactly inline. Real-world comments overwhelmingly sit between
//! statements, declarations, or list items, where placement is exact.
//!
//! ponytail: expression wrapping is greedy and width-aware (render flat,
//! fall back to one-item-per-line if it doesn't fit or a comment forces the
//! break) — not a Wadler-style pretty printer. Upgrade path if real-world
//! output quality disappoints (task #333's own note).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

const Span = diagnostics.Span;
const FileId = diagnostics.FileId;
const Kind = lexer.Kind;
const Index = ast.Index;
const none = ast.none;

/// Columns after which a bracketed list wraps one item per line.
const max_width: u32 = 100;
/// Spaces per indent level.
const indent_width: u32 = 2;
/// Recursion cap mirrors ast.dump's: a well-formed tree from this parser is
/// far shallower, so hitting it means a malformed tree, not deep real input.
const max_depth: u32 = 256;

// =============================================================================
// Comments
// =============================================================================

const Comment = struct {
    span: Span,
    kind: enum { line, block },
};

/// Re-derives every comment in `source` by re-lexing it and scanning the byte
/// gap between each pair of consecutive real tokens (see the file header for
/// why that's safe). Bounded by source length: each outer iteration consumes
/// at least one token or reaches `eof`. Caller owns the returned slice.
pub fn collectComments(gpa: Allocator, source: []const u8) ![]Comment {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("<fmt>", source);
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    var lx = lexer.Lexer.init(file, source, &diags);
    var comments: std.ArrayList(Comment) = .empty;
    errdefer comments.deinit(gpa);

    var prev_end: u32 = 0;
    while (true) {
        const tok = try lx.next();
        try scanGap(gpa, &comments, file, source, prev_end, tok.span.start);
        if (tok.kind == .eof) break;
        prev_end = tok.span.end;
    }
    return comments.toOwnedSlice(gpa);
}

/// Scans `source[from..to]` — a trivia-only gap between two real tokens — for
/// line and block comments, appending each in source order. Bounded by the
/// gap length.
fn scanGap(gpa: Allocator, out: *std.ArrayList(Comment), file: FileId, source: []const u8, from: u32, to: u32) !void {
    var i = from;
    while (i < to) {
        if (source[i] == '/' and i + 1 < to and source[i + 1] == '/') {
            const start = i;
            i += 2;
            while (i < to and source[i] != '\n') i += 1;
            try out.append(gpa, .{ .span = .{ .file = file, .start = start, .end = i }, .kind = .line });
        } else if (source[i] == '/' and i + 1 < to and source[i + 1] == '*') {
            const start = i;
            i += 2;
            while (i + 1 < to and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i = @min(i + 2, to);
            try out.append(gpa, .{ .span = .{ .file = file, .start = start, .end = i }, .kind = .block });
        } else {
            i += 1;
        }
    }
}

/// Newlines strictly within `source[a..b]` — used to decide "same source
/// line" (0) and "blank line present" (>= 2). Bounded by `b - a`. Returns 0
/// when `a >= b`: a `match` (or any statement-shaped node) in expression
/// position can leave `src_pos` ahead of a later node's `span.start` (width
/// measurement via `renderFlat` advances `src_pos` without restoring it), and
/// a backwards range has no forward gap to preserve.
fn newlinesBetween(source: []const u8, a: u32, b: u32) u32 {
    if (a >= b) return 0;
    var n: u32 = 0;
    for (source[a..b]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Operator precedence table for re-parenthesization (must match
/// parser.zig's `precedenceOf` exactly — both encode spec/SPEC.md §12).
fn precedence(k: Kind) u8 {
    return switch (k) {
        .star, .slash, .percent, .shl, .shr, .amp => 6,
        .plus, .minus, .pipe, .caret => 5,
        .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => 4,
        .amp_amp => 3,
        .pipe_pipe => 2,
        else => 0,
    };
}

// =============================================================================
// Printer
// =============================================================================

const FmtError = Allocator.Error || Writer.Error || error{TreeTooDeep};

const Printer = struct {
    gpa: Allocator,
    source: []const u8,
    /// The source's file id and a diagnostics sink — only used to re-lex a
    /// statement's last token in `endsInTerminator` (the tree is already valid,
    /// so this lexing never actually reports).
    file: FileId,
    diags: *diagnostics.Diagnostics,
    tree: *const ast.Tree,
    w: *Writer,
    comments: []const Comment,
    ci: usize = 0,
    indent: u32 = 0,
    col: u32 = 0,
    /// True at the start of a fresh output line: the indent for it has not
    /// been written yet (written lazily, by `raw`, once real content is
    /// about to land on the line — see `printCommaList`'s closing brace for
    /// why this needs to be lazy rather than eager).
    bol: bool = true,
    /// Source byte offset just after the last real token or comment emitted.
    src_pos: u32 = 0,
    depth: u32 = 0,
    /// One-shot hint set by a caller that, before dispatching into a
    /// bracketed list via generic `printNode`, knows exactly how many
    /// characters of fixed content will follow that list's closing bracket
    /// on the same line (e.g. func_decl's `: ReturnType {` after its params)
    /// — `printCommaList` folds this into its own width check and then
    /// resets it, so it never leaks into an unrelated list. Zero means "no
    /// known tail", the greedy-v1 default everywhere else.
    next_list_tail: u32 = 0,

    fn kids(self: *const Printer, idx: Index) []const Index {
        return self.tree.kids(idx);
    }

    // ---- low-level output ---------------------------------------------

    fn raw(self: *Printer, text: []const u8) FmtError!void {
        if (text.len == 0) return;
        if (self.bol) {
            self.bol = false;
            var written: u32 = 0;
            const total = self.indent * indent_width;
            while (written < total) : (written += 1) try self.w.writeByte(' ');
            self.col = total;
        }
        try self.w.writeAll(text);
        if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| {
            self.col = @intCast(text.len - nl - 1);
        } else {
            self.col += @intCast(text.len);
        }
    }

    fn newline(self: *Printer) FmtError!void {
        try self.w.writeByte('\n');
        self.col = 0;
        self.bol = true;
    }

    fn hasCommentBefore(self: *const Printer, end: u32) bool {
        return self.ci < self.comments.len and self.comments[self.ci].span.start < end;
    }

    /// Flushes every comment starting before `next_start` (placed trailing on
    /// the current line if contiguous with the last real content, else on
    /// its own line — with one blank line preserved when `allow_blank`), then
    /// ensures the cursor is on a fresh line ready for whatever comes next.
    fn gap(self: *Printer, next_start: u32, allow_blank: bool) FmtError!void {
        while (self.ci < self.comments.len and self.comments[self.ci].span.start < next_start) {
            const c = self.comments[self.ci];
            const same_line = !self.bol and newlinesBetween(self.source, self.src_pos, c.span.start) == 0;
            if (same_line) {
                try self.raw(" ");
            } else {
                if (!self.bol) try self.newline();
                if (allow_blank and newlinesBetween(self.source, self.src_pos, c.span.start) >= 2) try self.newline();
            }
            try self.raw(self.source[c.span.start..c.span.end]);
            self.src_pos = c.span.end;
            self.ci += 1;
            if (c.kind == .line) try self.newline(); // nothing can follow a line comment on its line
        }
        if (!self.bol) try self.newline();
        if (allow_blank and newlinesBetween(self.source, self.src_pos, next_start) >= 2) try self.newline();
    }

    /// Renders `idx` flat into a freshly allocated buffer without touching
    /// real output, so a caller can measure exact width before deciding how
    /// something *earlier* on the line should wrap. This is the only render
    /// of `idx` that happens — comments and `src_pos` advance for real — so
    /// the caller must reuse the returned text as its actual output (`raw`
    /// it directly) rather than calling `printNode(idx)` again. Caller owns
    /// the returned slice.
    fn renderFlat(self: *Printer, idx: Index) FmtError![]u8 {
        const col_before = self.col;
        var scratch: Writer.Allocating = .init(self.gpa);
        const saved_w = self.w;
        self.w = &scratch.writer;
        self.printNode(idx) catch |e| {
            self.w = saved_w;
            self.col = col_before;
            scratch.deinit();
            return e;
        };
        self.w = saved_w;
        self.col = col_before;
        return scratch.toOwnedSlice();
    }

    // ---- node dispatch ---------------------------------------------------

    fn printNode(self: *Printer, idx: Index) FmtError!void {
        if (idx == none) return;
        if (self.depth >= max_depth) return error.TreeTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        const n = self.tree.get(idx);
        try self.dispatch(idx, n);
        if (n.span.end > self.src_pos) self.src_pos = n.span.end;
    }

    /// A postfix chain's receiver (member/index/call/slice/tuple-index/type-
    /// assert/try) or a spawn/defer operand: atomic per the postfix grammar
    /// unless parens made it a binary/unary/catch/arrow underneath (see the
    /// file header — parsePostfix/parsePrimary only reach those via explicit
    /// source parens), in which case they must be re-added to preserve
    /// meaning.
    fn printAtomic(self: *Printer, idx: Index) FmtError!void {
        const wrap = switch (self.tree.get(idx).tag) {
            .binary, .unary, .catch_default, .catch_bind, .arrow_fn => true,
            else => false,
        };
        if (wrap) {
            try self.raw("(");
            try self.printNode(idx);
            try self.raw(")");
        } else try self.printNode(idx);
    }

    /// `catch`'s left operand: only catch/arrow need re-parenthesizing there
    /// (its lhs comes from `parseBinary` directly, so a bare binary is
    /// already exactly what the grammar expects).
    fn printCatchLhs(self: *Printer, idx: Index) FmtError!void {
        const wrap = switch (self.tree.get(idx).tag) {
            .catch_default, .catch_bind, .arrow_fn => true,
            else => false,
        };
        if (wrap) {
            try self.raw("(");
            try self.printNode(idx);
            try self.raw(")");
        } else try self.printNode(idx);
    }

    /// A comma-free, delimiter-free list (return values, assignment sides,
    /// `case` expressions, interface constraint bounds): always flat. These
    /// never wrap — see the file header on ASI: a `kw_return` immediately
    /// followed by a newline auto-terminates as a bare `return`, so a
    /// wrapped return value list would silently change meaning. Long lists
    /// here are rare enough in practice that always-flat is the simpler and
    /// safer choice.
    fn printFlatList(self: *Printer, items: []const Index, sep: []const u8) FmtError!void {
        for (items, 0..) |it, i| {
            if (i > 0) try self.raw(sep);
            try self.printNode(it);
        }
    }

    /// A bracketed comma list (params, args, struct fields, generics, ...).
    /// Greedy width-aware wrapping: render flat into a scratch buffer; if it
    /// contains no comment and fits the remaining width, keep it, else
    /// re-render one item per line with a trailing comma. `{`/`}` pad with an
    /// inner space when flat (matching the language's own sample source);
    /// every other bracket kind does not.
    fn printCommaList(self: *Printer, items: []const Index, open: []const u8, close: []const u8, span_end: u32) FmtError!void {
        const tail = self.next_list_tail;
        self.next_list_tail = 0;
        try self.raw(open);
        const pad = open.len == 1 and open[0] == '{';

        if (items.len == 0) {
            if (self.hasCommentBefore(span_end)) {
                self.indent += 1;
                try self.gap(span_end, false);
                self.indent -= 1;
            }
            try self.raw(close);
            return;
        }

        if (!self.hasCommentBefore(span_end)) {
            const col_before = self.col; // `raw` keeps mutating self.col during the trial below
            var scratch: Writer.Allocating = .init(self.gpa);
            defer scratch.deinit();
            const saved_w = self.w;
            self.w = &scratch.writer;
            for (items, 0..) |it, i| {
                if (i > 0) self.raw(", ") catch |e| {
                    self.w = saved_w;
                    return e;
                };
                self.printNode(it) catch |e| {
                    self.w = saved_w;
                    return e;
                };
            }
            self.w = saved_w;
            self.col = col_before; // undo the trial's (scratch-target) mutation either way
            const text = scratch.written();
            const extra: usize = if (pad) 2 else 0;
            if (std.mem.indexOfScalar(u8, text, '\n') == null and
                @as(usize, col_before) + extra + text.len + close.len + tail <= max_width)
            {
                if (pad) try self.raw(" ");
                try self.raw(text);
                if (pad) try self.raw(" ");
                try self.raw(close);
                return;
            }
        }

        self.indent += 1;
        for (items) |it| {
            try self.gap(self.tree.get(it).span.start, false);
            try self.printNode(it);
            try self.raw(",");
        }
        try self.gap(span_end, false);
        self.indent -= 1;
        try self.raw(close);
    }

    /// True for a statement/declaration whose canonical form always ends in
    /// a block's closing `}` (func/struct/interface decls, every control-flow
    /// statement): conventionally printed with no trailing `;`, and safe
    /// without one since `r_brace` is already an ASI terminator (lexer.zig
    /// `isTerminator`). Everything else gets an explicit `;` — see the file
    /// header for why fmt doesn't lean on ASI in general.
    fn endsInBlock(self: *const Printer, idx: Index) bool {
        return switch (self.tree.get(idx).tag) {
            .block, .func_decl, .struct_decl, .interface_decl, .enum_decl, .if_stmt, .while_stmt, .for_c, .for_of, .for_in, .for_inf, .switch_stmt, .select_stmt, .match_stmt => true,
            .@"export" => self.endsInBlock(self.tree.kids(idx)[0]),
            else => false,
        };
    }

    /// Whether `idx`'s canonical form ends in a token after which ASI (§7,
    /// `lexer.isTerminator`) inserts a semicolon — so an explicit `;` can be
    /// omitted and the text still re-parses identically. The last token kind is
    /// invariant under canonicalization (which only rewrites separators,
    /// spacing, and parens *within* a construct, never its final token), so
    /// reading it from the source span is sound. Bounded by the span length.
    fn endsInTerminator(self: *const Printer, idx: Index) bool {
        const span = self.tree.get(idx).span;
        if (span.end <= span.start) return false;
        var lx = lexer.Lexer.init(self.file, self.source[span.start..span.end], self.diags);
        var last: Kind = .eof;
        var guard: u32 = 0;
        const bound = span.end - span.start + 1;
        while (guard < bound) : (guard += 1) {
            const tok = lx.next() catch return false;
            if (tok.kind == .eof) break;
            last = tok.kind;
        }
        // The lexer itself synthesizes a `.semicolon` at end-of-input after a
        // terminator (its own ASI, §7) — so a trailing synthesized `;` is the
        // definitive signal that ASI would fire and the explicit one is
        // redundant. Fall back to the raw terminator check for safety.
        return last == .semicolon or lexer.isTerminator(last);
    }

    /// A `{ stmt }` block that canonicalizes onto one line: exactly one child,
    /// that child is itself a simple statement (not a block or control-flow,
    /// which must stack), and no comment sits inside the braces (a comment
    /// forces the break so it can never be swallowed). The two callers —
    /// match-arm and function bodies — decide *where* inlining is allowed; the
    /// house style never inlines control-flow bodies.
    fn blockInlineable(self: *const Printer, idx: Index) bool {
        const items = self.kids(idx);
        if (items.len != 1) return false;
        if (self.endsInBlock(items[0])) return false;
        return !self.hasCommentBefore(self.tree.get(idx).span.end);
    }

    /// Prints a body that is either a `.block` (collapsed to `{ stmt }` when
    /// `blockInlineable`, else stacked) or, for a braceless match arm, a bare
    /// statement. Used only at the match-arm and function-body sites.
    fn printBodyBlock(self: *Printer, idx: Index) FmtError!void {
        const n = self.tree.get(idx);
        if (n.tag == .block and self.blockInlineable(idx)) {
            try self.raw("{ ");
            try self.printNode(self.kids(idx)[0]);
            try self.raw(" }");
            if (n.span.end > self.src_pos) self.src_pos = n.span.end;
            return;
        }
        try self.printNode(idx);
    }

    /// Like `printSeq`, but never keeps a blank line before the *first* item.
    /// Used for `switch`/`select` clause lists (no blank after the opening `{`)
    /// and `case`/`default` clause bodies (no blank after the `:` label): the
    /// opener and the first item land on adjacent lines, and preserving a source
    /// blank there is both unwanted and non-idempotent (a second pass re-reads
    /// the kept blank as a paragraph break and would grow another).
    fn printNoLeadBlank(self: *Printer, items: []const Index, stmt_style: bool) FmtError!void {
        for (items, 0..) |it, i| {
            try self.gap(self.tree.get(it).span.start, i != 0);
            try self.printNode(it);
            if (stmt_style and !self.endsInBlock(it) and !self.endsInTerminator(it)) try self.raw(";");
        }
    }

    /// Statement/declaration sequence (program top decls, block statements,
    /// case bodies): one per line, one blank line preserved from the source.
    /// `stmt_style` selects a trailing `;` per `endsInBlock` above; `case`/
    /// `select` clause lists pass `false`: there's no separator between
    /// clauses at all.
    fn printSeq(self: *Printer, items: []const Index, stmt_style: bool) FmtError!void {
        for (items) |it| {
            try self.gap(self.tree.get(it).span.start, true);
            try self.printNode(it);
            if (stmt_style and !self.endsInBlock(it) and !self.endsInTerminator(it)) try self.raw(";");
        }
    }

    fn printBlock(self: *Printer, idx: Index, n: ast.Node) FmtError!void {
        const items = self.kids(idx);
        try self.raw("{");
        if (items.len == 0 and !self.hasCommentBefore(n.span.end)) {
            try self.raw("}");
            return;
        }
        self.indent += 1;
        // No blank line is kept right after `{` (gofmt strips it). Besides being
        // the one true style, this is what makes a block idempotent when its `{`
        // lands on its own line — e.g. a `case X: { … }` clause body, where the
        // opener and the first statement are separated by the `:` label line.
        try self.printNoLeadBlank(items, true);
        try self.gap(n.span.end, true);
        self.indent -= 1;
        try self.raw("}");
    }

    fn printBinarySide(self: *Printer, idx: Index, parent_prec: u8, is_rhs: bool) FmtError!void {
        const tag = self.tree.get(idx).tag;
        var wrap = tag == .catch_default or tag == .catch_bind or tag == .arrow_fn;
        if (!wrap and tag == .binary) {
            const child_prec = precedence(@enumFromInt(self.tree.get(idx).main));
            wrap = if (is_rhs) child_prec <= parent_prec else child_prec < parent_prec;
        }
        if (wrap) {
            try self.raw("(");
            try self.printNode(idx);
            try self.raw(")");
        } else try self.printNode(idx);
    }

    fn dispatch(self: *Printer, idx: Index, n: ast.Node) FmtError!void {
        switch (n.tag) {
            .none => {},

            .ident, .int_lit, .float_lit, .string_lit, .raw_string_lit, .rune_lit, .bool_lit, .nil_lit, .str_part => {
                try self.raw(self.source[n.span.start..n.span.end]);
            },

            .program => {
                try self.printSeq(self.kids(idx), true);
                try self.gap(@intCast(self.source.len), true);
            },

            .import_decl => {
                const k = self.kids(idx);
                try self.raw("import ");
                try self.printNode(k[0]);
                try self.raw(" from ");
                try self.printNode(k[1]);
            },
            .import_ns => try self.printNode(self.kids(idx)[0]),
            .import_star => {
                try self.raw("* as ");
                try self.printNode(self.kids(idx)[0]);
            },
            .import_group => try self.printCommaList(self.kids(idx), "{", "}", n.span.end),
            .import_item => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                if (k[1] != none) {
                    try self.raw(" as ");
                    try self.printNode(k[1]);
                }
            },

            .let_decl => {
                try self.raw("let ");
                try self.printFlatList(self.kids(idx), ", ");
            },
            .const_decl => {
                try self.raw("const ");
                try self.printFlatList(self.kids(idx), ", ");
            },
            .binding => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                if (k[1] != none) {
                    try self.raw(": ");
                    try self.printNode(k[1]);
                }
                if (k[2] != none) {
                    try self.raw(" = ");
                    try self.printNode(k[2]);
                }
            },
            .tuple_pat => try self.printCommaList(self.kids(idx), "(", ")", n.span.end),

            .type_alias => {
                const k = self.kids(idx);
                try self.raw("type ");
                try self.printNode(k[0]);
                if (k[1] != none) try self.printNode(k[1]);
                try self.raw(" = ");
                try self.printNode(k[2]);
            },

            .func_decl => {
                const k = self.kids(idx);
                try self.raw("function ");
                if (k[0] != none) {
                    try self.raw("(");
                    try self.printNode(k[0]);
                    try self.raw(") ");
                }
                try self.printNode(k[1]);
                if (k[2] != none) try self.printNode(k[2]);

                // Return type is rendered once, ahead of the params list, so
                // its exact width can fold into the params' own wrap
                // decision (`: ReturnType {` all sit on the params' line) —
                // see printCommaList's `tail` and renderFlat's contract.
                const ret_text: ?[]u8 = if (k[4] != none) try self.renderFlat(k[4]) else null;
                defer if (ret_text) |t| self.gpa.free(t);

                self.next_list_tail = if (ret_text) |t| @intCast(t.len + ": ".len + " {".len) else " {".len;
                try self.printNode(k[3]);

                if (ret_text) |t| {
                    try self.raw(": ");
                    try self.raw(t);
                }
                try self.raw(" ");
                try self.printBodyBlock(k[5]);
            },
            .receiver => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(": ");
                try self.printNode(k[1]);
            },
            .params => try self.printCommaList(self.kids(idx), "(", ")", n.span.end),
            .param => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(": ");
                try self.printNode(k[1]);
            },
            .param_rest => {
                const k = self.kids(idx);
                try self.raw("...");
                try self.printNode(k[0]);
                try self.raw(": ");
                try self.printNode(k[1]);
            },

            .struct_decl => {
                const k = self.kids(idx);
                try self.raw("struct ");
                try self.printNode(k[0]);
                if (k[1] != none) try self.printNode(k[1]);
                try self.raw(" ");
                try self.printNode(k[2]);
            },
            .field_list => try self.printCommaList(self.kids(idx), "{", "}", n.span.end),
            .field => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(": ");
                try self.printNode(k[1]);
            },
            .interface_decl => {
                const k = self.kids(idx);
                try self.raw("interface ");
                try self.printNode(k[0]);
                if (k[1] != none) try self.printNode(k[1]);
                try self.raw(" ");
                try self.printNode(k[2]);
            },
            .method_sig_list => try self.printCommaList(self.kids(idx), "{", "}", n.span.end),
            .method_sig => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.printNode(k[1]);
                if (k[2] != none) {
                    try self.raw(": ");
                    try self.printNode(k[2]);
                }
            },
            .enum_decl => {
                const k = self.kids(idx);
                try self.raw("enum ");
                try self.printNode(k[0]);
                if (k[1] != none) try self.printNode(k[1]);
                try self.raw(" ");
                try self.printNode(k[2]);
            },
            .variant_list => try self.printCommaList(self.kids(idx), "{", "}", n.span.end),
            .enum_variant => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                if (k[1] != none) {
                    try self.raw("(");
                    try self.printFlatList(self.kids(k[1]), ", ");
                    try self.raw(")");
                }
            },
            .generic_params => try self.printCommaList(self.kids(idx), "<", ">", n.span.end),
            .generic_param => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                if (k[1] != none) {
                    try self.raw(": ");
                    try self.printNode(k[1]);
                }
            },
            .constraint => try self.printFlatList(self.kids(idx), " & "),
            .@"export" => {
                try self.raw("export ");
                try self.printNode(self.kids(idx)[0]);
            },
            .fallible => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw("!");
                if (k[1] != none) try self.printNode(k[1]);
            },

            .slice_type => {
                try self.raw("[]");
                try self.printNode(self.kids(idx)[0]);
            },
            .array_type => {
                const k = self.kids(idx);
                try self.raw("[");
                try self.printNode(k[0]);
                try self.raw("]");
                try self.printNode(k[1]);
            },
            .map_type => {
                const k = self.kids(idx);
                try self.raw("map<");
                try self.printNode(k[0]);
                try self.raw(", ");
                try self.printNode(k[1]);
                try self.raw(">");
            },
            .tuple_type => try self.printCommaList(self.kids(idx), "(", ")", n.span.end),
            .void_type => try self.raw("()"),
            .func_type => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(" => ");
                try self.printNode(k[1]);
            },
            .type_list => try self.printCommaList(self.kids(idx), "(", ")", n.span.end),
            .chan_type => {
                try self.raw("chan<");
                try self.printNode(self.kids(idx)[0]);
                try self.raw(">");
            },
            .generic_inst => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.printNode(k[1]);
            },
            .type_args => try self.printCommaList(self.kids(idx), "<", ">", n.span.end),

            .block => try self.printBlock(idx, n),
            .stmt_list => try self.printSeq(self.kids(idx), true), // defensive: callers normally iterate the raw kids directly

            .assign => {
                const k = self.kids(idx);
                try self.printFlatList(self.kids(k[0]), ", ");
                try self.raw(" ");
                try self.raw(ast.opSymbol(@enumFromInt(n.main)));
                try self.raw(" ");
                try self.printFlatList(self.kids(k[1]), ", ");
            },
            .lhs_list, .expr_list => try self.printFlatList(self.kids(idx), ", "), // defensive: assign/switch_case read kids directly
            .inc_stmt => {
                try self.printNode(self.kids(idx)[0]);
                try self.raw("++");
            },
            .dec_stmt => {
                try self.printNode(self.kids(idx)[0]);
                try self.raw("--");
            },
            .expr_stmt => try self.printNode(self.kids(idx)[0]),
            .send_stmt => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(" <- ");
                try self.printNode(k[1]);
            },
            .return_stmt => {
                const k = self.kids(idx);
                try self.raw("return");
                if (k.len > 0) {
                    try self.raw(" ");
                    try self.printFlatList(k, ", ");
                }
            },
            .fail_stmt => {
                try self.raw("fail ");
                try self.printNode(self.kids(idx)[0]);
            },
            .break_stmt => try self.raw("break"),
            .continue_stmt => try self.raw("continue"),
            .spawn_stmt => {
                try self.raw("spawn ");
                try self.printAtomic(self.kids(idx)[0]);
            },
            .defer_stmt => {
                try self.raw("defer ");
                try self.printAtomic(self.kids(idx)[0]);
            },

            .if_stmt => {
                const k = self.kids(idx);
                try self.raw("if (");
                try self.printNode(k[0]);
                try self.raw(") ");
                try self.printBlock(k[1], self.tree.get(k[1]));
                if (k[2] != none) {
                    try self.raw(" else ");
                    if (self.tree.get(k[2]).tag == .if_stmt) {
                        try self.printNode(k[2]);
                    } else {
                        try self.printBlock(k[2], self.tree.get(k[2]));
                    }
                }
            },
            .while_stmt => {
                const k = self.kids(idx);
                try self.raw("while (");
                try self.printNode(k[0]);
                try self.raw(") ");
                try self.printBlock(k[1], self.tree.get(k[1]));
            },
            .for_c => {
                const k = self.kids(idx);
                try self.raw("for (");
                if (k[0] != none) try self.printNode(k[0]);
                try self.raw("; ");
                if (k[1] != none) try self.printNode(k[1]);
                try self.raw("; ");
                if (k[2] != none) try self.printNode(k[2]);
                try self.raw(") ");
                try self.printBlock(k[3], self.tree.get(k[3]));
            },
            .for_of => {
                const k = self.kids(idx);
                try self.raw("for ");
                try self.printNode(k[0]);
                try self.raw(" of ");
                try self.printNode(k[1]);
                try self.raw(" ");
                try self.printBlock(k[2], self.tree.get(k[2]));
            },
            .for_in => {
                const k = self.kids(idx);
                try self.raw("for ");
                try self.printNode(k[0]);
                try self.raw(" in ");
                try self.printNode(k[1]);
                try self.raw(" ");
                try self.printBlock(k[2], self.tree.get(k[2]));
            },
            .for_inf => {
                try self.raw("for ");
                try self.printBlock(self.kids(idx)[0], self.tree.get(self.kids(idx)[0]));
            },

            .switch_stmt => {
                const k = self.kids(idx);
                try self.raw("switch ");
                if (k[0] != none) {
                    try self.raw("(");
                    try self.printNode(k[0]);
                    try self.raw(") ");
                }
                try self.printNode(k[1]);
            },
            .case_list => {
                try self.raw("{");
                self.indent += 1;
                try self.printNoLeadBlank(self.kids(idx), false);
                try self.gap(n.span.end, true);
                self.indent -= 1;
                try self.raw("}");
            },
            .switch_case => {
                const k = self.kids(idx);
                try self.raw("case ");
                try self.printFlatList(self.kids(k[0]), ", ");
                try self.raw(":");
                self.indent += 1;
                try self.printNoLeadBlank(self.kids(k[1]), true);
                self.indent -= 1;
            },
            .switch_default => {
                const k = self.kids(idx);
                try self.raw("default:");
                self.indent += 1;
                try self.printNoLeadBlank(self.kids(k[0]), true);
                self.indent -= 1;
            },
            .match_stmt => {
                const k = self.kids(idx);
                try self.raw("match (");
                try self.printNode(k[0]);
                try self.raw(") ");
                try self.printNode(k[1]);
            },
            .arm_list => {
                try self.raw("{");
                self.indent += 1;
                try self.printNoLeadBlank(self.kids(idx), false);
                try self.gap(n.span.end, true);
                self.indent -= 1;
                try self.raw("}");
            },
            .match_arm => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(" => ");
                try self.printBodyBlock(k[1]);
            },
            .variant_pat => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                if (k[1] != none) try self.printCommaList(self.kids(k[1]), "(", ")", n.span.end);
            },

            .select_stmt => {
                try self.raw("select ");
                try self.raw("{");
                self.indent += 1;
                try self.printNoLeadBlank(self.kids(idx), false);
                try self.gap(n.span.end, true);
                self.indent -= 1;
                try self.raw("}");
            },
            .comm_case => {
                const k = self.kids(idx);
                try self.raw("case ");
                try self.printNode(k[0]);
                try self.raw(":");
                self.indent += 1;
                try self.printNoLeadBlank(self.kids(k[1]), true);
                self.indent -= 1;
            },
            .comm_default => {
                const k = self.kids(idx);
                try self.raw("default:");
                self.indent += 1;
                try self.printNoLeadBlank(self.kids(k[0]), true);
                self.indent -= 1;
            },
            .recv_bind => {
                const k = self.kids(idx);
                if (k[0] != none) {
                    try self.printNode(k[0]);
                    try self.raw(" = <- ");
                    try self.printNode(k[1]);
                } else {
                    try self.printNode(k[1]); // already a unary(<-, ...) node
                }
            },

            .binary => {
                const op: Kind = @enumFromInt(n.main);
                const prec = precedence(op);
                const k = self.kids(idx);
                try self.printBinarySide(k[0], prec, false);
                try self.raw(" ");
                try self.raw(ast.opSymbol(op));
                try self.raw(" ");
                try self.printBinarySide(k[1], prec, true);
            },
            .unary => {
                const op: Kind = @enumFromInt(n.main);
                const operand = self.kids(idx)[0];
                try self.raw(ast.opSymbol(op));
                const child = self.tree.get(operand);
                const wrap = switch (child.tag) {
                    .binary, .catch_default, .catch_bind, .arrow_fn => true,
                    else => false,
                };
                if (wrap) {
                    try self.raw("(");
                    try self.printNode(operand);
                    try self.raw(")");
                } else {
                    // Avoid a nested `-`/`+` unary merging into `--`/`++`.
                    if (child.tag == .unary and child.main == n.main and (op == .minus or op == .plus)) {
                        try self.raw(" ");
                    }
                    try self.printNode(operand);
                }
            },
            .catch_default => {
                const k = self.kids(idx);
                try self.printCatchLhs(k[0]);
                try self.raw(" catch ");
                try self.printNode(k[1]);
            },
            .catch_bind => {
                const k = self.kids(idx);
                try self.printCatchLhs(k[0]);
                try self.raw(" catch ");
                try self.printNode(k[1]);
                try self.raw(" ");
                try self.printBlock(k[2], self.tree.get(k[2]));
            },
            .arrow_fn => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(" => ");
                try self.printNode(k[1]);
            },
            .arrow_params => try self.printCommaList(self.kids(idx), "(", ")", n.span.end),
            .arrow_p => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                if (k[1] != none) {
                    try self.raw(": ");
                    try self.printNode(k[1]);
                }
            },

            .call => {
                const k = self.kids(idx);
                try self.printAtomic(k[0]);
                if (k[1] != none) try self.printNode(k[1]);
                try self.printNode(k[2]);
            },
            .args => try self.printCommaList(self.kids(idx), "(", ")", n.span.end),
            .arg => try self.printNode(self.kids(idx)[0]),
            .arg_spread => {
                try self.raw("...");
                try self.printNode(self.kids(idx)[0]);
            },
            .index => {
                const k = self.kids(idx);
                try self.printAtomic(k[0]);
                try self.raw("[");
                try self.printNode(k[1]);
                try self.raw("]");
            },
            .slice_expr => {
                const k = self.kids(idx);
                try self.printAtomic(k[0]);
                try self.raw("[");
                if (k[1] != none) try self.printNode(k[1]);
                try self.raw(":");
                if (k[2] != none) try self.printNode(k[2]);
                try self.raw("]");
            },
            .member => {
                const k = self.kids(idx);
                try self.printAtomic(k[0]);
                try self.raw(".");
                try self.printNode(k[1]);
            },
            .tuple_index => {
                const k = self.kids(idx);
                try self.printAtomic(k[0]);
                try self.raw(".");
                try self.printNode(k[1]);
            },
            .type_assert => {
                const k = self.kids(idx);
                try self.printAtomic(k[0]);
                try self.raw(".(");
                try self.printNode(k[1]);
                try self.raw(")");
            },
            .try_expr => {
                try self.printAtomic(self.kids(idx)[0]);
                try self.raw("?");
            },
            .composite_lit => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                const body = self.tree.get(k[1]);
                try self.printCommaList(self.kids(k[1]), "{", "}", body.span.end);
            },
            .field_inits => try self.printCommaList(self.kids(idx), "{", "}", n.span.end),
            .field_init => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(": ");
                try self.printNode(k[1]);
            },
            .map_entries => try self.printCommaList(self.kids(idx), "{", "}", n.span.end),
            .map_entry => {
                const k = self.kids(idx);
                try self.printNode(k[0]);
                try self.raw(": ");
                try self.printNode(k[1]);
            },
            .slice_lit => try self.printCommaList(self.kids(idx), "[", "]", n.span.end),
            .str_interp => {
                try self.raw("\"");
                for (self.kids(idx)) |k| {
                    const kn = self.tree.get(k);
                    if (kn.tag == .str_part) {
                        try self.raw(self.source[kn.span.start..kn.span.end]);
                    } else if (kn.tag == .match_stmt) {
                        // A `match` expression renders multi-line, which cannot
                        // live inside a string literal; copy its (necessarily
                        // single-line) source verbatim so the interpolation stays
                        // valid. ponytail: the fmt pass could inline it with
                        // `,`-separated arms instead of preserving source.
                        try self.raw("${");
                        try self.raw(self.source[kn.span.start..kn.span.end]);
                        try self.raw("}");
                        if (kn.span.end > self.src_pos) self.src_pos = kn.span.end;
                    } else {
                        try self.raw("${");
                        try self.printNode(k);
                        try self.raw("}");
                    }
                }
                try self.raw("\"");
            },
        }
    }
};

// =============================================================================
// Public API
// =============================================================================

pub const FormatResult = struct {
    /// Canonical source on success, or rendered diagnostics (same shape as
    /// `compileReport`) if `source` doesn't parse. Owned by the caller's gpa.
    text: []u8,
    failed: bool,
};

/// Formats `source` to Bit's one canonical style. If `source` doesn't parse,
/// `failed` is true and `text` holds the rendered diagnostics instead — fmt
/// never guesses at malformed input.
pub fn format(gpa: Allocator, path: []const u8, source: []const u8) !FormatResult {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile(path, source);
    var diags = diagnostics.Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    if (diags.hasErrors()) {
        var rendered: Writer.Allocating = .init(gpa);
        defer rendered.deinit();
        try diags.renderAll(&rendered.writer);
        return .{ .text = try gpa.dupe(u8, rendered.written()), .failed = true };
    }

    const comments = try collectComments(gpa, source);
    defer gpa.free(comments);

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var p = Printer{
        .gpa = gpa,
        .source = source,
        .file = file,
        .diags = &diags,
        .tree = &tree,
        .w = &out.writer,
        .comments = comments,
    };
    try p.printNode(tree.root);
    return .{ .text = try gpa.dupe(u8, out.written()), .failed = false };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectFmt(src: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const r = try format(gpa, "t.bit", src);
    defer gpa.free(r.text);
    try testing.expect(!r.failed);
    try testing.expectEqualStrings(expected, r.text);
}

fn expectIdempotent(gpa: Allocator, src: []const u8) !void {
    const once = try format(gpa, "t.bit", src);
    defer gpa.free(once.text);
    try testing.expect(!once.failed);
    const twice = try format(gpa, "t.bit", once.text);
    defer gpa.free(twice.text);
    try testing.expect(!twice.failed);
    try testing.expectEqualStrings(once.text, twice.text);
}

test "canonical function declaration" {
    try expectFmt(
        "function add(a:i32,b:i32):i32{return a+b}",
        "function add(a: i32, b: i32): i32 { return a + b }\n",
    );
}

test "let/const, struct, interface canonicalize to comma separators" {
    try expectFmt("let   x=1", "let x = 1\n");
    try expectFmt(
        "struct Point { x: f64; y: f64 }",
        "struct Point { x: f64, y: f64 }\n",
    );
    try expectFmt(
        "interface Ord { less(other: Self): bool }",
        "interface Ord { less(other: Self): bool }\n",
    );
}

test "blank line between top-level decls is preserved, collapsed to one" {
    try expectFmt("let a = 1\n\n\n\nlet b = 2", "let a = 1\n\nlet b = 2\n");
    try expectFmt("let a = 1\nlet b = 2", "let a = 1\nlet b = 2\n");
}

test "line and block comments are re-attached" {
    try expectFmt(
        "// leading\nlet x = 1 // trailing\n",
        "// leading\nlet x = 1 // trailing\n",
    );
    try expectFmt("let x = 1 /* c */", "let x = 1 /* c */\n");
}

test "re-parenthesization preserves precedence and grouping" {
    try expectFmt("let x = (1 + 2) * 3", "let x = (1 + 2) * 3\n");
    try expectFmt("let x = 1 + 2 * 3", "let x = 1 + 2 * 3\n");
    try expectFmt("let x = 1 - (2 - 3)", "let x = 1 - (2 - 3)\n");
    try expectFmt("let x = (1 - 2) - 3", "let x = 1 - 2 - 3\n");
    try expectFmt("let x = -(a + b)", "let x = -(a + b)\n");
    try expectFmt("let x = (a + b).c", "let x = (a + b).c\n");
}

test "arrow params always canonicalize to parenthesized form" {
    try expectFmt("let f = x => x * 2", "let f = (x) => x * 2\n");
}

test "long param list wraps one per line with a trailing comma" {
    try expectFmt(
        "function f(aaaaaaaaaa: int, bbbbbbbbbb: int, cccccccccc: int, dddddddddd: int, eeeeeeeeee: int): int { return 0 }",
        "function f(\n  aaaaaaaaaa: int,\n  bbbbbbbbbb: int,\n  cccccccccc: int,\n  dddddddddd: int,\n  eeeeeeeeee: int,\n): int { return 0 }\n",
    );
}

test "semicolons omitted after ASI terminators, kept where ASI would not fire" {
    // Ends in a terminator (int_lit, `)`, ident) -> no `;`.
    try expectFmt("let x = 1", "let x = 1\n");
    try expectFmt("let x = f()", "let x = f()\n");
    // Ends in `>` (a generic type), which ASI does NOT treat as a terminator,
    // so the explicit `;` must stay or re-parsing would change.
    try expectFmt("type Boxed = Box<int>", "type Boxed = Box<int>;\n");
}

test "single-statement match arm and function body inline; a match never gets a trailing ';'" {
    try expectFmt(
        "enum Light { Red, Green }\nfunction next(l: Light): Light {\n  match (l) {\n    Red => { return Light.Green }\n    Green => { return Light.Red }\n  }\n}\n",
        "enum Light { Red, Green }\nfunction next(l: Light): Light {\n  match (l) {\n    Red => { return Light.Green }\n    Green => { return Light.Red }\n  }\n}\n",
    );
    // A single-statement function body inlines too.
    try expectFmt(
        "function area(r: f64): f64 {\n  return 3 * r\n}\n",
        "function area(r: f64): f64 { return 3 * r }\n",
    );
}

test "a comment inside a single-statement block forces the multi-line form" {
    try expectFmt(
        "function f(): i64 {\n  return 1 // note\n}\n",
        "function f(): i64 {\n  return 1 // note\n}\n",
    );
}

test "idempotence over hand-written samples" {
    const gpa = testing.allocator;
    const srcs = [_][]const u8{
        "function main() {\n  print(\"hello\");\n}\n",
        "struct Point { x: f64, y: f64 };\n",
        "let x = (1 + 2) * 3;\nlet y = -(a + b);\n",
        "// c1\nfunction f(): int {\n  // c2\n  return 1; // c3\n}\n",
    };
    for (srcs) |s| try expectIdempotent(gpa, s);
}
