//! `ar` archive reader (task #345): extracts the member object(s) out of
//! `libbitrt.a` so `elf_reader.zig`/`macho_reader.zig` can parse them. Common
//! (System V / GNU) format only — the format `zig build libbitrt` actually
//! writes (verified against a real build: `!<arch>\n` magic, a `/` global
//! symbol-table member, real member names short enough to fit inline with a
//! GNU trailing-`/` terminator). BSD's `#1/<len>` inline-long-name variant is
//! also handled since it costs little and this reader has no way to know in
//! advance which `ar` produced an archive fed to it.
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

        const name = try resolveName(gpa, raw_name, long_names, data);
        try members.append(gpa, .{ .name = name, .data = data });
    }

    return members.toOwnedSlice(gpa);
}

/// `data` is needed only for the BSD `#1/<len>` case, where the name is a
/// prefix of the member's own data rather than a separate table lookup.
fn resolveName(gpa: Allocator, raw_name: []const u8, long_names: []const u8, data: []const u8) Error![]const u8 {
    // GNU: "name/" — trailing slash marks the end of a short inline name.
    if (std.mem.endsWith(u8, raw_name, "/")) {
        return raw_name[0 .. raw_name.len - 1];
    }
    // GNU: "/<decimal offset>" — name lives in the `//` long-name table,
    // terminated by `\n`.
    if (raw_name.len > 1 and raw_name[0] == '/' and isAllDigits(raw_name[1..])) {
        const off = std.fmt.parseInt(usize, raw_name[1..], 10) catch return error.BadLongName;
        if (off >= long_names.len) return error.BadLongName;
        const end = std.mem.indexOfScalarPos(u8, long_names, off, '\n') orelse return error.BadLongName;
        var name_end = end;
        if (name_end > off and long_names[name_end - 1] == '/') name_end -= 1;
        return long_names[off..name_end];
    }
    // BSD: "#1/<len>" — the name is the first `len` bytes of the member's
    // own data (and does not count as part of the member's real content).
    if (std.mem.startsWith(u8, raw_name, "#1/")) {
        const len = std.fmt.parseInt(usize, raw_name[3..], 10) catch return error.BadLongName;
        if (len > data.len) return error.BadLongName;
        return gpa.dupe(u8, std.mem.trimEnd(u8, data[0..len], &.{0})) catch return error.OutOfMemory;
    }
    return raw_name;
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
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
