//! Every exported stdlib symbol is documented (#356).
//!
//! The list of what `std/strings` exports is not maintained by hand anywhere —
//! it is derived from the resolver's `exports` table by `seed/doc.zig`, the
//! same code behind `bit doc`. This test walks `stdlib/*`, asks for that list,
//! and fails the build if a symbol has no section in `docs/stdlib/<module>.md`.
//!
//! A section is an `###` heading whose first backticked word is the symbol:
//!
//!     ### `toUpper(s: string): string`
//!     ### `pi: f64`
//!     ### `File.readAll(): string!`
//!
//! Requiring the heading — not merely a mention — is deliberate. Prose says
//! "returns the count"; a heading says "here is `count`, and here is its
//! signature". Adding an export without documenting it breaks the build, which
//! is the only mechanism that reliably keeps reference docs complete.
//!
//! The examples in those pages are compiled separately, by `tests/docs.zig`.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;
const Dir = std.Io.Dir;

/// Bounds, so the walk is provably finite (Power of 10).
const max_modules = 64;
const max_doc_bytes = 1 << 20;

/// Whether `md` has an `### \`<name>...\`` heading. The character right after the
/// name must not be an identifier character, so `count` does not match a heading
/// for `countWords`.
fn hasSection(md: []const u8, name: []const u8) bool {
    var rest = md;
    while (std.mem.indexOf(u8, rest, "### `")) |at| {
        const after = rest[at + "### `".len ..];
        if (std.mem.startsWith(u8, after, name)) {
            const tail = after[name.len..];
            if (tail.len == 0 or !isIdentChar(tail[0])) return true;
        }
        rest = after;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "hasSection matches a symbol heading, not a prefix or a mention" {
    const md =
        \\Prose mentioning count and toUpper freely.
        \\### `count(s: string, sub: string): int`
        \\### `File.readAll(): string!`
        \\### `pi: f64`
    ;
    try testing.expect(hasSection(md, "count"));
    try testing.expect(hasSection(md, "File.readAll"));
    try testing.expect(hasSection(md, "pi"));
    try testing.expect(!hasSection(md, "countWords")); // longer than the heading
    try testing.expect(!hasSection(md, "toUpper")); // prose only, no heading
    try testing.expect(!hasSection(md, "coun")); // prefix of a heading
}

// #1528: `Checker.substMethod` and `TypeContext.reinstantiate` build an
// instantiation's method set from the template's, and both used to drop
// `Method.exported`. `doc.zig` filters on that flag, so an `export`ed method
// vanished from the docs of any symbol whose type is an INSTANCE rather than
// the template — i.e. an exported alias of a generic instantiation.
//
// No stdlib module declares such an alias today, so the whole walk above cannot
// see this. The fixture is written to a scratch module of its own (the pattern
// `tests/docs.zig` uses) rather than checked in, so it stays invisible to the
// harnesses that scan `tests/` for Bit sources.
test "an exported method survives instantiation into the docs (#1528)" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    const scratch = try std.fmt.allocPrint(gpa, "/tmp/bit-docexport-{x}", .{testing.random_seed});
    defer gpa.free(scratch);
    Dir.cwd().deleteTree(io, scratch) catch {};
    try Dir.cwd().createDirPath(io, scratch);
    defer Dir.cwd().deleteTree(io, scratch) catch {};

    const main_path = try std.fs.path.join(gpa, &.{ scratch, "main.bit" });
    defer gpa.free(main_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data =
        \\export struct Box<T> {
        \\  v: T
        \\}
        \\
        \\export function (b: Box<T>) get(): T {
        \\  return b.v
        \\}
        \\
        \\function (b: Box<T>) hidden(): T {
        \\  return b.v
        \\}
        \\
        \\export type IntBox = Box<i64>
        \\
    });

    var report: Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var d = (try bit.doc.moduleDoc(gpa, io, scratch, build_options.stdlib_dir, &report.writer)) orelse {
        std.debug.print("fixture does not compile:\n{s}\n", .{report.written()});
        return error.FixtureFailed;
    };
    defer d.deinit();

    var template_get = false;
    var instance_get = false;
    var hidden = false;
    for (d.symbols) |s| {
        if (std.mem.eql(u8, s.name, "Box.get")) template_get = true;
        if (std.mem.eql(u8, s.name, "IntBox.get")) instance_get = true;
        if (std.mem.endsWith(u8, s.name, ".hidden")) hidden = true;
    }
    try testing.expect(template_get); // the control: the template always worked
    try testing.expect(instance_get); // the regression: dropped before #1528
    try testing.expect(!hidden); // a private method is still no public surface
}

test "every exported stdlib symbol has a docs/stdlib section" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();

    var std_dir = try Dir.openDirAbsolute(io, build_options.stdlib_dir, .{ .iterate = true });
    defer std_dir.close(io);

    var it = std_dir.iterate();
    var modules: u32 = 0;
    var missing: u32 = 0;
    var documented: u32 = 0;
    while (modules < max_modules) : (modules += 1) {
        const entry = (try it.next(io)) orelse break;
        if (entry.kind != .directory) continue;

        const mod_abs = try std.fs.path.join(gpa, &.{ build_options.stdlib_dir, entry.name });
        defer gpa.free(mod_abs);
        const page_path = try std.fmt.allocPrint(gpa, "{s}/stdlib/{s}.md", .{ build_options.docs_dir, entry.name });
        defer gpa.free(page_path);

        var report: Io.Writer.Allocating = .init(gpa);
        defer report.deinit();
        var d = (try bit.doc.moduleDoc(gpa, io, mod_abs, build_options.stdlib_dir, &report.writer)) orelse {
            std.debug.print("stdlib/{s} does not compile:\n{s}\n", .{ entry.name, report.written() });
            return error.StdlibModuleFailed;
        };
        defer d.deinit();
        if (d.symbols.len == 0) continue; // an internal module with no exports

        const md = Dir.cwd().readFileAlloc(io, page_path, gpa, .limited(max_doc_bytes)) catch |e| {
            std.debug.print("stdlib/{s} exports {d} symbols but {s} is unreadable: {s}\n", .{ entry.name, d.symbols.len, page_path, @errorName(e) });
            return e;
        };
        defer gpa.free(md);

        for (d.symbols) |s| {
            if (hasSection(md, s.name)) {
                documented += 1;
                continue;
            }
            missing += 1;
            std.debug.print("docs/stdlib/{s}.md: no `### `{s}`` section for the exported {s} `{s}` ({s})\n", .{ entry.name, s.name, s.kind.text(), s.name, s.type_text });
        }
    }
    try testing.expect(modules < max_modules);
    try testing.expect(documented > 0); // the walk must actually find symbols
    try testing.expectEqual(@as(u32, 0), missing);
}
