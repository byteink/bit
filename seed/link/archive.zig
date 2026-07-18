//! `ar` archive reader (task #345): extracts the member object(s) out of
//! `libbitrt.a` so `elf_reader.zig`/`macho_reader.zig` can parse them. Handles
//! both formats `zig build libbitrt` actually writes: **GNU/System V** for ELF
//! targets (a `/` symbol-table member, a `//` long-name table, GNU trailing-`/`
//! short names) and **BSD** for Mach-O targets (an `__.SYMDEF` symbol table and
//! `#1/<len>` names carried as a null-padded prefix of each member's own data).
//! Both symbol tables are skipped — `link.zig`'s merge builds the whole-link
//! global table from every member's own symbols for dead-strip anyway, so an
//! index would save nothing (see below).
//!
//! Deliberately does *not* use the `/` symbol-table member to route straight
//! to the member defining a wanted symbol — `link.zig`'s merge always needs
//! every member's full symbol table anyway (to build the whole-link global
//! table for dead-strip reachability), so there is nothing an index would
//! save here. Skipped, not parsed.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    TruncatedArchive,
    BadMagic,
    BadHeader,
    BadLongName,
};

pub const Member = struct {
    name: []const u8,
    data: []const u8,
};

const magic = "!<arch>\n";
const header_len = 60;

/// Parses `bytes` (the whole `.a` file) into its real members, skipping the
/// `/` (symbol table) and `//` (long-name table) special members. Returned
/// `Member.data`/`.name` slices alias `bytes` — caller keeps `bytes` alive
/// for as long as the result is used.
pub fn parse(gpa: Allocator, bytes: []const u8) Error![]Member {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) {
        return error.BadMagic;
    }

    var long_names: []const u8 = &.{};
    var members: std.ArrayList(Member) = .empty;
    defer members.deinit(gpa);

    var pos: usize = magic.len;
    while (pos < bytes.len) {
        // Archives pad each member to an even offset with one `\n` filler
        // byte; skip it before reading the next header.
        if (pos % 2 == 1) pos += 1;
        if (pos == bytes.len) break;
        if (pos + header_len > bytes.len) return error.TruncatedArchive;

        const header = bytes[pos..][0..header_len];
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.BadHeader;

        const raw_name = std.mem.trimEnd(u8, header[0..16], " ");
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, header[48..58], " "), 10) catch return error.BadHeader;

        const data_start = pos + header_len;
        if (data_start + size > bytes.len) return error.TruncatedArchive;
        const data = bytes[data_start..][0..size];
        pos = data_start + size;

        if (std.mem.eql(u8, raw_name, "/")) {
            continue; // GNU/System V symbol table — unused, see doc comment
        }
        if (std.mem.eql(u8, raw_name, "//")) {
            long_names = data; // GNU long-filename table
            continue;
        }

        const resolved = try resolveName(raw_name, long_names, data);
        // BSD symbol tables carry an `__.SYMDEF`/`__.SYMDEF SORTED`/`__.SYMDEF_64`
        // name (the macOS `ar`/Zig-for-macho form of the GNU `/` member) — the
        // index we deliberately don't use, same as `/` above.
        if (std.mem.startsWith(u8, resolved.name, "__.SYMDEF")) continue;
        try members.append(gpa, .{ .name = resolved.name, .data = data[resolved.data_start..] });
    }

    return members.toOwnedSlice(gpa);
}

const Resolved = struct {
    name: []const u8,
    /// Offset within the member's raw data where its real content begins —
    /// nonzero only for BSD `#1/<len>`, whose name is a prefix of the data.
    data_start: usize,
};

