//! Recursive-descent parser with Pratt expression parsing (spec/SPEC.md §9-§18,
//! Appendix A). Produces the index-based `ast.Tree`; every node's span is set
//! from the tokens that produced it.
//!
//! Ambiguities the grammar resolves by bounded lookahead (§12.7, §12.8) are
//! implemented with a checkpoint/restore speculative parse: `self.speculating`
//! turns every `expect`-style mismatch into `error.Speculative` instead of a
//! reported diagnostic, so a failed speculative attempt costs no side effects.
//! The four call sites are: arrow-function params vs parenthesized expression,
//! generic call/composite-literal vs comparison, `[]T{..}`/`[N]T{..}` vs a bare
//! slice literal, and `for (pat, pat) of` vs C-style `for (init; cond; post)`.
//!
//! Error recovery is synchronization at statement boundaries: a malformed
//! top-level declaration or statement is reported once, then the parser skips
//! to the next `;`/declaration/statement keyword and keeps going, so one file
//! can report every syntax error it contains instead of stopping at the first.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const diagnostics = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const Kind = lexer.Kind;
const Token = lexer.Token;
const Lexer = lexer.Lexer;
const Span = diagnostics.Span;
const FileId = diagnostics.FileId;
const Diagnostics = diagnostics.Diagnostics;
const Index = ast.Index;
const none = ast.none;

/// `Speculative` unwinds a checkpointed attempt without reporting a diagnostic;
/// it never escapes `parse` (asserted there). `OutOfMemory` is a real failure.
const ParseError = Allocator.Error || error{Speculative};

/// Parses `source` into `tree` (setting `tree.root`), reporting every syntax
/// error to `diags` and recovering at statement boundaries so unrelated errors
/// in the same file are all reported.
pub fn parse(gpa: Allocator, tree: *ast.Tree, diags: *Diagnostics, file: FileId, source: []const u8) !void {
    var p = try Parser.init(gpa, tree, diags, file, source);
    tree.root = p.parseProgram() catch |err| switch (err) {
        // speculating always returns to 0 before parseProgram returns; a
        // Speculative error escaping this far is a parser bug, not user input.
        error.Speculative => unreachable,
        else => |e| return e,
    };
}

/// Upper bounds on the outermost loops (Power of 10: every loop is bounded).
/// Real files never approach these; hitting one means recovery is looping.
const max_top_decls = 1 << 16;
const max_block_stmts = 1 << 16;
const max_case_clauses = 1 << 14;
const max_postfix_ops = 1 << 12;
const max_asm_items = 1 << 8;
/// Speculative attempts never nest more than a couple of levels deep in this
/// grammar (see file header); a deeper nest means a logic bug, not real input.
const max_speculate_depth = 16;

