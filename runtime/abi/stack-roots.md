# Root scanning and stack maps

[Runtime ABI](../ABI.md)

## 4. Root scanning and stack maps

The collector is **precise**: at a safepoint it must learn exactly which
registers and stack slots hold live references, from compiler-emitted per-callsite
stack maps.

Runtime interface (`runtime/gc/gc.bit`):

```
RootScanner {
    ctx  : *anyopaque
    scan : fn(ctx, *Gc) void   // calls gc.markRoot(ref) for every live root
}
```

- Codegen's obligation: emit, per safepoint call-site, a stack map describing the
  live reference slots (frame offsets and live registers). The stack-map walker
  implements `RootScanner.scan` by decoding those maps up the call stack and
  calling `gc.markRoot` for each live reference.
- Roots passed to `markRoot` should obey §3 (base pointers or null), but
  `markRoot` is defensively total: it marks a word only if it is exactly a live
  object base, ignoring null, interior, and foreign pointers. This matters
  because the type system lists some single-word pointers as "references" that
  are not GC objects — a `chan` handle is page-allocated and process-lifetime, a
  bare function value is a code address — and both stack maps and object pointer
  maps legitimately carry them; the collector must not decode one as an object.

**Register file.** A live reference at a safepoint is in a register the walk can
recover, or spilled to a frame slot — never one that is simply lost. Which
registers those are depends on WHICH KIND of safepoint it is, and the two
answers differ on both targets:

- **An ordinary call.** Its stack map is consulted only for a frame the walk has
  already unwound INTO, and the register values it reads have been restored from
  the prologue save slots of the frames in between. A prologue saves only what
  the calling convention makes callee-saved, so a reference live at a call
  safepoint may occupy only the callee-saved subset — x86-64
  `rbx`/`r13`/`r14`/`r15` (plus `rsi`/`rdi` under Win64), AArch64 `x19`..`x28`.
- **A back-edge poll.** Its stack map is only ever consulted as frame 0 of the
  snapshot `bit_rt_safepoint` itself published, with no restore in front of it,
  so a reference there may occupy any register the shim stores. That is the
  WHOLE allocatable integer file but one, because the shim saves and reloads
  all of them (below): on AArch64 `x1`..`x8`, `x12`..`x15`, `x19`..`x28`
  (#4429); on x86-64 `rcx`, `rdx`, `rbx`, `rsi`, `rdi`, `r8`, `r9`, `r13`,
  `r14`, `r15` (#5992). `x0`/`rax` is excluded: the compiler materializes the
  shim's own `entryOf` operand into it ahead of the payload, so the caller's
  value is already gone before the first store. The operand itself travels in
  never-allocatable scratch (`x9`/`r11`), so no other register is lost.

The snapshot is complete for that set because the walk is partitioned by
frame, not by register: `bit_rt_safepoint` is the only publisher of a non-zero
`SafepointFrame` (the allocation and thread-enter doors publish 0), so frame 0
of every precise walk is a poll site read from the raw snapshot, and every
later frame is a call site read after the restore, where only callee-saved
registers can be named. Both backends assert this per stack-map entry
(`arm64compile.bit`'s `assertStackMapsSnapshotSaved`, `x64compile.bit`'s
`xAssertStackMapsSnapshotSaved`). The widened registers survive a park too:
they sit in the shim's frame on the task's own stack, which a context switch
preserves and the parked-task conservative scan covers.

`compiler/regallocpoints.bit`'s `AllocPoints` carries the split — `polls` versus
`calleeSafepoints` — and `RegFile.pollSaved` versus `RegFile.calleeSaved` carries
the two masks. Reporting a register in `pollSaved` that the shim does not store
publishes an unwritten stack word as a root: a use-after-free, not a slow
program. The two must move together, in one commit.

FLOAT registers are unaffected: the shim saves none, and its `bl` into
`stwSafepoint` is an ordinary call, so a float live across a poll is still
confined to the convention's callee-saved set. Stack maps describe only
Int-class locations anyway, so this is a clobber question and never a rooting
one.

**Snapshot.** Collection only ever runs from `bit_rt_safepoint` (below), which is
a naked shim that records the caller's return address, frame pointer, and saved
register file *before* any runtime code can overwrite them. The frame is
built **on the polling thread's own stack** — the shim reserves it below the
caller's `sp`/`rsp` and passes its address to the poll body as the first C
argument — so every thread that polls has its own snapshot with no thread-local
storage, no registration, and no shared global. The walk starts there.

**Invariant a caller must preserve.** The frame MUST be reserved on the
publishing thread's own stack, at an address strictly below that thread's
stack pointer at the moment of the call — never a static buffer or a
per-thread heap block. The collector uses the published address itself as a
conservative lower bound for that thread's live stack (`runtime/stw/stw.bit`,
root class 10, `stwParkedLo`), not merely as a pointer to the fields above.
This is load-bearing, not incidental: a shim that ever built this frame
anywhere else would make class 10 silently inert — `stwTaskHoldsSp` would be
false for every task, no bound would ever lower, and a stopped mutator's live
stack would go unscanned again with no error and no red gate.

The snapshot's `regs` array is **not** zeroed (the shim runs at every loop
back-edge; clearing 32 words per poll is not free). Only the saved file is
written — the callee-saved subset on x86-64, the whole allocatable integer file
on AArch64. That is sound in both directions: the register file
restriction above means a stack map can only ever name a register the shim *did*
save, and every word the walk reads is routed through `markRoot`, which marks it
only if it is exactly a live object base. An unwritten slot can therefore
neither be read as a root nor be mis-decoded if it were.