/// `data` is needed only for the BSD `#1/<len>` case, where the name is a
/// prefix of the member's own data rather than a separate table lookup. Every
/// returned name aliases `raw_name`/`long_names`/`data` — never allocated.
fn resolveName(raw_name: []const u8, long_names: []const u8, data: []const u8) Error!Resolved {
    // GNU: "name/" — trailing slash marks the end of a short inline name.
    if (std.mem.endsWith(u8, raw_name, "/")) {
        return .{ .name = raw_name[0 .. raw_name.len - 1], .data_start = 0 };
    }
    // GNU: "/<decimal offset>" — name lives in the `//` long-name table,
    // terminated by `\n`.
    if (raw_name.len > 1 and raw_name[0] == '/' and isAllDigits(raw_name[1..])) {
        const off = std.fmt.parseInt(usize, raw_name[1..], 10) catch return error.BadLongName;
        if (off >= long_names.len) return error.BadLongName;
        const end = std.mem.indexOfScalarPos(u8, long_names, off, '\n') orelse return error.BadLongName;
        var name_end = end;
        if (name_end > off and long_names[name_end - 1] == '/') name_end -= 1;
        return .{ .name = long_names[off..name_end], .data_start = 0 };
    }
    // BSD: "#1/<len>" — the name is the first `len` (null-padded) bytes of the
    // member's own data; the real content follows at `data[len..]`.
    if (std.mem.startsWith(u8, raw_name, "#1/")) {
        const len = std.fmt.parseInt(usize, raw_name[3..], 10) catch return error.BadLongName;
        if (len > data.len) return error.BadLongName;
        return .{ .name = std.mem.trimEnd(u8, data[0..len], &.{0}), .data_start = len };
    }
    return .{ .name = raw_name, .data_start = 0 };
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Writer (task #1398) — the inverse of `parse`, so a `libbitrt.a` can be
// *produced* from Bit-compiled objects rather than only consumed.
// ---------------------------------------------------------------------------

/// Which name encoding to write. Matches what each platform's own `ar` (and
/// `zig build libbitrt`) produces, and what `parse` above already reads back:
/// GNU/System V for ELF targets, BSD for Mach-O.
pub const Format = enum { gnu, bsd };

/// Deliberately writes NO symbol-table member (`/` or `__.SYMDEF`). `parse`
/// skips both by design — `link.zig`'s merge builds the whole-link global table
/// from every member's own symbols for dead-strip anyway — so an index would be
/// bytes this toolchain never reads. Every other byte matches what `ar` writes,
/// so a member's header and payload are byte-comparable with `zig build
/// libbitrt`'s output for the same input.
///
/// mtime/uid/gid are always `0` (reproducible output). `mode` follows each
/// platform's own convention so the result is byte-comparable with that
/// platform's tooling: `644` for GNU members, `0` for BSD ones, and blank on the
/// `//` table — exactly what `zig build libbitrt` writes for each.
pub fn write(gpa: Allocator, format: Format, members: []const Member) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);

    // GNU carries names longer than 15 bytes in a `//` table, referenced by
    // byte offset; BSD carries every name inline, so it needs no table.
    var long_names: std.ArrayList(u8) = .empty;
    defer long_names.deinit(gpa);
    const long_offsets = try gpa.alloc(usize, members.len);
    defer gpa.free(long_offsets);
    @memset(long_offsets, 0);
    if (format == .gnu) {
        for (members, 0..) |m, i| {
            if (m.name.len <= 15) continue;
            long_offsets[i] = long_names.items.len;
            try long_names.appendSlice(gpa, m.name);
            try long_names.appendSlice(gpa, "/\n"); // real GNU ar slash-terminates
        }
        if (long_names.items.len > 0) {
            try writeHeader(gpa, &out, "//", long_names.items.len, null);
            try out.appendSlice(gpa, long_names.items);
            try padEven(gpa, &out);
        }
    }

    for (members, 0..) |m, i| {
        switch (format) {
            .gnu => {
                var buf: [24]u8 = undefined;
                const field = if (m.name.len <= 15)
                    std.fmt.bufPrint(&buf, "{s}/", .{m.name}) catch unreachable
                else
                    std.fmt.bufPrint(&buf, "/{d}", .{long_offsets[i]}) catch unreachable;
                try writeHeader(gpa, &out, field, m.data.len, "644");
                try out.appendSlice(gpa, m.data);
            },
            .bsd => {
                // The name is a NUL-padded prefix of the member's own data, its
                // padded length declared in the name field. Aligned to 4, which
                // is what macOS `ar` and Zig both produce.
                const padded = std.mem.alignForward(usize, m.name.len, 4);
                var buf: [24]u8 = undefined;
                const field = std.fmt.bufPrint(&buf, "#1/{d}", .{padded}) catch unreachable;
                try writeHeader(gpa, &out, field, padded + m.data.len, "0");
                try out.appendSlice(gpa, m.name);
                try out.appendNTimes(gpa, 0, padded - m.name.len);
                try out.appendSlice(gpa, m.data);
            },
        }
        try padEven(gpa, &out);
    }
    return out.toOwnedSlice(gpa);
}

