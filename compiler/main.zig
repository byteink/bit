const std = @import("std");
const Io = std.Io;

/// Seed compiler version. Kept in sync with `build.zig.zon`.
pub const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    var buf: [64]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const out = &stdout.interface;
    try out.print("bitc {s}\n", .{version});
    try out.flush();
}

test "version string is non-empty" {
    try std.testing.expect(version.len > 0);
}