const Parser = struct {
    gpa: Allocator,
    tree: *ast.Tree,
    diags: *Diagnostics,
    lx: Lexer,
    tok: Token,
    /// >0 while inside a speculative attempt: `fail` raises `error.Speculative`
    /// instead of reporting, and `expect`/`fail` never desync the token stream
    /// via recovery (the whole attempt is rolled back by the caller instead).
    speculating: u32 = 0,
    /// True while parsing an expression that is directly followed by a
    /// mandatory block with no delimiter in between — only `for_of`/`for_in`'s
    /// iterable (§13.1: `for_of = (IDENT | pat) "of" expression block`, no
    /// parens around `expression`). A bare `IDENT {` there is ambiguous between
    /// the loop body and a struct composite literal (§12.2), so composite
    /// literals are suppressed at that position. `commaList` clears it while
    /// inside any bracketed list, since a nested `(`/`[`/`<...>` list re-opens
    /// unambiguous ground for composite literals.
    no_composite_lit: bool = false,

    fn init(gpa: Allocator, tree: *ast.Tree, diags: *Diagnostics, file: FileId, source: []const u8) !Parser {
        var lx = Lexer.init(file, source, diags);
        const first = try lx.next();
        return .{ .gpa = gpa, .tree = tree, .diags = diags, .lx = lx, .tok = first };
    }

    // ---- token stream + speculative checkpoint -----------------------------

    const Mark = struct { lx: Lexer, tok: Token };

    fn mark(self: *const Parser) Mark {
        return .{ .lx = self.lx, .tok = self.tok };
    }

    fn reset(self: *Parser, m: Mark) void {
        self.lx = m.lx;
        self.tok = m.tok;
    }

    fn advance(self: *Parser) ParseError!void {
        self.tok = try self.lx.next();
    }

    fn accept(self: *Parser, kind: Kind) ParseError!bool {
        if (self.tok.kind != kind) return false;
        try self.advance();
        return true;
    }

    /// Consumes `kind`, returning its span, or fails (see `fail`).
    fn expect(self: *Parser, kind: Kind, what: []const u8) ParseError!Span {
        if (self.tok.kind == kind) {
            const s = self.tok.span;
            try self.advance();
            return s;
        }
        try self.fail(what);
        return self.tok.span;
    }

    /// `>>`, `>>=` and `>=` lex as single tokens, but a run of `>` also closes
    /// nested generic argument lists — `chan<map<string, int>>`. The lexer cannot
    /// tell the two apart without tracking angle-bracket depth (the classic C++
    /// `vector<vector<int>>` problem), so the parser splits the token where it
    /// knows a `>` is due: take the leading `>`, leave the remainder current.
    ///
    /// Splitting is iterative, which is what `let x: Opt<Opt<i64>>= v` needs:
    /// `>>=` yields `>` and leaves `>=`, which the enclosing list then splits
    /// again into `>` and `=`.
    ///
    /// A wrong guess costs nothing: in expression position this only runs under
    /// `tryGenericPostfix`'s speculation, and `a < b >= c` rewinds via `reset`.
    fn expectGenericClose(self: *Parser) ParseError!Span {
        const rest: Kind = switch (self.tok.kind) {
            .shr => .gt,
            .shr_eq => .gt_eq,
            .gt_eq => .eq,
            else => return self.expect(.gt, "'>'"),
        };
        const s = self.tok.span;
        self.tok = .{ .kind = rest, .span = .{ .file = s.file, .start = s.start + 1, .end = s.end } };
        return .{ .file = s.file, .start = s.start, .end = s.start + 1 };
    }

    /// Whether the current token closes a list opened with `close`. A generic
    /// list also closes on the `>` hiding at the front of a `>>`, `>>=` or `>=`.
    fn atClose(self: *const Parser, close: Kind) bool {
        if (self.tok.kind == close) return true;
        if (close != .gt) return false;
        return switch (self.tok.kind) {
            .shr, .shr_eq, .gt_eq => true,
            else => false,
        };
    }

    fn expectIdent(self: *Parser) ParseError!Index {
        if (self.tok.kind != .ident) {
            try self.fail("an identifier");
            return none;
        }
        return self.leaf(.ident);
    }

    /// Reports "expected `what`, found `<token>`" unless speculating, in which
    /// case the whole attempt aborts via `error.Speculative` and nothing is
    /// reported (the caller rolls the token stream back to its checkpoint).
    /// An `.invalid` current token already has its own lexer diagnostic at this
    /// exact span, so no second report is added for it (recovery still runs).
    fn fail(self: *Parser, what: []const u8) ParseError!void {
        if (self.speculating > 0) return error.Speculative;
        if (self.tok.kind == .invalid) return;
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "expected {s}, found {s}", .{ what, describe(self.tok.kind) }) catch what;
        try self.diags.report(.expected_token, self.tok.span, msg, self.asiHint());
    }

    /// The hint for a parse error whose unexpected token is a semicolon §7
    /// SYNTHESIZED rather than one the author wrote.
    ///
    /// That case is worth calling out because the source shows no `;` at all, so
    /// "found ';'" names a token the reader cannot see, and the line it points
    /// at usually looks perfectly well formed. It is the whole reported symptom
    /// behind both wrapped `import` (#1412) and a condition broken before its
    /// operator (#1430) — the parse is behaving exactly as §7 specifies, and the
    /// only thing missing is saying so.
    ///
    /// A synthesized semicolon is the one token the lexer emits as a POINT span
    /// (`Span.point`, zero width at the newline); a written `;` covers its byte.
    /// This changes no grammar — the same programs parse and fail as before.
    fn asiHint(self: *const Parser) ?[]const u8 {
        if (self.tok.kind != .semicolon) return null;
        if (self.tok.span.start != self.tok.span.end) return null; // an author's ';'
        return "a line break after a value ends the statement (§7); to continue an expression, end the line with the operator instead of starting the next line with it";
    }

    /// A guarded loop hit its element cap: the construct holds more elements
    /// than the parser admits (`max_*` bounds, §Power-of-10 rule 2). Report it
    /// rather than asserting — large or adversarial input (2^14 case clauses,
    /// 2^16 statements) must never crash the compiler (fuzz #334).
    fn tooMany(self: *Parser, what: []const u8) ParseError!void {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "too many {s}", .{what}) catch what;
        try self.diags.report(.expected_token, self.tok.span, msg, null);
    }

    /// Builds a leaf node from the current token's span and consumes it.
    fn leaf(self: *Parser, tag: ast.Tag) ParseError!Index {
        const tok_span = self.tok.span;
        try self.advance();
        return self.tree.addLeaf(tag, tok_span);
    }

    fn span(self: *const Parser, idx: Index) Span {
        return self.tree.get(idx).span;
    }

    fn join(a: Span, b: Span) Span {
        return .{ .file = a.file, .start = a.start, .end = b.end };
    }

    /// Runs a speculative attempt: on `error.Speculative` the token stream is
    /// rolled back and `null` is returned; any other error (only `OutOfMemory`)
    /// propagates. Any tree nodes the attempt built are orphaned, not reused —
    /// harmless waste in an append-only tree, far simpler than undoing `add`.
    fn speculate(self: *Parser, comptime attempt: fn (*Parser) ParseError!Index) ParseError!?Index {
        std.debug.assert(self.speculating < max_speculate_depth);
        const m = self.mark();
        self.speculating += 1;
        const result = attempt(self);
        self.speculating -= 1;
        return result catch |err| switch (err) {
            error.Speculative => {
                self.reset(m);
                return null;
            },
            else => |e| return e,
        };
    }

    // ---- generic comma-separated list ---------------------------------------

    /// Parses zero or more comma-separated items up to (not consuming) `close`,
    /// allowing a trailing comma. `allow_semi` also accepts `;` as a separator
    /// (struct fields and interface method signatures accept either, §10.5-6).
    /// Caller consumes `close` itself and frees the returned slice.
    fn commaList(self: *Parser, close: Kind, comptime parseItem: fn (*Parser) ParseError!Index, allow_semi: bool) ParseError![]Index {
        // Every caller has just consumed an opening `(`/`[`/`<`/`{`, so a
        // composite literal inside the list is never ambiguous with an
        // enclosing block — see `no_composite_lit`.
        const saved_no_composite = self.no_composite_lit;
        self.no_composite_lit = false;
        defer self.no_composite_lit = saved_no_composite;

        var items: std.ArrayList(Index) = .empty;
        errdefer items.deinit(self.gpa);
        if (self.atClose(close)) return items.toOwnedSlice(self.gpa);
        try items.append(self.gpa, try parseItem(self));
        // Bounded by remaining tokens: each iteration consumes a separator.
        while (self.tok.kind == .comma or (allow_semi and self.tok.kind == .semicolon)) {
            try self.advance();
            if (self.atClose(close)) break; // trailing separator
            try items.append(self.gpa, try parseItem(self));
        }
        return items.toOwnedSlice(self.gpa);
    }

    /// At least one comma-separated expression, stopping at the first non-comma
    /// (used where there is no closing delimiter: return/assign/case lists).
    fn exprList1(self: *Parser) ParseError![]Index {
        var items: std.ArrayList(Index) = .empty;
        errdefer items.deinit(self.gpa);
        try items.append(self.gpa, try self.parseExpression());
        while (try self.accept(.comma)) try items.append(self.gpa, try self.parseExpression());
        return items.toOwnedSlice(self.gpa);
    }

    // =========================================================================
    // Program structure (§9)
    // =========================================================================

    fn parseProgram(self: *Parser) ParseError!Index {
        var decls: std.ArrayList(Index) = .empty;
        defer decls.deinit(self.gpa);
        var guard: u32 = 0;
        while (self.tok.kind != .eof and guard < max_top_decls) : (guard += 1) {
            if (try self.accept(.semicolon)) continue;
            const decl = try self.parseTopDecl();
            try decls.append(self.gpa, decl);
            // `none` means parseTopDecl already reported and synchronized itself;
            // re-checking for ';' here would double-report the same failure.
            if (decl == none) continue;
            if (!try self.accept(.semicolon) and self.tok.kind != .eof) {
                try self.fail("';'");
                self.synchronizeTopLevel();
            }
        }
        if (guard >= max_top_decls) try self.tooMany("top-level declarations");
        return self.tree.add(.program, .{ .file = self.tok.span.file, .start = 0, .end = self.tok.span.end }, 0, decls.items);
    }

    /// Skips to the next token that can start a top-level declaration (or EOF),
    /// consuming a `;` if that's what stops it. Bounded by remaining tokens.
    fn synchronizeTopLevel(self: *Parser) void {
        while (self.tok.kind != .eof) {
            if (self.tok.kind == .semicolon) {
                _ = self.advance() catch return;
                return;
            }
            switch (self.tok.kind) {
                .kw_import, .kw_export, .kw_let, .kw_const, .kw_function, .kw_struct, .kw_interface, .kw_type => return,
                else => {},
            }
            _ = self.advance() catch return;
        }
    }

    fn parseTopDecl(self: *Parser) ParseError!Index {
        switch (self.tok.kind) {
            .kw_import => return self.parseImportDecl(),
            .kw_export => {
                const start = self.tok.span;
                try self.advance();
                const inner = try self.parseExportableDecl();
                // `none` means parseExportableDecl's dispatch failure already
                // reported and synchronized; propagate it rather than wrap it.
                if (inner == none) return none;
                return self.tree.add(.@"export", join(start, self.span(inner)), 0, &.{inner});
            },
            .kw_let, .kw_const => return self.parseValueDecl(.process),
            .at => return self.parseAttrDecl(),
            .kw_function => return self.parseFuncDecl(none),
            .kw_struct => return self.parseStructDecl(),
            .kw_interface => return self.parseInterfaceDecl(),
            .kw_enum => return self.parseEnumDecl(),
            .kw_type => return self.parseTypeAlias(),
            .ident => {
                if (std.mem.eql(u8, self.curText(), "extern")) return self.parseExternFnDecl();
                try self.fail("a top-level declaration");
                self.synchronizeTopLevel();
                return none;
            },
            else => {
                try self.fail("a top-level declaration");
                self.synchronizeTopLevel();
                return none;
            },
        }
    }

    fn parseExportableDecl(self: *Parser) ParseError!Index {
        switch (self.tok.kind) {
            .kw_let, .kw_const => return self.parseValueDecl(.process),
            .at => return self.parseAttrDecl(),
            .kw_function => return self.parseFuncDecl(none),
            .kw_struct => return self.parseStructDecl(),
            .kw_interface => return self.parseInterfaceDecl(),
            .kw_enum => return self.parseEnumDecl(),
            .kw_type => return self.parseTypeAlias(),
            .ident => {
                if (std.mem.eql(u8, self.curText(), "extern")) return self.parseExternFnDecl();
                try self.fail("a declaration after 'export'");
                self.synchronizeTopLevel();
                return none;
            },
            else => {
                try self.fail("a declaration after 'export'");
                self.synchronizeTopLevel();
                return none;
            },
        }
    }

    // ---- function attributes (§10.3.1) --------------------------------------

    /// Parses `@name @name ...` then requires a `function` or a `let` —
    /// attributes attach to function declarations (§10.3.1) and to module-level
    /// state (§11.11 `@threadlocal let`). Any other target is a parse error.
    ///
    /// A `let`'s storage class rides in the node's `main` scalar rather than as
    /// an extra child, exactly as `asm_stmt` carries `volatile`. That choice is
    /// load-bearing rather than cosmetic: a `let_decl`'s children ARE its
    /// bindings, and a dozen sites across check/resolve/lower/fmt iterate them
    /// expecting nothing else — an appended `attr_list` child would have to be
    /// skipped correctly at every one of them, in BOTH compilers, with no
    /// compile-time exhaustiveness check on the selfhost side to catch a miss.
    /// `main` breaks none of them.
    fn parseAttrDecl(self: *Parser) ParseError!Index {
        const attrs = try self.parseAttrList();
        switch (self.tok.kind) {
            .kw_function => return self.parseFuncDecl(attrs),
            .kw_let => {
                // §11.11 defines exactly one attribute at this position, so the
                // legal set here is a syntactic property of the position and is
                // checked here. Function attributes keep their own E0076 path
                // in the checker, which sees a richer decl.
                if (!self.attrsAreThreadLocal(attrs)) {
                    try self.fail("'@threadlocal', the only attribute a 'let' accepts");
                    self.synchronizeTopLevel();
                    return none;
                }
                return self.parseValueDecl(.thread);
            },
            else => {
                try self.fail("'function' or 'let' after an attribute");
                self.synchronizeTopLevel();
                return none;
            },
        }
    }

    /// True iff `attrs` is exactly the single attribute `@threadlocal`, with no
    /// argument. Anything else — a second attribute, an argument, a different
    /// name — is rejected by the caller.
    fn attrsAreThreadLocal(self: *Parser, attrs: Index) bool {
        const list = self.tree.kids(attrs);
        if (list.len != 1) return false;
        const attr_kids = self.tree.kids(list[0]);
        if (attr_kids.len != 1) return false; // an argument was supplied
        const name_span = self.tree.get(attr_kids[0]).span;
        return std.mem.eql(u8, self.lx.src[name_span.start..name_span.end], "threadlocal");
    }

    /// `attr_list = attr { attr }`, `attr = "@" IDENT [ "(" string_lit ")" ]`.
    /// One or more `@name`, each optionally carrying a single string argument
    /// (§11.9 `@symbol("...")`). The argument child is ELIDED when absent, so a
    /// bare `@naked`/`@nosplit` keeps the exact 1-child shape it had before
    /// arguments existed and every attr-bearing dump stays byte-identical.
    fn parseAttrList(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        var items: std.ArrayList(Index) = .empty;
        errdefer items.deinit(self.gpa);
        // Bounded: every iteration consumes the `@`, so it cannot outlast input.
        while (self.tok.kind == .at) {
            const at_span = self.tok.span;
            try self.advance(); // '@'
            const name = try self.expectIdent();
            if (self.tok.kind == .l_paren) {
                try self.advance(); // '('
                const arg = if (self.tok.kind == .string_lit) try self.leaf(.string_lit) else blk: {
                    try self.fail("a string literal argument");
                    break :blk none;
                };
                const close = try self.expect(.r_paren, "')'");
                try items.append(self.gpa, try self.tree.add(.attr, join(at_span, close), 0, &.{ name, arg }));
            } else {
                try items.append(self.gpa, try self.tree.add(.attr, join(at_span, self.span(name)), 0, &.{name}));
            }
            // Both IDENT and `)` are ASI terminators (§7), so a newline after an
            // attribute synthesizes a semicolon. An attribute list is only ever
            // followed by another attribute or `function`, so a separator here
            // can never be meaningful — drop it, which lets an attribute sit on
            // its own line above the declaration it modifies.
            while (self.tok.kind == .semicolon) try self.advance();
        }
        const kids = try items.toOwnedSlice(self.gpa);
        defer self.gpa.free(kids);
        const end = if (kids.len == 0) start else self.span(kids[kids.len - 1]);
        return self.tree.add(.attr_list, join(start, end), 0, kids);
    }

    // ---- imports (§17.2) ----------------------------------------------------

    fn parseImportDecl(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'import'
        const body = try self.parseImportBody();
        _ = try self.expect(.kw_from, "'from'");
        const path = if (self.tok.kind == .string_lit) try self.leaf(.string_lit) else blk: {
            try self.fail("a string literal");
            break :blk none;
        };
        return self.tree.add(.import_decl, join(start, self.span(path)), 0, &.{ body, path });
    }

    fn parseImportBody(self: *Parser) ParseError!Index {
        switch (self.tok.kind) {
            .ident => {
                const name = try self.leaf(.ident);
                return self.tree.add(.import_ns, self.span(name), 0, &.{name});
            },
            .star => {
                const start = self.tok.span;
                try self.advance();
                _ = try self.expect(.kw_as, "'as'");
                const name = try self.expectIdent();
                return self.tree.add(.import_star, join(start, self.span(name)), 0, &.{name});
            },
            .l_brace => {
                const start = self.tok.span;
                try self.advance();
                const items = try self.commaList(.r_brace, parseImportItem, false);
                defer self.gpa.free(items);
                const end = try self.expect(.r_brace, "'}'");
                return self.tree.add(.import_group, join(start, end), 0, items);
            },
            else => {
                try self.fail("an import name, '*', or '{'");
                return none;
            },
        }
    }

    fn parseImportItem(self: *Parser) ParseError!Index {
        const name = try self.expectIdent();
        var alias: Index = none;
        if (try self.accept(.kw_as)) alias = try self.expectIdent();
        return self.tree.add(.import_item, self.span(name), 0, &.{ name, alias });
    }

    // =========================================================================
    // Declarations (§10)
    // =========================================================================

    /// `storage` is `.process` for every unattributed `let`/`const` — the
    /// overwhelmingly common case, which keeps `main = 0` and so leaves the AST
    /// shape and dump of existing declarations byte-identical.
    fn parseValueDecl(self: *Parser, storage: ast.GlobalStorage) ParseError!Index {
        const start = self.tok.span;
        const is_const = self.tok.kind == .kw_const;
        try self.advance(); // 'let' | 'const'
        var bindings: std.ArrayList(Index) = .empty;
        defer bindings.deinit(self.gpa);
        try bindings.append(self.gpa, try self.parseBinding());
        while (try self.accept(.comma)) try bindings.append(self.gpa, try self.parseBinding());
        const end = self.span(bindings.items[bindings.items.len - 1]);
        return self.tree.add(if (is_const) .const_decl else .let_decl, join(start, end), @intFromEnum(storage), bindings.items);
    }

    fn parseBinding(self: *Parser) ParseError!Index {
        const pat = if (self.tok.kind == .l_paren) try self.parseTuplePat() else try self.expectIdent();
        var ty: Index = none;
        if (try self.accept(.colon)) ty = try self.parseType();
        var init_expr: Index = none;
        if (try self.accept(.eq)) init_expr = try self.parseExpression();
        const end_idx = if (init_expr != none) init_expr else if (ty != none) ty else pat;
        return self.tree.add(.binding, join(self.span(pat), self.span(end_idx)), 0, &.{ pat, ty, init_expr });
    }

    fn parseTuplePat(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_paren, "'('");
        const items = try self.commaList(.r_paren, parsePat, false);
        defer self.gpa.free(items);
        const end = try self.expect(.r_paren, "')'");
        return self.tree.add(.tuple_pat, join(start, end), 0, items);
    }

    fn parsePat(self: *Parser) ParseError!Index {
        if (self.tok.kind == .l_paren) return self.parseTuplePat();
        return self.expectIdent(); // '_' lexes as an ordinary identifier
    }

    fn parseTypeAlias(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'type'
        const name = try self.expectIdent();
        const generics = try self.maybeGenericParams();
        _ = try self.expect(.eq, "'='");
        const ty = try self.parseType();
        return self.tree.add(.type_alias, join(start, self.span(ty)), 0, &.{ name, generics, ty });
    }

    fn maybeGenericParams(self: *Parser) ParseError!Index {
        if (self.tok.kind != .lt) return none;
        const start = self.tok.span;
        try self.advance();
        const items = try self.commaList(.gt, parseGenericParam, false);
        defer self.gpa.free(items);
        const end = try self.expect(.gt, "'>'");
        return self.tree.add(.generic_params, join(start, end), 0, items);
    }

    fn parseGenericParam(self: *Parser) ParseError!Index {
        const name = try self.expectIdent();
        var constraint: Index = none;
        if (try self.accept(.colon)) constraint = try self.parseConstraint();
        const end_idx = if (constraint != none) constraint else name;
        return self.tree.add(.generic_param, join(self.span(name), self.span(end_idx)), 0, &.{ name, constraint });
    }

    /// `constraint = type_name { "&" type_name }` — '&'-separated, not comma.
    fn parseConstraint(self: *Parser) ParseError!Index {
        var items: std.ArrayList(Index) = .empty;
        defer items.deinit(self.gpa);
        try items.append(self.gpa, try self.expectIdent());
        // Bounded by remaining tokens.
        while (try self.accept(.amp)) try items.append(self.gpa, try self.expectIdent());
        const start = self.span(items.items[0]);
        const end = self.span(items.items[items.items.len - 1]);
        return self.tree.add(.constraint, join(start, end), 0, items.items);
    }

    // ---- functions and methods (§10.3-4) -------------------------------------

    fn parseFuncDecl(self: *Parser, attrs: Index) ParseError!Index {
        const kw_span = self.tok.span;
        try self.advance(); // 'function'
        var recv: Index = none;
        var recv_generics: Index = none;
        if (self.tok.kind == .l_paren) {
            try self.advance();
            recv = try self.parseReceiver(&recv_generics);
            _ = try self.expect(.r_paren, "')'");
        }
        const name = try self.expectIdent();
        const generics = try self.mergeGenericParams(recv_generics, try self.maybeGenericParams());
        const params = try self.parseParams();
        var result: Index = none;
        if (try self.accept(.colon)) result = try self.parseResultType();
        const body = try self.parseBlock();
        // Attrs are elided (6-child form) when absent so the attr-less corpus'
        // AST dumps stay byte-identical; the checker reads `k[6]` only when present.
        const start = if (attrs == none) kw_span else self.span(attrs);
        if (attrs == none) {
            return self.tree.add(.func_decl, join(start, self.span(body)), 0, &.{ recv, name, generics, params, result, body });
        }
        return self.tree.add(.func_decl, join(start, self.span(body)), 0, &.{ recv, name, generics, params, result, body, attrs });
    }

    /// `extern_fn_decl = "extern" "function" IDENT signature` (§11.7). No body,
    /// no receiver, no generics — a bare binding from a Bit name to an external
    /// symbol the linker resolves from a dylib.
    ///
    /// `extern` is a *contextual* keyword: it lexes as an ordinary identifier and
    /// stays usable as one everywhere else. That is unambiguous here because an
    /// identifier can never begin a top-level declaration, so seeing one named
    /// `extern` at declaration position commits with no lookahead.
    fn parseExternFnDecl(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'extern'
        if (self.tok.kind != .kw_function) {
            try self.fail("'function' after 'extern'");
            self.synchronizeTopLevel();
            return none;
        }
        try self.advance(); // 'function'
        const name = try self.expectIdent();
        const params = try self.parseParams();
        var result: Index = none;
        if (try self.accept(.colon)) result = try self.parseResultType();
        const end = if (result == none) self.span(params) else self.span(result);
        return self.tree.add(.extern_fn_decl, join(start, end), 0, &.{ name, params, result });
    }

    /// `receiver = IDENT ':' IDENT [ generic_params ]` (§10.4).
    ///
    /// A receiver on a generic struct (`(s: Stack<T>)`) *declares* `T`, it does
    /// not use it — there is nothing in scope for `T` to name yet. So the list
    /// is parsed as generic params and handed back through `out_generics` to
    /// lead the method's own `<...>`; the receiver node keeps its two-child
    /// shape and names the uninstantiated template.
    fn parseReceiver(self: *Parser, out_generics: *Index) ParseError!Index {
        const name = try self.expectIdent();
        _ = try self.expect(.colon, "':'");
        const ty = try self.expectIdent();
        out_generics.* = try self.maybeGenericParams();
        // The span covers the two kids only, not the type-param list: it stays
        // what a plain receiver's is, and the list has its own node.
        return self.tree.add(.receiver, join(self.span(name), self.span(ty)), 0, &.{ name, ty });
    }

    /// Concatenates the receiver's type params with the method's own
    /// (`function (s: Stack<T>) mapped<U>()`), receiver params first so
    /// `collectFuncDecl` can zip them against the struct's declared params by
    /// position. Either side may be absent.
    fn mergeGenericParams(self: *Parser, a: Index, b: Index) ParseError!Index {
        if (a == none) return b;
        if (b == none) return a;
        const merged_span = join(self.span(a), self.span(b));
        const ak = self.tree.kids(a);
        const bk = self.tree.kids(b);
        const items = try self.gpa.alloc(Index, ak.len + bk.len);
        defer self.gpa.free(items);
        @memcpy(items[0..ak.len], ak);
        @memcpy(items[ak.len..], bk);
        return self.tree.add(.generic_params, merged_span, 0, items);
    }

    fn parseParams(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_paren, "'('");
        const items = try self.commaList(.r_paren, parseParam, false);
        defer self.gpa.free(items);
        const end = try self.expect(.r_paren, "')'");
        return self.tree.add(.params, join(start, end), 0, items);
    }

    fn parseParam(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        const is_rest = try self.accept(.ellipsis);
        const name = try self.expectIdent();
        _ = try self.expect(.colon, "':'");
        const ty = try self.parseType();
        return self.tree.add(if (is_rest) .param_rest else .param, join(start, self.span(ty)), 0, &.{ name, ty });
    }

    // ---- struct / interface (§10.5-6) ----------------------------------------

    fn parseStructDecl(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'struct'
        const name = try self.expectIdent();
        const generics = try self.maybeGenericParams();
        _ = try self.expect(.l_brace, "'{'");
        const items = try self.commaList(.r_brace, parseField, true);
        defer self.gpa.free(items);
        const end = try self.expect(.r_brace, "'}'");
        const field_list = try self.tree.add(.field_list, join(start, end), 0, items);
        return self.tree.add(.struct_decl, join(start, end), 0, &.{ name, generics, field_list });
    }

    fn parseField(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        const exported = try self.accept(.kw_export);
        const name = try self.expectIdent();
        _ = try self.expect(.colon, "':'");
        const ty = try self.parseType();
        const node = try self.tree.add(.field, join(start, self.span(ty)), 0, &.{ name, ty });
        if (!exported) return node;
        return self.tree.add(.@"export", join(start, self.span(ty)), 0, &.{node});
    }

    fn parseEnumDecl(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'enum'
        const name = try self.expectIdent();
        const generics = try self.maybeGenericParams();
        _ = try self.expect(.l_brace, "'{'");
        const items = try self.commaList(.r_brace, parseVariant, true);
        defer self.gpa.free(items);
        const end = try self.expect(.r_brace, "'}'");
        const variant_list = try self.tree.add(.variant_list, join(start, end), 0, items);
        return self.tree.add(.enum_decl, join(start, end), 0, &.{ name, generics, variant_list });
    }

    /// One enum variant: a name, optionally followed by a parenthesized payload
    /// type list `V(T, U)` (Stage 2 — parsed now, carried as `type_list`).
    fn parseVariant(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        const name = try self.expectIdent();
        var payload: Index = none;
        var end = self.span(name);
        if (try self.accept(.l_paren)) {
            const tys = try self.commaList(.r_paren, parseType, false);
            defer self.gpa.free(tys);
            end = try self.expect(.r_paren, "')'");
            payload = try self.tree.add(.type_list, join(start, end), 0, tys);
        }
        return self.tree.add(.enum_variant, join(start, end), 0, &.{ name, payload });
    }

    fn parseInterfaceDecl(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'interface'
        const name = try self.expectIdent();
        const generics = try self.maybeGenericParams();
        _ = try self.expect(.l_brace, "'{'");
        const items = try self.commaList(.r_brace, parseMethodSig, true);
        defer self.gpa.free(items);
        const end = try self.expect(.r_brace, "'}'");
        const sig_list = try self.tree.add(.method_sig_list, join(start, end), 0, items);
        return self.tree.add(.interface_decl, join(start, end), 0, &.{ name, generics, sig_list });
    }

    fn parseMethodSig(self: *Parser) ParseError!Index {
        const name = try self.expectIdent();
        const params = try self.parseParams();
        var result: Index = none;
        if (try self.accept(.colon)) result = try self.parseResultType();
        const end_idx = if (result != none) result else params;
        return self.tree.add(.method_sig, join(self.span(name), self.span(end_idx)), 0, &.{ name, params, result });
    }

    // =========================================================================
    // Types (§11)
    // =========================================================================

    fn canStartType(kind: Kind) bool {
        return switch (kind) {
            .ident, .l_bracket, .kw_map, .kw_chan, .l_paren => true,
            else => false,
        };
    }

    fn parseType(self: *Parser) ParseError!Index {
        switch (self.tok.kind) {
            .ident => {
                const name = try self.leaf(.ident);
                if (self.tok.kind != .lt) return name;
                // Type position: '<' is unambiguously generic_inst, no speculation needed.
                try self.advance();
                const items = try self.commaList(.gt, parseType, false);
                defer self.gpa.free(items);
                const end = try self.expectGenericClose();
                const targs = try self.tree.add(.type_args, join(self.span(name), end), 0, items);
                return self.tree.add(.generic_inst, join(self.span(name), end), 0, &.{ name, targs });
            },
            .star => return self.parsePtrType(),
            .l_bracket => return self.parseSliceOrArrayType(),
            .kw_map => return self.parseMapType(),
            .kw_chan => return self.parseChanType(),
            .l_paren => return self.parseTupleOrFuncOrParenType(),
            else => {
                try self.fail("a type");
                return none;
            },
        }
    }

    fn parsePtrType(self: *Parser) ParseError!Index {
        const start = try self.expect(.star, "'*'");
        const elem = try self.parseType();
        return self.tree.add(.ptr_type, join(start, self.span(elem)), 0, &.{elem});
    }

    fn parseSliceOrArrayType(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_bracket, "'['");
        if (try self.accept(.r_bracket)) {
            const elem = try self.parseType();
            return self.tree.add(.slice_type, join(start, self.span(elem)), 0, &.{elem});
        }
        const size = if (self.tok.kind == .int_lit) try self.leaf(.int_lit) else blk: {
            try self.fail("an array size");
            break :blk none;
        };
        _ = try self.expect(.r_bracket, "']'");
        const elem = try self.parseType();
        return self.tree.add(.array_type, join(start, self.span(elem)), 0, &.{ size, elem });
    }

    fn parseMapType(self: *Parser) ParseError!Index {
        const start = try self.expect(.kw_map, "'map'");
        _ = try self.expect(.lt, "'<'");
        const key = try self.parseType();
        _ = try self.expect(.comma, "','");
        const val = try self.parseType();
        const end = try self.expectGenericClose();
        return self.tree.add(.map_type, join(start, end), 0, &.{ key, val });
    }

    fn parseChanType(self: *Parser) ParseError!Index {
        const start = try self.expect(.kw_chan, "'chan'");
        _ = try self.expect(.lt, "'<'");
        const elem = try self.parseType();
        const end = try self.expectGenericClose();
        return self.tree.add(.chan_type, join(start, end), 0, &.{elem});
    }

    /// `(` already means one of: `()` (the unit type — chiefly `()!`, §18.2),
    /// `() => R` (func_type, zero params), a tuple type, a parenthesized type,
    /// or a func_type with 1+ params — all deterministic from the tokens seen
    /// so far, no speculation needed.
    fn parseTupleOrFuncOrParenType(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_paren, "'('");
        if (try self.accept(.r_paren)) {
            // `() =>` is a zero-param function type; a bare `()` is the unit
            // (void) type, which only appears where a result is written but
            // cannot be omitted — i.e. carrying `!` (`()!`).
            if (!try self.accept(.fat_arrow)) {
                return self.tree.add(.void_type, join(start, start), 0, &.{});
            }
            const result = try self.parseResultType();
            const list = try self.tree.add(.type_list, join(start, start), 0, &.{});
            return self.tree.add(.func_type, join(start, self.span(result)), 0, &.{ list, result });
        }
        var items: std.ArrayList(Index) = .empty;
        defer items.deinit(self.gpa);
        try items.append(self.gpa, try self.parseType());
        // Bounded by remaining tokens.
        while (try self.accept(.comma)) {
            if (self.tok.kind == .r_paren) break; // trailing comma
            try items.append(self.gpa, try self.parseType());
        }
        const end = try self.expect(.r_paren, "')'");
        if (try self.accept(.fat_arrow)) {
            const result = try self.parseResultType();
            const list = try self.tree.add(.type_list, join(start, end), 0, items.items);
            return self.tree.add(.func_type, join(start, self.span(result)), 0, &.{ list, result });
        }
        if (items.items.len == 1) return items.items[0]; // transparent parenthesized type
        return self.tree.add(.tuple_type, join(start, end), 0, items.items);
    }

    fn parseResultType(self: *Parser) ParseError!Index {
        const ty = try self.parseType();
        if (!try self.accept(.bang)) return ty;
        var err_ty: Index = none;
        if (canStartType(self.tok.kind)) err_ty = try self.parseType();
        const end_idx = if (err_ty != none) err_ty else ty;
        return self.tree.add(.fallible, join(self.span(ty), self.span(end_idx)), 0, &.{ ty, err_ty });
    }

    // =========================================================================
    // Statements (§13.1)
    // =========================================================================

    fn parseBlock(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_brace, "'{'");
        var stmts: std.ArrayList(Index) = .empty;
        defer stmts.deinit(self.gpa);
        var guard: u32 = 0;
        while (self.tok.kind != .r_brace and self.tok.kind != .eof and guard < max_block_stmts) : (guard += 1) {
            if (try self.accept(.semicolon)) continue;
            try stmts.append(self.gpa, try self.parseStatement());
            if (!try self.accept(.semicolon) and self.tok.kind != .r_brace and self.tok.kind != .eof) {
                try self.fail("';'");
                self.synchronizeStatement();
            }
        }
        if (guard >= max_block_stmts) try self.tooMany("statements in a block");
        const end = try self.expect(.r_brace, "'}'");
        return self.tree.add(.block, join(start, end), 0, stmts.items);
    }

    /// Skips to the next statement-starting token, `;`, or a block/case
    /// boundary. Bounded by remaining tokens.
    fn synchronizeStatement(self: *Parser) void {
        while (self.tok.kind != .eof) {
            switch (self.tok.kind) {
                .semicolon => {
                    _ = self.advance() catch return;
                    return;
                },
                .r_brace, .kw_case, .kw_default => return,
                .kw_let, .kw_const, .kw_if, .kw_while, .kw_for, .kw_switch, .kw_match, .kw_select, .kw_return, .kw_fail, .kw_break, .kw_continue, .kw_spawn, .kw_defer => return,
                else => {},
            }
            _ = self.advance() catch return;
        }
    }

    fn parseStatement(self: *Parser) ParseError!Index {
        switch (self.tok.kind) {
            .kw_let, .kw_const => return self.parseValueDecl(.process),
            .kw_if => return self.parseIfStmt(),
            .kw_while => return self.parseWhileStmt(),
            .kw_for => return self.parseForStmt(),
            .kw_switch => return self.parseSwitchStmt(),
            .kw_match => return self.parseMatch(false),
            .kw_select => return self.parseSelectStmt(),
            .kw_return => return self.parseReturnStmt(),
            .kw_fail => return self.parseFailStmt(),
            .kw_break => {
                const s = self.tok.span;
                try self.advance();
                return self.tree.add(.break_stmt, s, 0, &.{});
            },
            .kw_continue => {
                const s = self.tok.span;
                try self.advance();
                return self.tree.add(.continue_stmt, s, 0, &.{});
            },
            .kw_spawn => return self.parseSpawnOrDefer(.spawn_stmt),
            .kw_defer => return self.parseSpawnOrDefer(.defer_stmt),
            .l_brace => return self.parseBlock(),
            else => return self.parseSimpleStmt(),
        }
    }

    fn parseSpawnOrDefer(self: *Parser, tag: ast.Tag) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'spawn' | 'defer'
        const call_expr = try self.parsePostfix();
        return self.tree.add(tag, join(start, self.span(call_expr)), 0, &.{call_expr});
    }

    /// The current token's source text — used only to match the contextual
    /// keywords inside an `asm` block (`x64`/`arm64`/`input`/`result`/`clobber`/
    /// `volatile`), which lex as ordinary identifiers.
    fn curText(self: *const Parser) []const u8 {
        return self.lx.src[self.tok.span.start..self.tok.span.end];
    }

    /// Consumes an identifier that must read exactly `word`; reports otherwise.
    fn expectWord(self: *Parser, word: []const u8) ParseError!void {
        if (self.tok.kind == .ident and std.mem.eql(u8, self.curText(), word)) {
            try self.advance();
            return;
        }
        try self.fail(word);
    }

    /// `asm [volatile] { directive... }` (§11.6). An expression yielding its
    /// `result` operand, or `()` when it declares none. Both target sub-blocks
    /// live on the one node — codegen reads only its own arch's — because Bit
    /// has no arch-conditional compilation and the runtime sites need none.
    fn parseAsm(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'asm'
        var is_volatile: u32 = 0;
        if (self.tok.kind == .ident and std.mem.eql(u8, self.curText(), "volatile")) {
            is_volatile = 1;
            try self.advance();
        }
        _ = try self.expect(.l_brace, "'{'");

        var x64_code: Index = none;
        var arm64_code: Index = none;
        var result: Index = none;
        var clob_x64: Index = none;
        var clob_arm64: Index = none;
        var kids: std.ArrayList(Index) = .empty;
        defer kids.deinit(self.gpa);

        var guard: u32 = 0;
        while (true) : (guard += 1) {
            // Statements auto-terminate at newlines, so a `;` sits between
            // directives (after each `}`); skip them.
            while (self.tok.kind == .semicolon) try self.advance();
            if (self.tok.kind == .r_brace or self.tok.kind == .eof) break;
            if (guard >= max_asm_items) {
                try self.tooMany("asm directives");
                break;
            }
            if (self.tok.kind != .ident) {
                try self.fail("an asm directive");
                break;
            }
            const dir = self.curText();
            if (std.mem.eql(u8, dir, "x64")) {
                try self.advance();
                x64_code = try self.parseAsmCode();
            } else if (std.mem.eql(u8, dir, "arm64")) {
                try self.advance();
                arm64_code = try self.parseAsmCode();
            } else if (std.mem.eql(u8, dir, "input")) {
                try self.advance();
                try kids.append(self.gpa, try self.parseAsmOperand(.asm_input));
            } else if (std.mem.eql(u8, dir, "result")) {
                try self.advance();
                result = try self.parseAsmOperand(.asm_result);
            } else if (std.mem.eql(u8, dir, "clobber")) {
                try self.advance();
                const is_x64 = self.tok.kind == .ident and std.mem.eql(u8, self.curText(), "x64");
                _ = try self.expectIdent(); // arch marker (x64 | arm64)
                const clob = try self.parseAsmClobber();
                if (is_x64) clob_x64 = clob else clob_arm64 = clob;
            } else {
                try self.fail("an asm directive (x64, arm64, input, result, clobber)");
                break;
            }
        }
        const end = try self.expect(.r_brace, "'}'");

        // Fixed-position header, then every `input` operand.
        var all: std.ArrayList(Index) = .empty;
        defer all.deinit(self.gpa);
        try all.appendSlice(self.gpa, &.{ x64_code, arm64_code, result, clob_x64, clob_arm64 });
        try all.appendSlice(self.gpa, kids.items);
        return self.tree.add(.asm_stmt, join(start, end), is_volatile, all.items);
    }

    /// `{ int_lit, ... }` — one target's pre-encoded bytes (x64) / words (arm64).
    fn parseAsmCode(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_brace, "'{'");
        const items = try self.commaList(.r_brace, parseAsmInt, true);
        defer self.gpa.free(items);
        const end = try self.expect(.r_brace, "'}'");
        return self.tree.add(.asm_code, join(start, end), 0, items);
    }

    fn parseAsmInt(self: *Parser) ParseError!Index {
        if (self.tok.kind != .int_lit) {
            try self.fail("an integer");
            return none;
        }
        return self.leaf(.int_lit);
    }

    /// `arm64 <reg> x64 <reg> ( = expr | : type )`.
    fn parseAsmOperand(self: *Parser, tag: ast.Tag) ParseError!Index {
        const start = self.tok.span;
        try self.expectWord("arm64");
        const arm64_reg = try self.expectIdent();
        try self.expectWord("x64");
        const x64_reg = try self.expectIdent();
        if (tag == .asm_input) {
            _ = try self.expect(.eq, "'='");
            const val = try self.parseExpression();
            return self.tree.add(.asm_input, join(start, self.span(val)), 0, &.{ arm64_reg, x64_reg, val });
        }
        _ = try self.expect(.colon, "':'");
        const ty = try self.parseType();
        return self.tree.add(.asm_result, join(start, self.span(ty)), 0, &.{ arm64_reg, x64_reg, ty });
    }

    /// `{ reg_ident, ... }` — clobbered registers (may include `memory`).
    fn parseAsmClobber(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_brace, "'{'");
        const items = try self.commaList(.r_brace, expectIdentItem, true);
        defer self.gpa.free(items);
        const end = try self.expect(.r_brace, "'}'");
        return self.tree.add(.asm_clobber, join(start, end), 0, items);
    }

    fn parseReturnStmt(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'return'
        if (!canStartExpression(self.tok.kind)) return self.tree.add(.return_stmt, start, 0, &.{});
        const items = try self.exprList1();
        defer self.gpa.free(items);
        const end = self.span(items[items.len - 1]);
        return self.tree.add(.return_stmt, join(start, end), 0, items);
    }

    fn parseFailStmt(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'fail'
        const e = try self.parseExpression();
        return self.tree.add(.fail_stmt, join(start, self.span(e)), 0, &.{e});
    }

    fn parseIfStmt(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'if'
        _ = try self.expect(.l_paren, "'('");
        const cond = try self.parseExpression();
        _ = try self.expect(.r_paren, "')'");
        const then_blk = try self.parseBlock();
        var else_blk: Index = none;
        if (try self.accept(.kw_else)) {
            else_blk = if (self.tok.kind == .kw_if) try self.parseIfStmt() else try self.parseBlock();
        }
        const end_idx = if (else_blk != none) else_blk else then_blk;
        return self.tree.add(.if_stmt, join(start, self.span(end_idx)), 0, &.{ cond, then_blk, else_blk });
    }

    fn parseWhileStmt(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'while'
        _ = try self.expect(.l_paren, "'('");
        const cond = try self.parseExpression();
        _ = try self.expect(.r_paren, "')'");
        const body = try self.parseBlock();
        return self.tree.add(.while_stmt, join(start, self.span(body)), 0, &.{ cond, body });
    }

    // ---- for (§13.1: for_c | for_of | for_in | infinite) --------------------

    /// Parses an expression with composite literals suppressed at its top
    /// level (`no_composite_lit`) — used for `for_of`/`for_in`'s iterable,
    /// which the grammar places directly before the loop's `block` with no
    /// disambiguating parens (see the field doc comment).
    fn parseIterExpression(self: *Parser) ParseError!Index {
        const saved_no_composite = self.no_composite_lit;
        self.no_composite_lit = true;
        const e = try self.parseExpression();
        self.no_composite_lit = saved_no_composite;
        return e;
    }

    fn parseForStmt(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'for'
        if (self.tok.kind == .l_paren) {
            if (try self.speculate(tryForOfTuple)) |node| {
                const body = try self.parseBlock();
                const parts = self.tree.kids(node);
                return self.tree.add(.for_of, join(start, self.span(body)), 0, &.{ parts[0], parts[1], body });
            }
            const clause = try self.parseForC();
            const body = try self.parseBlock();
            const parts = self.tree.kids(clause);
            return self.tree.add(.for_c, join(start, self.span(body)), 0, &.{ parts[0], parts[1], parts[2], body });
        }
        if (self.tok.kind == .ident) {
            const m = self.mark();
            const name = try self.expectIdent();
            if (try self.accept(.kw_of)) {
                const iter = try self.parseIterExpression();
                const body = try self.parseBlock();
                return self.tree.add(.for_of, join(start, self.span(body)), 0, &.{ name, iter, body });
            }
            if (try self.accept(.kw_in)) {
                const iter = try self.parseIterExpression();
                const body = try self.parseBlock();
                return self.tree.add(.for_in, join(start, self.span(body)), 0, &.{ name, iter, body });
            }
            self.reset(m);
            try self.fail("'of' or 'in'");
            self.synchronizeStatement();
            return none;
        }
        const body = try self.parseBlock();
        return self.tree.add(.for_inf, join(start, self.span(body)), 0, &.{body});
    }

    /// Speculative: `"(" pat "," pat ")" "of" expression`, returned as a
    /// 2-element scratch node `[tuple_pat, iter_expr]` for the caller to unpack.
    fn tryForOfTuple(self: *Parser) ParseError!Index {
        const binder = try self.parseTuplePat();
        if (self.tree.kids(binder).len < 2) return error.Speculative; // needs 2+ per grammar
        _ = try self.expect(.kw_of, "'of'");
        const iter = try self.parseIterExpression();
        return self.tree.add(.for_of, self.span(binder), 0, &.{ binder, iter });
    }

    fn parseForC(self: *Parser) ParseError!Index {
        _ = try self.expect(.l_paren, "'('");
        var init_stmt: Index = none;
        if (self.tok.kind == .kw_let or self.tok.kind == .kw_const) {
            init_stmt = try self.parseValueDecl(.process);
        } else if (self.tok.kind != .semicolon) {
            init_stmt = try self.parseSimpleStmtNoTerm();
        }
        _ = try self.expect(.semicolon, "';'");
        var cond: Index = none;
        if (self.tok.kind != .semicolon) cond = try self.parseExpression();
        _ = try self.expect(.semicolon, "';'");
        var post: Index = none;
        if (self.tok.kind != .r_paren) post = try self.parseSimpleStmtNoTerm();
        _ = try self.expect(.r_paren, "')'");
        return self.tree.add(.for_c, self.tok.span, 0, &.{ init_stmt, cond, post });
    }

    // ---- switch (§13.1) -------------------------------------------------------

    fn parseSwitchStmt(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'switch'
        var subject: Index = none;
        if (try self.accept(.l_paren)) {
            subject = try self.parseExpression();
            _ = try self.expect(.r_paren, "')'");
        }
        _ = try self.expect(.l_brace, "'{'");
        var cases: std.ArrayList(Index) = .empty;
        defer cases.deinit(self.gpa);
        var guard: u32 = 0;
        while (self.tok.kind != .r_brace and self.tok.kind != .eof and guard < max_case_clauses) : (guard += 1) {
            if (self.tok.kind == .kw_case) {
                const cstart = self.tok.span;
                try self.advance();
                const exprs = try self.exprList1();
                defer self.gpa.free(exprs);
                _ = try self.expect(.colon, "':'");
                const stmts = try self.parseCaseStmts();
                defer self.gpa.free(stmts);
                const elist = try self.tree.add(.expr_list, cstart, 0, exprs);
                const slist = try self.tree.add(.stmt_list, cstart, 0, stmts);
                try cases.append(self.gpa, try self.tree.add(.switch_case, cstart, 0, &.{ elist, slist }));
            } else if (self.tok.kind == .kw_default) {
                const dstart = self.tok.span;
                try self.advance();
                _ = try self.expect(.colon, "':'");
                const stmts = try self.parseCaseStmts();
                defer self.gpa.free(stmts);
                const slist = try self.tree.add(.stmt_list, dstart, 0, stmts);
                try cases.append(self.gpa, try self.tree.add(.switch_default, dstart, 0, &.{slist}));
            } else {
                try self.fail("'case' or 'default'");
                // synchronizeStatement stops at a statement keyword without
                // consuming it; in a clause body that would spin this loop, so
                // step past the offending token first to guarantee progress.
                try self.advance();
                self.synchronizeStatement();
            }
        }
        if (guard >= max_case_clauses) try self.tooMany("case clauses");
        const end = try self.expect(.r_brace, "'}'");
        const clist = try self.tree.add(.case_list, join(start, end), 0, cases.items);
        return self.tree.add(.switch_stmt, join(start, end), 0, &.{ subject, clist });
    }

    /// Statements inside one `case`/`default` clause, up to the next clause or `}`.
    fn parseCaseStmts(self: *Parser) ParseError![]Index {
        var stmts: std.ArrayList(Index) = .empty;
        errdefer stmts.deinit(self.gpa);
        var guard: u32 = 0;
        while (self.tok.kind != .kw_case and self.tok.kind != .kw_default and self.tok.kind != .r_brace and self.tok.kind != .eof and guard < max_block_stmts) : (guard += 1) {
            if (try self.accept(.semicolon)) continue;
            try stmts.append(self.gpa, try self.parseStatement());
            const at_boundary = self.tok.kind == .kw_case or self.tok.kind == .kw_default or self.tok.kind == .r_brace or self.tok.kind == .eof;
            if (!try self.accept(.semicolon) and !at_boundary) {
                try self.fail("';'");
                self.synchronizeStatement();
            }
        }
        return stmts.toOwnedSlice(self.gpa);
    }

    // ---- match (§16.4) ---------------------------------------------------------

    /// `match (subject) { Pat => body, ... }` (§13.8). `as_expr` selects the arm
    /// body grammar: an expression (the match yields that value, §13.8) in
    /// expression position, or a statement (block or single) in statement
    /// position. The node tag (`match_stmt`) is shared; the check/lower stage
    /// picks the value- or effect-producing path by where the node appears.
    fn parseMatch(self: *Parser, as_expr: bool) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'match'
        _ = try self.expect(.l_paren, "'('");
        const subject = try self.parseExpression();
        _ = try self.expect(.r_paren, "')'");
        _ = try self.expect(.l_brace, "'{'");
        var arms: std.ArrayList(Index) = .empty;
        defer arms.deinit(self.gpa);
        var guard: u32 = 0;
        while (self.tok.kind != .r_brace and self.tok.kind != .eof and guard < max_case_clauses) : (guard += 1) {
            // Arms separate on `,` or `;` (ASI supplies the `;` at a newline);
            // one-liners `A => x, B => y` and multi-line bodies both parse.
            if (try self.accept(.semicolon) or try self.accept(.comma)) continue;
            try arms.append(self.gpa, try self.parseMatchArm(as_expr));
            const at_boundary = self.tok.kind == .r_brace or self.tok.kind == .eof;
            if (!try self.accept(.semicolon) and !try self.accept(.comma) and !at_boundary) {
                try self.fail("',' or ';'");
                self.synchronizeStatement();
            }
        }
        if (guard >= max_case_clauses) try self.tooMany("match arms");
        const end = try self.expect(.r_brace, "'}'");
        const arm_list = try self.tree.add(.arm_list, join(start, end), 0, arms.items);
        return self.tree.add(.match_stmt, join(start, end), 0, &.{ subject, arm_list });
    }

    fn parseMatchArm(self: *Parser, as_expr: bool) ParseError!Index {
        const start = self.tok.span;
        const pat = try self.parseVariantPat();
        _ = try self.expect(.fat_arrow, "'=>'");
        const body = if (as_expr) try self.parseExpression() else try self.parseStatement();
        return self.tree.add(.match_arm, join(start, self.span(body)), 0, &.{ pat, body });
    }

    /// A variant pattern: a variant name, optionally binding its payload
    /// `V(a, b)` — the binder list is `none` for a no-payload variant.
    fn parseVariantPat(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        const name = try self.expectIdent();
        var binders: Index = none;
        var end = self.span(name);
        if (try self.accept(.l_paren)) {
            const ids = try self.commaList(.r_paren, expectIdentItem, false);
            defer self.gpa.free(ids);
            end = try self.expect(.r_paren, "')'");
            binders = try self.tree.add(.expr_list, join(start, end), 0, ids);
        }
        return self.tree.add(.variant_pat, join(start, end), 0, &.{ name, binders });
    }

    /// A bare identifier as a `commaList` item (a match-arm payload binder).
    fn expectIdentItem(self: *Parser) ParseError!Index {
        return self.expectIdent();
    }

    // ---- select (§16.3) --------------------------------------------------------

    fn parseSelectStmt(self: *Parser) ParseError!Index {
        const start = self.tok.span;
        try self.advance(); // 'select'
        _ = try self.expect(.l_brace, "'{'");
        var clauses: std.ArrayList(Index) = .empty;
        defer clauses.deinit(self.gpa);
        var guard: u32 = 0;
        while (self.tok.kind != .r_brace and self.tok.kind != .eof and guard < max_case_clauses) : (guard += 1) {
            if (self.tok.kind == .kw_case) {
                const cstart = self.tok.span;
                try self.advance();
                const comm = try self.parseComm();
                _ = try self.expect(.colon, "':'");
                const stmts = try self.parseCaseStmts();
                defer self.gpa.free(stmts);
                const slist = try self.tree.add(.stmt_list, cstart, 0, stmts);
                try clauses.append(self.gpa, try self.tree.add(.comm_case, cstart, 0, &.{ comm, slist }));
            } else if (self.tok.kind == .kw_default) {
                const dstart = self.tok.span;
                try self.advance();
                _ = try self.expect(.colon, "':'");
                const stmts = try self.parseCaseStmts();
                defer self.gpa.free(stmts);
                const slist = try self.tree.add(.stmt_list, dstart, 0, stmts);
                try clauses.append(self.gpa, try self.tree.add(.comm_default, dstart, 0, &.{slist}));
            } else {
                try self.fail("'case' or 'default'");
                // Guarantee progress (see parseSwitchStmt): synchronizeStatement
                // does not consume a leading statement keyword.
                try self.advance();
                self.synchronizeStatement();
            }
        }
        if (guard >= max_case_clauses) try self.tooMany("select clauses");
        const end = try self.expect(.r_brace, "'}'");
        return self.tree.add(.select_stmt, join(start, end), 0, clauses.items);
    }

    fn parseComm(self: *Parser) ParseError!Index {
        if (self.tok.kind == .ident or self.tok.kind == .l_paren) {
            if (try self.speculate(tryRecvBindWithBinder)) |node| return node;
        }
        const e = try self.parseExpression();
        if (try self.accept(.arrow_left)) {
            const rhs = try self.parseExpression();
            return self.tree.add(.send_stmt, join(self.span(e), self.span(rhs)), 0, &.{ e, rhs });
        }
        return self.tree.add(.recv_bind, self.span(e), 0, &.{ none, e });
    }

    fn tryRecvBindWithBinder(self: *Parser) ParseError!Index {
        const binder = if (self.tok.kind == .l_paren) try self.parseTuplePat() else try self.expectIdent();
        _ = try self.expect(.eq, "'='");
        _ = try self.expect(.arrow_left, "'<-'");
        const e = try self.parseExpression();
        return self.tree.add(.recv_bind, join(self.span(binder), self.span(e)), 0, &.{ binder, e });
    }

    // ---- assign / inc-dec / expr / send (§13.1) --------------------------------

    fn isAssignOp(k: Kind) bool {
        return switch (k) {
            .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .shl_eq, .shr_eq => true,
            else => false,
        };
    }

    /// `assign_stmt | inc_dec_stmt | send_stmt | expr_stmt`, without consuming
    /// the trailing statement terminator (the caller's loop does that).
    fn parseSimpleStmt(self: *Parser) ParseError!Index {
        return self.parseSimpleStmtNoTerm();
    }

    fn parseSimpleStmtNoTerm(self: *Parser) ParseError!Index {
        if (self.tok.kind == .l_paren) {
            if (try self.speculate(tryTuplePatAssign)) |node| return node;
        }
        const first = try self.parseExpression();
        if (self.tok.kind == .plus_plus or self.tok.kind == .minus_minus) {
            const is_inc = self.tok.kind == .plus_plus;
            const end = self.tok.span;
            try self.advance();
            return self.tree.add(if (is_inc) .inc_stmt else .dec_stmt, join(self.span(first), end), 0, &.{first});
        }
        if (try self.accept(.arrow_left)) {
            const rhs = try self.parseExpression();
            return self.tree.add(.send_stmt, join(self.span(first), self.span(rhs)), 0, &.{ first, rhs });
        }
        if (self.tok.kind == .comma or isAssignOp(self.tok.kind)) {
            var lhss: std.ArrayList(Index) = .empty;
            defer lhss.deinit(self.gpa);
            try lhss.append(self.gpa, first);
            while (try self.accept(.comma)) try lhss.append(self.gpa, try self.parseExpression());
            if (!isAssignOp(self.tok.kind)) {
                try self.fail("an assignment operator");
                return self.tree.add(.expr_stmt, self.span(first), 0, &.{first});
            }
            const op = self.tok.kind;
            try self.advance();
            const rhss = try self.exprList1();
            defer self.gpa.free(rhss);
            const lhs_list = try self.tree.add(.lhs_list, self.span(lhss.items[0]), 0, lhss.items);
            const rhs_list = try self.tree.add(.expr_list, self.span(rhss[0]), 0, rhss);
            return self.tree.add(.assign, join(self.span(lhss.items[0]), self.span(rhss[rhss.len - 1])), @intFromEnum(op), &.{ lhs_list, rhs_list });
        }
        return self.tree.add(.expr_stmt, self.span(first), 0, &.{first});
    }

    fn tryTuplePatAssign(self: *Parser) ParseError!Index {
        const pat = try self.parseTuplePat();
        if (!isAssignOp(self.tok.kind)) return error.Speculative;
        const op = self.tok.kind;
        try self.advance();
        const rhss = try self.exprList1();
        defer self.gpa.free(rhss);
        const lhs_list = try self.tree.add(.lhs_list, self.span(pat), 0, &.{pat});
        const rhs_list = try self.tree.add(.expr_list, self.span(rhss[0]), 0, rhss);
        return self.tree.add(.assign, join(self.span(pat), self.span(rhss[rhss.len - 1])), @intFromEnum(op), &.{ lhs_list, rhs_list });
    }

    // =========================================================================
    // Expressions (§12)
    // =========================================================================

    /// Whether `k` can begin an expression. `parseReturnStmt` is the only
    /// caller: it decides a bare `return` from `return expr`. The prefix-operator
    /// tail must therefore track `parseUnary`'s own set exactly — `.star`, the
    /// §11.4 raw-pointer dereference, was missing here while `parseUnary`
    /// accepted it, so `return *p` was rejected as a bare return followed by
    /// stray input even though `let v = *p` parsed fine.
    fn canStartExpression(k: Kind) bool {
        return switch (k) {
            .ident, .int_lit, .float_lit, .string_lit, .str_part, .raw_string_lit, .rune_lit, .bool_lit, .nil_lit, .l_paren, .l_bracket, .kw_map, .kw_chan, .kw_match, .kw_asm, .bang, .minus, .plus, .tilde, .arrow_left, .star => true,
            else => false,
        };
    }

    /// `expression = arrow_fn | catch_expr`. The single-identifier arrow form
    /// (`x => ...`) needs one token of lookahead past the identifier; every
    /// other arrow form starts with `(` and is handled inside `parsePrimary`.
    fn parseExpression(self: *Parser) ParseError!Index {
        if (self.tok.kind == .ident) {
            const m = self.mark();
            const name = try self.leaf(.ident);
            if (self.tok.kind == .fat_arrow) {
                try self.advance();
                const param = try self.tree.add(.arrow_p, self.span(name), 0, &.{ name, none });
                const params = try self.tree.add(.arrow_params, self.span(name), 0, &.{param});
                const body = if (self.tok.kind == .l_brace) try self.parseBlock() else try self.parseExpression();
                return self.tree.add(.arrow_fn, join(self.span(name), self.span(body)), 0, &.{ params, body });
            }
            self.reset(m);
        }
        return self.parseCatchExpr();
    }

    /// `catch_expr = binary [ "catch" ( expression | IDENT block ) ]`.
    fn parseCatchExpr(self: *Parser) ParseError!Index {
        const expr = try self.parseBinary(1);
        if (self.tok.kind != .kw_catch) return expr;
        try self.advance();
        if (self.tok.kind == .ident) {
            if (try self.speculate(tryCatchBind)) |bind| {
                const parts = self.tree.kids(bind);
                return self.tree.add(.catch_bind, join(self.span(expr), self.span(parts[1])), 0, &.{ expr, parts[0], parts[1] });
            }
        }
        const default_expr = try self.parseExpression();
        return self.tree.add(.catch_default, join(self.span(expr), self.span(default_expr)), 0, &.{ expr, default_expr });
    }

    /// Speculative: `IDENT block`, returned as a 2-element scratch node.
    fn tryCatchBind(self: *Parser) ParseError!Index {
        const name = try self.expectIdent();
        const block = try self.parseBlock();
        return self.tree.add(.catch_bind, self.span(name), 0, &.{ name, block });
    }

    /// Precedence climbing over the left-associative binary table (§12).
    fn precedenceOf(k: Kind) u8 {
        return switch (k) {
            .star, .slash, .percent, .shl, .shr, .amp => 6,
            .plus, .minus, .pipe, .caret => 5,
            .eq_eq, .bang_eq, .lt, .lt_eq, .gt, .gt_eq => 4,
            .amp_amp => 3,
            .pipe_pipe => 2,
            else => 0,
        };
    }

    fn parseBinary(self: *Parser, min_prec: u8) ParseError!Index {
        var lhs = try self.parseUnary();
        // Bounded by remaining tokens: each iteration consumes an operator.
        while (true) {
            const prec = precedenceOf(self.tok.kind);
            if (prec == 0 or prec < min_prec) break;
            const op = self.tok.kind;
            try self.advance();
            const rhs = try self.parseBinary(prec + 1);
            lhs = try self.tree.add(.binary, join(self.span(lhs), self.span(rhs)), @intFromEnum(op), &.{ lhs, rhs });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) ParseError!Index {
        switch (self.tok.kind) {
            // `*` is the pointer dereference prefix (`*p`, load/store); `<-` is
            // channel receive. Both ride the `.unary` node (main = the operator).
            .bang, .minus, .plus, .tilde, .arrow_left, .star => {
                const start = self.tok.span;
                const op = self.tok.kind;
                try self.advance();
                const operand = try self.parseUnary();
                return self.tree.add(.unary, join(start, self.span(operand)), @intFromEnum(op), &.{operand});
            },
            else => return self.parsePostfix(),
        }
    }

    // ---- postfix chain (§12, call/index/slice/member/type_assert/?) -----------

    fn parsePostfix(self: *Parser) ParseError!Index {
        var expr = try self.parsePrimary();
        var bare_name = self.tree.get(expr).tag == .ident;
        var guard: u32 = 0;
        while (guard < max_postfix_ops) : (guard += 1) {
            switch (self.tok.kind) {
                .l_paren => {
                    try self.advance();
                    const items = try self.commaList(.r_paren, parseArgItem, false);
                    defer self.gpa.free(items);
                    const end = try self.expect(.r_paren, "')'");
                    const args = try self.tree.add(.args, join(self.span(expr), end), 0, items);
                    expr = try self.tree.add(.call, join(self.span(expr), end), 0, &.{ expr, none, args });
                    bare_name = false;
                },
                .l_bracket => {
                    expr = try self.parseIndexOrSlice(expr);
                    bare_name = false;
                },
                .dot => {
                    expr = try self.parseDotOp(expr);
                    bare_name = false;
                },
                .float_lit => {
                    // The lexer has no notion of postfix position: a bare '.'
                    // followed by digits with no preceding space always lexes as
                    // one FLOAT_LIT token (`.5`), which is also the only way
                    // `t.0` (tuple index, §12.5) can appear on the wire — there
                    // is no separate '.' token to drive `parseDotOp` here. Split
                    // it ourselves when the token is exactly ".DIGITS": any other
                    // shape (exponent, second '.') is not a valid continuation of
                    // anything, so it's left for the caller to reject as usual.
                    if (!isDotDigits(self.lx.src[self.tok.span.start..self.tok.span.end])) break;
                    const full = self.tok.span;
                    try self.advance();
                    const idx = try self.tree.addLeaf(.int_lit, .{ .file = full.file, .start = full.start + 1, .end = full.end });
                    expr = try self.tree.add(.tuple_index, join(self.span(expr), full), 0, &.{ expr, idx });
                    bare_name = false;
                },
                .question => {
                    const end = self.tok.span;
                    try self.advance();
                    expr = try self.tree.add(.try_expr, join(self.span(expr), end), 0, &.{expr});
                    bare_name = false;
                },
                .l_brace => {
                    // '{' is never a valid postfix continuation on anything but
                    // a bare identifier, and is suppressed there too while
                    // parsing an unparenthesized `for_of`/`for_in` iterable
                    // (`no_composite_lit`), where it belongs to the loop body.
                    if (!bare_name or self.no_composite_lit) break;
                    expr = try self.parseStructCompositeLitBody(expr);
                    bare_name = false;
                },
                .lt => {
                    const result = try self.tryGenericPostfix(expr, bare_name);
                    if (result) |node| {
                        expr = node;
                        bare_name = false;
                    } else break; // '<' left for the binary parser to treat as comparison
                },
                else => break,
            }
        }
        if (guard >= max_postfix_ops) try self.tooMany("postfix operators");
        return expr;
    }

    fn parseIndexOrSlice(self: *Parser, recv: Index) ParseError!Index {
        const recv_span = self.span(recv);
        try self.advance(); // '['
        // Inside `[...]` a composite literal is never ambiguous with an
        // enclosing block; see `no_composite_lit`.
        const saved_no_composite = self.no_composite_lit;
        self.no_composite_lit = false;
        defer self.no_composite_lit = saved_no_composite;
        var lo: Index = none;
        if (self.tok.kind != .colon) lo = try self.parseExpression();
        if (try self.accept(.colon)) {
            var hi: Index = none;
            if (self.tok.kind != .r_bracket) hi = try self.parseExpression();
            const end = try self.expect(.r_bracket, "']'");
            return self.tree.add(.slice_expr, join(recv_span, end), 0, &.{ recv, lo, hi });
        }
        if (lo == none) try self.fail("an index expression");
        const end = try self.expect(.r_bracket, "']'");
        return self.tree.add(.index, join(recv_span, end), 0, &.{ recv, lo });
    }

    fn parseDotOp(self: *Parser, recv: Index) ParseError!Index {
        const recv_span = self.span(recv);
        try self.advance(); // '.'
        if (try self.accept(.l_paren)) {
            const ty = try self.parseType();
            const end = try self.expect(.r_paren, "')'");
            return self.tree.add(.type_assert, join(recv_span, end), 0, &.{ recv, ty });
        }
        if (self.tok.kind == .int_lit) {
            const idx = try self.leaf(.int_lit);
            return self.tree.add(.tuple_index, join(recv_span, self.span(idx)), 0, &.{ recv, idx });
        }
        if (self.tok.kind == .ident) {
            const name = try self.leaf(.ident);
            return self.tree.add(.member, join(recv_span, self.span(name)), 0, &.{ recv, name });
        }
        try self.fail("an identifier, index, or '(' after '.'");
        return recv;
    }

    /// Speculative `"<" type {"," type} ">"` followed by `(` (call, valid
    /// anywhere in a postfix chain) or `{` (generic composite literal, valid
    /// only when `expr` is still the bare identifier primary — `allow_brace`).
    fn tryGenericPostfix(self: *Parser, expr: Index, allow_brace: bool) ParseError!?Index {
        std.debug.assert(self.speculating < max_speculate_depth);
        const m = self.mark();
        self.speculating += 1;
        const result = self.tryGenericPostfixInner(expr, allow_brace);
        self.speculating -= 1;
        return result catch |err| switch (err) {
            error.Speculative => {
                self.reset(m);
                return null;
            },
            else => |e| return e,
        };
    }

    fn tryGenericPostfixInner(self: *Parser, expr: Index, allow_brace: bool) ParseError!Index {
        const lt_span = try self.expect(.lt, "'<'");
        const items = try self.commaList(.gt, parseType, false);
        defer self.gpa.free(items);
        if (items.len == 0) return error.Speculative; // '<>' is never a type-arg list
        const gt_span = try self.expectGenericClose();
        const targs = try self.tree.add(.type_args, join(lt_span, gt_span), 0, items);
        if (self.tok.kind == .l_paren) {
            try self.advance();
            const args_items = try self.commaList(.r_paren, parseArgItem, false);
            defer self.gpa.free(args_items);
            const end = try self.expect(.r_paren, "')'");
            const args = try self.tree.add(.args, join(lt_span, end), 0, args_items);
            return self.tree.add(.call, join(self.span(expr), end), 0, &.{ expr, targs, args });
        }
        if (allow_brace and !self.no_composite_lit and self.tok.kind == .l_brace) {
            const generic_ty = try self.tree.add(.generic_inst, join(self.span(expr), gt_span), 0, &.{ expr, targs });
            return self.parseStructCompositeLitBody(generic_ty);
        }
        // `Enum<T>.Variant` (turbofish at a variant site): `<...>` before `.` is
        // never a comparison — `(a < b) > .x` has no valid parse — so a `.` here
        // is unambiguously a generic instantiation whose member the postfix loop
        // then reads (`Option<i64>.None`, `Result<i64, E>.Ok(v)`).
        if (self.tok.kind == .dot) {
            return self.tree.add(.generic_inst, join(self.span(expr), gt_span), 0, &.{ expr, targs });
        }
        return error.Speculative;
    }

    fn parseArgItem(self: *Parser) ParseError!Index {
        if (try self.accept(.ellipsis)) {
            const e = try self.parseExpression();
            return self.tree.add(.arg_spread, self.span(e), 0, &.{e});
        }
        const e = try self.parseExpression();
        return self.tree.add(.arg, self.span(e), 0, &.{e});
    }

    fn parseStructCompositeLitBody(self: *Parser, type_node: Index) ParseError!Index {
        const type_span = self.span(type_node);
        try self.advance(); // '{'
        const items = try self.commaList(.r_brace, parseFieldInit, false);
        defer self.gpa.free(items);
        const end = try self.expect(.r_brace, "'}'");
        const inits = try self.tree.add(.field_inits, join(type_span, end), 0, items);
        return self.tree.add(.composite_lit, join(type_span, end), 0, &.{ type_node, inits });
    }

    fn parseFieldInit(self: *Parser) ParseError!Index {
        const name = try self.expectIdent();
        _ = try self.expect(.colon, "':'");
        const e = try self.parseExpression();
        return self.tree.add(.field_init, join(self.span(name), self.span(e)), 0, &.{ name, e });
    }

    fn parseMapEntry(self: *Parser) ParseError!Index {
        const key = try self.parseExpression();
        _ = try self.expect(.colon, "':'");
        const val = try self.parseExpression();
        return self.tree.add(.map_entry, join(self.span(key), self.span(val)), 0, &.{ key, val });
    }

    // ---- primary (§12: literal | IDENT | paren/arrow | composite | bracket) ---

    fn parsePrimary(self: *Parser) ParseError!Index {
        switch (self.tok.kind) {
            .int_lit => return self.leaf(.int_lit),
            .float_lit => return self.leaf(.float_lit),
            .string_lit => return self.leaf(.string_lit),
            .raw_string_lit => return self.leaf(.raw_string_lit),
            .rune_lit => return self.leaf(.rune_lit),
            .bool_lit => return self.leaf(.bool_lit),
            .nil_lit => return self.leaf(.nil_lit),
            .str_part => return self.parseInterpString(),
            .ident => return self.leaf(.ident),
            .l_paren => return self.parseParenOrArrow(),
            .l_bracket => return self.parseBracketPrimary(),
            .kw_map => return self.parseMapPrimary(),
            .kw_chan => return self.parseChanPrimary(),
            .kw_match => return self.parseMatch(true),
            .kw_asm => return self.parseAsm(),
            else => {
                try self.fail("an expression");
                const bad = self.tok.span;
                if (self.tok.kind != .eof) try self.advance(); // guarantee progress
                return self.tree.addLeaf(.nil_lit, bad); // poison node, never referenced by valid code
            },
        }
    }

    fn parseInterpString(self: *Parser) ParseError!Index {
        var parts: std.ArrayList(Index) = .empty;
        defer parts.deinit(self.gpa);
        const start = self.tok.span;
        // Bounded by the lexer's own interpolation-nesting cap.
        while (true) {
            const part = try self.leaf(.str_part);
            try parts.append(self.gpa, part);
            if (!try self.accept(.interp_start)) break;
            try parts.append(self.gpa, try self.parseExpression());
            _ = try self.expect(.interp_end, "'}'");
        }
        const end = self.span(parts.items[parts.items.len - 1]);
        return self.tree.add(.str_interp, join(start, end), 0, parts.items);
    }

    /// `(` starts either an arrow function's parameter list or a parenthesized
    /// expression; committed by one token of lookahead after the matching `)`
    /// (§12.8). Parenthesized expressions are transparent: no grouping node.
    fn parseParenOrArrow(self: *Parser) ParseError!Index {
        if (try self.speculate(tryArrowParams)) |params| {
            try self.advance(); // '=>', confirmed by tryArrowParams
            const body = if (self.tok.kind == .l_brace) try self.parseBlock() else try self.parseExpression();
            return self.tree.add(.arrow_fn, join(self.span(params), self.span(body)), 0, &.{ params, body });
        }
        _ = try self.expect(.l_paren, "'('");
        // Inside `(...)` a composite literal is never ambiguous with an
        // enclosing block; see `no_composite_lit`.
        const saved_no_composite = self.no_composite_lit;
        self.no_composite_lit = false;
        const inner = try self.parseExpression();
        self.no_composite_lit = saved_no_composite;
        _ = try self.expect(.r_paren, "')'");
        return inner;
    }

    fn tryArrowParams(self: *Parser) ParseError!Index {
        const start = try self.expect(.l_paren, "'('");
        const items = try self.commaList(.r_paren, parseArrowP, false);
        defer self.gpa.free(items);
        const end = try self.expect(.r_paren, "')'");
        if (self.tok.kind != .fat_arrow) return error.Speculative; // the commit condition
        return self.tree.add(.arrow_params, join(start, end), 0, items);
    }

    fn parseArrowP(self: *Parser) ParseError!Index {
        const name = try self.expectIdent();
        var ty: Index = none;
        if (try self.accept(.colon)) ty = try self.parseType();
        const end_idx = if (ty != none) ty else name;
        return self.tree.add(.arrow_p, join(self.span(name), self.span(end_idx)), 0, &.{ name, ty });
    }

    /// `[` starts a bare slice literal, or (speculatively) a `[]T{..}` /
    /// `[N]T{..}` composite literal / constructor call.
    fn parseBracketPrimary(self: *Parser) ParseError!Index {
        if (try self.speculate(trySliceOrArrayTypePrimary)) |node| return node;
        const start = try self.expect(.l_bracket, "'['");
        const items = try self.commaList(.r_bracket, parseArgItem, false);
        defer self.gpa.free(items);
        const end = try self.expect(.r_bracket, "']'");
        return self.tree.add(.slice_lit, join(start, end), 0, items);
    }

    fn trySliceOrArrayTypePrimary(self: *Parser) ParseError!Index {
        const ty = try self.parseSliceOrArrayType();
        const type_span = self.span(ty);
        if (self.tok.kind == .l_brace) {
            try self.advance();
            const items = try self.commaList(.r_brace, parseArgItem, false);
            defer self.gpa.free(items);
            const end = try self.expect(.r_brace, "'}'");
            const args = try self.tree.add(.args, join(type_span, end), 0, items);
            return self.tree.add(.composite_lit, join(type_span, end), 0, &.{ ty, args });
        }
        if (self.tok.kind == .l_paren) {
            try self.advance();
            const items = try self.commaList(.r_paren, parseArgItem, false);
            defer self.gpa.free(items);
            const end = try self.expect(.r_paren, "')'");
            const args = try self.tree.add(.args, join(type_span, end), 0, items);
            return self.tree.add(.call, join(type_span, end), 0, &.{ ty, none, args });
        }
        return error.Speculative; // fall back to a bare slice literal
    }

    fn parseMapPrimary(self: *Parser) ParseError!Index {
        const ty = try self.parseMapType();
        const type_span = self.span(ty);
        if (try self.accept(.l_brace)) {
            const items = try self.commaList(.r_brace, parseMapEntry, false);
            defer self.gpa.free(items);
            const end = try self.expect(.r_brace, "'}'");
            const entries = try self.tree.add(.map_entries, join(type_span, end), 0, items);
            return self.tree.add(.composite_lit, join(type_span, end), 0, &.{ ty, entries });
        }
        if (try self.accept(.l_paren)) {
            const items = try self.commaList(.r_paren, parseArgItem, false);
            defer self.gpa.free(items);
            const end = try self.expect(.r_paren, "')'");
            const args = try self.tree.add(.args, join(type_span, end), 0, items);
            return self.tree.add(.call, join(type_span, end), 0, &.{ ty, none, args });
        }
        try self.fail("'{' or '(' after a map type");
        return ty;
    }

    fn parseChanPrimary(self: *Parser) ParseError!Index {
        const ty = try self.parseChanType();
        const type_span = self.span(ty);
        _ = try self.expect(.l_paren, "'(' (channel constructor)");
        const items = try self.commaList(.r_paren, parseArgItem, false);
        defer self.gpa.free(items);
        const end = try self.expect(.r_paren, "')'");
        const args = try self.tree.add(.args, join(type_span, end), 0, items);
        return self.tree.add(.call, join(type_span, end), 0, &.{ ty, none, args });
    }
};