/// One 60-byte header: a 16-byte name, then mtime/uid/gid/mode/size in
/// fixed-width space-padded decimal, then the "`\n" magic at offset 58. A null
/// `mode` leaves every numeric field but `size` blank, which is how `ar` writes
/// the `//` long-name table's own header.
fn writeHeader(gpa: Allocator, out: *std.ArrayList(u8), name_field: []const u8, size: usize, mode: ?[]const u8) Allocator.Error!void {
    std.debug.assert(name_field.len <= 16);
    const start = out.items.len;
    try out.appendNTimes(gpa, ' ', header_len);
    const h = out.items[start..][0..header_len];
    @memcpy(h[0..name_field.len], name_field);
    if (mode) |md| {
        h[16] = '0'; // mtime
        h[28] = '0'; // uid
        h[34] = '0'; // gid
        @memcpy(h[40..][0..md.len], md);
    }
    // Left-aligned in its fixed-width field; the tail it does not reach stays
    // the space fill written above, which is exactly how `ar` pads.
    _ = std.fmt.bufPrint(h[48..58], "{d}", .{size}) catch unreachable;
    h[58] = '`';
    h[59] = '\n';
}

/// `ar` starts every header at an even offset, padding with one `\n`.
fn padEven(gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (out.items.len % 2 == 1) try out.append(gpa, '\n');
}

const testing = std.testing;

test "parses a hand-built System V archive with a long-name member" {
    const gpa = testing.allocator;

    // Build a tiny archive by hand: symbol table (empty, ignored), a
    // long-name table with one 20-byte name, and one real member using it.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, magic);

    try appendHeader(gpa, &buf, "/", 0);

    const long_name = "a_very_long_member_name.o";
    var long_table: std.ArrayList(u8) = .empty;
    defer long_table.deinit(gpa);
    try long_table.appendSlice(gpa, long_name);
    try long_table.append(gpa, '\n');
    try appendHeader(gpa, &buf, "//", long_table.items.len);
    try buf.appendSlice(gpa, long_table.items);

    try appendHeader(gpa, &buf, "/0", 5);
    try buf.appendSlice(gpa, "hello");
    try buf.append(gpa, '\n'); // odd-length padding

    try appendHeader(gpa, &buf, "short.o/", 3);
    try buf.appendSlice(gpa, "abc");

    const members = try parse(gpa, buf.items);
    defer gpa.free(members);

    try testing.expectEqual(@as(usize, 2), members.len);
    try testing.expectEqualStrings(long_name, members[0].name);
    try testing.expectEqualStrings("hello", members[0].data);
    try testing.expectEqualStrings("short.o", members[1].name);
    try testing.expectEqualStrings("abc", members[1].data);
}

fn appendHeader(gpa: Allocator, buf: *std.ArrayList(u8), name: []const u8, size: usize) !void {
    var header: [header_len]u8 = @splat(' ');
    @memcpy(header[0..name.len], name);
    var size_buf: [10]u8 = @splat(' ');
    const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{size}) catch unreachable;
    @memcpy(header[48..][0..size_str.len], size_str);
    header[58] = '`';
    header[59] = '\n';
    try buf.appendSlice(gpa, &header);
}

test "rejects a file missing the ar magic" {
    try testing.expectError(error.BadMagic, parse(testing.allocator, "not an archive"));
}

test "parses a BSD archive, skips __.SYMDEF, strips the #1/ name prefix" {
    const gpa = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, magic);

    // The exact shape macOS `ar` / Zig-for-macho produces: a BSD symbol-table
    // member named "__.SYMDEF" (must be skipped) then one real object whose
    // name is a null-padded prefix of its own data (must be stripped off).
    try appendBsdMember(gpa, &buf, "__.SYMDEF", "INDEX-BYTES");
    try appendBsdMember(gpa, &buf, "libbitrt_zcu.o", "MACHOCONTENT");

    const members = try parse(gpa, buf.items);
    defer gpa.free(members);

    try testing.expectEqual(@as(usize, 1), members.len);
    try testing.expectEqualStrings("libbitrt_zcu.o", members[0].name);
    try testing.expectEqualStrings("MACHOCONTENT", members[0].data);
}