The AArch64 shim also RELOADS `x1`..`x8`/`x12`..`x15` before returning — the
callee-saved half needs no reload, since `stwSafepoint` is an ordinary AAPCS64
callee and preserves it. Those reloads read back exactly the words the saves
wrote, which is only true because this collector does not move objects. A moving
collector would have to write the updated addresses back into the snapshot
first, and this is the paragraph that would have to change.

**Frame chain.** Both backends establish an identical frame record: `*(fp)` is
the caller's frame pointer and `*(fp+8)` is the return address (`fp` = `rbp` on
x86-64, `x29` on AArch64). All stack-map offsets are **frame-pointer-relative**,
normalized by each backend, so the walker is arch-neutral.

**Wire format (`bit_stack_maps`).** Every object emits its own entries into a
dedicated section — ELF `.bit_gc`, Mach-O `__DATA,__bit_gc` — one entry per
function, each its own atom carrying a local symbol. The **linker** lays every
contributing object's entries out as one uninterrupted run and defines the two
symbols that bound it, `bit_stack_maps` and `bit_stack_maps_end` (Mach-O:
`_`-prefixed). The runtime `extern`s both and walks the half-open extent.

There is deliberately **no count and no terminator**. A merged table spanning
several archive members has no count any one object could write, and a
per-object terminator is worse than useless: concatenation would give
`[e1][T][e2][T]` and the walk would stop at the first `T`, silently losing every
later member's frames. Entries are self-delimiting and the extent is the bound.

Entry atoms are **8-aligned**: the writer follows every entry's fields
with zero PADDING bytes out to a multiple of 8, and the section declares 8-byte
alignment to match. Because every atom's *length* is already a multiple of 8,
the linker never has to insert padding of its own to honor that alignment —
whatever subset of atoms dead-stripping retains, the running byte count after
each surviving atom is still a multiple of 8, so the next atom is already
aligned. That is what keeps the walk sound with no count and no terminator: it
still advances by decoding one entry's real fields, then rounds its cursor up
to the same 8-byte boundary to skip that entry's own trailing pad — there is
never a linker-inserted gap to mistake for an entry, because none is ever
inserted. On Mach-O the section is in `__DATA` so dyld rebases its absolute
code pointers under PIE; on ELF it is read-only, since the image is non-PIE.

Before entries became 8-aligned, they were 1-aligned and tightly packed with no padding at
all — equally safe against a linker-inserted gap (there was nothing to align,
so nothing to pad), but it left every `__bitsm_N` atom's *declared* alignment
truthfully at 1, and `ld` warns on that: the atom's leading `u64 code_addr` is
a relocated pointer, and 1-byte declared alignment tells the linker it may be
placed anywhere.

