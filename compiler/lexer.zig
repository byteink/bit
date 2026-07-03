//! Hand-written lexer: source bytes -> token stream (spec/SPEC.md §4–§8).
//!
//! Every token carries a byte-offset span. The lexer synthesizes semicolons
//! (§7), tokenizes interpreted-string interpolation as a flat sequence
//! (`str_part` `interp_start` <expr tokens> `interp_end` `str_part` …), and
//! recovers from bad input by reporting a diagnostic and continuing — it never
//! fails fast and never gets stuck (every path advances or reaches EOF).
//!
//! Deviations from a naive reading, both grounded in the spec:
//!   * Block comments do NOT nest (§4.1): the first `*/` closes.
//!   * `true`/`false`/`nil` are lexed as literal tokens (§5.8), not generic
//!     keywords, so the parser sees them uniformly as literals.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const FileId = diagnostics.FileId;
const Span = diagnostics.Span;
const Diagnostics = diagnostics.Diagnostics;
const SourceManager = diagnostics.SourceManager;

pub const Token = struct {
    kind: Kind,
    span: Span,
};

/// The complete token set. Predeclared type/function names (§5.3) are `ident`
/// and resolved later; `true`/`false`/`nil` are literal kinds (§5.8).
pub const Kind = enum {
    eof,
    invalid, // a byte run that could not form a valid token (diagnostic emitted)

    ident,

    // literals
    int_lit,
    float_lit,
    string_lit, // complete interpreted string with no interpolation
    raw_string_lit,
    rune_lit,
    bool_lit, // true | false
    nil_lit,

    // interpreted-string interpolation pieces
    str_part, // a literal chunk of an interpolated string (head, middle, or tail)
    interp_start, // ${
    interp_end, // } closing an interpolation

    // keywords (§5.2, minus the three literal words)
    kw_as,
    kw_assert,
    kw_break,
    kw_case,
    kw_catch,
    kw_chan,
    kw_const,
    kw_continue,
    kw_default,
    kw_defer,
    kw_else,
    kw_export,
    kw_fail,
    kw_for,
    kw_from,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_interface,
    kw_let,
    kw_map,
    kw_match,
    kw_of,
    kw_return,
    kw_select,
    kw_spawn,
    kw_struct,
    kw_switch,
    kw_type,
    kw_while,

    // operators & delimiters (§6)
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    shl,
    shr,
    tilde,
    amp_amp,
    pipe_pipe,
    bang,
    eq_eq,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    eq,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    amp_eq,
    pipe_eq,
    caret_eq,
    shl_eq,
    shr_eq,
    plus_plus,
    minus_minus,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    semicolon,
    colon,
    dot,
    ellipsis,
    fat_arrow,
    question,
    arrow_left,
};

const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "as", .kw_as },
    .{ "assert", .kw_assert },
    .{ "break", .kw_break },
    .{ "case", .kw_case },
    .{ "catch", .kw_catch },
    .{ "chan", .kw_chan },
    .{ "const", .kw_const },
    .{ "continue", .kw_continue },
    .{ "default", .kw_default },
    .{ "defer", .kw_defer },
    .{ "else", .kw_else },
    .{ "export", .kw_export },
    .{ "fail", .kw_fail },
    .{ "for", .kw_for },
    .{ "from", .kw_from },
    .{ "function", .kw_function },
    .{ "if", .kw_if },
    .{ "import", .kw_import },
    .{ "in", .kw_in },
    .{ "interface", .kw_interface },
    .{ "let", .kw_let },
    .{ "map", .kw_map },
    .{ "match", .kw_match },
    .{ "of", .kw_of },
    .{ "return", .kw_return },
    .{ "select", .kw_select },
    .{ "spawn", .kw_spawn },
    .{ "struct", .kw_struct },
    .{ "switch", .kw_switch },
    .{ "type", .kw_type },
    .{ "while", .kw_while },
    // Literal keywords (§5.8): reserved words that lex as literal tokens.
    .{ "true", .bool_lit },
    .{ "false", .bool_lit },
    .{ "nil", .nil_lit },
});

