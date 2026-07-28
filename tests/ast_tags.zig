//! AST tag-set parity gate (#1420).
//!
//! Asserts that the seed's `ast.Tag` and selfhost's `enum Tag` (compiler/ast.bit)
//! name exactly the same set of nodes, and that every tag is mentioned by its
//! own parser.
//!
//! Why this exists. #1418 found `ParamRest` missing from selfhost entirely: the
//! seed parsed `...xs: T` and the self-hosted compiler rejected it outright — a
//! false positive, the one class THE SAFETY RULE forbids. Every differential
//! read green the whole time, because no file in stdlib/, examples/, tests/cases
//! or tests/imports declares a variadic. A construct outside the corpus is a
//! construct outside every guard. Finding it cost a 67-probe manual sweep; a set
//! comparison finds the same class in milliseconds, so it is worth having even
//! though it proves far less.
//!
//! SCOPE — read this before trusting a green run. This compares NAMES and
//! nothing else. It cannot tell you that a tag is handled correctly downstream,
//! or handled at all: the same #1418 audit found `Tag.TupleIndex` present in
//! ast.bit while check.bit had no case for it *or* for `Tag.TupleType`, and this
//! gate would have called that pair perfectly fine. "Parser-reachable" here means
//! the parser source mentions the tag, not that any input actually produces one.
//! Both checks are deliberately cheap proxies: they bound the blast radius of a
//! missing or orphaned tag, they do not prove semantics. Anything stronger
//! belongs in the behavioural differentials (selfhost-diffexamples.sh) or a
//! golden case.
//!
//! The seed side is read by reflection over the real enum, not by parsing
//! ast.zig — a text scan of that file silently missed `@"export"` (a Zig quoted
//! identifier, because `export` is a keyword) while developing this gate, which
//! is exactly the kind of false green a parity check must not have. Only the
//! selfhost side is parsed, and Bit tag identifiers are plain alphanumerics.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Upper bound on a scanned source file (Power of 10: no unbounded reads).
const max_source_bytes = 4 << 20;

/// Upper bound on tags in either enum — keeps every loop here statically
/// bounded. Raise if the AST ever approaches it.
const max_tags = 512;

/// The sentinel for "no child" / "no node". It is a real member of both enums
/// and deliberately never produced by either parser, so reachability skips it.
const sentinel_seed = "none";
const sentinel_selfhost = "None";

/// `ParamRest` -> `param_rest`. Selfhost spells tags in PascalCase; the seed and
/// both AST dumps use snake_case, so that is the comparison key.
fn snakeCase(gpa: std.mem.Allocator, pascal: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (pascal, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i != 0) try out.append(gpa, '_');
            try out.append(gpa, std.ascii.toLower(c));
        } else {
            try out.append(gpa, c);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The tag identifiers declared in compiler/ast.bit's `enum Tag { ... }`, in
/// declaration order. Returns PascalCase names; the caller converts.
///
/// The parse is deliberately literal: find the enum header, then take every
/// comma-separated identifier until the closing brace at column 0. Anything from
/// `//` onward is a comment. A malformed or missing block is an error, never an
/// empty set — an empty set would make every comparison below vacuously pass,
/// which is precisely the failure mode this gate is meant not to have.
fn selfhostTags(gpa: std.mem.Allocator, src: []const u8) ![][]const u8 {
    const header = "\nenum Tag {\n";
    const start = std.mem.indexOf(u8, src, header) orelse return error.TagEnumNotFound;
    const body_start = start + header.len;
    const end_rel = std.mem.indexOf(u8, src[body_start..], "\n}") orelse return error.TagEnumUnterminated;
    const body = src[body_start .. body_start + end_rel];

    var tags: std.ArrayList([]const u8) = .empty;
    errdefer tags.deinit(gpa);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        if (tags.items.len > max_tags) return error.TooManyTags;
        const line = if (std.mem.indexOf(u8, raw_line, "//")) |c| raw_line[0..c] else raw_line;
        var parts = std.mem.splitScalar(u8, line, ',');
        while (parts.next()) |part| {
            const name = std.mem.trim(u8, part, " \t\r");
            if (name.len == 0) continue;
            for (name) |c| if (!std.ascii.isAlphanumeric(c)) return error.MalformedTag;
            try tags.append(gpa, name);
        }
    }
    if (tags.items.len == 0) return error.NoTagsParsed;
    return tags.toOwnedSlice(gpa);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

test "seed and selfhost declare the same AST tag set" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    // Seed side: the real enum, by reflection. No parsing, so it cannot drift
    // from what the compiler actually compiles.
    const seed_fields = @typeInfo(bit.ast.Tag).@"enum".fields;
    comptime std.debug.assert(seed_fields.len <= max_tags);
    var seed_tags: [seed_fields.len][]const u8 = undefined;
    inline for (seed_fields, 0..) |f, i| seed_tags[i] = f.name;

    const ast_bit = try Dir.cwd().readFileAlloc(io, build_options.selfhost_ast, gpa, .limited(max_source_bytes));
    defer gpa.free(ast_bit);

    const pascal = try selfhostTags(gpa, ast_bit);
    defer gpa.free(pascal);

    var selfhost_snake: std.ArrayList([]const u8) = .empty;
    defer {
        for (selfhost_snake.items) |s| gpa.free(s);
        selfhost_snake.deinit(gpa);
    }
    for (pascal) |p| try selfhost_snake.append(gpa, try snakeCase(gpa, p));

    var failed = false;
    for (seed_tags) |t| {
        if (contains(selfhost_snake.items, t)) continue;
        std.debug.print("AST tag '{s}' exists in seed/ast.zig but not in compiler/ast.bit\n", .{t});
        failed = true;
    }
    for (selfhost_snake.items, pascal) |t, p| {
        if (contains(&seed_tags, t)) continue;
        std.debug.print("AST tag '{s}' (Tag.{s}) exists in compiler/ast.bit but not in seed/ast.zig\n", .{ t, p });
        failed = true;
    }
    if (failed) {
        std.debug.print("seed has {d} tags, selfhost has {d}\n", .{ seed_tags.len, selfhost_snake.items.len });
        return error.AstTagSetMismatch;
    }
}