Little-endian; the trailing pad is the only field not tightly packed against
its neighbor (read with unaligned loads — nothing inside one entry is
guaranteed 8-aligned, only the entry boundaries are):

```
per function (repeated to the end of the extent):
  u64 code_addr        # abs reloc -> the function's code symbol
  u16 version           # format-version stamp: smFormatVersion (2) in both
                         # compiler/codegen.bit and runtime/gc/stackmap.bit;
                         # the reader also accepts 1 (smFormatVersionV1),
                         # checked before any count-driven field is trusted
  u32 code_size        # bytes; the function spans [code_addr, code_addr+code_size)
  u16 num_saved
  per saved (num_saved times):
    u16 reg            # physical register number the prologue preserved
    i32 fp_off         # caller's value is at *(fp + fp_off)
  u16 num_safepoints
  per safepoint (num_safepoints times):
    u32 ret_offset     # this safepoint's return address = code_addr + ret_offset
    u16 num_slots
    i32 slot_fp_off[num_slots]   # live-reference stack slots, fp-relative
    u16 num_regs
    u16 reg[num_regs]            # physical registers holding a live reference
  u16 num_live          # version 2 only (#7303): one per back-edge poll
  per poll (num_live times):
    u16 sp_index                 # the poll's record, by position in this entry
    u32 live_regs                # bit n set when physical register n holds a
                                 # value of any type the code after it still needs
  u8 pad[0..7]          # zero bytes bringing this entry's total length to a
                         # multiple of 8; the walker recomputes the count by
                         # rounding its cursor up, not by reading a length field
```