/// Human-readable token description for "expected X, found Y" diagnostics.
/// True for a token spelled exactly `.` followed by one or more decimal digits
/// and nothing else (see the `.float_lit` postfix case for why this matters).
fn isDotDigits(text: []const u8) bool {
    if (text.len < 2 or text[0] != '.') return false;
    for (text[1..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn describe(k: Kind) []const u8 {
    return switch (k) {
        .eof => "end of file",
        .invalid => "an invalid token",
        .ident => "an identifier",
        .int_lit, .float_lit => "a number",
        .string_lit, .raw_string_lit => "a string",
        .rune_lit => "a rune",
        .bool_lit => "a boolean literal",
        .nil_lit => "'nil'",
        .str_part, .interp_start, .interp_end => "a string",
        .semicolon => "';'",
        .l_paren => "'('",
        .r_paren => "')'",
        .l_bracket => "'['",
        .r_bracket => "']'",
        .l_brace => "'{'",
        .r_brace => "'}'",
        .comma => "','",
        .colon => "':'",
        .dot => "'.'",
        .ellipsis => "'...'",
        .fat_arrow => "'=>'",
        .question => "'?'",
        .arrow_left => "'<-'",
        .eq => "'='",
        .lt => "'<'",
        .gt => "'>'",
        .bang => "'!'",
        .amp => "'&'",
        .star => "'*'",
        else => @tagName(k),
    };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

/// Parses `src` as a full program and returns its AST dump. Fails the test if
/// any diagnostic was produced (use `expectDiagCount` for error-path tests).
fn dumpProgram(gpa: Allocator, src: []const u8) ![]u8 {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("t.bit", src);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parse(gpa, &tree, &diags, file, src);
    if (diags.hasErrors()) {
        var rendered: std.Io.Writer.Allocating = .init(gpa);
        defer rendered.deinit();
        diags.renderAll(&rendered.writer) catch {};
        std.debug.print("unexpected diagnostics for {s}:\n{s}\n", .{ src, rendered.written() });
    }
    try testing.expect(!diags.hasErrors());
    return ast.dump(gpa, &tree, src);
}

fn expectProgram(src: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const got = try dumpProgram(gpa, src);
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// Parses `src` as a single expression and returns its AST dump.
fn dumpExpr(gpa: Allocator, src: []const u8) ![]u8 {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("t.bit", src);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    var p = try Parser.init(gpa, &tree, &diags, file, src);
    tree.root = try p.parseExpression();
    try testing.expect(!diags.hasErrors());
    return ast.dump(gpa, &tree, src);
}

fn expectExpr(src: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const got = try dumpExpr(gpa, src);
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// Parses `src` (a whole `{ ... }` block) and returns its AST dump.
fn dumpBlock(gpa: Allocator, src: []const u8) ![]u8 {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("t.bit", src);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    var p = try Parser.init(gpa, &tree, &diags, file, src);
    tree.root = try p.parseBlock();
    if (diags.hasErrors()) {
        var rendered: std.Io.Writer.Allocating = .init(gpa);
        defer rendered.deinit();
        diags.renderAll(&rendered.writer) catch {};
        std.debug.print("unexpected diagnostics for {s}:\n{s}\n", .{ src, rendered.written() });
    }
    try testing.expect(!diags.hasErrors());
    return ast.dump(gpa, &tree, src);
}

fn expectBlock(src: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const got = try dumpBlock(gpa, src);
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
}

// ---- declarations -------------------------------------------------------

test "value declarations: type, init, multiple bindings" {
    try expectProgram("let x: i32 = 1", "(program (let_decl (binding x i32 1)))");
    try expectProgram("const a = 1, b = 2", "(program (const_decl (binding a _ 1) (binding b _ 2)))");
    try expectProgram("let (v, ok) = m", "(program (let_decl (binding (tuple_pat v ok) _ m)))");
}

test "type alias" {
    try expectProgram("type ID = i32", "(program (type_alias ID _ i32))");
}

test "function declaration: params, result, fallible result" {
    try expectProgram(
        "function add(a: i32, b: i32): i32 { return a + b }",
        "(program (func_decl _ add _ (params (param a i32) (param b i32)) i32 (block (return_stmt (binary + a b)))))",
    );
    try expectProgram(
        "function f(): i32! { return 1 }",
        "(program (func_decl _ f _ (params) (fallible i32 _) (block (return_stmt 1))))",
    );
}

test "method declaration with receiver" {
    try expectProgram(
        "function (p: Point) norm(): f64 { return p.x }",
        "(program (func_decl (receiver p Point) norm _ (params) f64 (block (return_stmt (member p x)))))",
    );
}

test "generic function with bounded type parameter" {
    try expectProgram(
        "function max<T: Ord>(a: T, b: T): T { return a }",
        "(program (func_decl _ max (generic_params (generic_param T (constraint Ord))) (params (param a T) (param b T)) T (block (return_stmt a))))",
    );
}

test "struct and interface declarations" {
    try expectProgram(
        "struct Point { x: f64, y: f64 }",
        "(program (struct_decl Point _ (field_list (field x f64) (field y f64))))",
    );
    try expectProgram(
        "interface Ord { less(other: Self): bool }",
        "(program (interface_decl Ord _ (method_sig_list (method_sig less (params (param other Self)) bool))))",
    );
}

test "export wraps any declaration" {
    try expectProgram("export let x = 1", "(program (export (let_decl (binding x _ 1))))");
    try expectProgram(
        "struct S { export x: i32 }",
        "(program (struct_decl S _ (field_list (export (field x i32)))))",
    );
}

test "imports: single, star, group" {
    try expectProgram("import io from \"io\"", "(program (import_decl (import_ns io) \"io\"))");
    try expectProgram("import * as io from \"io\"", "(program (import_decl (import_star io) \"io\"))");
    try expectProgram(
        "import { readAll, writeAll as write } from \"io\"",
        "(program (import_decl (import_group (import_item readAll _) (import_item writeAll write)) \"io\"))",
    );
}

// ---- expressions ----------------------------------------------------------

test "binary precedence and associativity" {
    try expectExpr("1 + 2 * 3", "(binary + 1 (binary * 2 3))");
    try expectExpr("1 < 2 && 3 > 4", "(binary && (binary < 1 2) (binary > 3 4))");
    try expectExpr("1 - 2 - 3", "(binary - (binary - 1 2) 3)"); // left-associative
}

test "unary operators" {
    try expectExpr("-x + !y", "(binary + (unary - x) (unary ! y))");
    try expectExpr("<-ch", "(unary <- ch)");
}

test "postfix chain: member, index, slice, tuple index, type assert, try" {
    try expectExpr("a.b[0].c(1, 2)", "(call (member (index (member a b) 0) c) _ (args (arg 1) (arg 2)))");
    try expectExpr("a[1:2]", "(slice_expr a 1 2)");
    try expectExpr("a[:2]", "(slice_expr a _ 2)");
    try expectExpr("a[1:]", "(slice_expr a 1 _)");
    try expectExpr("t.0", "(tuple_index t 0)");
    try expectExpr("x.(i32)", "(type_assert x i32)");
    try expectExpr("f()?", "(try_expr (call f _ (args)))");
}

test "generic call disambiguates from comparison" {
    try expectExpr("f<T>(x)", "(call f (type_args T) (args (arg x)))");
    try expectExpr("a < b", "(binary < a b)");
    try expectExpr("a < b && c > d", "(binary && (binary < a b) (binary > c d))");
}

test "composite literals: struct, generic struct, slice, array, map" {
    try expectExpr("Point{x: 1, y: 2}", "(composite_lit Point (field_inits (field_init x 1) (field_init y 2)))");
    try expectExpr("Box<int>{value: 1}", "(composite_lit (generic_inst Box (type_args int)) (field_inits (field_init value 1)))");
    try expectExpr("[1, 2, 3]", "(slice_lit (arg 1) (arg 2) (arg 3))");
    try expectExpr("[]int{1, 2, 3}", "(composite_lit (slice_type int) (args (arg 1) (arg 2) (arg 3)))");
    try expectExpr("[3]int{1, 2, 3}", "(composite_lit (array_type 3 int) (args (arg 1) (arg 2) (arg 3)))");
    try expectExpr("map<string, int>{\"a\": 1}", "(composite_lit (map_type string int) (map_entries (map_entry \"a\" 1)))");
}

test "constructor calls: slice, map, chan" {
    try expectExpr("[]int(5)", "(call (slice_type int) _ (args (arg 5)))");
    try expectExpr("map<string, int>()", "(call (map_type string int) _ (args))");
    try expectExpr("chan<int>(16)", "(call (chan_type int) _ (args (arg 16)))");
}

test "arrow functions: bare ident, typed params, block body" {
    try expectExpr("x => x * 2", "(arrow_fn (arrow_params (arrow_p x _)) (binary * x 2))");
    try expectExpr(
        "(a: i32, b: i32) => { return a + b }",
        "(arrow_fn (arrow_params (arrow_p a i32) (arrow_p b i32)) (block (return_stmt (binary + a b))))",
    );
    try expectExpr("() => 0", "(arrow_fn (arrow_params) 0)");
}

test "parenthesized expression is transparent" {
    try expectExpr("(1 + 2) * 3", "(binary * (binary + 1 2) 3)");
}

test "catch: default value and error binding" {
    try expectExpr("f() catch 0", "(catch_default (call f _ (args)) 0)");
    try expectExpr(
        "f() catch e { return e }",
        "(catch_bind (call f _ (args)) e (block (return_stmt e)))",
    );
}

test "string interpolation" {
    try expectExpr("\"a${x}b\"", "(str_interp \"a\" x \"b\")");
}

// ---- statements -------------------------------------------------------------

test "assignment: single, multi, tuple pattern, compound op" {
    try expectBlock("{ x = 1 }", "(block (assign = (lhs_list x) (expr_list 1)))");
    try expectBlock("{ a, b = b, a }", "(block (assign = (lhs_list a b) (expr_list b a)))");
    try expectBlock("{ (v, ok) = m[k] }", "(block (assign = (lhs_list (tuple_pat v ok)) (expr_list (index m k))))");
    try expectBlock("{ x += 1 }", "(block (assign += (lhs_list x) (expr_list 1)))");
}

test "increment, decrement, send" {
    try expectBlock("{ x++; y-- }", "(block (inc_stmt x) (dec_stmt y))");
    try expectBlock("{ ch <- v }", "(block (send_stmt ch v))");
}

test "return, fail, break, continue, spawn, defer" {
    try expectBlock("{ return }", "(block (return_stmt))");
    try expectBlock("{ return 1, 2 }", "(block (return_stmt 1 2))");
    try expectBlock("{ fail err }", "(block (fail_stmt err))");
    try expectBlock("{ break; continue }", "(block (break_stmt) (continue_stmt))");
    try expectBlock("{ spawn f(x) }", "(block (spawn_stmt (call f _ (args (arg x)))))");
    try expectBlock("{ defer f(x) }", "(block (defer_stmt (call f _ (args (arg x)))))");
}

test "if / else if / else" {
    try expectBlock(
        "{ if (a) { x } else if (b) { y } else { z } }",
        "(block (if_stmt a (block (expr_stmt x)) (if_stmt b (block (expr_stmt y)) (block (expr_stmt z)))))",
    );
}

test "while loop" {
    try expectBlock("{ while (cond) { x } }", "(block (while_stmt cond (block (expr_stmt x))))");
}

test "for: C-style, of (ident), of (tuple pattern), in, infinite" {
    try expectBlock(
        "{ for (let i = 0; i < n; i++) { x } }",
        "(block (for_c (let_decl (binding i _ 0)) (binary < i n) (inc_stmt i) (block (expr_stmt x))))",
    );
    try expectBlock("{ for v of xs { x } }", "(block (for_of v xs (block (expr_stmt x))))");
    try expectBlock("{ for (k, val) of m { x } }", "(block (for_of (tuple_pat k val) m (block (expr_stmt x))))");
    try expectBlock("{ for k in obj { x } }", "(block (for_in k obj (block (expr_stmt x))))");
    try expectBlock("{ for { x } }", "(block (for_inf (block (expr_stmt x))))");
}

test "switch: case list and default" {
    try expectBlock(
        "{ switch (n) { case 1, 2: a; default: b } }",
        "(block (switch_stmt n (case_list (switch_case (expr_list 1 2) (stmt_list (expr_stmt a))) (switch_default (stmt_list (expr_stmt b))))))",
    );
}

test "select: recv with binder, send, default" {
    try expectBlock(
        "{ select { case v = <-ch: a; default: b } }",
        "(block (select_stmt (comm_case (recv_bind v ch) (stmt_list (expr_stmt a))) (comm_default (stmt_list (expr_stmt b)))))",
    );
    try expectBlock(
        "{ select { case ch <- v: a } }",
        "(block (select_stmt (comm_case (send_stmt ch v) (stmt_list (expr_stmt a)))))",
    );
}

// ---- error recovery ---------------------------------------------------------

test "error recovery: three independent syntax errors all report" {
    const gpa = testing.allocator;
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const src = "1\n2\n3\n";
    const file = try sm.addFile("err.bit", src);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parse(gpa, &tree, &diags, file, src);
    try testing.expectEqual(@as(usize, 3), diags.count());
    for (diags.list.items) |d| try testing.expectEqual(diagnostics.Code.expected_token, d.code);
}

test "error recovery: a malformed declaration does not corrupt later decls" {
    const gpa = testing.allocator;
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const src = "let = 1\nfunction ok(): i32 { return 1 }\n";
    const file = try sm.addFile("err2.bit", src);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parse(gpa, &tree, &diags, file, src);
    try testing.expect(diags.hasErrors());
    // The second, well-formed declaration must still parse: find its func_decl
    // node in the tree regardless of the first decl's poisoned binding.
    var found_func = false;
    for (tree.nodes.items(.tag)) |tag| {
        if (tag == .func_decl) found_func = true;
    }
    try testing.expect(found_func);
}

test "round trip: golden lexer corpus parses without crashing" {
    // Every string the lexer test suite exercises should at least parse to
    // completion (bounded, no hang) whether or not it is syntactically valid
    // Bit source at the statement/declaration level.
    const gpa = testing.allocator;
    const srcs = [_][]const u8{
        "let x = true nil foo_bar",
        "a<<=b >>= <- => ... ++ == !=",
        "0 42 1_000 0xFF 0o17 0b1010 3.14 .5 1e10 2.5e-3 0x1.8p3",
        "\"hello world\"",
        "\"a${x}b\"",
        "`raw\\n` 'a' '\\n'",
    };
    for (srcs) |src| {
        var sm = diagnostics.SourceManager.init(gpa);
        defer sm.deinit();
        const file = try sm.addFile("f.bit", src);
        var diags = Diagnostics.init(gpa, &sm);
        defer diags.deinit();
        var tree = try ast.Tree.init(gpa);
        defer tree.deinit();
        try parse(gpa, &tree, &diags, file, src);
    }
}