pub const Lexer = struct {
    src: []const u8,
    file: FileId,
    diags: *Diagnostics,
    i: u32 = 0,
    /// Kind of the last token returned — the single piece of state the
    /// automatic-semicolon rule needs (§7).
    last: Kind = .semicolon,
    /// One-slot queue: lets a string segment emit `str_part` now and `${` next.
    pending: ?Token = null,
    /// Set right after an `interp_end`: the next token continues the string body.
    resume_string: bool = false,
    /// Brace-nesting depth inside each active interpolation, innermost last.
    interp: [max_interp]u32 = undefined,
    interp_len: u32 = 0,

    /// Interpolation nesting cap: keeps state bounded (Power of 10). Real code
    /// never approaches this; deeper nesting degrades to literal `$` + diagnostic.
    const max_interp = 32;

    pub fn init(file: FileId, src: []const u8, diags: *Diagnostics) Lexer {
        return .{ .src = src, .file = file, .diags = diags };
    }

    /// Returns the next token, `.eof` at end. Only errors on diagnostic
    /// allocation failure.
    pub fn next(self: *Lexer) !Token {
        const tok = try self.produce();
        self.last = tok.kind;
        return tok;
    }

    fn produce(self: *Lexer) !Token {
        if (self.pending) |tok| {
            self.pending = null;
            return tok;
        }
        if (self.resume_string) {
            self.resume_string = false;
            return self.scanStringSegment(false);
        }
        return self.skipTriviaThenToken();
    }

    // ---- trivia + automatic semicolons ------------------------------------

    /// Consumes whitespace and comments, synthesizing a `;` when a newline (real
    /// or comment-embedded) follows a terminator token (§7); returns the next
    /// real token otherwise.
    fn skipTriviaThenToken(self: *Lexer) !Token {
        // Bounded: each iteration consumes ≥1 byte or returns.
        while (self.i < self.src.len) {
            switch (self.src[self.i]) {
                ' ', '\t', '\r' => self.i += 1,
                '\n' => {
                    self.i += 1;
                    if (self.wantSemi()) return self.semiToken(self.i - 1);
                },
                '/' => {
                    if (self.peekAt(1) == '/') {
                        self.skipLineComment();
                    } else if (self.peekAt(1) == '*') {
                        const had_nl = try self.skipBlockComment();
                        if (had_nl and self.wantSemi()) return self.semiToken(self.i - 1);
                    } else {
                        return self.scanToken();
                    }
                },
                else => return self.scanToken(),
            }
        }
        return self.atEof();
    }

    fn wantSemi(self: *const Lexer) bool {
        return self.interp_len == 0 and isTerminator(self.last);
    }

    fn atEof(self: *Lexer) !Token {
        if (self.interp_len > 0) {
            try self.report(.unterminated_string, self.i, self.i, "unterminated string", "close the interpolation and string");
            self.interp_len = 0;
        }
        if (self.wantSemi()) return self.semiToken(self.i);
        return .{ .kind = .eof, .span = Span.point(self.file, self.i) };
    }

    fn semiToken(self: *const Lexer, at: u32) Token {
        return .{ .kind = .semicolon, .span = Span.point(self.file, at) };
    }

    fn skipLineComment(self: *Lexer) void {
        self.i += 2; // consume "//"
        while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
    }

    /// Consumes a non-nesting block comment (§4.1). Returns whether it contained
    /// a newline (which counts as a newline for the semicolon rule).
    fn skipBlockComment(self: *Lexer) !bool {
        const start = self.i;
        self.i += 2; // consume "/*"
        var had_nl = false;
        // Bounded by src length; first "*/" closes.
        while (self.i + 1 < self.src.len) : (self.i += 1) {
            if (self.src[self.i] == '*' and self.src[self.i + 1] == '/') {
                self.i += 2;
                return had_nl;
            }
            if (self.src[self.i] == '\n') had_nl = true;
        }
        // Unterminated: consume the tail and report.
        while (self.i < self.src.len) : (self.i += 1) {
            if (self.src[self.i] == '\n') had_nl = true;
        }
        try self.report(.unterminated_block_comment, start, self.i, "unterminated block comment", "add a closing '*/'");
        return had_nl;
    }

    // ---- token dispatch ----------------------------------------------------

    /// Scans one real token at `self.i` (guaranteed in-bounds, non-trivia).
    fn scanToken(self: *Lexer) !Token {
        const start = self.i;
        const c = self.src[self.i];

        if (isIdentStart(c)) return self.scanIdent();
        if (isDigit(c)) return self.scanNumber();
        if (c == '.' and isDigit(self.peekAt(1))) return self.scanNumber();

        switch (c) {
            '"' => return self.scanStringSegment(true),
            '`' => return self.scanRawString(),
            '\'' => return self.scanRune(),

            '+' => return self.op1eq2(.plus, '+', .plus_plus, '=', .plus_eq),
            '-' => {
                if (self.peekAt(1) == '-') return self.op(2, .minus_minus);
                if (self.peekAt(1) == '=') return self.op(2, .minus_eq);
                return self.op(1, .minus);
            },
            '*' => return self.opEq(.star, .star_eq),
            '/' => return self.opEq(.slash, .slash_eq),
            '%' => return self.opEq(.percent, .percent_eq),
            '&' => return self.op1eq2(.amp, '&', .amp_amp, '=', .amp_eq),
            '|' => return self.op1eq2(.pipe, '|', .pipe_pipe, '=', .pipe_eq),
            '^' => return self.opEq(.caret, .caret_eq),
            '~' => return self.op(1, .tilde),
            '!' => return self.opEq(.bang, .bang_eq),
            '=' => {
                if (self.peekAt(1) == '=') return self.op(2, .eq_eq);
                if (self.peekAt(1) == '>') return self.op(2, .fat_arrow);
                return self.op(1, .eq);
            },
            '<' => {
                if (self.peekAt(1) == '<') {
                    if (self.peekAt(2) == '=') return self.op(3, .shl_eq);
                    return self.op(2, .shl);
                }
                if (self.peekAt(1) == '=') return self.op(2, .lt_eq);
                if (self.peekAt(1) == '-') return self.op(2, .arrow_left);
                return self.op(1, .lt);
            },
            '>' => {
                if (self.peekAt(1) == '>') {
                    if (self.peekAt(2) == '=') return self.op(3, .shr_eq);
                    return self.op(2, .shr);
                }
                if (self.peekAt(1) == '=') return self.op(2, .gt_eq);
                return self.op(1, .gt);
            },
            '(' => return self.op(1, .l_paren),
            ')' => return self.op(1, .r_paren),
            '[' => return self.op(1, .l_bracket),
            ']' => return self.op(1, .r_bracket),
            '{' => {
                if (self.interp_len > 0) self.interp[self.interp_len - 1] += 1;
                return self.op(1, .l_brace);
            },
            '}' => return self.scanRBrace(),
            ',' => return self.op(1, .comma),
            ';' => return self.op(1, .semicolon),
            ':' => return self.op(1, .colon),
            '.' => {
                if (self.peekAt(1) == '.' and self.peekAt(2) == '.') return self.op(3, .ellipsis);
                return self.op(1, .dot);
            },
            '?' => return self.op(1, .question),

            else => {
                self.i += 1;
                var buf: [40]u8 = undefined;
                const msg = if (c >= 0x20 and c < 0x7f)
                    std.fmt.bufPrint(&buf, "unexpected character '{c}'", .{c}) catch "unexpected character"
                else
                    std.fmt.bufPrint(&buf, "unexpected byte 0x{X:0>2}", .{c}) catch "unexpected byte";
                try self.report(.unexpected_character, start, self.i, msg, "remove this character");
                return .{ .kind = .invalid, .span = self.spanOf(start, self.i) };
            },
        }
    }

    /// `}` either closes an interpolation (depth 0 in the innermost frame) or is
    /// an ordinary right brace.
    fn scanRBrace(self: *Lexer) Token {
        const start = self.i;
        if (self.interp_len > 0) {
            if (self.interp[self.interp_len - 1] == 0) {
                self.i += 1;
                self.interp_len -= 1;
                self.resume_string = true;
                return .{ .kind = .interp_end, .span = self.spanOf(start, self.i) };
            }
            self.interp[self.interp_len - 1] -= 1;
        }
        self.i += 1;
        return .{ .kind = .r_brace, .span = self.spanOf(start, self.i) };
    }

    fn op(self: *Lexer, n: u32, kind: Kind) Token {
        const start = self.i;
        self.i += n;
        return .{ .kind = kind, .span = self.spanOf(start, self.i) };
    }

    /// Two-char `<op>=` else one-char `<op>`.
    fn opEq(self: *Lexer, one: Kind, with_eq: Kind) Token {
        if (self.peekAt(1) == '=') return self.op(2, with_eq);
        return self.op(1, one);
    }

    /// One-char `one`, or two-char forms for a doubled glyph and for `<op>=`.
    fn op1eq2(self: *Lexer, one: Kind, dbl_ch: u8, dbl: Kind, eq_ch: u8, with_eq: Kind) Token {
        if (self.peekAt(1) == dbl_ch) return self.op(2, dbl);
        if (self.peekAt(1) == eq_ch) return self.op(2, with_eq);
        return self.op(1, one);
    }

    // ---- identifiers -------------------------------------------------------

    fn scanIdent(self: *Lexer) Token {
        const start = self.i;
        self.i += 1;
        while (self.i < self.src.len and isIdentCont(self.src[self.i])) self.i += 1;
        const text = self.src[start..self.i];
        return .{ .kind = keywords.get(text) orelse .ident, .span = self.spanOf(start, self.i) };
    }

    // ---- numbers -----------------------------------------------------------

    const DigitClass = enum { dec, hex, oct, bin };
    const Run = struct { count: u32, bad_sep: bool };

    /// Consumes a maximal run of `class` digits allowing single `_` separators
    /// strictly between two digits. Reports misplaced separators via `bad_sep`.
    fn digitRun(self: *Lexer, class: DigitClass) Run {
        var count: u32 = 0;
        var bad = false;
        // Bounded by src length.
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (classOf(c, class)) {
                count += 1;
                self.i += 1;
                continue;
            }
            if (c == '_') {
                const prev_ok = count > 0 and classOf(self.src[self.i - 1], class);
                const next_ok = self.i + 1 < self.src.len and classOf(self.src[self.i + 1], class);
                if (!prev_ok or !next_ok) bad = true;
                self.i += 1;
                continue;
            }
            break;
        }
        return .{ .count = count, .bad_sep = bad };
    }

    fn scanNumber(self: *Lexer) !Token {
        const start = self.i;
        const c0 = self.src[self.i];
        var is_float = false;
        var bad = false;

        if (c0 == '0' and (self.peekAt(1) == 'x' or self.peekAt(1) == 'X')) {
            self.i += 2;
            const r = self.digitRun(.hex);
            if (r.count == 0) bad = true;
            if (r.bad_sep) bad = true;
            // Hex float requires a 'p' exponent (§5.5); a bare '.' without one is bad.
            if (self.peekAt(0) == '.' or self.peekAt(0) == 'p' or self.peekAt(0) == 'P') {
                is_float = true;
                if (self.peekAt(0) == '.') {
                    self.i += 1;
                    if (self.digitRun(.hex).bad_sep) bad = true;
                }
                if (self.peekAt(0) == 'p' or self.peekAt(0) == 'P') {
                    if (self.scanExponent()) |e| {
                        if (e) bad = true;
                    }
                } else bad = true;
            }
        } else if (c0 == '0' and (self.peekAt(1) == 'o' or self.peekAt(1) == 'O')) {
            self.i += 2;
            const r = self.digitRun(.oct);
            if (r.count == 0 or r.bad_sep) bad = true;
        } else if (c0 == '0' and (self.peekAt(1) == 'b' or self.peekAt(1) == 'B')) {
            self.i += 2;
            const r = self.digitRun(.bin);
            if (r.count == 0 or r.bad_sep) bad = true;
        } else {
            if (c0 == '.') {
                is_float = true;
                self.i += 1;
                const f = self.digitRun(.dec);
                if (f.count == 0 or f.bad_sep) bad = true;
            } else {
                const lead_zero = c0 == '0';
                const r = self.digitRun(.dec);
                if (r.bad_sep) bad = true;
                // Leading 0 then more decimal digits is C-octal, forbidden (§5.4).
                if (lead_zero and r.count > 1) bad = true;
                if (self.peekAt(0) == '.') {
                    is_float = true;
                    self.i += 1;
                    if (self.digitRun(.dec).bad_sep) bad = true;
                }
            }
            if (self.peekAt(0) == 'e' or self.peekAt(0) == 'E') {
                is_float = true;
                if (self.scanExponent()) |e| {
                    if (e) bad = true;
                }
            }
        }

        // A valid numeric literal never abuts an identifier character.
        if (self.i < self.src.len and isIdentCont(self.src[self.i])) {
            bad = true;
            while (self.i < self.src.len and isIdentCont(self.src[self.i])) self.i += 1;
        }

        if (bad) {
            try self.report(.invalid_number, start, self.i, "invalid number literal", "check digits and '_' separators");
            return .{ .kind = .invalid, .span = self.spanOf(start, self.i) };
        }
        return .{ .kind = if (is_float) .float_lit else .int_lit, .span = self.spanOf(start, self.i) };
    }

    /// Consumes `(e|E|p|P) [sign] DIGITS`. Returns null if no exponent marker was
    /// present, else whether the exponent was malformed (missing/bad digits).
    fn scanExponent(self: *Lexer) ?bool {
        const c = self.peekAt(0);
        if (c != 'e' and c != 'E' and c != 'p' and c != 'P') return null;
        self.i += 1;
        if (self.peekAt(0) == '+' or self.peekAt(0) == '-') self.i += 1;
        const d = self.digitRun(.dec);
        return d.count == 0 or d.bad_sep;
    }

    // ---- strings -----------------------------------------------------------

    /// Scans one literal segment of an interpreted string. `is_head` marks the
    /// opening `"` position; a string with no interpolation yields a single
    /// `string_lit`, otherwise `str_part` segments framed by `${` … `}`.
    fn scanStringSegment(self: *Lexer, is_head: bool) !Token {
        const open = self.i; // '"' when is_head, else first content byte
        if (is_head) self.i += 1; // consume opening quote
        const content = self.i;

        // Bounded by src length.
        while (self.i < self.src.len) {
            switch (self.src[self.i]) {
                '"' => {
                    const end = self.i;
                    self.i += 1; // consume closing quote
                    if (is_head) return .{ .kind = .string_lit, .span = self.spanOf(open, self.i) };
                    return .{ .kind = .str_part, .span = self.spanOf(content, end) };
                },
                '\n' => return self.unterminatedString(is_head, open, content),
                '\\' => try self.scanEscape(),
                '$' => {
                    if (self.peekAt(1) != '{') {
                        self.i += 1; // literal '$'
                        continue;
                    }
                    if (self.interp_len >= max_interp) {
                        try self.report(.unterminated_string, self.i, self.i + 2, "interpolation nested too deeply", null);
                        self.i += 1; // treat '$' as literal and keep going
                        continue;
                    }
                    const dollar = self.i;
                    const end = self.i;
                    self.i += 2; // consume "${"
                    self.interp[self.interp_len] = 0;
                    self.interp_len += 1;
                    self.pending = .{ .kind = .interp_start, .span = self.spanOf(dollar, self.i) };
                    return .{ .kind = .str_part, .span = self.spanOf(content, end) };
                },
                else => self.i += 1,
            }
        }
        return self.unterminatedString(is_head, open, content);
    }

    fn unterminatedString(self: *Lexer, is_head: bool, open: u32, content: u32) !Token {
        try self.report(.unterminated_string, open, self.i, "unterminated string", "add a closing '\"'");
        if (is_head) return .{ .kind = .string_lit, .span = self.spanOf(open, self.i) };
        return .{ .kind = .str_part, .span = self.spanOf(content, self.i) };
    }

    /// Validates and consumes one escape sequence starting at `\` (§5.6). Bad
    /// escapes report `invalid_escape` and recovery continues past them.
    fn scanEscape(self: *Lexer) !void {
        const start = self.i;
        self.i += 1; // consume '\'
        if (self.i >= self.src.len) {
            try self.report(.invalid_escape, start, self.i, "incomplete escape sequence", null);
            return;
        }
        switch (self.src[self.i]) {
            'n', 'r', 't', '\\', '\'', '"', '0', '$' => self.i += 1,
            'x' => {
                self.i += 1;
                if (!self.takeHex(2)) try self.report(.invalid_escape, start, self.i, "\\x needs two hex digits", null);
            },
            'u' => {
                self.i += 1;
                if (self.peekAt(0) != '{') {
                    try self.report(.invalid_escape, start, self.i, "\\u needs a '{'", null);
                    return;
                }
                self.i += 1;
                var n: u32 = 0;
                while (self.i < self.src.len and classOf(self.src[self.i], .hex)) : (self.i += 1) n += 1;
                if (self.peekAt(0) == '}') {
                    self.i += 1;
                    if (n == 0 or n > 6) try self.report(.invalid_escape, start, self.i, "\\u{...} needs 1–6 hex digits", null);
                } else try self.report(.invalid_escape, start, self.i, "unterminated \\u{...} escape", null);
            },
            else => {
                self.i += 1;
                try self.report(.invalid_escape, start, self.i, "unknown escape sequence", null);
            },
        }
    }

    fn takeHex(self: *Lexer, n: u32) bool {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            if (self.i < self.src.len and classOf(self.src[self.i], .hex)) self.i += 1 else return false;
        }
        return true;
    }

    fn scanRawString(self: *Lexer) !Token {
        const start = self.i;
        self.i += 1; // consume opening '`'
        while (self.i < self.src.len and self.src[self.i] != '`') self.i += 1;
        if (self.i >= self.src.len) {
            try self.report(.unterminated_string, start, self.i, "unterminated raw string", "add a closing '`'");
            return .{ .kind = .raw_string_lit, .span = self.spanOf(start, self.i) };
        }
        self.i += 1; // consume closing '`'
        return .{ .kind = .raw_string_lit, .span = self.spanOf(start, self.i) };
    }

    fn scanRune(self: *Lexer) !Token {
        const start = self.i;
        self.i += 1; // consume opening quote
        if (self.i >= self.src.len or self.src[self.i] == '\n' or self.src[self.i] == '\'') {
            return self.badRune(start);
        }
        if (self.src[self.i] == '\\') {
            try self.scanEscape();
        } else {
            self.i += 1; // one byte…
            while (self.i < self.src.len and isUtf8Cont(self.src[self.i])) self.i += 1; // …plus UTF-8 tail
        }
        if (self.i < self.src.len and self.src[self.i] == '\'') {
            self.i += 1;
            return .{ .kind = .rune_lit, .span = self.spanOf(start, self.i) };
        }
        return self.badRune(start);
    }

    /// Recovers a malformed rune: consume up to the closing quote / line end.
    fn badRune(self: *Lexer, start: u32) !Token {
        while (self.i < self.src.len and self.src[self.i] != '\'' and self.src[self.i] != '\n') self.i += 1;
        if (self.i < self.src.len and self.src[self.i] == '\'') self.i += 1;
        try self.report(.invalid_rune, start, self.i, "invalid character literal", "a rune is a single character in single quotes");
        return .{ .kind = .invalid, .span = self.spanOf(start, self.i) };
    }

    // ---- helpers -----------------------------------------------------------

    fn peekAt(self: *const Lexer, k: u32) u8 {
        const j = self.i + k;
        return if (j < self.src.len) self.src[j] else 0;
    }

    fn spanOf(self: *const Lexer, start: u32, end: u32) Span {
        return .{ .file = self.file, .start = start, .end = end };
    }

    fn report(self: *Lexer, code: diagnostics.Code, start: u32, end: u32, msg: []const u8, hint: ?[]const u8) !void {
        try self.diags.report(code, self.spanOf(start, end), msg, hint);
    }
};

