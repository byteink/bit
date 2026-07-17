//! Ad-hoc Mach-O code signing (task #345, macOS arm64). Apple Silicon refuses
//! to `exec` any arm64 binary without a valid code signature — an unsigned
//! image is `SIGKILL`ed by AMFI before its entry point runs. A locally built
//! executable that ships no certificate still needs a real, structurally valid
//! *ad-hoc* signature (no CMS, no identity, just page hashes the kernel
//! recomputes), which is what this module builds.
//!
//! The signature is an embedded `CS_SuperBlob` carrying one `CS_CodeDirectory`:
//!
//!   SuperBlob { magic, length, count=1 } [ BlobIndex{ CODEDIRECTORY, off } ]
//!   CodeDirectory { header … identifier … codeSlot[0..nCodeSlots] }
//!
//! Every code slot is the SHA-256 of one `pageSize` (4 KiB) page of the file,
//! from offset 0 up to `codeLimit` (the offset where the signature blob itself
//! begins — the signature never hashes itself). The kernel walks the same
//! pages, recomputes the hashes, and compares; `CS_ADHOC` + valid hashes is
//! what makes an identity-free binary launchable.
//!
//! All multi-byte fields are **big-endian** (the code-signing format is the one
//! part of Mach-O that is not host-endian). Struct layouts and constants are
//! transcribed from `<Security/CSCommon.h>` / dyld's `CodeSigningTypes.h`, not
//! from memory — and validated against the system `codesign -v` on a real Mac
//! (see `link/macho.zig`'s executable tests, which sign then verify).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xfade0cc0;
const CSMAGIC_CODEDIRECTORY: u32 = 0xfade0c02;
const CSSLOT_CODEDIRECTORY: u32 = 0;
const CS_ADHOC: u32 = 0x0002;
const CS_HASHTYPE_SHA256: u8 = 2;
/// Latest CodeDirectory version this writer emits — includes the `execSeg*`
/// fields AMFI reads on arm64 to authorize the main binary's executable pages.
const CD_VERSION: u32 = 0x20400;
const CS_EXECSEG_MAIN_BINARY: u64 = 0x1;

const page_size_log2: u8 = 12;
const page_size: u64 = 1 << page_size_log2;
const hash_size: u32 = 32; // SHA-256

/// Byte size of the `CS_CodeDirectory` fixed header up to `execSegFlags`
/// (version 0x20400): 9×u32 + 4×u8 + spare2 + scatter/team/spare3 + codeLimit64
/// + execSegBase/Limit/Flags. Fields past this point are the identifier string
/// and the hash slots.
const cd_header_size: u32 = 88;
/// `CS_SuperBlob` header (magic,length,count) + one `CS_BlobIndex` (type,off).
const superblob_header_size: u32 = 12 + 8;

fn nCodeSlots(code_limit: u64) u32 {
    return @intCast((code_limit + page_size - 1) / page_size);
}

fn writeBE(comptime T: type, dst: []u8, v: T) void {
    std.mem.writeInt(T, dst[0..@sizeOf(T)], v, .big);
}

/// Total embedded-signature size for a file signed over `[0, code_limit)`.
/// The executable writer calls this first to reserve `__LINKEDIT` space and
/// set `LC_CODE_SIGNATURE.datasize` before it can compute the final layout.
pub fn size(code_limit: u64, identifier: []const u8) u32 {
    const cd_len = cd_header_size + @as(u32, @intCast(identifier.len + 1)) + nCodeSlots(code_limit) * hash_size;
    return superblob_header_size + cd_len;
}