/// Appends one BSD `#1/<len>` member: a `#1/N` header whose data is the
/// name (null-padded to a 4-byte boundary, exercising the trim) then `content`.
fn appendBsdMember(gpa: Allocator, buf: *std.ArrayList(u8), name: []const u8, content: []const u8) !void {
    const name_field = std.mem.alignForward(usize, name.len, 4);
    var hdr_name_buf: [16]u8 = undefined;
    const hdr_name = std.fmt.bufPrint(&hdr_name_buf, "#1/{d}", .{name_field}) catch unreachable;
    try appendHeader(gpa, buf, hdr_name, name_field + content.len);
    try buf.appendSlice(gpa, name);
    try buf.appendNTimes(gpa, 0, name_field - name.len);
    try buf.appendSlice(gpa, content);
    if (buf.items.len % 2 == 1) try buf.append(gpa, '\n');
}

/// The writer's contract with `parse` (#1398): whatever goes in comes back out,
/// names and payloads byte-identical, in both name encodings. A long name, an
/// odd-length payload (which forces the `\n` even-offset padding) and an empty
/// member are each present because each is a distinct failure mode.
fn expectRoundTrip(format: Format, members: []const Member) !void {
    const gpa = testing.allocator;
    const bytes = try write(gpa, format, members);
    defer gpa.free(bytes);

    const back = try parse(gpa, bytes);
    defer gpa.free(back);

    try testing.expectEqual(members.len, back.len);
    for (members, back) |want, got| {
        try testing.expectEqualStrings(want.name, got.name);
        try testing.expectEqualStrings(want.data, got.data);
    }
}

test "writer round-trips through the reader in both name encodings" {
    const members = [_]Member{
        .{ .name = "short.o", .data = "abc" }, // odd length -> padding
        .{ .name = "a_very_long_member_name_over_15_bytes.o", .data = "hello" },
        .{ .name = "empty.o", .data = "" },
        .{ .name = "exactly_15chars", .data = "\x00\x01\xfe\xff" }, // the inline/table boundary
    };
    try expectRoundTrip(.gnu, &members);
    try expectRoundTrip(.bsd, &members);
}

test "writer emits the magic and no symbol-table member" {
    const gpa = testing.allocator;
    const bytes = try write(gpa, .gnu, &.{.{ .name = "a.o", .data = "x" }});
    defer gpa.free(bytes);
    try testing.expectEqualStrings(magic, bytes[0..magic.len]);
    // No `/` index and no `//` table (no long names here): the first header is
    // the real member's.
    try testing.expectEqualStrings("a.o/", std.mem.trimEnd(u8, bytes[magic.len..][0..16], " "));
}

test "writer's headers match the field layout ar writes" {
    const gpa = testing.allocator;
    const bytes = try write(gpa, .bsd, &.{.{ .name = "libbitrt_zcu.o", .data = "MACHO" }});
    defer gpa.free(bytes);
    const h = bytes[magic.len..][0..header_len];
    // Name padded to 4 (14 -> 16), as macOS ar and `zig build libbitrt` produce.
    try testing.expectEqualStrings("#1/16", std.mem.trimEnd(u8, h[0..16], " "));
    try testing.expectEqualStrings("0", std.mem.trimEnd(u8, h[16..28], " ")); // mtime
    try testing.expectEqualStrings("0", std.mem.trimEnd(u8, h[28..34], " ")); // uid
    try testing.expectEqualStrings("0", std.mem.trimEnd(u8, h[34..40], " ")); // gid
    try testing.expectEqualStrings("0", std.mem.trimEnd(u8, h[40..48], " ")); // mode (BSD)
    try testing.expectEqualStrings("21", std.mem.trimEnd(u8, h[48..58], " ")); // 16 name + 5 data
    try testing.expectEqualStrings("`\n", h[58..60]);
}

test "every header starts at an even offset" {
    const gpa = testing.allocator;
    const bytes = try write(gpa, .gnu, &.{
        .{ .name = "odd.o", .data = "abc" },
        .{ .name = "next.o", .data = "de" },
    });
    defer gpa.free(bytes);
    // The second member's header follows the first's odd payload, so it can
    // only be even if the `\n` filler was written.
    const second = magic.len + header_len + 3 + 1;
    try testing.expect(second % 2 == 0);
    try testing.expectEqualStrings("next.o/", std.mem.trimEnd(u8, bytes[second..][0..16], " "));
}
