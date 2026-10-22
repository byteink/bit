# Crypto, shared state, and concurrency

[Runtime ABI](../ABI.md)

## 21. Crypto (`runtime/rand` + `runtime/root`)

The runtime boundary primitives that cryptography needs but
that cannot be written in pure Bit — OS entropy and an optimizer-proof wipe.
The low-level layer under `std/crypto`.

```
bit_rt_random_bytes(len: i64)   -> string   // len CSPRNG bytes; "" for len <= 0; fatal on entropy failure
bit_rt_secure_zero(h)           -> void     // wipe a []byte's len packed bytes, un-elidable
```

**Entropy source is the OS CSPRNG, never a userspace PRNG and never a weak or
zero fallback.** A weak-entropy result silently returned is worse than a crash,
so an OS failure is **fatal** (routed through the §12 panic path), never a
degraded draw. Per platform (`runtime/rand`, raw syscalls for the same
reason as `runtime/net/net.bit`):

- **Linux** — `getrandom(buf, len, 0)`: the `/dev/urandom` pool, **blocking**
  until first-seeded (`flags = 0`, never `GRND_NONBLOCK`/`GRND_RANDOM`).
  `EINTR` retries; a short draw loops to fill the rest; `ENOSYS` (pre-3.17
  kernel) falls back to reading `/dev/urandom`.
- **macOS** — `arc4random_buf`: always present, a CSPRNG on Darwin, infallible.
- **Windows** — `BCryptGenRandom(NULL, buf, len, BCRYPT_USE_SYSTEM_PREFERRED_RNG)`,
  checking the `NTSTATUS`. Windows is not yet an executable runtime target (§9
  gates the runtime to POSIX x86-64/ARM64); this path is compile-checked only,
  and live Windows validation is deferred to when the scheduler/GC gain Windows
  support.

`random_bytes` returns the bytes as a fresh GC `string` (byte-exact, length
`len`), the same return path as `fs_read_all`.

`secure_zero` takes the `[]byte`'s `SliceHeader` and zeroes the `len` **packed
bytes** it views (`buf[off .. off+len]`) — `len` bytes, never `len * 8`. A
`[]byte`/`[]u8` is the packed, 1-byte-per-element case (§2): the wipe covers
exactly the buffer's logical byte range, `off` and `len` both already counted
in bytes. **Do not wipe `len * 8` bytes** — that was the correct byte count
only under the old word-per-element model this document no longer describes
for `[]u8`, and applied to a packed buffer it zeroes 7 bytes of *adjacent* heap
past the buffer's end for every logical byte the buffer holds, a silent
memory-corruption bug in code whose entire job is wiping key material safely.
The wipe is `@memset` followed by a compiler memory barrier so dead-store
elimination cannot drop it — the standard defense against a "cleared" key
lingering in memory.

---

## 21b. Hardware crypto fast paths (`runtime/cryptohw` + `runtime/cryptohw`)

x86-64 AES-NI / PCLMULQDQ / SHA-NI, runtime-CPUID-gated, reached from
`stdlib/crypto/{aes,gcm,sha256}.bit` through plain `extern fn`
declarations (SPEC.md §11.7) rather than the `RtFn` mechanism §12-§21 above
use — every parameter and result is a scalar or raw pointer (`extern
fn`'s exact admission rule), so no compiler-side wiring (`RtFn` enum,
lowering table, in either compiler) is needed. Highest-value primitives only,
per the task's own scope: **ChaCha20/Poly1305 SIMD acceleration is an
explicitly deferred follow-up**, not covered here.

```
bit_rt_crypto_aes_hw_available()      -> bool   // AES-NI usable: CPUID.1:ECX[25], BIT_CRYPTO_HW != "0"
bit_rt_crypto_ghash_hw_available()    -> bool   // PCLMULQDQ usable: PCLMUL + AVX + OS XSAVE
bit_rt_crypto_sha256_hw_available()   -> bool   // SHA-NI usable: SHA + AVX2 + OS XSAVE

bit_rt_crypto_aes_encrypt_hw(rk: *byte, nr: i64, block: *byte, out: *byte)
bit_rt_crypto_aes_decrypt_hw(drk: *byte, nr: i64, block: *byte, out: *byte)
bit_rt_crypto_aes_invert_schedule_hw(erk: *byte, nr: i64, out: *byte)
bit_rt_crypto_aes_ctr32_hw(rk: *byte, ctr: *byte, src: *byte, dst: *byte, blocks: i64)
bit_rt_crypto_ghash_mul_hw(acc0, acc1, b0, b1, h0, h1: u64, outHi: *u64) -> u64
bit_rt_crypto_sha256_compress_hw(state: *u32, block: *byte)
```

**Runtime detection, not compile-time.** Bit ships one binary per target that
must run on any host CPU of that architecture — unlike a build that assumes its own
`std.crypto`, which selects its AES-NI/PCLMULQDQ/SHA-NI paths at *compile*
time from `builtin.cpu.has(...)` (a decision baked into the binary by
`-mcpu`), `runtime/cryptohw` probes the actual host via the raw `cpuid` and
`xgetbv` instructions (both baseline x86-64 opcodes, always legal to issue —
no target-feature gating needed to execute the probe itself) and caches the
result on first use. `BIT_CRYPTO_HW=0` forces
`bit_rt_crypto_aes_hw_available` false, read once at the same first-use point,
so the constant-time software path can be exercised and cross-checked
against the hardware path even on capable silicon — the fallback
verification the task requires.

