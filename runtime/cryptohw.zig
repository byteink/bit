// Bit runtime — x86-64 AES-NI / PCLMULQDQ / SHA-NI hardware crypto compute
// kernels (task #1223, ABI.md §21b).
//
// Every function here is a pure, allocation-free, safepoint-free leaf that
// executes its hardware instructions UNCONDITIONALLY the moment it is called
// — none of them re-checks CPUID. The caller (`runtime/root.zig`'s
// `bit_rt_crypto_*_hw` exports, reached from Bit only after `stdlib/crypto`
// has itself checked `bitCryptoAesHwAvailable`/`bitCryptoGhashHwAvailable`/
// `bitCryptoSha256HwAvailable`, backed by `cpu.zig`'s cached CPUID+XGETBV
// probe) is what proves the feature is present. Calling one of these on a CPU
// that lacks the instruction is undefined behavior (`SIGILL`), by design —
// the same contract `runtime/cpu.zig`'s module doc describes.
//
// Ported from Zig 0.16's own std.crypto (std/crypto/aes/aesni.zig,
// std/crypto/ghash_polyval.zig, std/crypto/sha2.zig), matching their exact
// instruction sequences and feature gating (AES-NI needs AES+AVX; PCLMULQDQ
// needs PCLMUL+AVX; SHA-NI needs SHA+AVX2 — Zig's own precedent, not this
// module's independent judgment) rather than inventing new encodings. Unlike
// std.crypto, which selects these at COMPILE time from `builtin.cpu.has`,
// every call here is reached only through a RUNTIME CPUID check (`cpu.zig`),
// because Bit ships one binary per target that must run on any host CPU of
// that architecture.

const std = @import("std");

const V2u64 = @Vector(2, u64);

fn loadBlock(p: [*]const u8) V2u64 {
    return std.mem.bytesToValue(V2u64, p[0..16]);
}

fn storeBlock(p: [*]u8, v: V2u64) void {
    p[0..16].* = std.mem.toBytes(v);
}

// ---- AES-NI: block encrypt / decrypt / decrypt-schedule invert -----------
// Round keys are the plain FIPS-197 forward schedule `stdlib/crypto/aes.bit`'s
// existing constant-time software `expandKey` already produces (`16*(nr+1)`
// bytes, one 128-bit round key per round) — no key-format translation.

fn vaesenc(state: V2u64, rk: V2u64) V2u64 {
    return asm ("vaesenc %[rk], %[in], %[out]"
        : [out] "=x" (-> V2u64),
        : [in] "x" (state),
          [rk] "x" (rk),
    );
}

fn vaesenclast(state: V2u64, rk: V2u64) V2u64 {
    return asm ("vaesenclast %[rk], %[in], %[out]"
        : [out] "=x" (-> V2u64),
        : [in] "x" (state),
          [rk] "x" (rk),
    );
}

fn vaesdec(state: V2u64, rk: V2u64) V2u64 {
    return asm ("vaesdec %[rk], %[in], %[out]"
        : [out] "=x" (-> V2u64),
        : [in] "x" (state),
          [rk] "x" (rk),
    );
}

fn vaesdeclast(state: V2u64, rk: V2u64) V2u64 {
    return asm ("vaesdeclast %[rk], %[in], %[out]"
        : [out] "=x" (-> V2u64),
        : [in] "x" (state),
          [rk] "x" (rk),
    );
}

fn vaesimc(rk: V2u64) V2u64 {
    return asm ("vaesimc %[in], %[out]"
        : [out] "=x" (-> V2u64),
        : [in] "x" (rk),
    );
}

/// Encrypt one 16-byte `block` under the `nr+1`-round forward schedule
/// `round_keys` (`16*(nr+1)` bytes), writing the ciphertext to `out`. `out`
/// and `block` may alias (both are read/written only through XMM registers).
pub fn encryptBlock(round_keys: [*]const u8, nr: i64, block: [*]const u8, out: [*]u8) void {
    const n: usize = @intCast(nr);
    var state = loadBlock(block) ^ loadBlock(round_keys);
    var r: usize = 1;
    while (r < n) : (r += 1) {
        state = vaesenc(state, loadBlock(round_keys + 16 * r));
    }
    state = vaesenclast(state, loadBlock(round_keys + 16 * n));
    storeBlock(out, state);
}

/// Decrypt one 16-byte `block` under the `nr+1`-round DECRYPT-equivalent
/// schedule `dec_round_keys` (see `invertSchedule` below for how the caller
/// derives it from the forward schedule), writing the plaintext to `out`.
pub fn decryptBlock(dec_round_keys: [*]const u8, nr: i64, block: [*]const u8, out: [*]u8) void {
    const n: usize = @intCast(nr);
    var state = loadBlock(block) ^ loadBlock(dec_round_keys + 16 * n);
    var r: usize = n - 1;
    while (r > 0) : (r -= 1) {
        state = vaesdec(state, loadBlock(dec_round_keys + 16 * r));
    }
    state = vaesdeclast(state, loadBlock(dec_round_keys));
    storeBlock(out, state);
}