/// Every `compiler/parser*.bit` concatenated. They are sibling files in one
/// module (#1503), so a tag is parser-reachable if ANY of them mentions it.
///
/// Reading the directory rather than a fixed file list is deliberate: this gate
/// went vacuous once already when `parser.bit` was split and the hardcoded path
/// kept pointing at the 233-line remnant. A future split must not be able to
/// silently empty it again.
fn readSelfhostParser(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var dir = try Dir.cwd().openDir(io, build_options.selfhost_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var acc: std.ArrayList(u8) = .empty;
    errdefer acc.deinit(gpa);

    var seen: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.basename, "parser")) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".bit")) continue;
        const src = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_source_bytes));
        defer gpa.free(src);
        try acc.appendSlice(gpa, src);
        try acc.append(gpa, '\n');
        seen += 1;
    }

    // A rename or a moved directory would otherwise read as "every tag missing",
    // which is indistinguishable from a real regression. Fail on the cause.
    if (seen == 0) return error.NoSelfhostParserSources;
    return acc.toOwnedSlice(gpa);
}

test "every AST tag is reachable from its own parser" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const seed_parser = try Dir.cwd().readFileAlloc(io, build_options.seed_parser, gpa, .limited(max_source_bytes));
    defer gpa.free(seed_parser);
    const selfhost_parser = try readSelfhostParser(gpa, io);
    defer gpa.free(selfhost_parser);

    var failed = false;

    // Seed: the parser names a tag as `.ident` — or `.@"export"` when the tag
    // collides with a Zig keyword, so both spellings count as a mention.
    inline for (@typeInfo(bit.ast.Tag).@"enum".fields) |f| {
        if (comptime !std.mem.eql(u8, f.name, sentinel_seed)) {
            const plain = "." ++ f.name;
            const quoted = ".@\"" ++ f.name ++ "\"";
            if (std.mem.indexOf(u8, seed_parser, plain) == null and
                std.mem.indexOf(u8, seed_parser, quoted) == null)
            {
                std.debug.print("AST tag '{s}' is never produced by seed/parser.zig\n", .{f.name});
                failed = true;
            }
        }
    }

    const ast_bit = try Dir.cwd().readFileAlloc(io, build_options.selfhost_ast, gpa, .limited(max_source_bytes));
    defer gpa.free(ast_bit);
    const pascal = try selfhostTags(gpa, ast_bit);
    defer gpa.free(pascal);

    for (pascal) |p| {
        if (std.mem.eql(u8, p, sentinel_selfhost)) continue;
        const needle = try std.fmt.allocPrint(gpa, "Tag.{s}", .{p});
        defer gpa.free(needle);
        if (std.mem.indexOf(u8, selfhost_parser, needle) != null) continue;
        std.debug.print("AST tag 'Tag.{s}' is never produced by compiler/parser.bit\n", .{p});
        failed = true;
    }

    if (failed) return error.AstTagUnreachable;
}
