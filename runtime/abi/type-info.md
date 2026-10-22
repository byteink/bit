# Type information and references

[Runtime ABI](../ABI.md)

## 2. Per-type pointer maps (`TypeInfo`)

The compiler emits one static `TypeInfo` per distinct (monomorphized) type and
passes a pointer to it at each allocation site (`bit_rt_gc_alloc`, §6).

```
TypeInfo {                       // extern class, 64 bytes, 8-aligned
    size            : usize      // body size in bytes, excluding the header
    ptr_offsets_ptr : [*]const usize  // -\ byte offsets of GC-ref fields
    ptr_offsets_len : usize           // -/ (ptr_offsets_ptr[0..ptr_offsets_len])
    name_ptr        : [*]const u8     // -\ static type name; debug/stats only
    name_len        : usize           // -/ (may be empty: name_len == 0)
    methods_ptr     : [*]const Method // -\ this type's methods, for interface
    methods_len     : usize           // -/  dispatch (§2.1; may be empty)
    type_id         : usize      // the compiler's TypeId (disc), unique across
                                  // the whole compiled program (§2.2a, #6017)
}
```

`extern`, and split into raw `ptr`/`len` pairs rather than a slice
slices: codegen (a different compiler than the one building the runtime)
writes this class directly into an object file's `.rodata`, so its layout
must be a frozen, language-neutral contract, not whichever in-memory shape
happens to match a slice's layout today. `runtime/gc/gc.bit`'s `TypeInfo.of(size,
ptr_offsets, name)` is the convenience constructor tests use;
codegen instead writes the raw fields directly.

Because dispatch reads `methods` through the object's `info` pointer, a
`TypeInfo` is now **per concrete type**, not per layout: two distinct types with
identical `size`/`ptr_offsets` (e.g. `class Circle { r: f64 }` and
`class Square { s: f64 }`) get separate `TypeInfo`s so their method sets stay
distinct. Codegen keys the descriptor by the type's identity, not its layout.

- `ptr_offsets` lists the byte offset, **within the body**, of every field that
  holds a GC reference. Non-reference fields (integers, floats, inline structs of
  non-pointers, packed data) are absent.
- Each offset must be **8-aligned** and satisfy `offset + 8 <= size`.
- For nested value types, flatten: emit the offsets of the pointer fields the
  value contributes, at their absolute body offsets. Pointers reachable only
  through *other* objects belong to *those* objects' maps, not this one.
- `TypeInfo` instances are static, read-only, and live for the whole program.

The runtime traces an object by reading a reference at `body + offset` for each
entry and marking it. That is the entire precision contract for the heap.

### 2.1 Method table (interface dispatch)