/// Terminator tokens trigger an automatic semicolon at a following newline (§7).
fn isTerminator(k: Kind) bool {
    return switch (k) {
        .ident,
        .int_lit,
        .float_lit,
        .string_lit,
        .raw_string_lit,
        .rune_lit,
        .bool_lit,
        .nil_lit,
        .str_part,
        .kw_return,
        .kw_break,
        .kw_continue,
        .kw_fail,
        .r_paren,
        .r_bracket,
        .r_brace,
        .plus_plus,
        .minus_minus,
        .question,
        => true,
        else => false,
    };
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// ponytail: bytes ≥ 0x80 are accepted as identifier characters instead of
// decoding UTF-8 and checking XID_Start/XID_Continue tables. Upgrade path:
// swap these two predicates for a real Unicode identifier classifier.
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn isUtf8Cont(c: u8) bool {
    return (c & 0xC0) == 0x80;
}

fn classOf(c: u8, class: Lexer.DigitClass) bool {
    return switch (class) {
        .dec => c >= '0' and c <= '9',
        .hex => (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'),
        .oct => c >= '0' and c <= '7',
        .bin => c == '0' or c == '1',
    };
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

/// Lexes `src` fully and returns a one-line-per-token dump: `kind start..end text`.
/// Synthesized/EOF semicolons are zero-width so their text is empty.
fn dump(gpa: Allocator, diags: *Diagnostics, file: FileId, src: []const u8) ![]u8 {
    var lx = Lexer.init(file, src, diags);
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    var guard: u32 = 0;
    while (guard < 100_000) : (guard += 1) {
        const t = try lx.next();
        if (t.kind == .eof) break;
        const text = src[t.span.start..t.span.end];
        try out.writer.print("{s} {d}..{d}", .{ @tagName(t.kind), t.span.start, t.span.end });
        if (text.len > 0) try out.writer.print(" {s}", .{text});
        try out.writer.writeByte('\n');
    }
    return gpa.dupe(u8, out.written());
}

fn expectDump(src: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("t.bit", src);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    const got = try dump(gpa, &diags, file, src);
    defer gpa.free(got);
    try testing.expectEqualStrings(expected, got);
    try testing.expect(!diags.hasErrors());
}

/// Lexes `src`, returns the first diagnostic code (asserting exactly `n` were
/// produced) and the number of non-eof tokens (to prove lexing continued).
fn lexErr(src: []const u8, want: diagnostics.Code, want_count: usize) !void {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("t.bit", src);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var lx = Lexer.init(file, src, &diags);
    var toks: usize = 0;
    var guard: u32 = 0;
    while (guard < 100_000) : (guard += 1) {
        const t = try lx.next();
        if (t.kind == .eof) break;
        toks += 1;
    }
    try testing.expect(toks > 0); // lexing produced tokens and reached eof
    try testing.expectEqual(want_count, diags.count());
    try testing.expect(diags.count() > 0);
    try testing.expectEqual(want, diags.list.items[0].code);
}

test "identifiers, keywords, and literal words" {
    try expectDump("let x = true nil foo_bar",
        \\kw_let 0..3 let
        \\ident 4..5 x
        \\eq 6..7 =
        \\bool_lit 8..12 true
        \\nil_lit 13..16 nil
        \\ident 17..24 foo_bar
        \\semicolon 24..24
        \\
    );
}

test "operators are maximal munch" {
    try expectDump("a<<=b >>= <- => ... ++ == !=",
        \\ident 0..1 a
        \\shl_eq 1..4 <<=
        \\ident 4..5 b
        \\shr_eq 6..9 >>=
        \\arrow_left 10..12 <-
        \\fat_arrow 13..15 =>
        \\ellipsis 16..19 ...
        \\plus_plus 20..22 ++
        \\eq_eq 23..25 ==
        \\bang_eq 26..28 !=
        \\
    );
}

test "numeric literals: bases, floats, separators" {
    try expectDump("0 42 1_000 0xFF 0o17 0b1010 3.14 .5 1e10 2.5e-3 0x1.8p3",
        \\int_lit 0..1 0
        \\int_lit 2..4 42
        \\int_lit 5..10 1_000
        \\int_lit 11..15 0xFF
        \\int_lit 16..20 0o17
        \\int_lit 21..27 0b1010
        \\float_lit 28..32 3.14
        \\float_lit 33..35 .5
        \\float_lit 36..40 1e10
        \\float_lit 41..47 2.5e-3
        \\float_lit 48..55 0x1.8p3
        \\semicolon 55..55
        \\
    );
}

test "string without interpolation is one token" {
    try expectDump(
        \\"hello world"
    ,
        \\string_lit 0..13 "hello world"
        \\semicolon 13..13
        \\
    );
}

test "interpolated string emits a flat token sequence" {
    try expectDump(
        \\"a${x}b"
    ,
        \\str_part 1..2 a
        \\interp_start 2..4 ${
        \\ident 4..5 x
        \\interp_end 5..6 }
        \\str_part 6..7 b
        \\semicolon 8..8
        \\
    );
}

test "nested interpolation and inner string" {
    try expectDump(
        \\"${f("x${y}")}"
    ,
        \\str_part 1..1
        \\interp_start 1..3 ${
        \\ident 3..4 f
        \\l_paren 4..5 (
        \\str_part 6..7 x
        \\interp_start 7..9 ${
        \\ident 9..10 y
        \\interp_end 10..11 }
        \\str_part 11..11
        \\r_paren 12..13 )
        \\interp_end 13..14 }
        \\str_part 14..14
        \\semicolon 15..15
        \\
    );
}

test "raw string and rune" {
    try expectDump("`raw\\n` 'a' '\\n'",
        \\raw_string_lit 0..7 `raw\n`
        \\rune_lit 8..11 'a'
        \\rune_lit 12..16 '\n'
        \\semicolon 16..16
        \\
    );
}

test "comments are trivia; block comment does not nest" {
    try expectDump("a // line\nb /* /* not nested */ c",
        \\ident 0..1 a
        \\semicolon 9..9
        \\ident 10..11 b
        \\ident 32..33 c
        \\semicolon 33..33
        \\
    );
}

test "automatic semicolon: insertion, continuation, collapse" {
    try expectDump("x = 1\ny = a +\nb\n",
        \\ident 0..1 x
        \\eq 2..3 =
        \\int_lit 4..5 1
        \\semicolon 5..5
        \\ident 6..7 y
        \\eq 8..9 =
        \\ident 10..11 a
        \\plus 12..13 +
        \\ident 14..15 b
        \\semicolon 15..15
        \\
    );
}

test "no semicolon after non-terminator at EOF" {
    try expectDump("a +",
        \\ident 0..1 a
        \\plus 2..3 +
        \\
    );
}

test "error: unterminated string, lexing continues" {
    // "\"oops\nlet y = 2" : bad string on line 1, valid tokens on line 2.
    try lexErr("\"oops\nlet y = 2", .unterminated_string, 1);
}

test "error: bad escape reported, lexing continues" {
    try lexErr("\"a\\q\"", .invalid_escape, 1);
}

test "error: stray byte reported, lexing continues" {
    try lexErr("a @ b", .unexpected_character, 1);
}

test "error: invalid number (C-octal and bad separator)" {
    try lexErr("08", .invalid_number, 1);
    try lexErr("1__0", .invalid_number, 1);
}

test "error: unterminated block comment" {
    try lexErr("x /* nope", .unterminated_block_comment, 1);
}

test "error: unterminated raw string" {
    try lexErr("`open", .unterminated_string, 1);
}

test "fuzz smoke: never crashes or hangs on random bytes" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x0B17_7EED);
    const rand = prng.random();
    var iter: u32 = 0;
    // Bounded: 10k inputs of ≤ 64 random bytes each.
    while (iter < 10_000) : (iter += 1) {
        var buf: [64]u8 = undefined;
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        rand.bytes(buf[0..n]);

        var sm = SourceManager.init(gpa);
        defer sm.deinit();
        const file = try sm.addFile("f.bit", buf[0..n]);
        var diags = Diagnostics.init(gpa, &sm);
        defer diags.deinit();

        var lx = Lexer.init(file, buf[0..n], &diags);
        var guard: u32 = 0;
        while (guard < 200_000) : (guard += 1) {
            const t = try lx.next();
            if (t.kind == .eof) break;
        }
        try testing.expect(guard < 200_000); // proved termination
    }
}
