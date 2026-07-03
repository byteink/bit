//! Diagnostics engine — the single reporting channel for every compiler stage
//! (lexer through type checker). Collects errors instead of failing fast, maps
//! byte-offset spans to line/column, and renders either a human terminal report
//! (source excerpt + caret + hint) or LSP-shaped JSON.
//!
//! Ownership split: the `SourceManager` *borrows* source buffers and paths (the
//! driver owns them for the whole run), while `Diagnostics` *owns* copies of the
//! per-report message and hint (callers build those in temp buffers).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Handle to a source file registered with a `SourceManager`.
pub const FileId = enum(u32) { _ };

/// Half-open byte range `[start, end)` into a registered file's source.
/// `end == start` is a zero-width span that points at a single position.
pub const Span = struct {
    file: FileId,
    start: u32,
    end: u32,

    pub fn point(file: FileId, at: u32) Span {
        return .{ .file = file, .start = at, .end = at };
    }
};

pub const Severity = enum {
    err,
    warning,
    note,

    /// Human/JSON label. `err` prints as "error" (the keyword forbids the name).
    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

/// Central diagnostic code registry. Rendered as `E%04d` (E0001+). Ranges are
/// reserved per stage so codes stay stable as stages are added here; a code is
/// never renumbered once shipped. New stages append their own members below.
pub const Code = enum(u16) {
    // Lexer: 1–19
    unexpected_character = 1,
    unterminated_string = 2,
    unterminated_block_comment = 3,
    invalid_number = 4,

    // Parser: 20–39
    unexpected_token = 20,
    expected_token = 21,

    // Checker: 40–59
    undefined_name = 40,
    type_mismatch = 41,

    /// Numeric value used in `E%04d` rendering.
    pub fn number(self: Code) u16 {
        return @intFromEnum(self);
    }

    /// Formats the code as `E0001` into `buf`, returning the used slice.
    pub fn string(self: Code, buf: *[5]u8) []const u8 {
        return std.fmt.bufPrint(buf, "E{d:0>4}", .{self.number()}) catch unreachable;
    }
};

/// 0-based line and column plus the exact source text of that line. Both the
/// human report (which adds 1) and the LSP JSON (which keeps 0) derive from this.
pub const Location = struct {
    line: u32,
    column: u32,
    line_text: []const u8,
};

/// Registry of source files. Borrows every `source`/`path`; the caller must keep
/// them alive for as long as the manager (and any produced diagnostics) is used.
pub const SourceManager = struct {
    gpa: Allocator,
    files: std.ArrayList(File) = .empty,

    const File = struct {
        path: []const u8,
        source: []const u8,
    };

    pub fn init(gpa: Allocator) SourceManager {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *SourceManager) void {
        self.files.deinit(self.gpa);
        self.* = undefined;
    }

    /// Registers a file and returns its handle. Source and path are borrowed.
    pub fn addFile(self: *SourceManager, file_path: []const u8, source: []const u8) !FileId {
        const id: u32 = @intCast(self.files.items.len);
        try self.files.append(self.gpa, .{ .path = file_path, .source = source });
        return @enumFromInt(id);
    }

    pub fn path(self: *const SourceManager, file: FileId) []const u8 {
        return self.fileOf(file).path;
    }

    fn fileOf(self: *const SourceManager, file: FileId) *const File {
        const idx: u32 = @intFromEnum(file);
        std.debug.assert(idx < self.files.items.len);
        return &self.files.items[idx];
    }

    /// Maps a byte offset to 0-based line/column and the containing line's text.
    /// `offset` may equal `source.len` (points just past the end, e.g. EOF).
    pub fn locate(self: *const SourceManager, file: FileId, offset: u32) Location {
        const source = self.fileOf(file).source;
        std.debug.assert(offset <= source.len);

        var line: u32 = 0;
        var line_start: u32 = 0;
        var i: u32 = 0;
        // Bounded by source length: one pass to the offset.
        while (i < offset) : (i += 1) {
            if (source[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }

        var line_end: u32 = line_start;
        // Bounded by source length: scan to the next newline or EOF.
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

        return .{
            .line = line,
            .column = offset - line_start,
            .line_text = source[line_start..line_end],
        };
    }
};

/// One collected diagnostic. `message` and `hint` are owned by `Diagnostics`.
pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    span: Span,
    message: []const u8,
    hint: ?[]const u8,
};

/// ANSI styling, gated by a single flag so test/pipe output is deterministic.
const Style = struct {
    on: bool,

    fn seq(self: Style, comptime code: []const u8) []const u8 {
        return if (self.on) code else "";
    }
    fn reset(self: Style) []const u8 {
        return self.seq("\x1b[0m");
    }
    fn frame(self: Style) []const u8 {
        return self.seq("\x1b[1;34m"); // bold blue
    }
    fn primary(self: Style, sev: Severity) []const u8 {
        return switch (sev) {
            .err => self.seq("\x1b[1;31m"), // bold red
            .warning => self.seq("\x1b[1;33m"), // bold yellow
            .note => self.seq("\x1b[1;34m"), // bold blue
        };
    }
};

/// Collecting diagnostic sink. Does not fail fast: every `report`/`warn`/`note`
/// appends. `color` should be off for tests and non-tty output.
pub const Diagnostics = struct {
    gpa: Allocator,
    sources: *const SourceManager,
    list: std.ArrayList(Diagnostic) = .empty,
    color: bool = false,

    pub fn init(gpa: Allocator, sources: *const SourceManager) Diagnostics {
        return .{ .gpa = gpa, .sources = sources };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.list.items) |d| {
            self.gpa.free(d.message);
            if (d.hint) |h| self.gpa.free(h);
        }
        self.list.deinit(self.gpa);
        self.* = undefined;
    }

    /// Reports an error. `message`/`hint` are copied; callers may pass temporaries.
    pub fn report(self: *Diagnostics, code: Code, span: Span, message: []const u8, hint: ?[]const u8) !void {
        return self.add(.err, code, span, message, hint);
    }

    pub fn warn(self: *Diagnostics, code: Code, span: Span, message: []const u8, hint: ?[]const u8) !void {
        return self.add(.warning, code, span, message, hint);
    }

    pub fn note(self: *Diagnostics, code: Code, span: Span, message: []const u8, hint: ?[]const u8) !void {
        return self.add(.note, code, span, message, hint);
    }

    fn add(self: *Diagnostics, severity: Severity, code: Code, span: Span, message: []const u8, hint: ?[]const u8) !void {
        const msg_copy = try self.gpa.dupe(u8, message);
        errdefer self.gpa.free(msg_copy);
        const hint_copy: ?[]const u8 = if (hint) |h| try self.gpa.dupe(u8, h) else null;
        try self.list.append(self.gpa, .{
            .severity = severity,
            .code = code,
            .span = span,
            .message = msg_copy,
            .hint = hint_copy,
        });
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.list.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.list.items.len;
    }

    /// Renders every diagnostic as a human terminal report, in report order.
    pub fn renderAll(self: *const Diagnostics, w: *Writer) !void {
        for (self.list.items) |d| try self.renderOne(w, d);
    }

    fn renderOne(self: *const Diagnostics, w: *Writer, d: Diagnostic) !void {
        const style = Style{ .on = self.color };
        const loc = self.sources.locate(d.span.file, d.span.start);
        const gutter = digits(loc.line + 1);

        // Header: severity[code]: message
        var code_buf: [5]u8 = undefined;
        try w.print("{s}{s}[{s}]{s}: {s}\n", .{
            style.primary(d.severity),
            d.severity.label(),
            d.code.string(&code_buf),
            style.reset(),
            d.message,
        });

        // Location: "--> path:line:col" (1-based).
        try w.splatByteAll(' ', gutter);
        try w.print("{s}-->{s} {s}:{d}:{d}\n", .{
            style.frame(),
            style.reset(),
            self.sources.path(d.span.file),
            loc.line + 1,
            loc.column + 1,
        });

        // Blank frame line.
        try w.splatByteAll(' ', gutter);
        try w.print(" {s}|{s}\n", .{ style.frame(), style.reset() });

        // Source line: "<n> | <text>".
        try w.print("{s}{d}{s} {s}|{s} {s}\n", .{
            style.frame(),
            loc.line + 1,
            style.reset(),
            style.frame(),
            style.reset(),
            loc.line_text,
        });

        // Caret line: frame, padding that mirrors tabs, then carets + hint.
        try w.splatByteAll(' ', gutter);
        try w.print(" {s}|{s} ", .{ style.frame(), style.reset() });
        try writeCaretPad(w, loc.line_text, loc.column);
        try w.writeAll(style.primary(d.severity));
        try w.splatByteAll('^', caretWidth(d.span, loc));
        if (d.hint) |h| try w.print(" {s}", .{h});
        try w.print("{s}\n", .{style.reset()});
    }

    /// Emits all diagnostics as a minified JSON array shaped for LSP reuse:
    /// `{code, severity, file, range:{start,end:{line,character}}, message, hint?}`.
    /// Line/character are 0-based (LSP convention). `character` is the byte
    /// column; UTF-16 remapping is deferred to the LSP layer.
    pub fn writeJson(self: *const Diagnostics, w: *Writer) !void {
        try w.writeByte('[');
        for (self.list.items, 0..) |d, idx| {
            if (idx != 0) try w.writeByte(',');
            const start = self.sources.locate(d.span.file, d.span.start);
            const end = self.sources.locate(d.span.file, d.span.end);

            var code_buf: [5]u8 = undefined;
            try w.print("{{\"code\":\"{s}\",\"severity\":\"{s}\",\"file\":", .{
                d.code.string(&code_buf),
                d.severity.label(),
            });
            try encodeJson(self.sources.path(d.span.file), w);
            try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"message\":", .{
                start.line, start.column, end.line, end.column,
            });
            try encodeJson(d.message, w);
            if (d.hint) |h| {
                try w.writeAll(",\"hint\":");
                try encodeJson(h, w);
            }
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
};

fn encodeJson(s: []const u8, w: *Writer) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// Decimal digit count of a positive line number (min 1). Bounded: u32 ≤ 10 digits.
fn digits(n: u32) usize {
    var v = n;
    var d: usize = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// Writes caret indentation, copying tabs verbatim so carets align under the
/// span regardless of tab width. `column` is a byte offset within `line`.
fn writeCaretPad(w: *Writer, line: []const u8, column: u32) !void {
    var i: u32 = 0;
    const stop = @min(column, @as(u32, @intCast(line.len)));
    // Bounded by the column (≤ line length).
    while (i < stop) : (i += 1) {
        try w.writeByte(if (line[i] == '\t') '\t' else ' ');
    }
}

/// Caret run length: the span width, at least 1, clamped to the line's tail so a
/// multi-line or past-EOF span never underlines beyond the excerpt.
fn caretWidth(span: Span, loc: Location) usize {
    const line_tail = loc.line_text.len - @min(loc.column, @as(u32, @intCast(loc.line_text.len)));
    const width = if (span.end > span.start) span.end - span.start else 1;
    return @max(1, @min(width, @as(u32, @intCast(line_tail))));
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

fn render(gpa: Allocator, diags: *const Diagnostics) ![]u8 {
    var alloc: Writer.Allocating = .init(gpa);
    defer alloc.deinit();
    try diags.renderAll(&alloc.writer);
    return gpa.dupe(u8, alloc.written());
}

fn renderJson(gpa: Allocator, diags: *const Diagnostics) ![]u8 {
    var alloc: Writer.Allocating = .init(gpa);
    defer alloc.deinit();
    try diags.writeJson(&alloc.writer);
    return gpa.dupe(u8, alloc.written());
}

test "code renders as E%04d" {
    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("E0001", Code.unexpected_character.string(&buf));
    try testing.expectEqualStrings("E0041", Code.type_mismatch.string(&buf));
}

test "locate maps byte offset to 0-based line/column and line text" {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    const src = "let x = 1\nlet yy = 2\n";
    const file = try sm.addFile("t.bit", src);

    const a = sm.locate(file, 0);
    try testing.expectEqual(@as(u32, 0), a.line);
    try testing.expectEqual(@as(u32, 0), a.column);
    try testing.expectEqualStrings("let x = 1", a.line_text);

    const b = sm.locate(file, 14); // 'y' of "yy" on line 2 (index 14)
    try testing.expectEqual(@as(u32, 1), b.line);
    try testing.expectEqual(@as(u32, 4), b.column);
    try testing.expectEqualStrings("let yy = 2", b.line_text);
}

test "pretty output matches golden (colors off)" {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("test.bit", "let x = @\n");

    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    // '@' is at byte offset 8; single-char span.
    try diags.report(.unexpected_character, .{ .file = file, .start = 8, .end = 9 }, "unexpected character '@'", "expected an expression");

    const out = try render(gpa, &diags);
    defer gpa.free(out);
    const expected =
        "error[E0001]: unexpected character '@'\n" ++
        " --> test.bit:1:9\n" ++
        "  |\n" ++
        "1 | let x = @\n" ++
        "  |         ^ expected an expression\n";
    try testing.expectEqualStrings(expected, out);
}

test "caret aligns under tabs" {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    // A leading tab then "let x = @"; '@' is at byte offset 9.
    const file = try sm.addFile("t.bit", "\tlet x = @\n");

    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    try diags.report(.unexpected_character, .{ .file = file, .start = 9, .end = 10 }, "bad", null);

    const out = try render(gpa, &diags);
    defer gpa.free(out);
    const expected =
        "error[E0001]: bad\n" ++
        " --> t.bit:1:10\n" ++
        "  |\n" ++
        "1 | \tlet x = @\n" ++
        "  | \t        ^\n";
    try testing.expectEqualStrings(expected, out);
}

test "multiple diagnostics collected without fail-fast" {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("m.bit", "ab\n");

    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    try diags.warn(.invalid_number, Span.point(file, 0), "w", null);
    try diags.report(.unexpected_token, .{ .file = file, .start = 0, .end = 2 }, "e", null);

    try testing.expectEqual(@as(usize, 2), diags.count());
    try testing.expect(diags.hasErrors());
}

test "JSON output is LSP-shaped with 0-based range" {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("test.bit", "let x = @\n");

    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    try diags.report(.unexpected_character, .{ .file = file, .start = 8, .end = 9 }, "unexpected character \"@\"", "hint");

    const out = try renderJson(gpa, &diags);
    defer gpa.free(out);
    const expected =
        "[{\"code\":\"E0001\",\"severity\":\"error\",\"file\":\"test.bit\"," ++
        "\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":9}}," ++
        "\"message\":\"unexpected character \\\"@\\\"\",\"hint\":\"hint\"}]";
    try testing.expectEqualStrings(expected, out);
}

test "warnings and notes have no error flag" {
    const gpa = testing.allocator;
    var sm = SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("n.bit", "x\n");

    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    try diags.warn(.invalid_number, Span.point(file, 0), "w", null);
    try diags.note(.undefined_name, Span.point(file, 0), "n", null);
    try testing.expect(!diags.hasErrors());
}