/// Derive the AES-NI decrypt-equivalent round-key schedule from the forward
/// (encrypt) schedule `enc_round_keys`: round 0 and round `nr` copy straight
/// across unchanged (`AESDEC`/`AESDECLAST` consume the same first/last keys
/// as `AESENC`/`AESENCLAST`), and every interior round key is transformed by
/// `AESIMC` (InvMixColumns) — the one place hardware genuinely helps key
/// material, since it is the expensive part of deriving a decrypt schedule.
/// Key EXPANSION itself deliberately stays the existing constant-time
/// software `expandKey` (already correct, and a one-time per-cipher cost —
/// not a hot loop, so `AESKEYGENASSIST` buys nothing real here).
pub fn invertSchedule(enc_round_keys: [*]const u8, nr: i64, out: [*]u8) void {
    const n: usize = @intCast(nr);
    storeBlock(out, loadBlock(enc_round_keys));
    var r: usize = 1;
    while (r < n) : (r += 1) {
        storeBlock(out + 16 * r, vaesimc(loadBlock(enc_round_keys + 16 * r)));
    }
    storeBlock(out + 16 * n, loadBlock(enc_round_keys + 16 * n));
}

// ---- PCLMULQDQ: GHASH multiply --------------------------------------------
// Ported from std/crypto/ghash_polyval.zig's `clmulPclmul`/`clmul128`/
// `reduce`/`shift_key`. `stdlib/crypto/gcm.bit`'s software `gcmMulHWords`
// computes the same NIST SP800-38D-defined GF(2^128) product from the same
// big-endian wire-byte-order operands, so — despite the different internal
// representation (Gueron's carryless-multiply-then-reduce trick vs a per-bit
// shift-and-xor) — the two MUST agree bit-for-bit on the same inputs; that
// invariant is what `tests/imports` exercises directly (see cryptogcm/cryptoaes
// stderr diagnostics + hl-master real-hardware verification).

const Selector = enum { hi, lo, hi_lo };

fn clmul(x: u128, y: u128, comptime sel: Selector) u128 {
    const imm: u8 = switch (sel) {
        .lo => 0x00,
        .hi => 0x11,
        .hi_lo => 0x10,
    };
    const xv: V2u64 = @bitCast(x);
    const yv: V2u64 = @bitCast(y);
    const out = switch (imm) {
        0x00 => asm ("vpclmulqdq $0x00, %[x], %[y], %[out]"
            : [out] "=x" (-> V2u64),
            : [x] "x" (xv),
              [y] "x" (yv),
        ),
        0x11 => asm ("vpclmulqdq $0x11, %[x], %[y], %[out]"
            : [out] "=x" (-> V2u64),
            : [x] "x" (xv),
              [y] "x" (yv),
        ),
        else => asm ("vpclmulqdq $0x10, %[x], %[y], %[out]"
            : [out] "=x" (-> V2u64),
            : [x] "x" (xv),
              [y] "x" (yv),
        ),
    };
    return @bitCast(out);
}

const I256 = struct { hi: u128, lo: u128, mid: u128 };

/// Schoolbook 128x128 -> 256-bit carryless multiply (3 `vpclmulqdq`s): the
/// modern-CPU-favored shape per `ghash_polyval.zig`'s own module comment —
/// Karatsuba's extra shifts/adds only won on pre-Haswell silicon.
fn clmul128(x: u128, y: u128) I256 {
    return .{
        .hi = clmul(x, y, .hi),
        .lo = clmul(x, y, .lo),
        .mid = clmul(x, y, .hi_lo) ^ clmul(y, x, .hi_lo),
    };
}

/// Reduce a 256-bit carryless product modulo GCM's field polynomial
/// x^128+x^127+x^126+x^121+1, Shay Gueron's construction (see
/// `ghash_polyval.zig`'s `reduce` for the derivation).
fn reduce(x: I256) u128 {
    const hi = x.hi ^ (x.mid >> 64);
    const lo = x.lo ^ (x.mid << 64);
    const p64: u128 = ((1 << 121) | (1 << 126) | (1 << 127)) >> 64;
    const a = clmul(lo, p64, .lo);
    const b = ((lo << 64) | (lo >> 64)) ^ a;
    const c = clmul(b, p64, .lo);
    const d = ((b << 64) | (b >> 64)) ^ c;
    return d ^ hi;
}