/// Builds the ad-hoc embedded signature over `signed` (the final file bytes
/// from offset 0 up to `codeLimit == signed.len` — headers already patched,
/// signature region not yet appended). `exec_seg_limit` is the `__TEXT`
/// segment's file size (`execSegBase` is 0: `__TEXT` starts at file offset 0).
/// Returned bytes are owned by the caller and are exactly `size(...)` long.
pub fn build(gpa: Allocator, signed: []const u8, identifier: []const u8, exec_seg_limit: u64) Allocator.Error![]u8 {
    const code_limit: u64 = signed.len;
    const n = nCodeSlots(code_limit);
    const ident_len: u32 = @intCast(identifier.len + 1);
    const cd_len = cd_header_size + ident_len + n * hash_size;
    const total = superblob_header_size + cd_len;

    const out = try gpa.alloc(u8, total);
    @memset(out, 0);

    // ---- SuperBlob header + one index entry -------------------------------
    writeBE(u32, out[0..], CSMAGIC_EMBEDDED_SIGNATURE);
    writeBE(u32, out[4..], total);
    writeBE(u32, out[8..], 1); // count: one contained blob
    writeBE(u32, out[12..], CSSLOT_CODEDIRECTORY);
    writeBE(u32, out[16..], superblob_header_size); // CD offset within the SuperBlob

    // ---- CodeDirectory ----------------------------------------------------
    const cd = out[superblob_header_size..];
    const hash_offset = cd_header_size + ident_len; // slot[0]; no special slots
    writeBE(u32, cd[0..], CSMAGIC_CODEDIRECTORY);
    writeBE(u32, cd[4..], cd_len);
    writeBE(u32, cd[8..], CD_VERSION);
    writeBE(u32, cd[12..], CS_ADHOC);
    writeBE(u32, cd[16..], hash_offset);
    writeBE(u32, cd[20..], cd_header_size); // identOffset (identifier follows the header)
    writeBE(u32, cd[24..], 0); // nSpecialSlots (no requirements/entitlement hashes)
    writeBE(u32, cd[28..], n); // nCodeSlots
    writeBE(u32, cd[32..], @intCast(code_limit & 0xffffffff)); // codeLimit (codeLimit64 covers >4 GiB)
    cd[36] = @intCast(hash_size);
    cd[37] = CS_HASHTYPE_SHA256;
    cd[38] = 0; // platform: not a platform binary
    cd[39] = page_size_log2;
    // spare2 @40, scatterOffset @44, teamOffset @48, spare3 @52: all zero.
    writeBE(u64, cd[56..], if (code_limit > 0xffffffff) code_limit else 0); // codeLimit64
    writeBE(u64, cd[64..], 0); // execSegBase: __TEXT begins at file offset 0
    writeBE(u64, cd[72..], exec_seg_limit); // execSegLimit
    writeBE(u64, cd[80..], CS_EXECSEG_MAIN_BINARY); // execSegFlags

    @memcpy(cd[cd_header_size..][0..identifier.len], identifier);
    cd[cd_header_size + identifier.len] = 0;

    // ---- per-page SHA-256 code slots --------------------------------------
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const start: usize = @intCast(@as(u64, i) * page_size);
        const end: usize = @intCast(@min(@as(u64, i + 1) * page_size, code_limit));
        var h: [hash_size]u8 = undefined;
        Sha256.hash(signed[start..end], &h, .{});
        @memcpy(cd[hash_offset + i * hash_size ..][0..hash_size], &h);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests (structural; end-to-end `codesign -v` runs in link/macho.zig on a Mac)
// ---------------------------------------------------------------------------
const testing = std.testing;

test "size matches the built blob length" {
    const gpa = testing.allocator;
    const file = [_]u8{0xAB} ** (page_size + 100); // 2 pages (one partial)
    const sig = try build(gpa, &file, "hello", file.len);
    defer gpa.free(sig);
    try testing.expectEqual(size(file.len, "hello"), @as(u32, @intCast(sig.len)));
}

test "signature carries a valid SuperBlob + CodeDirectory and correct page hashes" {
    const gpa = testing.allocator;
    // 3 pages: two full, one partial — exercises nCodeSlots rounding and the
    // partial last page being hashed over its real bytes only.
    var file: [2 * page_size + 555]u8 = undefined;
    for (&file, 0..) |*b, i| b.* = @truncate(i);

    const sig = try build(gpa, &file, "bit-test", file.len);
    defer gpa.free(sig);

    try testing.expectEqual(CSMAGIC_EMBEDDED_SIGNATURE, std.mem.readInt(u32, sig[0..4], .big));
    try testing.expectEqual(@as(u32, @intCast(sig.len)), std.mem.readInt(u32, sig[4..8], .big));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, sig[8..12], .big));

    const cd = sig[superblob_header_size..];
    try testing.expectEqual(CSMAGIC_CODEDIRECTORY, std.mem.readInt(u32, cd[0..4], .big));
    try testing.expectEqual(CS_ADHOC, std.mem.readInt(u32, cd[12..16], .big));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, cd[28..32], .big)); // nCodeSlots

    // Slot 0 must be the SHA-256 of the first page — the exact check the kernel
    // performs. Recompute independently and compare.
    const hash_offset = std.mem.readInt(u32, cd[16..20], .big);
    var expect: [hash_size]u8 = undefined;
    Sha256.hash(file[0..page_size], &expect, .{});
    try testing.expectEqualSlices(u8, &expect, cd[hash_offset..][0..hash_size]);

    // The partial last page is hashed over its real length, not a padded page.
    var expect_last: [hash_size]u8 = undefined;
    Sha256.hash(file[2 * page_size ..], &expect_last, .{});
    try testing.expectEqualSlices(u8, &expect_last, cd[hash_offset + 2 * hash_size ..][0..hash_size]);
}