**Feature gates are decided at run time, not build time**, not an
independently invented set: AES-NI needs `AES + AVX`; PCLMULQDQ needs
`PCLMUL + AVX`; SHA-NI needs `SHA + AVX2`. All four CPUID bits also require
`OSXSAVE` (`CPUID.1:ECX[27]`) and `XGETBV(0)` reporting the OS has opted the
SSE/AVX state into its context-switch save set (`XCR0` bits 1-2) — the
standard "CPU says yes, but has the OS enabled it" check every real-world
AVX-using library performs before dispatching; skipping it is a genuine
`#UD`/state-corruption risk on an OS that has not opted in.

**Dispatch cannot leak.** Every `bit_rt_crypto_*_hw_available` call reads one
cached process-wide flag, decided once from the host CPU, never from key or
plaintext bytes — the `if (bitCryptoAesHwAvailable()) { ... } else { ... }`
gate in each `stdlib/crypto` module is a branch on a CPU-capability constant,
the same shape as any other host-detection branch in the codebase, not a
data-dependent one.

**AES-NI (#7390).** The five AES pins are real on x86-64
(`runtime/cryptohw/x64aes.bit`). On arm64 the four single-block pins panic,
where `stdlib/crypto` runs the §21d ARMv8 primitives instead, and
`bit_rt_crypto_aes_ctr32_hw` runs the ARMv8 AES instructions
(`runtime/cryptohw/armaesctr.bit`, #7397), panicking when the CPU lacks
them. They use legacy-SSE encodings only
(SSE2 plus AES-NI, no VEX), so availability is the CPUID AES bit alone, no
AVX or XGETBV check; `BIT_CRYPTO_HW=0` forces it false, so the switch
`stdlib/crypto/hw.bit` reads selects the software path on x86-64 too.
`bit_rt_crypto_aes_ctr32_hw` runs `blocks` full blocks of counter mode,
`dst` = `src` XOR AES(counter), `dst` may equal `src`. `ctr` points at a
caller-owned 24-byte block: bytes 0..15 the counter block, whose last four
bytes are a big-endian count that wraps modulo 2^32 (GCM's inc32), and bytes
16..23 the round count (10, 12 or 14) as a little-endian i64. The counter is
advanced past the last block. It
pipelines four (x86-64) or eight (arm64) counter blocks per round key and
returns to Bit every 64 KiB so a large buffer still reaches a safepoint;
GCM's GCTR runs on it on both architectures.

**AES-NI key material.** `bit_rt_crypto_aes_encrypt_hw` takes the plain
FIPS-197 forward round-key schedule (`16*(nr+1)` bytes, one 128-bit round key
per round) exactly as `aes.bit`'s existing constant-time software
`expandKey` already produces — no format translation, and no
hardware-accelerated key *expansion* (`AESKEYGENASSIST`): expansion runs once
per cipher construction, not in a hot loop, so the existing software path
already covers it at negligible cost. The one place hardware genuinely helps
key material is `bit_rt_crypto_aes_invert_schedule_hw`, which runs `AESIMC`
(InvMixColumns) over each interior round key to derive the decrypt-equivalent
schedule `bit_rt_crypto_aes_decrypt_hw` consumes — the actual expensive part
of preparing a decrypt schedule.

**GHASH.** `bit_rt_crypto_ghash_mul_hw` computes the same NIST
SP800-38D-defined GF(2^128) product `gcm.bit`'s software
`gcmMulHWords(acc, b0, b1, h0, h1)` does, from the same big-endian
wire-byte-order words, via PCLMULQDQ carryless-multiply (Karatsuba-free
schoolbook, 3 `vpclmulqdq`s) and Shay Gueron's reduction rather than the
software path's 128-iteration shift-and-xor — a different algorithm
computing the one function GCM defines, so the two agree bit-for-bit by
construction.

**SHA-256 compression.** `bit_rt_crypto_sha256_compress_hw` runs the same
FIPS-180-4 round function `sha256.bit`'s software `compress` does, shared
unchanged by SHA-224 and SHA-256 (they differ only in IV and output
truncation, both applied outside `compress`).

---

## 21c. ARM64 crypto hardware-capability detection (`runtime/cryptohw`)

```
bit_rt_crypto_hwcaps() -> u64   // bit 0 = AES, bit 1 = PMULL, bit 2 = SHA2,
                                // bit 3 = CRC32 (read by std/hash, #6678)
```

The ARM64 mirror of §21b's x86-64 probes, and unlike them, a real
implementation rather than an ABI-membership placeholder: it is the feature
*detector* that the AESE/PMULL/SHA256H primitives and stdlib routing are
built on top of.

**Per-target behavior**, split across `runtime/cryptohw/{linux,darwin}/cryptohw.bit`
because each side calls something the other cannot even compile (§19's
`syscall`/`extern function` split applies here too):

- **aarch64-linux**: bit `i` is set when `getauxval(AT_HWCAP)` (`runtime/auxv`)
  has the matching Linux `HWCAP_*` bit — `HWCAP_AES` (1<<3), `HWCAP_PMULL`
  (1<<4), `HWCAP_SHA2` (1<<6), `HWCAP_CRC32` (1<<7) — set.
- **aarch64-macos**: bit `i` is set when the matching `sysctlbyname` reads back
  1 — `hw.optional.arm.FEAT_AES`, `hw.optional.arm.FEAT_PMULL`,
  `hw.optional.arm.FEAT_SHA256`, `hw.optional.arm.FEAT_CRC32`.
- **x86_64-linux** (shares the `linux` archive member with aarch64-linux —
  `scripts/g2archive.sh`'s target->PLAT mapping) **and x86_64-windows**: bit 1
  only, from `bit_rt_crypto_x64_clmul_caps()` (`runtime/cryptohw/x64ghash.bit`,
  CPUID leaf 1 ECX: PCLMULQDQ and SSSE3), which §21e's pins run as PCLMULQDQ
  (#7385). An x86-64 `AT_HWCAP` value has no relationship to ARM crypto
  extensions, so the linux provider gates on `onX64()` (`runtime/syscalls`)
  before reading it at all; bits 0, 2 and 3 stay clear there because they
  name ARMv8 primitives with no x86-64 arm.

**Computed once, cached in a module-level variable** in whichever OS provider
is actually linked — a fresh process reads its `AT_HWCAP` word or its three
`sysctlbyname` results exactly once, and every later call returns the cached
bitmask. Racing initializers on the first call are harmless: every racing OS
thread reads the identical hardware state and would cache the identical
value, the same argument `runtime/park/darwin/wait.bit`'s cached mach
timebase makes.

---

## 21d. ARM64 AES block cipher and key schedule (`runtime/cryptohw/armaes.bit`)

```
bit_rt_aes_hw_expand_key(key, keyBits, roundKeys)          // FIPS-197 KeyExpansion
bit_rt_aes_hw_encrypt_block(roundKeys, rounds, blockIn, out)
bit_rt_aes_hw_decrypt_block(roundKeys, rounds, blockIn, out)
```

AES-128 and AES-256 only (`bit_rt_aes_hw_expand_key` panics on any other
`keyBits`); AES-192 is not implemented. Every parameter is a raw address
(`int`) — `key`/`blockIn`/`out` point at 16-byte buffers except `key` for
AES-256 (32 bytes), and `roundKeys` points at `16*(rounds+1)` bytes (176 for
AES-128, 240 for AES-256), the same flat forward-schedule layout
`stdlib/crypto/aes.bit`'s own (untouched) `expandKey` already produces.

**PLATFORM-FREE, not per-OS** — unlike §21c's `bit_rt_crypto_hwcaps`, this file
needs no OS service (no syscall, no `sysctlbyname`), only the CPU's own ARMv8
Cryptographic Extension instructions (AESE/AESMC/AESD/AESIMC), so one source
file is compiled once per TARGET (x86_64-linux, aarch64-linux, aarch64-macos)
the same way `runtime/syscalls/syscalls.bit` already is. Every exported
function starts `if (onX64())`, which must COMPILE on x86_64 since Bit has no
arch-conditional compilation (SPEC §11.8). A compiler with the `onX64()` fold
(SPEC §11.9) deletes the untaken arm from each target's object; the pinned
stage0 predates it, so an archive it builds keeps both. Reaching the arm on
x86_64 panics
rather than silently returning: nothing may legitimately call these
pins on x86_64, so a call that gets there is the bug, and a silent no-op left
the caller's buffer unmodified with no error, the worst failure mode a crypto
primitive has.

**THE EXTENSION IS OPTIONAL ON AARCH64**, unlike NEON — a Cortex-A72 (the
chip in a Raspberry Pi 3/4, and this project's own remote `mypi` fleet
includes one) has no AES instructions, and issuing one is `SIGILL`. So every
exported function also calls `aesRequireHwSupport`, which reads bit 0 (AES)
of `bit_rt_crypto_hwcaps()` and panics with a clear message rather than
letting the CPU fault — a diagnosable panic beats a raw illegal-instruction
crash, which is worse than the alternative of simply being slower.

**NO CALLER YET.** These three pins exist so a future change routing
`stdlib/crypto`'s AES through them has something to call; wiring them up
hits the same stage0-bootstrap wall documented above and needs its own
release + repin.

**Key schedule** is textbook FIPS-197 §5.2 KeyExpansion — RotWord, SubWord,
Rcon every `Nk` words, plus one extra SubWord at word 4 of the core for
256-bit keys — with SubWord computed via AESE against a zeroed round key
rather than the software constant-time S-box: XOR-with-zero is a no-op, so
AESE's SubBytes+ShiftRows over four IDENTICAL 32-bit lanes degenerates to
SubBytes alone (ShiftRows permutes four equal values), giving a
hardware-accelerated, position-preserving 4-byte S-box substitution in one
instruction.

**Block cipher** is the standard ARMv8 idiom: encrypt is `Nr-1` rounds of
AESE+AESMC over round keys `w[0..Nr-2]`, one more AESE with `w[Nr-1]` (the
last full round has no MixColumns), then a plain XOR with `w[Nr]`. Decrypt
uses FIPS §5.3.5's "equivalent inverse cipher" — the same AESD+AESIMC shape,
over an inverse schedule `dw[]` this primitive derives itself, once per call,
from the FORWARD schedule it is handed: `dw[0] = w[Nr]`, `dw[Nr] = w[0]`
unchanged, `dw[i] = AESIMC(w[Nr-i])` for the interior keys.

---

## 21e. ARM64 GHASH (`runtime/cryptohw/armghash.bit`)

```
bit_rt_ghash_hw_keys(h, keys, keysLen)     // write H's key table into `keys` (#7460)
bit_rt_ghash_hw_blocks_keyed(keys, state, data, blocks)  // fold under that table
```

Every pointer is a raw address (`int`) except `blocks`, a `u64` count.
`h`/`state` point at 16-byte buffers; `data` at `16*blocks` bytes.
`bit_rt_ghash_hw_blocks_keyed` implements the same recurrence
`stdlib/crypto/gcm.bit`'s software `gcmAbsorb` does: `state =
(state XOR block) * H`, once per block, in order. (#7481 retired the two earlier pins, which took H instead
of a key table and rebuilt H's powers on every call.)

**The key table (#7460).** `bit_rt_ghash_hw_keys` builds H's powers once into
the caller's `keysLen`-byte buffer at `keys` and panics when `keysLen` is
under 304; `bit_rt_ghash_hw_blocks_keyed` folds against that buffer. The
layout is per arch and private to the runtime (x86-64: H^1..H^8 with their Karatsuba keys, the PSHUFB mask and H's wire bytes, 288
bytes; arm64: twisted H^1..H^4, 64 bytes), written at the buffer's first
16-byte boundary, which is stable because the collector never moves an
object (§8). The caller keeps the buffer alive across both calls and never
writes it. `stdlib/crypto/gcm.bit` holds one per key in `AesGcm.hk` and folds
the AAD, the ciphertext and the length block through the keyed pin.

**PLATFORM-FREE**, same reasoning as §21d's AES pins — one source file per
TARGET. On x86-64 both pins route to `runtime/cryptohw/x64ghash.bit`, the same
recurrence on PCLMULQDQ (Karatsuba product, bit-reflected reduction modulo
x^128+x^7+x^2+x+1, #7385). Every exported function first calls
`ghashRequireHwSupport` (bit 1, carry-less multiply, of
`bit_rt_crypto_hwcaps()`) before issuing PMULL or PCLMULQDQ, for the same
"optional extension, SIGILL otherwise" reason §21d documents for AES.

On arm64 the fold is one PMULL/PMULL2 asm loop (#7403): twisted H and its
powers H^2..H^4 are computed once per key by the keys pin, four blocks
share one reduction, and one asm call folds at most 4096 blocks so the Bit
loop reaches a safepoint. `stdlib/crypto/gcm.bit` calls the keyed pins when `AesGcm.pmull` is set.

**The algorithm.** PMULL always treats a 64-bit register as LSB-first (bit 0
= coefficient of x^0); GHASH's own bit order (SP 800-38D §6.3) is MSB-first
(bit 0 = the top bit of byte 0 = coefficient of alpha^0). `LD1` followed by
`REV64` (byte-swap within each 64-bit lane) turns out to be an exact
bit-for-bit reversal relative to GHASH's convention — not a coincidence, a
direct consequence of LD1 placing each byte's own bits into the register the
normal way while REV64 reverses which byte holds which lane. One more lane
swap (`EXT #8`) reorders the two reversed halves into the FULL 128-bit
reciprocal polynomial of the input block, which is exactly what makes an
ordinary (non-reflected) PMULL/PMULL2 schoolbook multiply of two such loads
compute the reciprocal of the true GF(2^128) product — a real field-theory
identity (reciprocal-polynomial multiplication commutes with reflection),
verified independently against a from-scratch, non-reflected schoolbook
GF(2^128) reference over thousands of random 128-bit pairs plus every
relevant edge case, not assumed from a remembered formula.

The four cross terms (PS, QT, PT, QS) come from PMULL/PMULL2 against both the
loaded X and a lane-swapped copy of it. Combining them into one 256-bit raw
product needs a 1-bit left shift (with carry across all four 64-bit words)
plus a whole-word reversal to land in the software's own MSB-first-per-word
layout — the raw product is a 255-bit, not 256-bit, reflection, which is
where the 1-bit shift comes from. Reduction then folds the high half
(degrees 128-254) into the low half via the same relation the software path
applies one bit at a time (`R = alpha^128 = alpha^7+alpha^2+alpha+1`, the
0xe1 top byte every GHASH implementation in this tree shares), but applied to
the whole high half at once via four shifted copies (128, 127, 126, 121
bits). One round always leaves a small residue (degree up to 133); a second,
identical round always finishes it — proved empirically (thousands of random
trials, always exactly 0, 1 or 2 rounds, never 3), not derived from a
citation.

---

## 21f. ARM64 SHA-256 compression (`runtime/cryptohw/armsha256.bit`)

```
bit_rt_sha256_hw_blocks(state, data, blocks)   // fold `blocks` 64-byte blocks into state
```

`state`/`data` are raw addresses (`int`); `blocks` a `u64` count. `state`
points at a PACKED 32-byte buffer — 8 running `u32` words (a..h), native
(little-endian on ARM64) byte order per word — updated in place. That is
the layout a Bit `[]u32` slice's own `ptrOf` addresses (SPEC §11.8: a
`[]u32` packs at 4 bytes per element, #7574), so
`stdlib/crypto/sha256.bit`'s `absorb` passes `ptrOf(state)` of its
`state: []u32` directly, with no marshalling around the
call. `data` points at `64*blocks` PACKED bytes of message, read
big-endian per FIPS 180-4's own convention.
`bit_rt_sha256_hw_blocks` implements the same recurrence
`stdlib/crypto/sha256.bit`'s software `compress` does, once per 64-byte block,
in order.

**PLATFORM-FREE**, same reasoning as §21d/§21e — one source file per TARGET,
the exported function starts `if (onX64())` and panics if reached there
rather than silently returning (same reasoning as §21d), and it also
calls `sha256RequireHwSupport` (bit 2, SHA2, of `bit_rt_crypto_hwcaps()`) before
issuing SHA256H/SHA256H2/SHA256SU0/SHA256SU1, for the same "optional
extension, SIGILL otherwise" reason §21d documents for AES — the SHA-2
extension is a separate ARMv8 Cryptographic Extension feature bit from both
AES and PMULL, and is likewise optional in the base architecture.

**NO CALLER YET**, same as §21d/§21e — this pin exists for later work to
wire `stdlib/crypto/sha256.bit`'s `compress` through.

**The algorithm** is the standard ARMv8 crypto-extension SHA-256 sequence:
per 64-byte block, `REV32` the four loaded message words into big-endian
32-bit words, then 16 "quad rounds" — `SHA256SU0`+`SHA256H`+`SHA256H2`+
`SHA256SU1` for the first 12 quads (rounds 0-47, extending the message
schedule from `W[16]` through `W[63]`), then `SHA256H`+`SHA256H2` alone for
the last 3 quads (rounds 48-63, no further schedule words needed past
`W[63]`) — finishing with the pre-block state fed back in
(`state += saved_state`, FIPS 180-4 §6.2.2 step 4). `SHA256H` updates the
`{a,b,c,d}` half of the working state from the OLD `{e,f,g,h}` half;
`SHA256H2` updates `{e,f,g,h}` from the `{a,b,c,d}` half AS IT WAS BEFORE
`SHA256H` ran, which is why each quad round saves a copy of the pre-round
`{a,b,c,d}` register before calling `SHA256H` and hands that saved copy to
`SHA256H2`. This was validated two independent ways before any hex word was
hand-encoded: (1) the same instruction sequence expressed as ARM Neon C
intrinsics (`vsha256hq_u32` etc.), compiled by this Mac's own clang and
executed on this Mac's real SHA2-capable hardware, checked against
`hashlib.sha256` (FIPS 180-4 test vectors plus block-boundary edge cases);
(2) the hand-assembled `.s` translation of that identical sequence — the one
transcribed into `armsha256.bit` — independently linked and run against the
same vector set with the same result.

---

## 22. Shared mutable state audit

Every container-scope mutable in `runtime/**/*.bit` (grep: `^let ` at module
scope — this port has no module-scope `var` anywhere in `runtime/`, and
`^threadlocal var` matches nothing at all: Mach-O rejects `@threadlocal` in
the freestanding emit, so no runtime module uses it), classified per-worker /
per-task / synchronized, with why, as the complete enumeration the M:N
scheduler work needs — §5 and §13 above already argue the two hardest cases
(mutator registration, the error slot) in depth; this section is the
complete list so nothing was skipped.

**Write-once-before-any-worker-exists, read-only after (safe by boot order):**
`rtStartMain` runs on the process's one and only thread before `boot` spawns
the scheduler's worker pool (§9) — nothing below is ever written again once a
second OS thread can observe it:
- `runtime/root/os.bit`: `gArgc`, `gArgvPtr`, `gEnvpPtr` (`os.bit:77-79`) and
  `gAuxv` (`os.bit:85`) — the four process-entry cells §19 documents.
  Platform-free, not per-OS. `root.bit` declares none of them, and there is no
  separate `environ` cell: `gEnvpPtr` is the whole captured `envp` block.
  `runtime/shims/shims.bit` holds none of this either — its own header says
  the `setTable`/`getauxval`-table design was specified and then not needed,
  because `auxv()` (§19) can just read `gAuxv` back on demand: "No
  module-level state, so nothing to initialize and no ordering hazard between
  a setter and its first reader" (`shims.bit:63-64`).
- `runtime/root/root.bit`: `booted` (`root.bit:300`) — a single-boot guard
  (asserted false on entry before it is set); the test-only reset to `false`
  between test bodies runs single-threaded, never racing a live scheduler.

**Self-synchronized (a sibling spinlock cell, not an embedded class field —
this port has no `Heap`/`Gc`/`World`/`Scheduler` class type anywhere):**
- `runtime/root/root.bit`: `heapBlock` (`root.bit:258`) plus its two spinlock
  cells `heapLockCell`/`listLockCell` (`root.bit:260-261`). `runtime/alloc/
  alloc.bit`'s free-list functions take the block by pointer
  (`root.bit:397`'s `ptrOf(heapBlock)`) — alloc.bit itself declares no module
  state (confirmed: it has no line matching `^let `). Has its own N-thread
  stress test.
- `runtime/root/root.bit`: `gcState` (`root.bit:257`) — the collector's
  `gcWords` block, likewise taken by pointer (`root.bit:383`) and handed to
  `runtime/gc/gc.bit`'s entry points. `gc.bit`'s own header says why it stays
  here rather than moving with the rest of gc: "the process-wide instance
  belongs to `runtime/root/`" (`gc.bit:12-17`); `gc.bit` declares no module
  state of its own.
- `runtime/gc/gcworldsync.bit`: `worldBlock` (`gcworldsync.bit:187`) — the §5
  stop-the-world Mutator registry. NOT `root.bit`: this moved once
  `ptrOf` on module data was fixed, retiring the caller-owned bind
  this file used to need. §5 above already documents the current shape ("THE
  REGISTRY BLOCK IS `runtime/gc`'s OWN MODULE STATE... `gcworldsync.bit`
  declares `worldBlock`").
- `runtime/root/{linux,darwin}/boot.bit`: `schedBlock`/`gSched`
  (`linux/boot.bit:189,254`; `darwin/boot.bit:143,187`) — per-OS, the same
  split §19's `host_target` has, and NOT `runtime/sched/sched.bit` either:
  `sched.bit` declares no scheduler-block singleton at all (no exported
  `schedWords`-style layout constant, no module state). `boot` owns the
  16-word block and the process-global address `bit_rt_spawn` reads back
  through `gSched`.

**Per-task scratch (NOT module state and NOT `threadlocal`, the
M:N-migration-safe replacement): nothing between the write and its matching
read can cross a scheduling point here either, but the value lives at the
base of the running task's own stack, so it survives the task migrating to a
different OS thread — a per-OS-thread slot could not:**
- `pending_err` (§13) — `runtime/root/slots.bit`'s `bit_rt_set_err`/
  `bit_rt_get_err` (`slots.bit:49`/`:57`) read/write `scrErr`, word 7 of the
  per-task block (`runtime/sched/scratch.bit:57`). Never a threadlocal in
  this file: Mach-O's freestanding emit refuses `@threadlocal` outright
  (`slots.bit:11-12`). The regression test this bullet used to cite by name
  no longer exists in the tree under that name; nothing currently guards this
  property with a dedicated stress test the way `worldBlock` above does.
- `last_recv_ok` — `bit_rt_chan_recv_ok` (`slots.bit:78`) reads `scrRecvOk`,
  word 264 of the same per-task block (`scratch.bit:77`), published by
  `bit_rt_chan_recv` on every receive path. Same file and mechanism as
  `pending_err` above; not the same mechanism as `udp_last_sender` below,
  despite the two being listed together before this audit.
- `last_fs_read_all_failed` (§14) — `bit_rt_fs_read_all_failed`
  (`slots.bit`'s `rtFsReadAllFailed`) reads `scrFsReadFailed`, word 265 of the
  same per-task block (`scratch.bit`'s `scrFsReadFailed`). Same file and
  mechanism as `pending_err`/`last_recv_ok` above. The two-pass landing pattern's pass 1
  re-added the word and the accessor pair with no caller; its pass 2 wired
  `runtime/root/{darwin,linux}/fs.bit`'s `rtFsReadAll` to publish it on its
  `end < 0` and `s == 0` paths (cleared at entry, so a prior call's outcome on
  this task never leaks into the next) and `stdlib/fs/fs.bit`'s
  `File.readAll` to read it.
- `iface_as_ok` (§2.2) — `runtime/root/iface.bit`'s `rtIfaceAs`/
  `rtIfaceAsOk` (`bit_rt_iface_as`/`bit_rt_iface_as_ok`) read/write
  `scrIfaceOk`, word 266 of the same per-task block
  (`runtime/sched/scratch.bit:98`). Same file and mechanism as the three
  entries above. **This used to be a single process-wide word**
  (`runtime/root/root.bit`'s `let ifaceOk: i64 = 0`, now removed), sound only
  against a second assertion on the *same* task — adjacency does nothing to
  stop a different, concurrently running OS thread from writing the same
  global word once `BIT_WORKERS>1`, the identical false conclusion the UDP
  sender-buffer and sockaddr scratch-buffer fixes disproved for their own
  buffers. Reproduced and fixed by moving the
  flag to per-task scratch, the same migration-safety reason `scrRecvOk` and
  the error slot are shaped this way.

**Per-OS-thread by design, each because nothing between the write and its
matching read can cross a scheduling point — a green task migrates workers
only at an explicit yield/park, never mid-expression — AND each slot really is
per-worker storage, not a single shared word (§5.1):**
- `runtime/net/{linux,darwin}/netabi.bit`: `udpSenderBuf`/`udpSenderValid` WERE
  here, one slot per worker indexed by `wkId`. Deleted by #7746: the sender now
  travels in a buffer the caller passes to `bit_rt_net_udp_recv_from_w`, so no
  runtime cell is read back by a later call. (A per-worker slot read back by
  adjacency is sound only while nothing between the write and the read yields;
  a loop back-edge poll can, and the task then read a stranger's sender.)
- `runtime/sched/sched.bit`: `Worker.tls` — re-derived on every read from the
  running task's own stack pointer (`sched.bit:15`'s `schedCurrentTask`),
  never cached across a call boundary, specifically because a parked task can
  resume on a *different* OS thread: a cached thread pointer would
  hand back the previous thread's stale `Worker`. No global backs this at
  all, in this file or any other — there is nothing to race because there is
  nothing stored.

**NOT yet converted: NOT FOUND.** This category held exactly one entry,
`iface_as_ok`'s `ifaceOk` flag, which was converted to per-task scratch —
see the "Per-task scratch" list above. Nothing in `runtime/**/*.bit` is
currently a single process-wide word carrying a live cross-task race under
`BIT_WORKERS>1`.

**Global, mutated, but inert or already atomic: NOT FOUND.** Neither
`scan_ctx` nor `select_seed_counter`, as this section previously described
them, exists in `runtime/**/*.bit` today:
- No callback-based root scan survives to need an opaque `ctx` sentinel:
  `gcMarkBegin`/`gcCollectFinish` (§6) take no callback and no `ctx`
  argument, and `runtime/chan/chanreg.bit`'s own header explains why —
  `@nosplit` rejects a call through a function value (E0075), so root
  scanning was inverted into a cursor the collector drives instead
  (`chanreg.bit:22-24`). A repo-wide search for `scan_ctx`/`ScanCtx` turns up
  only the unrelated `stwScanCtx` (`runtime/stw/stwscan.bit:84`, a saved
  register-context walk, not a sentinel).
- `select_seed_counter` was designed but never built: `runtime/chan/
  chanselect.bit`'s own header says the atomic module-state counter "would
  need an atomic on module state, which needs `ptrOf`" and that design is
  "replaced by state that is per-task" (`chanselect.bit:19-24`) —
  `scrCounter` (`runtime/sched/scratch.bit:47`), mixed with the task's own
  address via splitmix64 (`chanselect.bit:36-40`). Per-task, so nothing to
  synchronize; not `runtime/chan`'s module state either, since chan declares
  none.

**Read-only after link (never a `var` at all):** `TypeInfo` method tables and
per-type pointer-offset arrays (§2) and every `RtFn`/`bit_rt_*` dispatch target
are compiler-emitted `const` data baked into the object at build time; nothing
in the runtime ever mutates a `TypeInfo` or a dispatch table post-link, so they
need no synchronization under any worker count.

**Racy-but-idempotent memoization caches (no lock, correct anyway because every
racing writer computes the identical value):**
- `runtime/cryptohw/{linux,darwin}/cryptohw.bit`: `hwcapsCache` — the
  `bit_rt_crypto_hwcaps` AES/PMULL/SHA2 bitmask, sentinel `-1` for "not yet
  computed." Every racing OS thread reads the identical `AT_HWCAP` word (linux)
  or the identical three `sysctlbyname` results (darwin) and therefore computes
  and stores the identical bitmask, the same argument the next bullet's
  `runtime/park/darwin/wait.bit` cache already relies on for its own (currently
  undocumented here — see that file's own header) `tbNumer`/`tbDenom` mach
  timebase cache.

**Not found:** no OTHER interned-data table or memoization cache exists in
`runtime/**/*.bit` outside the entries above (`runtime/rand/rand.bit` and
`runtime/net/net.bit` declare no container-scope state at all — every random/network call
is a stateless syscall wrapper).

## 23. Concurrency memory model — runtime guarantees (SPEC.md §13.7)

§22 audits the runtime's *own* internal state; this section is the other
half — what the runtime does at each rendezvous point to make SPEC.md §13.7's
happens-before edges actually hold for **Bit-level** (user heap) memory, once
`boot` runs more than one worker (§9). Each edge is backed by a real
release/acquire pairing, never a plain (relaxed) load/store, because a plain
access on most targets permits the reordering the edge exists to forbid:

1. **`spawn` → first statement (§13.7 edge 1).** The packed-argument class
   (§9 Spawn) is fully written by the spawning thread before `bit_rt_spawn`
   hands the task off. `runtime/sched/sched.bit`'s per-worker `Deque` writes the task into
   its ring slot, then publishes it with a `.release`-ordered `tail` store
   (`pushBottom`); a stealing or popping worker loads `head`/`tail` with
   `.acquire` before reading that slot (`popBottom`/`steal`). The global
   queue used on deque overflow is instead one `SpinLock`-guarded intrusive
   list (same acquire/release CAS-then-store pairing as channels, item 2
   below). Either path — not scheduling order, which is unspecified — is the
   edge.
2. **Channel send → matching receive (edges 2, 4, 5).** Each `Chan(T)` is
   guarded end-to-end by one `runtime/spinlock.bit` `SpinLock` (`runtime/chan/chan.bit`): `acquire`
   is a `.acquire`-ordered CAS, `release` is a `.release` store (`runtime/spinlock.bit`).
   A send writes the value (into the ring buffer, or straight to a parked
   receiver for the unbuffered case) *before* releasing the lock; a receive
   takes the lock (its `.acquire` CAS) before reading that value. The lock's
   acquire/release pairing — not any weaker ordering — is the edge; nothing
   in `runtime/chan/chan.bit`'s rendezvous is lock-free.
3. **`close` → observing closed (edge 3).** `close` sets the closed flag
   under the same `SpinLock`; a receive observes it (and returns
   `ok == false` once drained, ABI.md §11) only after taking that same lock.
   Program order under one lock is what carries the edge — no separate
   flag-specific ordering is needed.
4. **`std/sync` `Mutex`/`RWMutex` (edge 6).** Expected to reuse
   `runtime/spinlock.bit`'s `SpinLock` (or the scheduler's park/unpark on top of it,
   for a mutex that parks instead of spins under contention) — the same
   acquire/release CAS-then-store pairing already proven by `runtime/chan/chan.bit` and
   `runtime/sched/sched.bit`'s deques above. `Once`/`WaitGroup` (edges 7, 8) are expected to
   compose from the same Mutex/atomic primitives and inherit the same
   pairing. This is `std/sync`'s implementation contract, not yet
   built on this branch.
5. **`std/sync` atomics — `Release`/`Acquire`/`Relaxed` (edge 9, SPEC.md
   §13.7.1).** These must lower to the target's native ordered forms, not to
   the seq-cst-only sequences §11.5's raw `*T` builtins already emit:
   AArch64 `STLR`/`LDAR` (or the `STLXR`/`LDAXR` release/acquire retry forms
   for the read-modify-write ops), x86-64 a plain `mov` for both directions
   (TSO already gives release/acquire for free — the compiler's job is only to
   not reorder *other* instructions across it) with `lock`-prefixed
   read-modify-write ops as today. `Relaxed` skips the ordering but keeps the
   underlying instruction atomic — it is never a plain non-atomic load/store,
   which would reintroduce word-tearing SPEC.md §13.7 defines away for
   single-word values. This is new codegen surface (tracked with `std/sync`'s
   implementation) — the seq-cst-only raw builtins (§11.5) cannot be
   reused as-is for `Relaxed`/`Release`/`Acquire` because they hard-code the
   strongest ordering at every callsite.

**Why the GC-safety exception in SPEC.md §13.7 is precise, not hand-waved.**
§5's root scan trusts a stack slot's or register's declared shape at a
safepoint — it does not re-validate that a slice's `ptr` and `len` (or a
reference-holding class's own fields) were written together. A racing,
non-atomic write to a GC-traced multiword field can leave exactly such a
torn value sitting in a live slot; if a safepoint (§5) lands while it is
there, the collector scans it as if it were well-formed. An interface value
is not an example of this today — it is one word, the receiver's object
pointer (§2.1, SPEC §14.3), so it carries no `type`/`data` pair to tear.
This is the concrete mechanism behind SPEC.md §13.7's claim that a
composite-value race — never a single-word one — is the one way
otherwise-safe Bit code can reach real memory-unsafety, and it is exactly
why the audit in §22 above only needed to reason about *runtime*-internal
state: user Bit code gets no such audit for free, which is the whole reason
§13.7 and this section exist.

## 24. CPU sampling profiler (`runtime/root/darwin/prof.bit`)

```
bit_rt_prof_start(intervalMicros: int) -> int   // 0 ok, -1 on a libSystem failure
bit_rt_prof_stop()                     -> int   // samples stored (<= 8192)
bit_rt_prof_sample(i: int)             -> int   // ring slot i, or -1 out of range
```

**aarch64-macos only.** Darwin `SIGPROF` (27) via `setitimer(ITIMER_PROF, ...)`
(`<sys/time.h>`), a leaf-PC sampler in the same `@nosplit` handler style as
§12's `segvHandler`/`trapHandler` (../root/darwin/signal.bit) — same ucontext
offsets, reused rather than re-derived. Every tick records ONLY the
interrupted instruction's address (no frame-pointer walk from signal
context), into a fixed 8192-entry ring allocated once as module state (Power
of 10 rule 3): a busier run than that reports its true tick count from
`bit_rt_prof_stop` and simply drops samples past the cap, rather than
growing.

**Single-OS-thread scope, stated rather than hidden.** BSD/XNU deliver a
process-directed itimer's signal to an arbitrary unblocked thread; this file
attempts no per-worker distribution (no `timer_create`-equivalent), so
coverage is validated only at `BIT_WORKERS=1`. A multi-worker build may see
samples cluster on whichever OS thread the kernel happens to pick.

**ASLR.** This binary is PIE (§4's stack-map section already notes dyld
rebases `.bit_gc`'s absolute code pointers for the same reason). A signal
context's `pc` is a runtime (slid) address; `bit_rt_prof_start` captures
`_dyld_get_image_vmaddr_slide(0)` once and every stored sample has it
subtracted, so recorded addresses are file-relative — directly comparable to
the binary's own Mach-O local symbol table (`compiler/machoreloc.bit`: "one
LOCAL entry per surviving `__text` function") with no further correction at
render time. `std/prof` (userland API) and `compiler/profrender.bit`
(symbolizing reader, behind `bit prof`) are the two halves built on top of
these three symbols; see their own file headers.

[Previous: Collections, time, and operating-system services](collections-time-and-io.md)