/// Shift a raw (unshifted, big-endian-loaded) H one bit left in GF(2^128),
/// reducing when the top bit fell off — required for the direct
/// carryless-multiply-then-`reduce` technique to land on the same
/// (unshifted, big-endian) GHASH result `gcmMulHWords`'s per-bit
/// shift-and-xor already computes. Recomputed on every call rather than
/// cached: `gcmMulHWords`'s own signature takes the raw `h0`/`h1` per call,
/// and this keeps the hardware primitive a stateless drop-in for it.
fn shiftKey(h: u128) u128 {
    const carry: u128 = 0 -% (h >> 127);
    return (h << 1) ^ (((@as(u128, 0xc2) << 120) | 1) & carry);
}

/// One GHASH block step: `acc = (acc XOR block) * H` in GF(2^128), matching
/// `stdlib/crypto/gcm.bit`'s `gcmMulHWords(acc, b0, b1, h0, h1)` exactly —
/// same big-endian word pairs in, same big-endian word pair out.
pub fn ghashMul(acc0: u64, acc1: u64, b0: u64, b1: u64, h0: u64, h1: u64, out_hi: *u64) u64 {
    const x = (@as(u128, acc0 ^ b0) << 64) | @as(u128, acc1 ^ b1);
    const h = shiftKey((@as(u128, h0) << 64) | @as(u128, h1));
    const r = reduce(clmul128(x, h));
    out_hi.* = @truncate(r >> 64);
    return @truncate(r);
}

// ---- SHA-NI: SHA-256 compression ------------------------------------------
// Ported from std/crypto/sha2.zig's x86_64 branch of `Sha256.round` (its own
// `V4u32`/`sha256msg1`/`vpalignr`/`paddd`/`sha256msg2`/`sha256rnds2`
// sequence). `stdlib/crypto/sha256.bit`'s `compress(state, block, k)` shares
// the SAME FIPS-180-4 round function for both SHA-224 and SHA-256 (they
// differ only in IV and output truncation, both applied outside `compress`),
// so this one kernel serves both.

const V4u32 = @Vector(4, u32);

// FIPS 180-4 §4.2.2 round constants, identical values/order to
// `stdlib/crypto/sha256.bit`'s `roundConstants()`.
const K: [64]u32 = .{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

/// Run all 64 SHA-256 compression rounds over one 64-byte `block`, updating
/// the 8-word `state` in place — `stdlib/crypto/sha256.bit`'s `compress`
/// signature exactly (minus `k`, which this kernel carries its own flat copy
/// of above, identical values/order to `roundConstants()`).
///
/// A near-verbatim port of `sha2.zig`'s x86_64 branch of `Sha256.round`
/// (single combined 4-instruction asm block per message-schedule step, same
/// operand wiring) — reproduced instruction-for-instruction rather than
/// split into named single-instruction helpers, since re-deriving each
/// AVX/SHA-NI operand's source/dest mapping from the mnemonic by hand is
/// exactly the kind of subtle-transcription-error risk a byte-for-byte port
/// of a tested implementation avoids.
pub fn compress(state: [*]u32, block: [*]const u8) void {
    var s: [64]u32 align(16) = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const b = i * 4;
        s[i] = (@as(u32, block[b]) << 24) | (@as(u32, block[b + 1]) << 16) |
            (@as(u32, block[b + 2]) << 8) | @as(u32, block[b + 3]);
    }

    var x: V4u32 = .{ state[5], state[4], state[1], state[0] };
    var y: V4u32 = .{ state[7], state[6], state[3], state[2] };
    const s_v: *[16]V4u32 = @ptrCast(&s);

    var k: usize = 0;
    while (k < 16) : (k += 1) {
        if (k < 12) {
            var tmp = s_v[k];
            s_v[k + 4] = asm (
                \\ sha256msg1 %[w4_7], %[tmp]
                \\ vpalignr $0x4, %[w8_11], %[w12_15], %[result]
                \\ paddd %[tmp], %[result]
                \\ sha256msg2 %[w12_15], %[result]
                : [tmp] "=&x" (tmp),
                  [result] "=&x" (-> V4u32),
                : [_] "0" (tmp),
                  [w4_7] "x" (s_v[k + 1]),
                  [w8_11] "x" (s_v[k + 2]),
                  [w12_15] "x" (s_v[k + 3]),
            );
        }

        const w: V4u32 = s_v[k] +% @as(V4u32, K[4 * k ..][0..4].*);
        y = asm ("sha256rnds2 %[x], %[y]"
            : [y] "=x" (-> V4u32),
            : [_] "0" (y),
              [x] "x" (x),
              [_] "{xmm0}" (w),
        );

        x = asm ("sha256rnds2 %[y], %[x]"
            : [x] "=x" (-> V4u32),
            : [_] "0" (x),
              [y] "x" (y),
              [_] "{xmm0}" (@as(V4u32, @bitCast(@as(u128, @bitCast(w)) >> 64))),
        );
    }

    state[0] +%= x[3];
    state[1] +%= x[2];
    state[4] +%= x[1];
    state[5] +%= x[0];
    state[2] +%= y[3];
    state[3] +%= y[2];
    state[6] +%= y[1];
    state[7] +%= y[0];
}