`methods` lists only the methods some site dispatches to, not every method the
type defines (SPEC §14; `dispatchedTables`, `compiler/lowermethodtable.bit`,
#6114). Each entry is:

```
Method {                         // extern class, 16 bytes, 8-aligned
    id  : u64                    // global method id (§ below); 0-extended u32
    fn  : *const anyopaque       // the method's code address (.text)
}
```

- **Method id.** The compiler assigns every distinct method *name* a stable
  dense `u32` id, shared program-wide. Interfaces are structural and matched by
  the checker on name+signature, so a name uniquely identifies the method within
  any one type (a type can't declare two methods of the same name), which makes
  the name id a sufficient dispatch key for a `call_iface` site — the checker
  verified name AND signature agreement between the interface and every
  concrete type it can hold before that site's id was ever emitted.
- **#5979: `v.(I)` for an INTERFACE target `I` (SPEC §14.4) is the one
  dispatch id consumer the checker does NOT verify** — it narrows an
  unrelated interface value's dynamic type against `I` at runtime, so a class
  whose method merely SHARES A NAME with one of `I`'s, with a different
  parameter or result type, used to pass the narrowing and then segfault the
  first call through it. `methodId` (`compiler/lower.bit`) keys the id on
  `name + "#" + signature` (the method's own `(params) => result` func type,
  rendered structurally by `typeName`) instead of the bare name, so a
  signature mismatch misses every method-table lookup it used to hit. Every
  id producer (this table's construction, `v.(I)`'s narrowing, and every
  ordinary `call_iface`/`Op.CallValue` trampoline site) reads the same key
  so the id space stays self-consistent.
- **`Self` in an interface signature (#7387).** An interface's `dup(): Self`
  renders `Self` in that key where the implementing class's `dup(): A` renders
  `A`, so the class's table also carries the method under the interface's key
  whenever binding `Self` to the class yields the class's own signature
  (`selfSlots`, `compiler/lowermethodtable.bit`). A program with no such
  interface adds no slot and mints no id.
- Each method's `fn` takes the receiver (the object body pointer) as its leading
  argument, then the call's own arguments — identical to a static method call.
- Entries are unordered; `methods_len` may be 0 (a type with no methods).

Dispatch (`call_iface value.id(args)`): codegen first tests `value` for null
and panics via `bit_rt_panic_nil_iface` (§12.1) if so — `value` IS the
receiver pointer, and a nil interface is a legal, checker-blessed zero value
(SPEC §13.4) with no `TypeInfo` to load `-16` bytes from. Only once that
passes does the callee load `info = *(value - 16)` (the header's `info`
field, §1), then resolves `fn` through the site's inline cache below, then
calls `fn(value, args...)`. `bit_rt_iface_lookup(info, id)` (§9) linearly
scans `info.methods` for `id` — types have few methods, so this is a short,
allocation-free walk — and returns the code address. The checker guarantees a
NON-NIL receiver satisfies the interface, so the id is always present there; a
miss is a compiler bug and traps.

**Inline cache (#5965).** Every `call_iface` site owns one writable,
zero-initialised, 8-aligned 16-byte cell `{info, fn}` (`compiler/ifacecache.bit`
names it `<function>$ic<k>` and registers it as a module cell). The hit path
loads the cell's `info`, then its `fn`, compares `info` with the receiver's
and, when equal, calls `fn` with no runtime call at all. A miss calls
`bit_rt_iface_lookup_ic(info, id, cell)` (§9), which resolves exactly as
`bit_rt_iface_lookup` does and returns the address; if the cell is still
empty it also binds it. The cell is monomorphic and bound at most once: the
first type a site sees owns it, and any other type misses on every call
(HotSpot's monomorphic-to-megamorphic transition, never rebinding). Binding
once is what keeps a megamorphic site from writing a shared cache line on
every call from every worker. A miss whose cell is already bound (its `fn`,
read by the probe, non-zero) calls `bit_rt_iface_lookup` directly, so a site
that keeps missing pays the probe and one branch over the pre-cache sequence,
never an extra call level; only a miss on an empty cell calls
`bit_rt_iface_lookup_ic`.

Two concurrent misses never pair one type's `info` with another type's `fn`:

- The binder claims the cell with a compare-and-swap of `fn` from 0
  (`atomicCmpxchg`), so exactly one writer ever exists per cell, and only that
  writer then stores `info`, with release (`atomicStoreRelease`). Neither word
  is written again, so there is no later write a reader could mix in.
- The reader loads `info` before `fn` — `ldar` on AArch64, a plain load on
  x86-64, which never reorders two loads. An `info` that matches the receiver
  is therefore the binder's release store, so the `fn` loaded after it is the
  one the binder stored before it. A reader that runs between the CAS and the
  `info` store sees `info == 0`, which no object's header holds, and misses.

The miss path never collects, so the method call stays the site's only
safepoint.

A **closure value** is one such object: `gc_alloc`'d, a fixed 16-byte
`{ code_ptr, env_ptr }` cell (`TypeInfo{ size = 16, ptr_offsets = [8] }`). The
code pointer at +0 targets `.text` and is never a GC reference; the environment
pointer at +8 is the cell's one ref field. Codegen calls a closure by loading
both and calling `code_ptr(env_ptr, args...)` — the environment is threaded in
as the callee's leading argument. Nothing new is required of the runtime: a
closure cell is scanned by the same `ptr_offsets` mechanism as any class.

A **dynamic slice value** (`[]T`) is a pointer to a `gc_alloc`'d 40-byte header
`{ buf, len, off, cap, is_ref }` (`TypeInfo{ size = 40, ptr_offsets = [0] }`).
`buf` at +0 points at a *separate* `gc_alloc`'d element buffer (the header's one
traced reference); the slice views the `len` elements at `buf[off .. off + len]`,
with capacity `cap` counted from `off` (so `buf` holds `off + cap` elements, each
`elem_size` bytes wide — §9). `len`/`off`/`cap`/`is_ref` sit at +8/+16/+24/+32,
counted in elements, never bytes — only the per-element stride the buffer is
addressed with changes. Keeping `buf` a base pointer and carrying an `off` means
a reslice `s[lo:hi]` shares the same `buf` and only bumps `off`/`len`/`cap` —
**no interior pointer is ever stored as a GC reference** (§3). `is_ref` records
whether each buffered element is itself a GC reference.

**Element storage: word-per-element by default; a non-ref buffer may pack to
its element's own byte stride.**
A GC reference is word-sized, and when `is_ref` the collector traces every word
of the element buffer as a root (below) — so a reference-typed buffer can never
pack, unconditionally, regardless of element width. This is a forward-looking design constraint, not a description of what
today's collector would do with a violation: on the current non-moving
collector, `gcMarkRoot` (`runtime/gc/gcmark.bit:95-105`) marks a candidate word
only if it is non-null, in-range, and confirmed by `gcOwns` to be exactly a
live object's body base, and `markObject` (`runtime/gc/gcmark.bit:65-82`) only
sets the object's mark bit and pushes it on the worklist — it never writes back
through the traced slot (`scanObject`, `runtime/gc/gcmark.bit:131-164`, drives
both). So decoding packed scalar bytes as a reference today is bounded to
retention, never corruption — the same soundness argument §5 makes for the
conservative stack scan. The invariant still forbids packing by construction,
because it is what keeps this rule safe the day the collector gains a write
barrier or starts moving objects, and because unbounded retention is itself a
bug worth ruling out now. The direction that already produces a
silent-wrongness bug is the opposite one: a reference-typed buffer handed the
LEAF `slice_buf_info` descriptor instead of the traced `ref_array_info` one,
so the collector never walks it and sweeps referents the program still
holds — see the fabricated-header bug at `runtime/root/slices.bit:443-451`
(`_tests_/cases/run_empty_slice_null_header.bit`). Packing is scoped by
`is_ref`, not by element identity: any `is_ref == false` buffer may pack to its
element's own byte stride (`elem_size`, §9) — the scalar's own width for a
narrow prim (`1`, `2` or `4`, listed below), or a class `T`'s own body size
(`elem_size = layout.size`) when EVERY field of `T` is a non-reference scalar
(`ptr_offsets` empty), or `16` for a `decimal` (#6570). `elem_size` is a per-call-site
compile-time constant, never runtime state, and travels as an explicit
argument to every slice entry point below — the collector needs no change to
support it: a packed, non-ref buffer keeps the LEAF `slice_buf_info`
descriptor regardless of stride, so `scanObject` reads zero words of it either
way. A buffer whose element type has ANY reference field — `ptr_offsets`
non-empty, including a single reference field mixed with scalars — stays
word-per-element (`elem_size = 8`) unconditionally: the collector's tracing
loop for a ref buffer walks it word by word, and a struct-wide stride is not
representable that way. `bit_rt_slice_get`/`bit_rt_slice_set` stay
WORD-VALUED (one `int` in, one `int` out) regardless of `elem_size`, so
neither is ever called with `elem_size > 8` for a packed buffer — the
compiler lowers a wide-element field read/write to a direct load/store at the
field's own offset instead, and the runtime FATALs if a stride it cannot
represent through either function ever reaches it, rather than silently
returning or storing a truncated word. Every scalar narrower than a word
packs at its own width: `i8`/`u8`/`bool` at 1, `i16`/`u16` at 2 (#7562),
`i32`/`u32`/`f32` at 4 (#7574); the runtime moves exactly those bytes, `get` zero-extended.

Channels (§11) and native maps (§15, `runtime/root/maps.bit`'s `allocBuf`
callers) do **not** pack and stay word-per-element regardless of element type:
a channel carries only a handful of in-flight values and a map's live entry
count is bounded by its slot table, so neither reaches the scale — a byte
slice can hold megabytes — where the 8x word-per-byte amplification that
packing removes actually matters.

The runtime owns construction/growth/bounds-checked
access/reslicing via `bit_rt_slice_new/append/get/set/slice` (§9); `len(s)` reads
the header word directly (`slice_len`, offset 8, shared with the `string`
header). When `is_ref`, the element buffer carries the `ref_array_info`
descriptor (§2) and the collector traces every word of its (dynamically sized)
body as a root — so objects reachable only through a slice survive collection.
A non-ref buffer stays a leaf. The header keeps the buffer itself alive via its
`ptr_offsets = [0]`.

The compiler lowers append to `bit_rt_slice_append_fresh`,
`bit_rt_slice_append_str_fresh` and `bit_rt_slice_append_slice_fresh`: these
preserve an existing destination header. The corresponding names without
`_fresh` remain mutating targets for proven-owned headers. No environment
setting selects the mutating targets; the ownership proof controls their use.

### 2.2 Type assertions

Because an interface value *is* the receiver pointer, its dynamic type is the
`TypeInfo` in that object's header — and descriptors are **per concrete type**
(§2), so descriptor identity is type identity. A type assertion (SPEC §14.4) is
therefore a pointer comparison against the target type's descriptor, whose
address codegen materializes from the `type_info` IR op (the same
`__bittype_<disc>_<size>_<offsets>` symbol `gc_alloc` references).

```
bit_rt_iface_as(recv: ref, want: usize) -> ref        // recv on match, else null
bit_rt_iface_as_ok() -> bool                          // ok of the iface_as/iface_as_enum just before it
bit_rt_iface_assert(recv: ref, want: usize) -> ref    // panics on mismatch
bit_rt_iface_as_enum(recv: ref, want: usize) -> ref   // ENUM target: recv on a type_id match, else null (§2.2a)
bit_rt_iface_has(recv: ref, id: usize) -> ref         // recv if its type has method `id`, else null
bit_rt_iface_implements(recv: ref, ids: ref) -> ref   // INTERFACE target: recv if its type has every id in `ids`, else null, cached (§2.2b)
```

- `want` is a `*const TypeInfo` passed as a plain integer: the descriptor lives
  in `.rodata`, so it must **not** be reference-typed, or a stack map would offer
  it to the collector as a root (§4).
- `recv` is only dereferenced once `owns()` confirms it is exactly a live
  object's body: a nil interface is a null word, and a reference-typed value need
  not be a GC object at all (§3). Neither case matches, so both yield `ok=false`.
- The mismatch result is **null**, not the un-narrowed receiver. The result is
  typed `T`, so returning the receiver would let a caller that ignores `ok` read
  one concrete type as another. Null is `T`'s zero value.
- `bit_rt_iface_as_ok` reports the `ok` of the `bit_rt_iface_as` **immediately
  preceding it**, from a **per-task scratch** slot (`scrIfaceOk`,
  `runtime/sched/scratch.bit`), not a per-thread one (Mach-O refuses
  `@threadlocal` at emission, §11.11). Lowering emits the pair back to back
  with nothing between them, which stops a *second assertion on the same
  task* from landing in the window; because the slot lives in per-task
  scratch rather than a process-wide word, it is also safe against a second,
  genuinely concurrent OS thread writing it at the same real time once
  `BIT_WORKERS>1` (§9) — the same reason `bit_rt_chan_recv_ok` (§11) and the
  fallible-call error slot (§13) are safe at any worker count. Before it moved
  to per-task scratch this was a single process-wide flag and that was a live
  gap; see §22's audit and §5's note on what adjacency does and does not buy.
- `bit_rt_iface_assert` names both types in its panic message; the descriptors
  already carry them.
- `bit_rt_iface_has` is the INTERFACE-target assertion `iface.(I)`,
  where the question is not descriptor identity but whether the dynamic type's
  method set satisfies `I` (SPEC §14.3/§14.4). `id` is the `bit_rt_iface_lookup`
  dispatch id (§2.1) of ONE method of `I`; the answer for the whole set is built
  by **chaining**: lowering emits one call per method of `I`, feeding each
  result into the next, so a miss anywhere yields null and every later call
  misses too. It writes the same per-task `ok` slot `bit_rt_iface_as` writes, so
  the last call in the chain leaves the conjunction there and `bit_rt_iface_as_ok`
  reads it under the same adjacency rule. Null on a miss for the reason above,
  sharpened: the result is typed `I`, so returning the un-narrowed receiver
  would let a caller that ignores `ok` dispatch a method the object does not
  have, and `bit_rt_iface_lookup` answers that with 0 — a call to address 0.
- **#5979: `id` alone used to accept a same-named, differently-shaped method.**
  `bit_rt_iface_has`'s `id` came from the method NAME only, and a class whose
  method shared only the name with `I`'s — different parameter or result
  types — landed in the same method-table slot the chain looked for, passed
  the narrowing, and then segfaulted the first `call_iface` through it (the
  checker never verifies this: `v.(I)` narrows an UNRELATED interface's
  dynamic type, so there is no static agreement to lean on). See §2.1's id
  bullet: `id` is signature-qualified, so this chain's calls miss exactly
  when §2.1's table-building side does.

#### 2.2a `bit_rt_iface_as_enum`: the BOXED-ENUM target (#6017)

`e.(EnumType)` (SPEC §14.4) where `EnumType` is a **boxed** enum (§14.7) cannot
use §2.2's descriptor-pointer identity: a boxed enum's object size is
`8 + 8*argc` bytes, ONE SHAPE PER VARIANT, so two objects of the same enum
type can carry two *different* `TypeInfo` addresses — unlike a class, whose
layout, and therefore whose descriptor, is fixed once at the declaration.
`bit_rt_iface_as_enum` decides the match by the descriptors' `type_id` word
(§2) instead of their address: every descriptor for the same enum carries
the same `type_id` — the compiler's own TypeId (`disc`), unique across the
WHOLE compiled program — regardless of which variant built it. `want` is
therefore any valid descriptor address carrying the target's `type_id` —
codegen does not need it to match a real allocation's exact shape, only its
`type_id` (`lowerEnumTypeInfo`, `compiler/lowerexpr.bit`).

**Not `name`.** An earlier version of this primitive compared the
descriptors' NAME bytes instead, reasoning that every descriptor for one
enum carries identical name bytes. That is true but insufficient: `name` is
the bare DECLARED name with no module or package qualification (`typeName`,
`compiler/types.bit`) and is documented "debug/stats only" (§2) for exactly
this reason — two DISTINCT enum types, in different modules or different
first-party packages, can share a declared name (`enum Err { ... }` is a
natural, unremarkable choice in more than one package). A name-only compare
would call them the same type and then read a payload word under the wrong
variant's layout — a live type-confusion bug, caught in review before this
primitive shipped (#6017). `type_id` cannot collide this way: it is an index
into the one `TypeContext` the whole program's `bit check`/`bit build`
shares, so two distinct declarations always get two distinct ids no matter
how they are spelled or where they live.

It writes the same per-task `ok` slot `bit_rt_iface_as` writes, so
`bit_rt_iface_as_ok` reads either (same adjacency contract). There is no
`bit_rt_iface_assert_enum`: the one-result panicking form
(`let v = e.(EnumType)`) is built in the lowerer from `bit_rt_iface_as_enum` +
`bit_rt_iface_as_ok` + an inline branch/panic, the same shape
`lowerIfaceAssertOne` already uses for an INTERFACE target (§2.2 above),
rather than a second runtime entry point.

A non-boxed (bare-tag) enum can never be a type-assertion target at all —
§14.4/§14.3 — so `bit_rt_iface_as_enum` is never called with one; `bit check`
rejects it before lowering (E0041).

#### 2.2b `bit_rt_iface_implements`: the INTERFACE target, verdict cached (#7406)

```
bit_rt_iface_implements(recv: ref, ids: ref string) -> ref   // recv if its type has every method id of `ids`, else null
```

The INTERFACE-target assertion `x.(I)` (SPEC §14.4) is one call. `ids` is a
pooled string constant holding `I`'s dispatch ids (§2.1) as decimal numbers
joined by `,` (e.g. `"12,57"`); lowering emits no call for an interface with no
methods. The result is `recv` on a hit and null on a miss or when `recv` has no
dynamic type, and the caller takes `ok` as `result != nil` (#7408); the per-task
`ok` slot is not written.

The verdict is cached per (dynamic type, `ids`) pair, so a repeated assertion
costs a probe, not a method-table walk per method. The key is the dynamic
type's descriptor address and the address of the pooled `ids` string (equal id
lists share one string). The cache is a fixed table in `.bss`: no GC
allocation. Each entry is two words written once and never changed (a CAS
claims the first word, a release store publishes the second), so a reader never
observes a torn pair at any worker count; a full probe window (8 slots)
computes the answer uncached. The runtime lives in `runtime/root`, shared by
every provider, so no provider has anything to add. `bit_rt_iface_has` (the
per-method chain this replaced) stays for code the pinned stage0 built.

### 2.3 `string` value, and shared-backing views (`s[lo:hi]`)

**RULING (2026-08-28): `{ptr, len, base}`, superseding the `{base, len,
off}` decision this section previously recorded.** That
design measured out on macOS — silent garbage under `BIT_GC=stress`, `rc=0` —
and segfaulted booting `fn main(){}` on x86_64-linux — both failures were
reproduced, and the `{ptr, len, base}` layout was verified end to end on both
platforms, emitter unchanged, with neither failure mode. This lands in three
independently-landable steps instead of a flag day; this document describes
the shape that exists once Step A has landed and marks what Steps B/C still
owe.

```
string header {                  // TypeInfo{ size = 24, ptr_offsets = [16] }
  ptr  : usize   // +0   absolute address of the first byte — an INTERIOR
                 //      pointer into the object's own inline bytes (or, once
                 //      Step C lands, another string's). NEVER in ptr_offsets.
  len  : usize   // +8   byte count. Unchanged from v1, and identical to the
                 //      dynamic slice header's `len` offset (§2 above).
  base : ref     // +16  the object that owns the inline bytes. TRACED
                 //      (ptr_offsets = [16]) — self for a fresh heap string
                 //      (`strInitOwned`), the source string for a view
                 //      (`strInitView`, Step C), 0 for a static literal.
}
```

**The property that makes this landable in three ordinary changes: slots 0/1
never move.** `ptr` is still at +0 and `len` still at +8, exactly as v1's
`{ptr, len}` header always had them, so a bare 16-byte two-word header is
STILL a fully valid, readable string — forever, not just during the
migration. `runtime/root/root.bit`'s `strHeaderSize` (16) is therefore the
MINIMUM READABLE header rather than "the" header size; `strAllocHeader` (24)
is what every fresh heap allocation uses from Step A onward. This is the
opposite shape from the superseded `{base, len, off}` decision, which moved
`ptr`'s role to a derived `base + off` and so could not be read by any code
still expecting `{ptr, len}` at all — that is what made it a 17-file flag day
rather than three independent steps.

- **Step A — widen the heap allocator.** `allocString` now allocates
  `strAllocHeader + n` bytes (`n` the byte count) and writes a self-owning
  header: `ptr = body + strAllocHeader`, `len = n`, `base = body`. All nine
  `strBytes`/`strBytesOf`/`strData`/`strLenOf`/`strSize` reader
  implementations across the tree are byte-for-byte unchanged — they read
  `loadWord(s + strPtr)`/`loadWord(s + strLen)` exactly as before, because
  neither offset moved. The compiler's literal emission is unchanged, so a
  literal is still a bare two-word `{ptr, len}` header — valid, per the
  landability property above.
- **Step B — 3-word literals.** `compiler/emitmacho.bit`,
  `compiler/emitelf.bit`, `compiler/emitpecode.bit` append a third word
  (`base = 0`) to every emitted string literal header; symbol size 16 -> 24.
  The existing absolute reloc in slot 0 and `len` in slot 1 are untouched.
- **Step C — the payoff.** `rtStringSlice` is a header-only
  allocation (24 bytes, no byte copy): `ptr = ptr(s) + lo`, `len = hi - lo`,
  `base = s` — sharing `s`'s bytes instead of copying them, which is what
  Step A and Step B alone did not yet buy. `allocStringView` is the one
  allocator for it, beside `allocString`. `base` must be the immediate
  source `s`, not `base(s)`: flattening a chain read is a separate follow-up
  gated on every `libbitrt.a` in the field carrying a 3-word base, since
  reading slot +16 of a 2-word header (any string built before that repin)
  is garbage.

**The interior-pointer objection, and its mitigation — a LIVE constraint, not
a decided-away one.** `ptr` is a stored address into the middle of an
object, never a base pointer, so by §3's rule below it must never be listed
in `ptr_offsets`. Unlike the superseded `{base, len, off}` design — which was
chosen specifically to make this constraint structurally unrepresentable, by
never storing an interior address as a field at all — this layout keeps
`ptr` as a stored field and accepts the constraint. The mitigation is
confinement, not avoidance: `runtime/root/root.bit`'s `strInitOwned` (a
fresh, self-owning string) and `strInitView` (a shared-backing view, Step C)
are the ONLY code allowed to write a string header's words, so "keep `ptr`
out of `ptr_offsets`" is one fact in one file — `ptr_offsets` itself is
written once, by `rootInit` — rather than a rule every future write site has
to re-derive correctly. `gcOwns` (§3) is the collector's own backstop should
that confinement ever be violated: it is exact base-address equality, so an
interior pointer fed to `gcMarkRoot` is rejected outright — a no-op, not a
corruption. Measured directly under `BIT_GC=stress`: forcing
`ptr` into `ptr_offsets` produced 4004/4004 rejections and 0 marks.

**Why `riString`'s declared `size` must be `strAllocHeader` (24), never 0 or
the variable per-object total.** `runtime/gc/gcmark.bit`'s `scanObject`
bounds-checks every traced offset against the type descriptor's declared
`size` before dereferencing it (`off + 8 > size` is rejected and counted,
never read) — the descriptor carries one fixed size, not each object's
actual (header + inline-bytes) length. `strBase` (16) only clears that check
if `size >= 24`, which is exactly the fixed minimum Step A's `allocString`
now guarantees for every `riString`-tagged heap object; the variable part
(the inline bytes) is sized per-allocation via `gcAllocRaw` and is never
what the descriptor's `size` field describes, mirroring how the dynamic
slice header's fixed `slcHeaderSize` already works (§2 above).

**No aliasing hazard, unlike `[]T`.** `[]T` sharing (§2
above) already accepts that a mutation through one view is visible through
every other view of the same buffer. `string` has SPEC §13.3 read-only value
semantics and no mutation path at all (§1.1 above makes the identical
argument for tuples), so two views of the same backing bytes can never
disagree — sharing costs nothing in observable behaviour that `[]T` sharing
did not already cost.

**One accepted, un-mitigated cost — already priced in for `[]T`.** A tiny, long-lived view keeps its ENTIRE backing string alive:
`s[0:1]` on a multi-megabyte `s` retains the whole megabyte for as long as
the view is reachable. This is the identical shape `[]T` reslicing already
accepts in §2 and is not new here.

**The hand-built panic-path headers need NO edit, ever, under this design —
the opposite of what the superseded decision required.** `@nosplit` forbids
allocation (E0075), so several panic-message constructors and one deadlock
constructor assemble a `{ptr, len}` header **by hand** in module-static
scalar arrays and pass its address straight to `bit_rt_panic` — or, for the
two runtime-internal ones (`panicDeadlock` and `runtime/gc/stackmap.bit`'s
pair), to the always-fatal `bit_rt_fatal` instead (§12):

| File | Function | Static array |
|---|---|---|
| `runtime/root/slices.bit` | `panicBounds` | `boundsMsg: [6]i64` |
| `runtime/root/slices.bit` | `panicBadStride` | `badStrideMsg: [6]i64` |
| `runtime/root/maps.bit` | `panicNilMapWrite` | `nilMapMsg: [4]i64` |
| `runtime/chan/chanwrap.bit` | `panicNilChanClose` | `nilChanCloseMsg: [5]i64` |
| `runtime/chan/chanwrap.bit` | `panicClosedChanClose` | `closedChanCloseMsg: [5]i64` |
| `runtime/chan/chanwrap.bit` | `panicSendClosed` | `sendClosedMsg: [5]i64` |
| `runtime/sched/worker.bit` | `panicDeadlock` | `deadlockMsg: [6]i64` (own mirrored `deadlockStrHeaderSize`, not imported — `runtime/sched` cannot import `runtime/root`) |
| `runtime/gc/stackmap.bit` | `panicStackMapBounds` | `smBoundsMsg: [8]i64` (offsets 0/8/16 inlined as literals, not imported — `runtime/root` imports FROM `runtime/gc`, not the reverse) |

Each stays a two-word header, unedited, and stays correct: it is a valid
`{ptr, len}` string by the landability property above, and none of these
arrays carries a `TypeInfo` — they are module state with no descriptor, so
nothing ever scans them looking for a `base` field at +16 in the first
place (the same reasoning this document already gives for `gcState`/
`heapBlock`/`infoBlock` being unscanned). The superseded `{base, len, off}`
decision required widening all eight of these by one word each; this design
needs none of that.

**Verification owed by each step, beyond its own gate.** `string` layout is
`runtime/**`, so per this workspace's standing rule the proof artifact for a
header-write change is `cmp` on `libbitrt-{aarch64-macos,aarch64-linux,
x86_64-linux}.a`, never `bin/bit`, mutation-verified. `BIT_GC=stress` over
the full corpus (`test-golden`, `test-stress-batch`) must show counts EQUAL
to `main`, side by side — a fan-out or gate that silently ran fewer programs
would print the same PASS line with a smaller denominator. Re-run
`selfhost-diffruntime` (the `runtime/**` corpus differential) for any step
that changes emitted `.text`, not just data layout.

---

## 3. Reference contract

- A GC reference is **either null (all-zero) or the body base pointer** of a live
  managed object — the exact value the allocator returned.
- **Interior pointers are not references.** A pointer into the middle of an
  object must never be stored in a slot named by a pointer map (§2) or a stack
  map (§4). The collector assumes every traced/root reference is a base pointer;
  an interior pointer would resolve to a bogus header.
- The runtime exposes `Gc.owns(ptr)` which is true only for a live object's base
  pointer — interior and foreign pointers return false. It backs the debug/test
  check for this contract.
- **Confirmed for a traced field beside untraced derived fields in the same
  object.** A `TypeInfo` may list one field as a traced reference
  (always a base pointer, per this section) while its neighbours in the same
  object are plain integers, or a stored interior address, a reader combines
  with that reference — this is what the dynamic slice header already does
  (`buf` traced via `ptr_offsets = [0]`; `off`/`len`/`cap`/`is_ref` untraced
  integers, §2) and what §2.3's `string` header does too (`base` traced via
  `ptr_offsets = [16]`; `ptr` an untraced, unlisted interior pointer; `len` an
  untraced integer). The rule above is not weakened by this, but §2.3's
  `string` header is the sharper case: unlike the slice header, `ptr` **is** a
  stored derived interior address (the `{ptr, len, base}` ruling,
  superseding the `{base, len, off}` shape this section previously described
  as chosen specifically to avoid storing one at all). Safety rests entirely
  on `ptr` never being listed in `ptr_offsets` — an invariant every future
  writer of the header has to re-uphold, not one this rule enforces
  structurally by itself. §2.3 confines that re-upholding to two functions
  (`strInitOwned`/`strInitView`) as its mitigation, and `Gc.owns` above is the
  runtime backstop if that confinement is ever violated.

---


[Previous: Managed values and object layout](object-layout.md) | [Next: Root scanning and stack maps](stack-roots.md)