**Two versions, one image (#7303).** Version 2 keeps version 1's safepoint
records and appends a trailer carrying `live_regs` for each back-edge poll
only: a call record's mask would be a superset nothing reads, and four bytes
on every record grew `__bit_gc` by 14% on the json benchmark. The pinned
stage0 that builds `libbitrt.a` keeps stamping version 1 until a repin, so a
default build links both, and the reader parses each entry by its own stamp.
`smLiveRegsAt(pc)` answers `smLiveUnknown` (-1) for a version-1 entry, a call
safepoint, or a `pc` with no record, which a consumer must treat as "every
saved register may be live". The mask covers only the allocatable integer
file; a register outside it is never named.

**The consumer zeroes dead words (#7304).** Bit n of `live_regs` is
`regs[n]` of the poll's `SafepointFrame`, on every target: both backends
number the mask by physical register (`physRegMask`), as the shim lays out
`regs[n]` at `+16+8n`. Before `stwCollect` walks a frame precisely, for its
own snapshot and for every parked mutator's, `gcZeroDeadRegs`
(`runtime/gc/stackmaplive.bit`) stores 0 into every `regs[n]` that is clear
in the mask AND holds no caller's value, so neither the precise walk nor
the conservative scans of classes 8 and 10 root what a dead register last
held. A register the target ABI preserves across calls (x19..x28 on
AArch64; rbx, rbp, r12..r15 on x86-64, plus rsi and rdi on Win64) that
the function's entry does not list in `saved` carries a caller's value
and is kept; one it does list is dead, its caller's value being in the
save slot. Zeroing rather than skipping is deliberate: the shim reloads
its caller-saved words on the way out, so a mask that misses a live
register zeroes that register and the program fails under
`BIT_GC=stress`, instead of a live object being freed in silence. An
unknown mask zeroes nothing.

**The producer and the reader are separate build inputs, and this format's
correctness depends on them agreeing.** The padding above is written by
whichever compiler emitted an object (`compiler/codegen.bit`'s
`writeStackMaps`) and read by whichever `runtime/gc/stackmap.bit` this tree
currently has — two different build stages, not one. The default
`./make libbitrt` path compiles `runtime/**` with the *pinned stage0*, a
previous release's compiler frozen at build time, while the reader is always
the working tree's current source. A stage0 built before entries became
8-aligned emits unpadded, 1-aligned entries; the tree's current reader
unconditionally rounds every entry's cursor up to 8 regardless of what the
writer did — the
walk desyncs on the first entry whose own length is not already a multiple
of 8 and dereferences garbage on the first collection. `BIT_GC=off` on such
a binary runs fine, because the walk that dereferences garbage never
executes.
`tools/build/artifacts.bit`'s `checkStackMapPadding()` guards this after
`stepLibbitrt` writes the host archive — the earliest point these bytes
exist to inspect — asserting every member object's `__bit_gc` (Mach-O) /
`.bit_gc` (ELF) section length is a multiple of 8, refusing and deleting the
archive otherwise, and naming the two-pass `BIT_STAGE0_BIN` bootstrap
(docs/development.md, "Landing a runtime ABI change") as the fix. It is a
guard against this *class* of skew — any future change to this wire format
that a stage0 repin has not yet caught up to — not a promise that today's
exact field layout is what a mismatch would ever reproduce again.

**A per-entry format-version stamp, shipped.** The padding checker
above is a build-time guard for one specific historical skew; it does not
generalize to the *next* layout change, and the entry-alignment change
reached production as a silent bus error before any guard existed for it at
all. The fix is the
`u16 version` field in the format block above, placed right after
`code_addr` (so the field the object writer's relocation logic depends on —
`code_addr` sitting at each entry's offset 0 — is untouched, and neither
`emitmacho.bit` nor `emitelf.bit` needed to change), checked by the reader
before any count-driven field (`num_saved`, `num_safepoints`, ...) is
trusted. A mismatch panics by name with both versions, using the same idiom
as `panicStackMapBounds` above rather than a fixed literal message, since the
two numbers are runtime values read off the blob. `compiler/codegen.bit`'s
`writeStackMaps` stamps `smFormatVersion` (currently 2) into every entry it
writes, and `runtime/gc/stackmap.bit` carries the matching reader half
(`smFormatVersion`, `panicStackMapVersion`, `appendDecimal`), wired into
`scanFrame`'s live parse: the fixed-header bounds check widened 14 -> 16
bytes to cover the new field, and the version is read and compared before
`num_saved` or any other count-driven field is trusted. Proven against a
synthetic blob through a temporary C-driver hook in both
directions — match walks normally, mismatch refuses with `"gc: stack-map
format version mismatch: expected <E>, found <F>"`. Because the writer and
reader landed in the same change, a default single-pass build's merged table
only ever carries one version; the mismatch path fires only across a stage0
repin boundary (see the paragraph above) — the loud failure this stamp
exists to produce instead of the entry-alignment change's silent bus error.

The walk, per frame: find the function whose code range contains `pc`; at the
matching `ret_offset`, `markRoot` each `slot_fp_off` slot and each live register
(read from the running snapshot for the innermost frame, or reconstructed from
inner frames' `saved` entries as the walk unwinds); apply this frame's `saved`
entries to recover the caller's registers; then step to `*(fp)` / `*(fp+8)`.
`pc` leaving every function's range ends the Bit portion of the stack.

**Retention.** A stack-map entry is kept exactly when the function it describes
is kept. It cannot be a dead-strip root — each entry relocates to its function,
so rooting the entries would retain every function of every runtime module in
every image — and it cannot be left to ordinary reachability, because nothing
references an entry, so all of them would be dropped and the collector would see
no frames at all. The linker decides it after dead-strip, in the same pass that
orders the merged group. Dead-stripping `libbitrt.a` is thereby *finer*-grained
than a whole-program table allowed, not coarser.

**The SLOT half of an entry is currently redundant for correctness,
and this is proven, not assumed.** `slot_fp_off[num_slots]` above is read by
exactly two root classes, both walking `gcScanSnapshot`
(`runtime/gc/stackmap.bit`): the collecting thread's own frames
(`runtime/stw/stw.bit:437`) and every other STOPPED mutator's published
frame (`runtime/stw/stw.bit:439`). No other root class reads it —
`grep -rn '\.slots'` outside `compiler/codegen.bit` (the writer) and this
file's own reader finds nothing else. Both call sites are shadowed by an
UNCONDITIONAL conservative scan of the identical stack memory that runs on
every single collection, in production as well as under `BIT_GC=stress`:

- The collecting thread's own live `sp` (`stwReadSp`, `runtime/stw/stwscan.bit:144`)
  is read strictly deeper in the call chain than the `SafepointFrame` the
  safepoint shim recorded above, so it is always a lower (or equal) address.
  Root class 8 (`runtime/stw/stwscan.bit:311-317`) lowers that task's
  conservative scan bound to this `sp` before the unconditional
  `stwScanStackRange(g, lo, top)` at `runtime/stw/stwscan.bit:327` — a range that
  is therefore always a superset of every address `gcScanSnapshot`'s
  frame-pointer-chain walk can reach on that same stack (frame pointers only
  grow toward higher addresses, `runtime/gc/stackmap.bit:496-498`).
- A parked mutator's scan bound is lowered the same way by root class 10
  (`stwParkedLo`, `runtime/stw/stwscan.bit:247-261`) to the exact address
  of that mutator's own published `SafepointFrame` — the very address
  `gcScanSnapshot`'s unwind starts from — before the same unconditional
  `stwScanStackRange` call.

So **no frame shape currently leaves a stack-map slot as the sole root for a
spilled reference.** Confirmed empirically as well as by this argument:
mutating `compiler/regalloc.bit`'s `slots = append(slots, loc.index)` to a
no-op drops every emitted entry's `num_slots` to 0 while a program built
against the mutated compiler still runs tens of thousands of `BIT_GC=stress`
collections to an unchanged result. **This does not mean the field should be removed or that class 8/10
are optional** — a future generational or moving collector, or any future
narrowing of class 8/10's conservative range for performance, would make the
slot list load-bearing again. It means today's always-on conservative
fallback happens to make it redundant for correctness right now, and nothing
in the codebase currently tests that the slot list is itself correct.

**The REGISTER half is a different story: it is genuinely load-bearing,
not shadowed.** `runtime/stw/stwscan.bit:328-336` skips class 7's ctx
scan for the running task, so `gcMarkRoot(g, *(regs + rn))` is, for a
self-collecting task, the only thing marking a live register directly.
Mutating `compiler/regalloc.bit`'s `regs = append(regs, loc.index)` to a
no-op (every entry's `num_regs` -> 0) makes `_tests_/stress/schedgrowdarwin`
and `schedgrowdemanddarwin` (`test-stress-batch`) crash deterministically —
`bus error` / `segmentation fault`, 3/3 runs, at idle host load, both clean
on the unmutated compiler at comparable load, ruling out contention. Both
programs start a real OS thread and hand it a GC-managed `WorkerLaunch`
(`runtime/sched/grow.bit`); the spawning call chain can hold that reference
live only in a register across the handoff, and a missing root there frees
it out from under the new thread reading its fields. **One narrower shape
does happen to survive**: a single task that triggers its own collection
while holding a register-only reference with no other thread involved
survives, because `bit_rt_safepoint`'s snapshot frame — including its raw
`regs[32]` dump — sits on that same task's own stack, inside class 8's
`[sp, top)` scan (`runtime/gc/stackmap.bit`'s fuller note has the full
argument). That corner is not the general case and must not be generalized
from — `.regs` stays exactly as necessary as it looks.

### 4.1 The one-table assumption, and why it had to go (RESOLVED)

The format above assumes **one table per link**, under one fixed symbol, emitted
by the single object that is the whole program. That assumption is what makes a
Bit-sourced `libbitrt.a` unreachable today, and resolving it is a contract
change, so it is recorded here before the code moves.

A freestanding archive member (SPEC §17.6) carries no `bit_stack_maps` — two
members defining that symbol is a duplicate-definition error. §17.6 therefore
requires every function in such a member to be `@nosplit` or `@naked`, which is
sound for exactly the reason §10.3 gives: such a function may not allocate and
may not reach a safepoint, so no collection can begin beneath its frame and the
absent map is never consulted.

**That requirement collides head-on with the scheduler.** `schedWorkerRun` must
*not* be `@nosplit`: its safepoints are what let a worker yield to a stop-the-world
rendezvous, and removing the attribute is what took `_tests_/stress/schedpool` from
**zero** collections under `BIT_GC=stress` to a working count. Re-adding it to
satisfy §17.6 would re-break the collector. Both rules are correct in isolation
and cannot both hold, so a runtime module that must reach safepoints has **no
representation as an archive member** under the current format.

Measured, with the `@nosplit` emit gate removed and nothing else changed: **all
ten** ported runtime modules (`spinlock alloc gc park chan sched rand thread
auxv root`) emit freestanding and archive to **217 defined / 217 distinct
symbols, zero duplicates** — and **zero** of them carry a stack map. The pin
scan (§9) is already fully satisfied for all ten. The stack-map table is the
only remaining obstacle between here and a fully-Bit `libbitrt.a`.

**This is now implemented; §4 above describes the landed format.** The record
below is kept because it is the argument for the design, not a plan.

**Resolution: the table becomes per-member and the linker merges it.** Each
object emits its own stack-map entries into a dedicated section (ELF `.bit_gc`,
Mach-O `__DATA,__bit_gc` — both section kinds already exist in the object
writers); the linker lays that section's atoms contiguously and the runtime walks
the merged extent instead of one blob. A stack-map entry must be retained
exactly when the function it describes is retained, so entries are per-function
atoms rather than one blob per module — which also makes dead-stripping of
`libbitrt.a` finer-grained than it is today, not coarser.

Consequences for this document, all now applied in §4: the leading
`u32 num_funcs` is gone (a merged table has no single count), entries are a flat
sequence bounded by the linker-defined extent, and `bit_stack_maps` names the
start of that extent rather than a blob one object owns. **§17.6's `@nosplit`
requirement was deleted, not relaxed** — a member carrying its own maps has no
reason to restrict what its functions may do.

Two alternatives were weighed and rejected:

- **A second "runtime member" kind** that carries stack maps and is not
  `@nosplit`, kept distinct from today's freestanding. This is *dominated*: the
  moment a member carries maps it needs the merge mechanism above, so this is
  the same format change plus a second mode to maintain forever.
- **Linking non-freestanding modules as a whole-project object** instead of an
  archive member. Cheapest, but it re-opens the prelude-symbol collision that
  module-scoped emission was introduced to solve, whose failure mode is an
  unresolvable `m<id>$` reference that dies far from its cause (dead-stripped
  when unreferenced, a dyld abort on Darwin). It also breaks the distribution
  model: `bit` links a *prebuilt* `libbitrt.a`, and this would require the
  runtime to be recompiled into every user program's object.

### 4.2 Debug-info line table

See `spec/SPEC.md` §18.6.1 for the choice of bespoke over DWARF, and why. The
walker that symbolizes a panic reads a second, independent side table,
laid out like §4's stack maps because that shape is already proven against
dead-stripping, cross-object merging, and reading with no allocation.

**This is a second, fully independent table, not an extension of `.bit_gc`.**
It duplicates `code_addr`/`code_size` per function rather than reusing the
stack-map table's function index, so each table can be produced, consumed, or
extended without the other's correctness depending on it — the two are merged
by two unrelated linker passes with no guarantee their function order agrees
after separate dead-stripping.

**Section and extent symbols.** ELF `.bit_dbg`; Mach-O `__DATA,__bit_dbg` —
`__DATA` because, like `.bit_gc`, entries hold absolute code and string
pointers that dyld must rebase under PIE. Like `.bit_gc`, each object emits
its own entries and the **linker** concatenates them, defining
`bit_debug_lines` / `bit_debug_lines_end` (Mach-O: `_`-prefixed) at the merged
extent's bounds. No object defines either symbol itself: two members defining
one global name is a duplicate-definition error, and only the linker sees the
whole link.

**Wire format**, little-endian. Every field is fixed-width and both the
per-function header (24 bytes) and each row (16 bytes) are already multiples
of 8, so — unlike `.bit_gc`'s variable-length safepoint sub-arrays — no entry
ever needs a trailing pad byte or a rounding step to reach the next one:

```
per function (repeated to the end of the extent):
  u64 code_addr        # abs reloc -> the function's code symbol (the same
                        # atom §4 relocates against; two independent
                        # relocations, one per table, against one symbol)
  u16 format_version   # checked before code_size/num_rows are trusted (below)
  u32 code_size
  u16 num_rows
  u64 name_hdr_ptr      # abs reloc -> this FUNCTION's own display name's
                         # string-pool header — one per entry, not
                         # one per row, unlike file_hdr_ptr below
  per row (num_rows times):
    u32 pc_offset        # code_addr + pc_offset is this row's start address;
                          # rows sorted ascending; a row's span runs to the
                          # next row's pc_offset, or to code_size for the last
    u64 file_hdr_ptr      # abs reloc -> that source file's existing
                          # string-pool header — the same {ptr,len} shape
                          # already emitted for every string literal (§12's
                          # RtBytes is that same shape) — not a new string
                          # encoding
    u32 line              # 1-based
```

Row 0 of every function **must** have `pc_offset == 0`: full coverage from
the function's first instruction is mandatory, so a `pc` inside a found
function's range can never fail to match some row — "no row covers this
offset" is not a state the walker has to handle.

**`format_version`, shipped from the first line, not retrofitted.** §4's
version stamp was added to `.bit_gc` after the entry-alignment change
reached production as a silent bus error with no guard at all — producer and reader are different
build stages (`libbitrt`'s own entries come from the pinned stage0; every
other entry in the same link comes from whatever compiler built it), and
this table has the identical exposure. Rather than repeat that retrofit
later, this table's `format_version` is present from its first line: the
walker reads and compares it *before* trusting `code_size`, `num_rows`, or
any row — placed immediately after `code_addr`, the same position §4's stamp
chose, so the one field the relocation logic depends on sitting at offset 0
is undisturbed. A mismatch does **not** call `bit_rt_panic` (below): it is
treated exactly like "no record."

**`format_version` bumped 1 -> 2 when `name_hdr_ptr` was added** — a reader built against version 1's 16-byte header must not
misinterpret version 2's 24-byte one as though the byte at old offset 16 were
already the first row's `pc_offset`. Per the paragraph above, a mismatch
degrades to "no record" rather than misreading bytes.

**File references reuse the existing string pool, interned per object.**
`module.stringPool` (`compiler/ir.bit:410`) is not deduplicated today — every
`append` adds a new entry regardless of content. A debug-info emitter that
called that path once per row would emit the same file path hundreds of
times. The emitter must intern each distinct source file path **once per
object** (a small map from path to the string-pool header symbol already
emitted for it), so every function's rows in the same file share one 16-byte
header. This is required for the format's size to be what SPEC §18.6.1
measures, not an optional optimization.

**Function names reuse the same string pool, interned per object, once per
entry rather than once per row.** `name_hdr_ptr` points at the
function's own display name — the same string codegen already names that
function's `code_addr` relocation with — interned into `module.stringPool`
exactly once per debug-info entry, mirroring the file-path interning above
but keyed by function rather than by row, since a function's name does not
vary row to row the way its rows' files can.

**Lookup, at panic time, with no allocation.** Two nested searches, mirroring
`runtime/gc/stackmap.bit`'s existing `blobU16`/`blobU32`/`blobU64`/`blobI32`
raw-offset reads (no composite locals, `@nosplit`-legal per §10.3):

1. Linear scan of the extent (bounded by `bit_debug_lines_end -
   bit_debug_lines`, exactly as the stack-map walker already bounds its own
   scan) for the function whose `[code_addr, code_addr + code_size)` contains
   the target `pc`. Nothing here is sorted by address — link order is not
   load-address order — so this is a linear scan, not a binary search,
   matching the stack-map walker's own proven cost shape.
2. Once the function is found, binary search its `num_rows` rows for the
   greatest `pc_offset` not exceeding `pc - code_addr`. Rows *within one
   function* are sorted by construction, since `code_size` and pc_offset
   monotonicity depend only on that function's own final code layout,
   decided by codegen when the entry is written — not on link order (unlike
   step 1). **Any block-reordering pass must not skip this**: if codegen reorders basic blocks
   after IR emission (the x86-64 backend's RPO block ordering already does),
   rows must be sorted by final `pc_offset` at the point the entry is
   serialized, not emitted in source or IR order.

**No record found — degrade, never abort.** A single unresolvable frame must
not blank the rest of the trace:

- `pc` matches no function's range at all (code outside every emitted
  function — libc, or a function this table omits). Print the raw address
  (`??? (0x<hex>)` — the convention `sample`'s own output already uses for an
  unresolved frame) and continue to the next frame via the frame-pointer
  chain.
- `format_version` mismatch: the whole table is untrusted for this process,
  every frame prints raw.
- **The reader must never call `bit_rt_panic` on a malformed table**, unlike
  `scanFrame`'s `panicStackMapBounds` (§4). That guard is sound for the GC
  because it runs during ordinary execution — panicking mid-collection is the
  right failure mode for a corrupt stack map. This table is read **from
  inside `bit_rt_panic` itself**, after the process has already decided to
  terminate; a hard panic here would recurse into a second panic reporting a
  first one, which is worse than an incomplete trace. Any bounds violation
  degrades that one frame to a raw address instead.

**Retention.** Exactly §4's rule: an entry is kept exactly when the function
it describes is kept — each entry relocates to that function's own code
symbol, so it cannot be a dead-strip root (that would retain every function
of every linked module) and cannot rely on ordinary reachability (nothing
else references an entry). The linker decides retention in the same
dead-strip pass §4 already runs.

**`@nosplit` / freestanding is not a constraint here**, unlike §4.1's
stack-map history. `.bit_gc` collided with `@nosplit` because an *absent* map
had to be provably never consulted (no safepoint beneath a nosplit frame). A
debug-info entry is consulted only during an already-terminating panic walk,
never during ordinary execution, so a freestanding archive member emitting
its own debug-info entries needs no companion restriction.

### 4.3 Module-cell roots (#6481)

A module-level `let`, or a `const` set at startup, whose type the collector
traces (a `string`, a slice, a class, ...) lives in the data section, where no stack map, object pointer map
or task block names it. The compiler lists the cells' reference words in one
table, the entry function hands the table to the runtime, and every collection
marks from it after the stack, task and channel roots and before it drains.

```text
table (a process-storage global, 8-aligned, one per program):
  u64 count                 N, the number of entries
  u64 cell_addr[N]          abs reloc -> one traced module cell's reference word
```

- **One entry per reference word.** A traced cell is one handle word, so a
  `string`, a slice, a class or a function value is one entry. A fixed array
  never has one: E0072 refuses an array of reference-typed elements, so every
  `[N]U` cell is untraced. A `*T` or a C-like enum is a bare word the collector
  never follows and is not listed. A `runtime/` cell never is: the checker
  refuses a traced type there, and `@threadlocal` cells are untraced by the same
  rule.
- **Registration.** The root module's `main`, in all four signatures of §10,
  starts with one call, `bit_rt_module_roots_register(table: usize) -> void`,
  before any user code, and before the module startup driver `bit$startup` runs
  the cells' initializers, so an object an initializer allocates is rooted from
  the moment it exists. The `bit test` dispatch `main` makes the same call first.
  A program with no traced module cell has no table and
  makes no call; the collector then pays one load and a compare per collection.
  `--freestanding` emits neither: there is no managed runtime to hand it to.
- **Why a call and not a symbol the runtime reads.** The runtime is built by the
  pinned stage0, which has no spelling for a data symbol only the program
  defines, and a program built by stage0 links this tree's runtime, so a symbol
  the runtime required of every program would not link. A call reaches only
  programs built by a compiler that emits it, and the symbol is always defined.
- **Marking.** `stwScanModuleRoots` (`runtime/stw/stwscan.bit`) is root class 11:
  for each entry it loads the word at the address and passes it to
  `gcMarkConservative`, which marks it only if it is a live heap object. A cell
  that still holds its zero image (null) costs one probe.
- **All three emitters.** The table is an ordinary process-storage global with
  abs64 fixups, the mechanism a static closure cell already uses, so the Mach-O
  (rebased by dyld under PIE), ELF (RELA) and PE/COFF object writers emit it
  without a format-specific case.

---


[Previous: Type information and references](type-info.md) | [Next: Safepoints, allocation, and GC tuning](safepoints-and-gc.md)
