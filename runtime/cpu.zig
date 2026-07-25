// Bit runtime — x86-64 CPUID feature detection for the crypto hardware fast
// paths (ABI.md §21, task #1223).
//
// Bit ships one binary per target that must run correctly on ANY host CPU of
// that target's architecture — unlike `zig build` gating hardware crypto on
// `builtin.cpu.has(...)` (a COMPILE-time decision baked into the binary), this
// module probes the ACTUAL host at RUNTIME via the `cpuid` instruction (a
// baseline x86-64 opcode: always available, no target-feature gating needed to
// execute it) and caches the result once. Every AES-NI/PCLMULQDQ/SHA-NI call
// site in `runtime/cryptohw.zig` branches on that cached result, never on
// secret data — a fixed CPU capability decided once at first use, not per
// call, so there is no timing channel through which key- or plaintext-
// dependent behavior could leak (ABI.md §21).
//
// AVX-gating matters even for AES-NI/SHA-NI: `runtime/cryptohw.zig` uses the
// VEX-encoded forms (`vaesenc`, `vpclmulqdq`, ...), which fault if the OS has
// not enabled the XSAVE state (`XCR0` bits 1/2) that holds the XMM/YMM
// registers those forms read and write — the standard "CPUID says AVX, but is
// the OS ready for it" check every real-world AVX-using library performs
// before dispatching (`OSXSAVE` in `CPUID.1:ECX[27]`, then `XGETBV(0)` bits
// 1-2). Skipping it is a real crash risk on an OS that has not opted in.
const std = @import("std");
const builtin = @import("builtin");
const is_x86_64 = builtin.cpu.arch == .x86_64;

/// Bit flags of `Features`, returned by `detect`. Matches the four CPUID
/// features ABI.md §21 documents: AES-NI, PCLMULQDQ, AVX2, SHA-NI.
pub const aes: u32 = 1 << 0;
pub const pclmul: u32 = 1 << 1;
pub const avx2: u32 = 1 << 2;
pub const sha: u32 = 1 << 3;

var features: std.atomic.Value(u32) = .init(0);
var features_ready: std.atomic.Value(bool) = .init(false);

/// The cached CPU-capability bitmask (`aes | pclmul | avx2 | sha`), computed
/// once from real CPUID + XGETBV probes and masked by the `BIT_CRYPTO_NO_HW`
/// force-disable override (also read exactly once, here). Concurrent first
/// callers may all recompute before the flag is visible — harmless: probing
/// hardware and reading the environment are both idempotent, so every racing
/// writer stores the same value.
pub fn detect(environ: std.process.Environ) u32 {
    if (features_ready.load(.acquire)) return features.load(.monotonic);
    var f = rawDetect();
    if (forceDisabled(environ)) f = 0;
    features.store(f, .monotonic);
    features_ready.store(true, .release);
    return f;
}

/// `BIT_CRYPTO_NO_HW=1` (or `on`) forces every hardware fast path off, so the
/// constant-time software path can be exercised and compared against the
/// hardware result even on capable silicon (ABI.md §21, task #1223's verify:
/// "force-disable flag exercises the fallback").
fn forceDisabled(environ: std.process.Environ) bool {
    if (comptime builtin.os.tag == .windows) return false;
    const v = environ.getPosix("BIT_CRYPTO_NO_HW") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on");
}

fn rawDetect() u32 {
    if (!is_x86_64) return 0;
    const has_leaf7 = maxLeaf() >= 7;
    const l1 = cpuid(1, 0);
    const has_aes_cpu = (l1.ecx & (1 << 25)) != 0;
    const has_pclmul_cpu = (l1.ecx & (1 << 1)) != 0;
    const has_avx_cpu = (l1.ecx & (1 << 28)) != 0;
    const has_osxsave = (l1.ecx & (1 << 27)) != 0;
    const avx_usable = has_avx_cpu and has_osxsave and osSupportsAvx();

    var f: u32 = 0;
    if (has_aes_cpu and avx_usable) f |= aes;
    if (has_pclmul_cpu and avx_usable) f |= pclmul;

    if (has_leaf7) {
        const l7 = cpuid(7, 0);
        const has_avx2_cpu = (l7.ebx & (1 << 5)) != 0;
        const has_sha_cpu = (l7.ebx & (1 << 29)) != 0;
        const avx2_usable = has_avx2_cpu and avx_usable;
        if (avx2_usable) f |= avx2;
        // Zig's own std.crypto gates SHA-NI on `sha AND avx2` (sha2.zig) —
        // matched here rather than invented independently (module doc).
        if (has_sha_cpu and avx2_usable) f |= sha;
    }
    return f;
}

const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

/// `EAX=leaf, ECX=subleaf` before `cpuid`; the four output registers land
/// directly in named outputs, so no scratch register is needed. Only ever
/// reached when `is_x86_64` (`rawDetect` returns 0 first on any other arch),
/// so this inline asm is dead code — never emitted — on arm64 builds.
fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// `CPUID.0:EAX` — the highest standard leaf this CPU accepts, needed before
/// touching leaf 7 (a CPU predating it would otherwise return the leaf-0 or
/// undefined data instead of faulting).
fn maxLeaf() u32 {
    return cpuid(0, 0).eax;
}

/// `XGETBV(0)`'s `XCR0` low 32 bits, read only after `OSXSAVE` (`CPUID.1:ECX[27]`)
/// confirms the instruction is legal to issue. Bits 1 (SSE/XMM) and 2 (AVX/YMM)
/// both set means the OS has opted every thread into saving/restoring that
/// state across a context switch — the precondition every VEX-encoded
/// instruction in `runtime/cryptohw.zig` needs to not fault.
fn osSupportsAvx() bool {
    var eax: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("xgetbv"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [index] "{ecx}" (@as(u32, 0)),
    );
    std.mem.doNotOptimizeAway(&edx);
    return (eax & 0b110) == 0b110;
}
