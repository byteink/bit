# Runtime ABI

The binary contract between the **compiler** (codegen) and the **runtime** (GC,
scheduler, channels). Change this document first; codegen and runtime both
implement what it says. Anything not written here is not guaranteed.

Status: v1 covers the garbage collector (`runtime/gc`, §1-8), green-thread
spawn and program entry (`runtime/root`, §9-10), channels (`runtime/chan`
+ `runtime/root`, §11), and panics (§12). The per-callsite stack-map wire
format and the multi-worker stop-the-world barrier are explicitly **not**
frozen here — §4/§5 say why and who owns them next.

Every section below names the **Bit** module that implements it. `libbitrt.a` is
built entirely from `runtime/**/*.bit`.

All layouts below are for 64-bit targets (x86-64, ARM64). Pointers and `usize`
are 8 bytes; the null reference is the all-zero bit pattern.

---

## 1. Managed object layout

Every GC-managed allocation is `header ++ body`:

```
offset  size  field
0       8     info    *const TypeInfo   type descriptor (§2)
8       8     next    ?*GcHeader        runtime-private all-objects list
16      8     size    usize             runtime-private total alloc size
24      1     marked  bool              runtime-private mark bit
        7     (padding)
32      ...   body                      the object's fields
```

- Header size is **32 bytes**, 8-aligned. The body begins at `base + 32`.
- **The reference the compiler works with is the body pointer** (`base + 32`),
  i.e. the value returned by the allocator. Codegen never sees the header; the
  runtime reaches it by subtracting 32.
- `next`, `size`, `marked` are owned by the runtime. Codegen must not read or
  write them, and must not assume their meaning — only `info` and the 32-byte
  offset are stable ABI for codegen. The rest may change with the collector.

### Alignment

- Object base is 8-aligned; body is therefore 8-aligned.
- v1 supports body fields needing **at most 8-byte alignment** (pointers,
  `i64`/`u64`, `f64`). Over-aligned fields (SIMD, 16-byte) are out of scope; add
  an over-aligned allocation path when a type needs it.

### Initialization

- The allocator returns a **zeroed body**. Every pointer field therefore reads as
  null until codegen stores into it. This is required: a collection may occur at
  any safepoint between allocation and field initialization, and tracing must
  never follow an uninitialized slot.

### 1.1 Aggregates and multi-value returns

A **tuple is a boxed managed record**, laid out by exactly the same rules as a
class: elements in declaration order, each aligned to its own size, `[N]T`
elements inlined, body size rounded up to 8, and every element holding a GC
reference listed in the type's `ptr_offsets` (§2). A tuple's `TypeInfo` is keyed
by its `TypeId` like any other type, so two tuples with identical element types
are the same type and share one descriptor. Codegen sees a tuple exactly as it
sees a class: one 8-byte traced handle.

**A `ret` therefore carries at most one value.** `return a, b` in a function
whose result type is `(A, B)` allocates a 2-element tuple record, stores the
elements into it, and returns that single reference. Destructuring
(`let (a, b) = f()`) and element access (`t.0`) read the elements back with
ordinary field loads at the layout's offsets.

**Why this and not a register pair or a hidden out-pointer.** Both alternatives
would change the calling convention — the caller/callee register contract, the
stack-map shape at call sites (§4), and every backend's prologue/epilogue — to
buy nothing the boxed form does not already provide. The boxed form needs **zero
calling-convention change**: it reuses `gc_alloc` + `field_set` / `field_get`,
which are already exercised by every class in the language, and it inherits
correct GC tracing for free because the tuple's `ptr_offsets` describes its
elements the same way a class's does. A register pair would additionally need a
rule for tuples wider than the return-register budget, reintroducing a spill path
that the boxed form never has. The cost is one allocation per multi-value return;
that is the same cost a class return already pays, and it is the price of the
uniform "every aggregate is one traced handle" model this ABI is built on.

This is not a new constraint being imposed on codegen — it is the contract
codegen already implements. All four backends refuse a multi-value `ret` today
(the codegen backends' `emitRet` / `.ret`,
`compiler/x64.bit` `xEmitRet`, `compiler/arm64.bit` `Op.Ret`). Boxing in the
lowerer is what makes that refusal unreachable rather than what works around it.

**Element mutability.** Tuple elements are **read-only** (SPEC §12.5): `t.0` may
be read but not assigned. That is what keeps the boxed representation faithful to
the value semantics SPEC §13.3 declares for tuples — with no way to mutate an
element, a shared box is indistinguishable from a copy, the same argument the
spec already makes for `string`. Boxing a *mutable* tuple would silently convert
a declared value type into a reference type.

---

## 2. Per-type pointer maps (`TypeInfo`)

The compiler emits one static `TypeInfo` per distinct (monomorphized) type and
passes a pointer to it at each allocation site (`bit_rt_gc_alloc`, §6).

```
TypeInfo {                       // extern class, 56 bytes, 8-aligned
    size            : usize      // body size in bytes, excluding the header
    ptr_offsets_ptr : [*]const usize  // -\ byte offsets of GC-ref fields
    ptr_offsets_len : usize           // -/ (ptr_offsets_ptr[0..ptr_offsets_len])
    name_ptr        : [*]const u8     // -\ static type name; debug/stats only
    name_len        : usize           // -/ (may be empty: name_len == 0)
    methods_ptr     : [*]const Method // -\ this type's methods, for interface
    methods_len     : usize           // -/  dispatch (§2.1; may be empty)
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

`methods` lists every method the concrete type defines, for structural
interface dispatch (SPEC §14). Each entry is:

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
  the name id a sufficient dispatch key.
- Each method's `fn` takes the receiver (the object body pointer) as its leading
  argument, then the call's own arguments — identical to a static method call.
- Entries are unordered; `methods_len` may be 0 (a type with no methods).

Dispatch (`call_iface value.id(args)`): codegen first tests `value` for null
and panics via `bit_rt_panic_nil_iface` (§12.1, #2240) if so — `value` IS the
receiver pointer, and a nil interface is a legal, checker-blessed zero value
(SPEC §13.4) with no `TypeInfo` to load `-32` bytes from. Only once that
passes does the callee load `info = *(value - 32)` (the header's `info`
field, §1), then `fn = bit_rt_iface_lookup(info, id)` (§9), then call
`fn(value, args...)`. `bit_rt_iface_lookup` linearly scans `info.methods` for
`id` — types have few methods, so this is a short, allocation-free walk —
and returns the code address. The checker guarantees a NON-NIL receiver
satisfies the interface, so the id is always present there; a miss is a
compiler bug and traps.

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

**Element storage: word-per-element by default, byte-packed only for `[]u8`.**
A GC reference is word-sized, and when `is_ref` the collector traces every word
of the element buffer as a root (below) — so a reference-typed buffer can never
pack: decoding packed scalar bytes as a reference would be a silent-wrongness
bug, not a crash, and this invariant forbids it by construction. Packing is
scoped narrower still: only `[]u8` (a non-ref, 1-byte element) packs to one
byte per element (`elem_size = 1`, §9). Every other element type — every
`is_ref == true` buffer, and every non-ref scalar 2 bytes or wider (`i16` and
up, `f64`, boxed values) — stays word-per-element (`elem_size = 8`) exactly as
before. Packing wider non-ref scalars (`i16`/`i32`/`bool`/...) is explicitly
future work; this document does not authorize it.

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

### 2.2 Type assertions

Because an interface value *is* the receiver pointer, its dynamic type is the
`TypeInfo` in that object's header — and descriptors are **per concrete type**
(§2), so descriptor identity is type identity. A type assertion (SPEC §14.4) is
therefore a pointer comparison against the target type's descriptor, whose
address codegen materializes from the `type_info` IR op (the same
`__bittype_<disc>_<size>_<offsets>` symbol `gc_alloc` references).

```
bit_rt_iface_as(recv: ref, want: usize) -> ref        // recv on match, else null
bit_rt_iface_as_ok() -> bool                          // ok of the iface_as just before it
bit_rt_iface_assert(recv: ref, want: usize) -> ref    // panics on mismatch
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
  fallible-call error slot (§13) are safe at any worker count. Until #3280
  this was a single process-wide flag and that was a live gap; see §22's
  audit and §5's note on what adjacency does and does not buy.
- `bit_rt_iface_assert` names both types in its panic message; the descriptors
  already carry them.

### 2.3 `string` value, and shared-backing views (`s[lo:hi]`, DECIDED #3123)

**v1 today.** A `string` is a pointer to a `gc_alloc`'d 16-byte header
`{ptr, len}` (`runtime/root/root.bit`'s `strPtr`/`strLen`/`strHeaderSize`)
immediately followed by its bytes, with `ptr` addressing those inline bytes.
The object is a LEAF (`TypeInfo{ size = 0, ptr_offsets = [] }`, sized per
allocation via `gcAllocRaw`) — `ptr` is an interior pointer into the object
itself, never a separate reference, which is why `bit_rt_string_slice`
(`s[lo:hi]`, SPEC §12.6) **copies**: a shared view's `ptr` would be an
interior pointer into a *different* object with nothing in the view keeping
that object alive. That copy is measured at 75.7% of the `strings` benchmark.
This section decides the replacement layout; the code has not moved yet.

**Decision: a three-word header, `{base, len, off}`, 24 bytes.**

```
string header {                  // TypeInfo{ size = 24, ptr_offsets = [0] }
  base : ref     // +0   traced — the object that owns the inline bytes
  len  : usize   // +8   this view's byte count (same offset v1 used)
  off  : usize   // +16  byte offset of this view's first byte, from base's body
}
```

- `base` is the **only** traced field (`ptr_offsets = [0]`) — the same offset
  and the same "one traced backing reference" convention §2's dynamic slice
  header already uses for `buf`. For a freshly built string (every
  `allocString` call site below) `base` is the string's **own** address, so its
  bytes stay inline immediately after the header exactly as v1 stored them —
  nothing about a fresh string's memory shape changes except the header
  growing by one word. For a view produced by `s[lo:hi]`, `base` is the ROOT
  string that actually owns the bytes, **never an intermediate view**: `rtStringSlice`
  reads `base(s)` (flattened, not `s` itself) so a chain `s[a:b][c:d]` still
  costs the tracer one hop, not a chain of hops.
- `len` stays at **+8**, unchanged from v1 and identical to the dynamic slice
  header's `len` offset — the existing claim in §2 above ("`len(s)` reads the
  header word directly ... shared with the `string` header") continues to
  hold with no further change.
- `off` at +16 is a **plain byte count, not a pointer**: the view's first byte
  is at `base + strHeaderSize + off`, computed at the read call site exactly
  the way a slice computes `buf + off*elem_size` (§2 above) — an address is
  never stored, only ever derived in a register. `bit_rt_string_slice` becomes
  a **header-only allocation** (`gcAlloc`, 24 fixed bytes, no byte copy) that
  sets `base = base(s)`, `off = off(s) + lo`, `len = hi - lo` — field for
  field the same shape `bit_rt_slice_slice` (`runtime/root/slices.bit`) already
  uses for `buf`/`off`/`len`. Note the field layout is a literal prefix of the
  slice header (`buf`/`len`/`off` at the same +0/+8/+16): `string` needs no
  `cap` (never grows) and no `is_ref` (never holds references), so it stops at
  three words where slice needs five.

**Why `{base, len, off}` and not the `{ptr, len, base}` shape #3123's parent
ticket named.** Both cost the same 24 bytes and the same one `gc_alloc` per
reslice. The `{ptr, len, base}` shape stores a raw interior address in `ptr`
and keeps it safe only by never listing `ptr` in `ptr_offsets` — correct, but
it is one more fact a future editor of `allocString`/`rtStringSlice` has to
keep re-deriving correctly at every write site. The `{base, len, off}` shape
used here removes the interior pointer as a **stored value** entirely: nothing
this object ever holds is an address into another object's middle, so there is
no derived pointer for a future `ptr_offsets` edit to mis-list. See §3 below
for how this changes (or rather, does not change) the interior-pointer rule.

**No aliasing hazard, unlike `[]T`.** `[]T` sharing (§2 above) already accepts
that a mutation through one view is visible through every other view of the
same buffer. `string` has SPEC §13.3 read-only value semantics and no mutation
path at all (§1.1 above makes the identical argument for tuples), so two views
of the same backing bytes can never disagree — sharing costs nothing in
observable behaviour here that `[]T` sharing did not already cost.

**One accepted, un-mitigated cost, already priced in for `[]T`.** A tiny,
long-lived view keeps its ENTIRE backing string alive: `s[0:1]` on a
multi-megabyte `s` retains the whole megabyte for as long as the view is
reachable. This is the identical shape `[]T` reslicing already accepts in §2
and is not new here. No mitigation (a copy-below-some-threshold escape hatch)
is adopted by this decision — see Option 2 below — a follow-up ticket that
wants one should propose it against a working shared-backing baseline, not
fold it into the ABI layout.

**Alternatives named on the parent ticket, and why each was rejected:**

- **Option 2 (inline small strings / copy below a size threshold).** Still
  pays an O(n) copy for every substring **above** the threshold — exactly the
  size range a benchmark slicing large buffers in a loop spends its time in —
  so it lowers the constant without removing the cost class, while adding a
  second on-disk string shape every one of the nine readers below would have
  to branch on.
- **Option 3 (keep `s[lo:hi]` copying; ship only non-allocating stdlib range
  primitives).** Correct and by far the simplest, but leaves the operator SPEC
  §12.6 and this ticket's own benchmark both name — `s[lo:hi]` written
  directly — exactly as slow as today; it only helps call sites that happen to
  route through a stdlib function instead of the slice syntax itself.

**The six hand-built headers on the panic path never call `allocString`.**
`@nosplit` forbids allocation (E0075), so five panic-message constructors and
one deadlock constructor assemble a `{ptr, len}` header **by hand** in
module-static scalar arrays and pass its address straight to `bit_rt_panic`:

| File | Function | Static array |
|---|---|---|
| `runtime/root/slices.bit` | `panicBounds` | `boundsMsg: [6]i64` |
| `runtime/root/maps.bit` | `panicNilMapWrite` | `nilMapMsg: [4]i64` |
| `runtime/chan/chanwrap.bit` | `panicNilChanClose` | `nilChanCloseMsg: [5]i64` |
| `runtime/chan/chanwrap.bit` | `panicClosedChanClose` | `closedChanCloseMsg: [5]i64` |
| `runtime/chan/chanwrap.bit` | `panicSendClosed` | `sendClosedMsg: [5]i64` |
| `runtime/sched/worker.bit` | `panicDeadlock` | `deadlockMsg: [6]i64` (own mirrored `deadlockStrHeaderSize`, not imported — `runtime/sched` cannot import `runtime/root`) |

Under this layout each array grows by one word to carry `base`, and each
constructor stores its **own** `ptrOf(...)` address into that word
(self-referential, `off = 0`, exactly the "fresh string" convention above).
That self-reference is inert to the collector for two independent reasons
already load-bearing elsewhere in this document: these arrays are module
state with no `TypeInfo`, so nothing ever scans them as an object with
`ptr_offsets` in the first place (the same reasoning `runtime/root/root.bit`
already gives for `gcState`/`heapBlock`/`infoBlock` being unscanned); and
every function on this call path — `panicBounds`, `panicNilMapWrite`,
`panicNilChanClose`, `panicClosedChanClose`, `panicSendClosed`,
`panicDeadlock`, then `bit_rt_panic` → `panicWrite`/`strBytesOf` →
`rootWriteAll` — is `@nosplit`, so no safepoint is ever reached and no stack
map is ever asked to describe the local holding that address as live (§4). A
foreign, non-`owns()` address in a nominally-traced slot that is never
actually offered to a scanner is the same tolerated shape §4 already
documents for a `chan` handle or bare-function value.

**Implementation plan for follow-up tickets** (every `strBytes`/`strSize`
reader found by grepping `runtime/` for `strBytes|strSize|strData|strLenOf|
strPtr|strLen` — nine reader implementations across eight files, not an
estimate):

1. **Header constants + canonical funnel — `runtime/root/root.bit`.** Rename
   `strPtr` (0) to `strBase` (0, unchanged offset); keep `strLen` at 8; add
   `strOff: int = 16`; `strHeaderSize` 16 -> 24. Rewrite `strBytes`/`strSize`
   (the two functions, ~line 591/599) for the new arithmetic (the `s == 0` null
   guard is unchanged). `allocString` (~line 510) additionally stores
   `body -> strBase` and `0 -> body + strOff` after computing `body`; its
   `gcAllocRaw(strHeaderSize + nbytes, ...)` call needs no other change, and
   because every OTHER fresh-string constructor in the tree (10 call sites:
   `floats.bit:172`, `strings.bit:10,164,211,235,246,295,312`, `iface.bit:149`,
   plus `strings.bit:305 rtStringFromBytes`) already funnels through
   `allocString`, none of them need their own edit. Add a `riStringOffs` slot
   to `infoBlock` (mirroring the existing `riSliceOffs`/`riMapOffs` slots,
   `~line 257-265`), write `[0]` into it, and change the `riString` `writeInfo`
   call (`~line 409`) from the current all-zero leaf entry to
   `writeInfo(base, riString, strHeaderSize, base + riStringOffs*8, 1, 0, 0)`;
   grow `riWords`/`infoBlock: [46]i64` by the one added word.
2. **The view constructor — `runtime/root/strings.bit`, `rtStringSlice`
   (~line 105-125).** Replace `allocString` + `copyBytes` with `gcAlloc(g, base
   + riString*8)` (fixed 24-byte header) and the three `storeWord`s described
   above, mirroring `runtime/root/slices.bit:374-397`'s `rtSliceSlice` exactly.
   Range-check and null-header behaviour (panics via `oobStringRange`,
   `#2014`) are unchanged.
3. **Six module-private duplicate read funnels** — each is its own copy
   because it lives in a module that cannot import `runtime/root`'s privates
   (documented at each site) and each needs the identical two-line rewrite as
   `strBytes`/`strSize`: `runtime/root/linux/io.bit` `strBytesOf`/`strSizeOf`
   (~444/452), `runtime/root/darwin/io.bit` `strBytesOf`/`strSizeOf`
   (~392/400), `runtime/net/linux/netabi.bit` `strData`/`strSizeOf`
   (~123/127), `runtime/net/darwin/netabi.bit` `strData`/`strSizeOf`
   (~112/116), `runtime/root/linux/fs.bit` `strData`/`strLenOf` (~119/120),
   `runtime/root/darwin/fs.bit` `strData`/`strLenOf` (~128/129).
4. **Two inline (non-funnel) readers.** `runtime/rand/linux/random.bit:83` and
   `runtime/rand/darwin/random.bit:86` import `strPtr` directly and compute
   `loadWord(s + strPtr)` inline; change the import to `strBase`/`strOff`/
   `strHeaderSize` and the expression to
   `loadWord(s + strBase) + strHeaderSize + loadWord(s + strOff)`. `s` here is
   always the just-allocated result of `rtStrAlloc`, so this is provably `s +
   strHeaderSize` today, but the general form is what stays correct once
   `rtStrAlloc` can itself return the result of a call that later became a view
   — write the general form, not the specialization.
5. **Six hand-built pseudo-headers** (table above): widen each static array by
   one `i64` word and add one `storeWord(base + strBase, base)` (or, for
   `panicDeadlock`'s raw-pointer style, `*msg = base`) alongside the existing
   `len`/text stores; `deadlockStrHeaderSize` in `runtime/sched/worker.bit`
   moves 16 -> 24 in lockstep with `strHeaderSize` since it is a deliberate,
   documented mirror rather than an import.
6. **Verification the follow-up ticket owes, beyond its own gate.** Mutation
   test `rtStringSlice`: force a collection (`BIT_GC=stress`) between
   constructing a view and reading it, and between dropping every other
   reference to the source string and reading the view, confirming the bytes
   survive — the shape `tests/stress/gcworld` already exercises for the #1991
   defect this section's `base` field is specifically designed to avoid
   repeating. `string` layout is `runtime/**`, so per this workspace's standing
   rule the proof artifact is `cmp` on `libbitrt-{aarch64-macos,aarch64-linux,
   x86_64-linux}.a`, never `bin/bit`. Re-run `selfhost-diffruntime` (the
   `runtime/**` corpus differential) since this changes emitted `.text` for
   every listed function, not just data layout.

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
  object (#3123).** A `TypeInfo` may list one field as a traced reference
  (always a base pointer, per this section) while its neighbours in the same
  object are plain integers a reader combines with that reference to *derive*
  an address — this is not a new case, it is what the dynamic slice header
  already does (`buf` traced via `ptr_offsets = [0]`; `off`/`len`/`cap`/
  `is_ref` untraced integers, §2) and what §2.3's `string` header does
  identically (`base` traced; `off`/`len` untraced integers). The rule above
  is not weakened by this: no interior pointer is ever *stored* in either
  header, so there is nothing for `ptr_offsets` to omit incorrectly. A design
  that instead stores a derived interior address as its own field (the
  `{ptr, len, base}` shape §2.3 considered and did not choose) would still
  satisfy this section — but only if that field is never listed in
  `ptr_offsets`, which is an invariant every future writer of the header has
  to re-uphold rather than one this rule enforces structurally. §2.3 chose the
  derive-on-read shape for exactly that reason.

---

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

**Register file.** A function containing any safepoint restricts its allocatable
registers to the callee-saved subset only (x86-64 `rbx`/`r13`/`r14`/`r15`;
AArch64 `x19`..`x28`), so any live reference at a safepoint is in one of those
registers or spilled to a frame slot — never a call-clobbered register. This is
what makes the walk below tractable: callee-saved values are recoverable by
unwinding, call-clobbered ones would be lost.

**Snapshot.** Collection only ever runs from `bit_rt_safepoint` (below), which is
a naked shim that records the caller's return address, frame pointer, and
callee-saved registers *before* any runtime code can overwrite them. The frame is
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
stack would go unscanned again with no error and no red gate (#1834).

The snapshot's `regs` array is **not** zeroed (the shim runs at every loop
back-edge; clearing 32 words per poll is not free). Only the callee-saved file is
written. That is sound in both directions: the register file restriction above
means a stack map can only ever name a register the shim *did* save, and every
word the walk reads is routed through `markRoot`, which marks it only if it is
exactly a live object base. An unwritten slot can therefore neither be read as a
root nor be mis-decoded if it were.

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

Entry atoms are **8-aligned** (#1927): the writer follows every entry's fields
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

Before #1927, entries were 1-aligned and tightly packed with no padding at
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
  u8 pad[0..7]          # zero bytes bringing this entry's total length to a
                         # multiple of 8; the walker recomputes the count by
                         # rounding its cursor up, not by reading a length field
```

**The producer and the reader are separate build inputs, and this format's
correctness depends on them agreeing (#3198).** The padding above is written by
whichever compiler emitted an object (`compiler/codegen.bit`'s
`writeStackMaps`) and read by whichever `runtime/gc/stackmap.bit` this tree
currently has — two different build stages, not one. The default
`./make libbitrt` path compiles `runtime/**` with the *pinned stage0*, a
previous release's compiler frozen at build time, while the reader is always
the working tree's current source. A stage0 built before #1927 landed emits
unpadded, 1-aligned entries; the tree's post-#1927 reader unconditionally
rounds every entry's cursor up to 8 regardless of what the writer did — the
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

**#3189 (designed, not yet shipped): a per-entry format-version stamp.** The
padding checker above is a build-time guard for one specific historical skew;
it does not generalize to the *next* layout change, and #1927 reached
production as a silent bus error before any guard existed for it at all. The
designed fix is a `u16` version field placed right after `code_addr` (so the
field the object writer's relocation logic depends on — `code_addr` sitting
at each entry's offset 0 — is untouched, and neither `emitmacho.bit` nor
`emitelf.bit` needs to change), checked by the reader before any
count-driven field (`num_saved`, `num_safepoints`, ...) is trusted. A
mismatch panics by name with both versions, using the same idiom as
`panicStackMapBounds` above rather than a fixed literal message, since the
two numbers are runtime values read off the blob. `runtime/gc/stackmap.bit`
carries the reader half (`smFormatVersion`, `panicStackMapVersion`,
`appendDecimal`) as of this note, proven against a synthetic blob through a
temporary C-driver hook (#1839's technique) in both directions — match walks
normally, mismatch refuses with `"gc: stack-map format version mismatch:
expected <E>, found <F>"` — but is **not yet wired into `scanFrame`'s live
parse**, because the writer half (`compiler/codegen.bit`'s `writeStackMaps`
emitting the same stamp) has to land in the same change: this format's
correctness already depends on the writer and reader agreeing (the paragraph
above), so widening the reader's expected entry-header size without the
writer emitting the new field would desync every entry of every program, not
just a mismatched one. See #3189 for the exact writer diff.

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
rendezvous, and removing the attribute is what took `tests/stress/schedpool` from
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

### 4.2 Debug-info line table (designed, not yet emitted — #3281)

Decided by #3281 (`spec/SPEC.md` §18.6.1: bespoke over DWARF, and why). The
walker that symbolizes a panic (#3285) reads a second, independent side table,
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
per-function header (16 bytes) and each row (16 bytes) are already multiples
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

**`format_version`, shipped from the first line, not retrofitted.** #3189
designed (but has not yet shipped) a version stamp for `.bit_gc` after #1927
reached production as a silent bus error with no guard at all — producer and
reader are different build stages (`libbitrt`'s own entries come from the
pinned stage0; every other entry in the same link comes from whatever
compiler built it), and this table has the identical exposure. Rather than
repeat that retrofit, the walker reads and compares `format_version` *before*
trusting `code_size`, `num_rows`, or any row — placed immediately after
`code_addr`, the same position #3189 chose, so the one field the relocation
logic depends on sitting at offset 0 is undisturbed. A mismatch does **not**
call `bit_rt_panic` (below): it is treated exactly like "no record."

**File references reuse the existing string pool, interned per object.**
`module.stringPool` (`compiler/ir.bit:410`) is not deduplicated today — every
`append` adds a new entry regardless of content. A debug-info emitter that
called that path once per row would emit the same file path hundreds of
times. The emitter must intern each distinct source file path **once per
object** (a small map from path to the string-pool header symbol already
emitted for it), so every function's rows in the same file share one 16-byte
header. This is required for the format's size to be what SPEC §18.6.1
measures, not an optional optimization.

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
   step 1). **#3283 must not skip this**: if codegen reorders basic blocks
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

---

## 5. Safepoints and stop-the-world

- v1 is **stop-the-world**: no mutator observes the heap mid-collection.
- A **safepoint** is a program point where the stack maps are valid and the
  mutator may yield to the collector. Codegen inserts safepoint polls (at least at
  loop back-edges and function entry/allocation) so collection cannot be starved.
- The collector never moves objects (non-moving mark-sweep), so references are
  stable across a collection and no pointer fix-up is required.

**The stop-the-world handshake.** "Stop the world" is a real rendezvous, not an
assumption about there being one thread. Any number of OS threads may execute Bit
code concurrently and reach safepoints concurrently.

Every OS thread that runs Bit code is a **mutator**, holding one slot in a fixed,
statically sized registry (no allocation after startup; a slot is claimed by
`bit_rt_gc_thread_enter` and released by `bit_rt_gc_thread_exit`). A slot is in
one of three states:

**THE REGISTRY BLOCK IS `runtime/gc`'s OWN MODULE STATE, AND THERE IS NO WAY TO
SUPPLY ONE (#1991/#2184).** `runtime/gc/gcworldsync.bit` declares `worldBlock`
and `syscallRegBlock`; `bit_rt_gc_world_ready` tells it boot has finished, and
carries no address. `bit_rt_gc_world_addr` reads the block's address back out and
answers 0 until readiness — which is what every door tests before reading a
thread token, because the x86-64 token is a `%fs:0` load that faults on a thread
whose FS base is not installed yet.

There used to be a `bit_rt_gc_world_bind(addr)` taking the block's address as a
plain integer. That is what #1991 was. A bound address is invisible to the
collector — not a root, never traced, never rewritten — and there was no unbind,
so handing it managed memory type-checked, linked and ran until a collection
swept the block, after which every safepoint poll in the process read freed
memory. `tests/stress/gcworld` did exactly that: bound a `[]i64` slice, printed
all 29 of its assertions correctly, then took a SIGSEGV at teardown once `main`
returned. Keeping the slice live through `main` does not help; the faulting reads
happen after `main` returns.

The block is module state now, so the lifetime invariant holds by construction
and there is nothing left to check. The door that remains cannot be misused
because it carries no address.

A program that wants a **private** registry passes its own block to the
parameterised doors (`bit_rt_port_stw_poll_on`,
`bit_rt_port_gc_current_mutator_on`), which never touch the process-wide
**registry block** — the rule #1833 established and `tests/stress/stwcollect`
follows. #1833's defect was a private caller REPLACING the live runtime's own
address binding, so its own worker registered into the wrong registry entirely;
"never touch" is about that block/binding, not about every word this file's
module state holds. The per-thread poll hint (`mutHintSlot`, #1698/#2821) IS one
process-wide word shared by both the global and the parameterised doors, and
that is deliberate, not a hole in this rule: it never identifies which registry
to consult (the `world` parameter always does that) and it is re-validated
against THIS call's own registry before being trusted, so a hint left by a poll
against the other registry can only miss and fall back to the exact search,
never answer wrongly.

```
running   executing Bit code; may reach a safepoint at any moment
parked    stopped at a safepoint, its snapshot published for the collector
blocked   inside a call that holds NO live Bit references (see below)
syscall   stopped in the kernel, holding live references; scanned in place (below)
```

**REGISTRATION IS LAZY, BUT "A THREAD IS NEVER INVISIBLE" IS FALSE AS A BLANKET
CLAIM — IT IS FALSIFIED, NOT MERELY UNCONFIRMED (#1677).** A thread claims its
slot on its **first touch of the collector by either door** — any allocation, or
its first safepoint poll. Before that first touch the thread holds NO slot:
`rendezvous` does not wait for it, no snapshot exists for it (root classes 2/3,
§4, do not apply), and — if the thread is not itself a scheduler-registered
green task — the conservative task-stack scan below does not apply to it
either. A thread that becomes the **sole holder of a live reference** during
this window — reading it out of shared/module state whose other copy is then
cleared, with no allocation and no loop back-edge crossed since the thread
started — is invisible to every root class this file documents, and a
concurrent collection running on an already-registered mutator elsewhere WILL
sweep it.

This is not hypothetical. #1677 built a reproducer: a raw OS thread (started via
`runtime/thread`'s `threadStart`, the same primitive `runtime/root/<os>/boot.bit`
uses to start the scheduler's own worker) whose first statements read a live
object's sole address out of an otherwise-cleared mailbox and hold it in a local
while another, already-registered mutator forces real collections under
`BIT_GC=stress`. The object was swept and its memory reused every one of 20/20
runs. A mutation-test control — adding one allocation to the thread before the
hand-off, so it registers first — flips the result to "survives" every time,
confirming the window is exactly the pre-registration gap and nothing else.

The window is narrow (a thread must hold a reference nowhere a root class
covers, before its first door-touch, while a collection completes) but it is
real, and it is exactly what `runtime/sched/worker.bit`'s `Worker.run` closes by calling
`gc_hooks.threadEnter()` **eagerly** at OS-thread entry rather than relying on
lazy registration alone. The Bit port dropped that eager call (#1671) on the
reasoning that lazy registration was sufficient on its own; #1677/#1699 correct
that — the eager call is being restored at OS-thread entry points, measured for
`abandoned`-count regression on all three targets (#1699). Calling
`bit_rt_gc_thread_enter` explicitly at a thread's start is not merely
"preferred", it is what closes this gap; a thread that skips it is exposed for
as long as its first door-touch is delayed.

The allocation door is the one that matters, and it means *every* allocation
entry point, not just `bit_rt_gc_alloc`: strings, slice headers, slice buffers,
slice growth, map control blocks, map headers and select-case buffers all
allocate, and a thread can reach any of them long before its first loop back
edge. A runtime that registers at only some of them has threads that allocate
while the rendezvous does not wait for them and the root scan cannot see them —
their live objects are swept underneath them. (`runtime/root/root.bit` funnels all of these
through two wrappers so the invariant is checkable by grep; #1431 is what
happens when it is not.)

**A parked slot counts as stopped only for the stop it acknowledged.** Each stop
carries a monotonically increasing **epoch**, and a mutator records the epoch it
parked *for*. `rendezvous` treats a `parked` slot as stopped only when its
acknowledgement matches the epoch being collected for. Without this, a thread on
its way out of a *previous* stop still reads as `parked`, so the next collector
passes it and begins marking while it resumes and mutates — with its snapshot
already cleared, so nothing is scanned for it. `blocked` slots are passed without
acknowledging, which is exactly what the `blocked` contract below buys, so a
thread leaving `blocked` must instead re-check the stop flag before it runs.

At a safepoint poll each mutator does exactly one of:

1. **A stop is already requested** — publish the snapshot, go `parked`, and wait
   until the stop clears. This is how a thread yields to someone else's
   collection.
2. **No stop is requested and the allocation trigger is not crossed** — return.
   This is the overwhelmingly common path and costs one atomic load.
3. **The trigger is crossed** — try to become the collector: take the
   world lock, request the stop, wait for every *other* `running` mutator to
   reach `parked`, collect, then clear the stop and release. A thread that
   fails to take the lock parks instead of spinning, so it can never hold the
   lock's winner hostage.

**A collection that cannot achieve a full stop is abandoned, never forced.** The
rendezvous wait is bounded (Power-of-10: every loop is); on expiry the collector
clears the stop request, releases every parked thread, and returns *without*
collecting. Skipping a collection is always safe — the heap simply grows to the
next trigger — so correctness never depends on the rendezvous succeeding, and no
blocking mutator can deadlock the collector. Abandonments are counted and
reported by `BIT_GC_STATS=1`.

**Roots under the handshake.** The collecting thread walks its own stack
precisely from its own snapshot (§4); every *other* `parked` mutator is walked
precisely from the snapshot it published; parked green tasks are scanned
conservatively from the registry as described below. `blocked` mutators are
neither waited for nor scanned.

**The `blocked` contract, and its one precondition.** `bit_rt_gc_blocking_begin`
/ `_end` bracket a region in which the calling thread **holds no live Bit
references in any of its frames**. The collector then neither waits for that
thread nor scans it. This exists for one shape: a scheduler worker that has no
task on it and is about to sleep on an idle backoff. Without it, an idle sleeping
worker would hold up every collection for the length of its sleep. Calling it
around a region that *does* hold references is a collector bug — the references
are invisible and will be swept.

**The boot thread (#1660; the ABI names confirmed by #2542, not duplicated).**
The OS thread that runs `boot` is itself a registered mutator, not exempt from
the rendezvous. Its wait for `main` to finish — an exponential-backoff
`parkSleepNs` loop — must bracket the sleep, and only the sleep, with
`bit_rt_gc_blocking_begin` immediately before it and `bit_rt_gc_blocking_end`
immediately after: the same pair the `blocked` contract above already names, no
separate boot-specific primitive exists or is needed. Across that bracket it
must hold no live Bit reference in any frame, because the collector does not
scan a blocked thread's stack — the precondition holds because `boot` allocates
nothing on the managed heap before `main` starts, so everything live across the
wait is a scalar or a raw pointer into module state, never a heap reference. The
two call sites are `runtime/root/darwin/boot.bit`'s step-7 loop and, on Linux,
`runtime/root/linux/boottail.bit`'s (the same loop, split out of
`runtime/root/linux/boot.bit` by #2882).

**The `syscall` contract (#1904).** `bit_rt_gc_syscall_begin` / `_end` bracket a
region in which the calling thread blocks in the kernel **while still holding
live Bit references**. It is the state `blocked` cannot express and `running`
cannot afford: the collector neither waits for the thread (like `blocked`) nor
skips it (unlike `blocked`) — it scans the thread where it stands.

`_begin` publishes the two things a conservative scan needs and a `@nosplit`
frame cannot supply precisely, since such code carries no stack map:

- the calling thread's **stack pointer**, which lowers the scan's bound from the
  task's `ctxSp` (where it last *parked*, arbitrarily far above where it now is)
  to where it actually stands;
- its **callee-saved integer registers**, because a live reference the allocator
  parked in one of those is on no stack at all — the #1742 defect exactly.

The two overlap deliberately. If an intervening frame clobbered a callee-saved
register, the ABI required it to spill the original above the published `sp`
first, so the stack walk covers what the register snapshot missed.

PRECONDITION: the thread really does block, and runs no Bit code and pushes
nothing below the published `sp` until `_end`. A thread that kept running under
this state would be scanned from a stale bound — the same class of bug as
claiming `blocked` while holding references. `_end` re-checks the stop flag
before running, like `blocking_end`, because a `syscall` slot is passed without
acknowledging.

**Known limitation, narrowed by #1904 but not closed.** Blocking runtime calls
made *from* Bit code (`bit_rt_print` on a full pipe, `bit_rt_fs_read` on stdin,
`bit_rt_net_resolve`'s DNS timeout) mostly do **not** use either contract: their
frames legitimately hold live references, so `blocked` is wrong, and they have
not been converted to `syscall`. Such a thread stays `running`, so a concurrent
collection waits for it and abandons if it exceeds the rendezvous bound. That is
safe but wastes a collection.

`bit_rt_os_run`'s `waitpid` and the bounded variants' poll sleep WERE converted,
and they were the expensive ones: a subprocess wait holds the whole world for the
child's lifetime. Measured before, under `./make test`, at 21 abandoned
rendezvous per completed collection; 0 after. The remaining call sites are the
same refinement applied to the same pattern.

The same limitation covers a thread asleep in `parkSleepNs`, and there the cost
is proportional to the sleep: every concurrent collection waits out whatever is
left of it. The Linux provider therefore drops the calling thread's timer slack
(#1439), because the kernel's 50us default rounded a 1us sleep to ~75us and made
that wait two orders of magnitude larger than the sleep actually asked for. That
narrows the tax; it does not remove it, and a caller that genuinely sleeps for
milliseconds still holds up every collection for its whole sleep.

**Live-task registry and parked stacks.** The scheduler keeps every task on an
all-tasks registry (`Scheduler.registerTask`, from `spawn` until the task's
`.done` teardown). At a collection the running task's stack is walked precisely
(§4); every *other* registered task's stack is scanned **conservatively** —
every 8-byte word in `[ctx.sp, stack_top)` that is exactly a live object base
(`Gc.markConservative`) is treated as a root. This is sound because a parked
task's live callee-saved references are all spilled to its own stack by the
runtime call chain that parked it (a channel op → `park` → context switch), so
they lie within that range; the non-moving collector makes a false positive
merely retain garbage, never corrupt. Precise per-frame maps for parked tasks
(instead of the conservative scan) are a later refinement.

**This soundness argument is scoped to a task that has actually parked at least
once.** A task that has been scheduled but never yet switched into and out of —
`ctx.sp` still holds the value set at task creation, not a genuine snapshot of
where its frames currently are — is on the registry but the conservative scan
of `[ctx.sp, stack_top)` covers essentially none of its real stack while it
runs. The Bit port's `runtime/sched/worker.bit` can dispatch straight into an
already-queued task on a fresh OS thread before that thread's own run-loop
back edge is ever reached (#1677's finding, stated there for the OS-thread
registry rather than this one, applies identically here): the same "holds no
live Bit references before its first door-touch" gap. #1699 tracks closing
both with the same eager-registration fix.

### 5.1 The adjacency contract: what it guarantees, and what it never did

Several ABI entry points split what is logically a two-result operation into a
pair of calls — `bit_rt_iface_as`/`bit_rt_iface_as_ok` (§2.2),
`bit_rt_chan_recv`/`bit_rt_chan_recv_ok` (§11), and the fallible-call error
slot's set/get pair (§13) — and rely on codegen emitting the pair back to
back, with no safepoint poll and no yield between them. That property is the
**adjacency contract**: the second call always observes exactly the outcome
the first call just produced, because nothing can run on that same task in
between.

**What it guarantees.** Ordering of a call pair *on one task*, against an
intervening park *of that same task*. A safepoint poll is the only place a
task can be preempted (above); if codegen never emits one between the two
calls, that task cannot park between them, so nothing else running on that
task can observe or disturb the intermediate state. This remains true and
useful at any worker count — it is not what the rest of this note corrects.

**What it never guaranteed.** Anything about a *second task, on a second OS
thread, running at the same real time*. Adjacency is a property of one task's
own instruction stream; it says nothing about a different mutator
concurrently reading or writing the same storage. A value read back purely by
adjacency is safe from a **second caller** only when the runtime boots exactly
one worker. **#1900 ended that.** Once `BIT_WORKERS>1`, a second worker's
identical call pair is not interleaved with the first — it runs simultaneously
on another core — and if both write the same process-wide or module-level
word, one worker's result is whatever the other happened to leave there. This
was read into the adjacency contract by every site that cited it as a safety
argument for a *shared* buffer; adjacency was never that.

**#3272** (`udpSenderBuf`/`udpSenderValid`, `runtime/net/{darwin,linux}/
netabi.bit` — the root cause behind #1912, open six months across three wrong
hypotheses before this was found) and **#3273** (`saBuf`/`saBuf2`/`optBuf`/
`lenBuf`/`ipBuf`, `runtime/net/{darwin,linux}/sock.bit`, mutation-tested both
directions, whose pre-fix fingerprint was `gotport == the other socket's
port` — an outright swap) proved the distinction above the hard way: a
comment reading "sound only under the single-worker contract" and a live
cross-worker race were the same code, before and after `BIT_WORKERS>1` was
actually exercised. §22 audits every remaining module-level cell in
`runtime/**` against this distinction by name.

**The replacement shape**, established by those two fixes:

- If the value is naturally scoped to the calling **task** rather than the
  calling worker — as §11's `scrRecvOk` and §13's error slot are, both being
  the ABI's own outcome of a call the task itself just made — use **per-task
  scratch**: a fixed word offset in the task's own scratch block
  (`runtime/sched/scratch.bit`), read via `scratchOf(schedCurrentTask())`.
  This is strictly *stronger* than a per-worker slot, because it survives the
  M:N scheduler migrating the task to a different worker between the two
  calls.
- If the value is scoped to the calling **worker** instead — a buffer built
  once per OS thread rather than per task, as `udpSenderBuf` and the
  sockaddr scratch buffers are — use **per-worker slots** indexed by `wkId`,
  double-bounded against both `schedMaxWorkers` and the array's own literal
  capacity (`let a: [N]i64` needs a literal `N`), plus one fallback slot for a
  caller with no current task.
- If the span can **park**, decide the slot **after** the park returns, not
  before it starts — `netAbiUdpRecv` (#3273) writes the raw result into
  throwaway per-call scratch and only asks for its worker slot once
  `netRecvFrom` has actually returned, because the task can resume on a
  different worker mid-call.
- Filling a buffer once outside a retry loop that can park is unsound under
  per-worker slots even though it was harmless under one shared buffer — a
  migrated task's next read lands on a different, unfilled slot (#3273 had to
  move `netSendTo`'s fill inside its loop for exactly this reason).
- **`@nosplit` does NOT mean "cannot park."** `schedPark`
  (`runtime/sched/task.bit`) and `schedSwitch` (`runtime/sched/sched.bit`) are
  themselves `@nosplit`, so E0075 permits calling them from a `@nosplit` body.
  Prove a span cannot park by what it actually calls, never by inferring it
  from the attribute alone.

**A closed gap.** §2.2's `bit_rt_iface_as_ok` flag used to be the process-wide
shape this note describes as unsound at `BIT_WORKERS>1`. #3280 converted it to
per-task scratch (`scrIfaceOk`, `runtime/sched/scratch.bit`) alongside its
§11/§13 siblings; `rtIfaceAs`/`rtIfaceAsOk` (`runtime/root/iface.bit`) now read
and write that slot, and the module-level `ifaceOk` global is gone from
`runtime/root/root.bit`. The adjacency contract now holds for this flag the
same way it does for the rest of §5.1.

---

## 6. Allocation and collection entry points

v1 exposes the runtime API in Bit (`runtime/gc/gc.bit`); the runtime-init/codegen
ticket wires the process-wide collector instance and any C-callable export
symbols.

```
Gc.init(heap, cfg) !Gc          // create over a size-class Heap
Gc.alloc(info) ?[*]u8           // allocate a zeroed body of type `info`
Gc.markRoot(ref)                // mark one root reference (used by scanners)
Gc.safepoint(scanner)           // poll: collect if the trigger was crossed
Gc.collect(scanner)             // force a full stop-the-world collection
Gc.owns(ptr) bool               // §3 base-pointer membership check
Gc.deinit()                     // free all objects and the mark worklist
```

`alloc` never collects on its own — collection happens only at safepoints, where
the stack maps make the roots precise.

Codegen never calls the API above directly — it calls the two exported C
symbols `runtime/root` wires to it:

```
bit_rt_gc_alloc(info: *const TypeInfo) -> *u8   // Gc.alloc, fatal (not null) on OOM
bit_rt_safepoint()                    -> void   // poll + §5 stop-the-world handshake
```

`bit_rt_safepoint` takes no arguments and returns nothing **as seen by its
caller**; the on-stack snapshot of §4 is built and passed on entirely inside the
shim, so codegen is unaffected by it. The shim reserves ~300 bytes below the
caller's stack pointer, which is why a function containing a safepoint may not
rely on the x86-64 red zone (it is non-leaf by construction, so it already may
not).

Threads that run Bit code participate in the §5 handshake through four more
exports, none of which codegen emits — they are called by whatever creates the
thread (`runtime/sched`'s worker pool, `runtime/sched/`'s Bit port, or user
code that starts a raw OS thread via `runtime/thread`):

```
bit_rt_gc_thread_enter()   -> void   // claim a mutator slot for this OS thread
bit_rt_gc_thread_exit()    -> void   // release it; the platform does this at thread exit
bit_rt_gc_blocking_begin() -> void   // enter a no-live-references blocking region
bit_rt_gc_blocking_end()   -> void   // leave it
bit_rt_gc_syscall_begin()  -> void   // enter a kernel block that DOES hold references
bit_rt_gc_syscall_end()    -> void   // leave it
```

`_enter` is idempotent per thread and is also performed lazily by the first
safepoint poll, so a thread can never be invisible to the collector.

**`_exit` IS NO LONGER THE THREAD BODY'S RESPONSIBILITY (#1801).** A leaked slot
stays `running` forever, which does not corrupt anything but does make every
later rendezvous time out, i.e. collection stops — and that is silent, so a rule
each new caller had to remember was the wrong place for it (measured: 247 of
`tests/stress/gcthreadslinux`'s 292 abandoned collections were blocked on an
exited child's slot). The release now happens without the body's cooperation, by
whichever hook the platform actually offers:

| Platform | Where the slot is released | Why there |
|----------|----------------------------|-----------|
| Linux    | `runtime/thread/linux`'s child exit path calls `_exit` once the body returns | the provider owns the whole `clone(2)` child exit path, and a static binary has no libc hook |
| Darwin   | a pthread TSD destructor, armed when the slot is CLAIMED (`exit_hook`, `runtime/root`) | `pthread_create` owns the child's entry and stack, so there is nothing to wrap — but every pthread runs its destructors, including threads this runtime never started |

Three consequences worth stating. The Linux ordering is deliberate: the slot is
released while the child is still in user space, so a joiner that sees the `done`
word cleared also sees a released slot. Darwin's hook fires during
`_pthread_tsd_cleanup`, the same pass that tears the thread's TLVs down, so it
carries the slot pointer as the key's VALUE — a destructor reading the runtime's
`threadlocal` sees null (measured) and releases nothing. And the Linux provider's
`threadRelease` no longer treats `done` as proof that the child has left its
stack, because a body may clear that word itself; it waits on a flag only the
child's exit path clears, as that path's last memory access.

`_exit` remains exported, and remains what a thread calls to give its slot back
*earlier* than its own death — a worker that finishes its Bit loop and then keeps
running is the case (`runtime/sched`'s pool). Calling it disarms the platform
hook, so the two can never release one slot twice.

All are plain `callconv(.c)` functions with C linkage names — ordinary
external symbols to the linker (§9's export table lists every `bit_rt_*`
symbol together).

---

## 7. GC tuning (environment)

Read once at startup by `configFromEnv`. Knobs tune policy, never correctness.

| Variable            | Default | Effect                                             |
|---------------------|---------|----------------------------------------------------|
| `BIT_GC`            | on      | `off`/`0` disables collection; `stress` collects at every safepoint |
| `BIT_GC_MIN_KB`     | 4096    | Min live KiB before the first/next collection      |
| `BIT_GC_GROWTH_PCT` | 200     | Heap growth percent between collections (>= 100)   |
| `BIT_GC_MARKSTACK`  | 8192    | Mark worklist capacity in entries (> 0)            |
| `BIT_GC_STATS`      | off     | `1`/`on` prints one line per collection to stderr  |

POSIX only in v1; Windows keeps the compiled defaults until the runtime adds
`GetEnvironmentVariableW`.

**`bit` itself is a Bit program**, so every row above also configures `bit`'s
own process, not only the program it is building or running (#2425). `bit
build`/`check` compile in-process and simply run slower under `BIT_GC=stress`
(the compiler's own heap, not the input program, pays the per-safepoint
collection) — no exec follows, so a slow compile is the whole story.

`bit run` and `bit test` both compile in-process and then exec a built binary
as a separate child that inherits the environment fresh — `run` the program
it just built, `test` a synthetic `BIT_TEST_INDEX`-dispatch binary
(`compiler/testgen.bit`'s `injectTestMain`) — so under `BIT_GC=stress` neither
would ever reach that exec: the compile alone does not finish in useful time
(#2425 measured a six-line input still compiling after 60s, zero collections
even logged). Both therefore **refuse** `BIT_GC=stress` outright
(`compiler/build.bit`'s `refuseRunUnderStressGc`/`refuseTestUnderStressGc`,
the latter called from `compiler/testrun.bit`'s `testCmd`, #2979) rather than
appearing to hang.

| Subcommand   | In-process compile? | Under `BIT_GC=stress` | Supported route to stress the subject |
|--------------|----------------------|------------------------|----------------------------------------|
| `bit build`/`check` | yes, no exec after | slow compile, honestly reported (`warnCompilerUnderStressGc`) | run the output binary directly under `BIT_GC=stress` |
| `bit run`    | yes, execs the built binary | **refuses immediately** (#2425) | `bit build` the source, then run the output binary directly under `BIT_GC=stress` |
| `bit test`   | yes, execs a synthetic test binary per `test_*` | **refuses immediately** (#2979) | no build-only step is exposed for the synthetic test binary; move the logic into a normal `fn main()`, `bit build` it, and run that directly under `BIT_GC=stress` |

---

## 8. Collector algorithm (informative)

Not ABI — may change without touching §1–§7. v1 is a precise, non-moving,
stop-the-world **mark-and-sweep**: objects are threaded on an all-objects list;
mark traces from roots via the pointer maps using a fixed-capacity worklist
(worklist overflow falls back to bounded rescan passes, so mark-phase memory is
constant); sweep frees unmarked objects back to the size-class heap. Upgrade path
is incremental/generational collection when pause times matter.

---

## 9. Program entry, boot, and spawn (`runtime/root`)

### Process entry

The linker (task #345) designates `_start` as the object's entry point (the
standard convention on every target this runtime supports — ELF `e_entry`,
Mach-O `LC_MAIN`/`LC_UNIXTHREAD`, PE `AddressOfEntryPoint`; wiring the header
field is the linker's concern, not this one). `_start` is hand-written asm per
arch: it reads the OS-provided `argc`/`argv`/`envp` block directly off the
initial stack pointer (the standard libc-free `_start` shape, matching
glibc/musl `crt1`) and calls `rtStartMain(sp: usize)`, which extracts `envp`,
calls `boot`, and exits the process with `boot`'s returned code.

### Boot sequence (`boot(main_fn, environ) !i32`)

1. Init the heap (`runtime/alloc/alloc.bit`) and collector (`runtime/gc/gc.bit`, config from
   `configFromEnv(environ)` — §7).
2. Init and start the scheduler (`runtime/sched/sched.bit`) with `nthreads`
   worker OS threads: `BIT_WORKERS` if set and parseable, clamped to `[1, 32]`,
   **otherwise 1**. The ceiling is static so `boot` allocates nothing new for it.

   **The default is 1 by measurement, not caution.** Defaulting to the CPU count
   was implemented and reverted in the same ticket: an idle worker still runs its
   find-work/steal/backoff loop, so a pool wider than the runnable work costs
   more than it saves. On an 18-core box, four CPU-bound tasks took 108% of one
   task's time with four workers and 215% with eighteen; a full `./make test`,
   which runs many Bit processes at once, drove load to 79 and timed out a test
   that had never timed out. Every Bit process would have become a thread bomb.
   The default flips once an idle worker is cheap.

   This was pinned to **exactly one** until #1900. It was never a *collector*
   requirement — §5's handshake makes concurrent mutators safe, and each worker
   registers as a mutator for the life of its run loop — only a
   scheduler-maturity choice, because work stealing across several workers had
   no test that exercised it.

   **What that means for anyone reading a stack trace from before #1900:** with
   one worker, a worker's steal path could never find a victim, so the stealing
   branch of `schedFindWorkAt` was unreachable in every binary this runtime ever
   produced. It runs for the first time with `nthreads > 1`. Treat a failure
   that appears only under multiple workers as a first execution, not a
   regression.

   `BIT_WORKERS=1` reproduces the pre-#1900 behaviour exactly, and exists so a
   suspected concurrency failure can be bisected against it without a rebuild.
3. Spawn `main_fn` (§10) as the first green thread.
4. Poll (bounded exponential backoff) until that task reports done, then shut
   the scheduler down, tear down the collector, and return the task's exit
   code.

`boot` never runs twice in one process (single-boot guard) — there is no
"reboot this runtime" operation.

### Preemption: the sysmon monitor and the preempt request flag

**Only half of this exists today.** Epic #1768 splits preemption into a
state module plus four consumers; as of this writing only two of the five
child tickets have landed (#2576, #2578 — #2577, #2579, #2580 are open).
Every claim below was checked directly against the source with the greps
shown, not against ticket text or a comment's stated intent.

**The state module (`runtime/sched/preempt.bit`, #2576, landed).** No
function in this file makes an OS call; every function takes its clock
reading as a parameter instead of reading one itself
(`runtime/sched/preempt.bit:16-18`). It defines:

- `preemptBudgetNs: i64 = 10000000` (10 ms) — a task that has held its
  worker longer than this is eligible for a preempt request
  (`runtime/sched/preempt.bit:28`).
- Two fixed-size, worker-indexed globals, `startNs` and `requested`, each
  `[32]i64` (`runtime/sched/preempt.bit:58-59`), whose scan bound is this
  file's own `preemptSlots: int = 32` (`runtime/sched/preempt.bit:51`) —
  deliberately a separate constant from the scheduler's own worker-count
  constant, which this file treats as advisory only, not as the real bound
  on these arrays.
- `preemptStamp(worker: i64, nowNs: i64)`, which sets `startNs[worker] =
  nowNs` and clears `requested[worker]` (`runtime/sched/preempt.bit:74-77`).
- `sysmonTick(nowNs: i64): i64`, which scans every worker slot — bounded by
  both the scheduler's worker-count constant and `preemptSlots`
  (`runtime/sched/preempt.bit:97`) — and sets `requested[w] = 1` for any
  worker whose `startNs` is more than `preemptBudgetNs` in the past,
  returning the count set this call (`runtime/sched/preempt.bit:94-106`).
- `preemptRequested(worker: i64): bool`, which reads the flag without
  clearing it (`runtime/sched/preempt.bit:109-111`).
- `maybePreempt(worker: i64): bool`, which reports a pending request and
  clears it in the same call. It only reports — the caller is responsible
  for the actual yield (`runtime/sched/preempt.bit:117-123`).

**Wired: the stamp on dispatch (#2578, landed).** `schedWorkerStep` calls
`preemptStamp(*(w + wkId), monoNs())` once per task dispatch, immediately
before `schedSwitch` hands control to the task
(`runtime/sched/workerrun.bit:143`) — the only call site for `preemptStamp`
in the tree (`git grep -n preemptStamp -- '*.bit'`).

**Not wired: nothing ticks the monitor.** `sysmonTick` has no call site
anywhere in the tree outside its own definition in `preempt.bit`
(`git grep -n sysmonTick -- '*.bit'` finds the definition plus one comment
in `runtime/sched/workerrun.bit` that names it, and nothing else). There is
no `sysmonRun` function, and no monitor OS thread of any kind, anywhere in
the repository (`git grep -n sysmonRun` — zero matches, including in
`runtime/root/darwin/boot.bit` and `runtime/root/linux/boot.bit`). Neither
platform starts a second OS thread next to the `BIT_WORKERS` worker boot
sequence above. Booting that thread is #2579 (darwin) and #2580 (linux);
both are open. Until one of them lands, `requested` can never become
nonzero on any worker, because nothing ever calls `sysmonTick`.

**Not wired: nothing consumes the flag.** `maybePreempt` and
`preemptRequested` likewise have zero call sites anywhere in the tree
outside their own definitions in `preempt.bit`
(`git grep -n 'maybePreempt\|preemptRequested' -- '*.bit'` matches only
`preempt.bit` itself) — no safepoint check anywhere in `runtime/sched/` or
`runtime/root/` reads either function today. Calling `maybePreempt` from the
scheduler's safepoint check, and yielding when it returns true, is #2577,
open.

**Net effect today:** the flag is stamped into existence on every dispatch
but never set by a tick (no monitor exists to tick it) and never consumed at
a safepoint (nothing calls `maybePreempt`). Once #2577/#2579/#2580 land, a
task with no safepoint is still not preemptible even though `sysmonTick` may
have set its flag: the flag is only ever acted on where `maybePreempt` is
called, and a task that never reaches that call point keeps running
regardless of `requested`'s value.

**No separate preemption knob.** `preemptBudgetNs` is a compile-time
constant, read from no environment variable. The only worker-related
environment knob is `BIT_WORKERS`, above; nothing else in the environment
controls worker count or preemption.

### Spawn

```
bit_rt_spawn(fn_ptr: TaskFn, arg: ?*anyopaque) -> void
TaskFn = *const fn (arg: ?*anyopaque) callconv(.c) void
```

Fixed 2-arg native shape, matching `sched.TaskFn` exactly — spawn's arity does
**not** grow with the spawned call's own argument count. For `spawn f(a, b, c)`
codegen must pack `(a, b, c)` (and `f`'s captured environment, if any) into one
`bit_rt_gc_alloc`'d class and generate a small trampoline that unpacks it and
calls `f` with the real arguments; `fn_ptr`/`arg` here are that trampoline and
its one packed-argument pointer, never `f` and its raw arguments directly.
Never fails visibly: OOM is fatal here (SPEC.md §16.1's `spawn` has no
fallible surface form), so codegen never checks a return value.

### Exported C symbols (all `bit_rt_*`, one process-wide runtime instance)

**Standing rule for Bit-sourced runtime modules: every runtime function another
module calls MUST be pinned with `@symbol("...")` (SPEC §11.9).** This is a
structural requirement, not a style preference, and it is not optional for
anything in the table below.

The reason is `modulePrefix`: a non-root module's symbols are emitted as
`m<id>$name`, where `<id>` is an ordinal the **importing** build assigns. The
ordinal is therefore a property of the build that consumed the module, not of
the module itself, so the same source compiled into two separately emitted
objects gets two different names. `export` does not bypass this — it controls
Bit-level visibility (may another module import the name), not the link-level
symbol. Meanwhile code generation calls the runtime by fixed name (`bit_rt_alloc`,
`bit_rt_safepoint`, ...). Without a pin, a Bit-sourced runtime module can never
define the symbol the caller emits a reference to, and the archive members will
not link.

`@symbol` fixes the **name, not the retention**: a linker still dead-strips a
definition nothing references. `export` and `@symbol` are independent and
compose freely.

The rule is **enforced by `--freestanding` itself** (SPEC §17.6), so forgetting
a pin is a build failure naming the symbol rather than a link error, a
dead-stripped reference, or a dyld abort at load. Both compilers refuse to emit
a freestanding object that would reference a compiler-mangled name it does not
define.

Pins are validated by both compilers — E0079 `symbol_attr_invalid` (one
string-literal argument, a C identifier, free non-generic functions only, C-ABI
signature) and E0080 `duplicate_symbol` (project-wide: each pinned name must be
defined exactly once).

| Symbol               | Signature                                              |
|-----------------------|--------------------------------------------------------|
| `bit_rt_gc_alloc`     | `(info: *const TypeInfo) -> *u8` (§6)                  |
| `bit_rt_iface_lookup` | `(info: *const TypeInfo, id: u64) -> *const anyopaque` (§2.1) |
| `bit_rt_safepoint`    | `() -> void` (§6)                                      |
| `bit_rt_spawn`        | `(fn_ptr: TaskFn, arg: ?*anyopaque) -> void`            |
| `bit_rt_chan_make`    | `(capacity: usize, is_ref: bool) -> *anyopaque` (§11)  |
| `bit_rt_chan_send`    | `(ch: ?*anyopaque, value: u64) -> void` (§11)          |
| `bit_rt_chan_recv`    | `(ch: ?*anyopaque) -> ChanRecvResult` (§11)             |
| `bit_rt_chan_close`   | `(ch: ?*anyopaque) -> void` (§11)                       |
| `bit_rt_select_alloc` | `(n: usize) -> *SelectCaseDesc` (§11)                   |
| `bit_rt_select`       | `(descs: *SelectCaseDesc, n: usize, has_default: bool) -> usize` (§11) |
| `bit_rt_panic`        | `(msg: *const RtBytes) -> noreturn` (§12)               |
| `bit_rt_panic_div_zero` | `() -> noreturn` (§12.1)                              |
| `bit_rt_panic_overflow` | `() -> noreturn` (§12.1, §13.5)                       |
| `bit_rt_panic_nil_call` | `() -> noreturn` (§12.1)                              |
| `bit_rt_panic_nil_iface` | `() -> noreturn` (§12.1)                             |
| `bit_rt_assert`       | `(cond: bool, msg: *const RtBytes) -> void` (§12)       |
| `bit_rt_print`        | `(s: *const RtBytes) -> void` (§12, fd 1)               |
| `bit_rt_eprint`       | `(s: *const RtBytes) -> void` (§12, fd 2)               |
| `bit_rt_string_concat`| `(a: *const RtBytes, b: *const RtBytes) -> *const RtBytes` (§2) |
| `bit_rt_string_eq`    | `(a: *const RtBytes, b: *const RtBytes) -> bool` (§2)   |
| `bit_rt_string_cmp`   | `(a: *const RtBytes, b: *const RtBytes) -> i64` (§2, three-way lexicographic order; unsigned bytes, shorter-is-less on a common prefix) |
| `bit_rt_string_byte`  | `(s: *const RtBytes, index: usize) -> u64` (§2, `s[i]`; u64-widened) |
| `bit_rt_string_slice` | `(s: *const RtBytes, lo: usize, hi: usize) -> *const RtBytes` (§2, `s[lo:hi]`; copies) |
| `bit_rt_bytes_from_string` | `(s: *const RtBytes) -> *SliceHeader` (§2, `[]byte(s)`) |
| `bit_rt_string_from_bytes` | `(h: *const SliceHeader) -> *const RtBytes` (§2, `string(b)`) |
| `bit_rt_string_from_int`   | `(v: i64) -> *const RtBytes` (§2, the signed prims i8..i64) |
| `bit_rt_string_from_uint`  | `(v: u64) -> *const RtBytes` (§2, the unsigned prims u8..u64, zero-extended by the caller; #2011) |
| `bit_rt_string_from_float` | `(v: f64) -> *const RtBytes` (§2)                  |
| `bit_rt_parse_float`  | `(s: *const RtBytes) -> f64` (§2, correctly-rounded text->f64; the inverse of `bit_rt_string_from_float`) |
| `bit_rt_string_from_bool`  | `(v: bool) -> *const RtBytes` (§2)                 |
| `bit_rt_slice_new`    | `(len: usize, cap: usize, is_ref: usize, elem_size: usize) -> *SliceHeader` (§2, `elem_size` in **bytes** — `1` for a packed `[]u8`, `8` for every other element type) |
| `bit_rt_slice_append` | `(h: *SliceHeader, word: u64, is_ref: usize, elem_size: usize) -> *SliceHeader` (§2, `is_ref`/`elem_size` are the static element type's — a null `h` has no header to read them from, #1569) |
| `bit_rt_slice_get`    | `(h: *const SliceHeader, index: usize, elem_size: usize) -> u64` (§2) |
| `bit_rt_slice_set`    | `(h: *SliceHeader, index: usize, word: u64, elem_size: usize) -> void` (§2) |
| `bit_rt_slice_slice`  | `(h: *const SliceHeader, lo: usize, hi: usize) -> *SliceHeader` (§2, unchanged — reslicing works in element counts already, `runtime/root/slices.bit` `rtSliceSlice`) |
| `bit_rt_map_new`      | `(key_desc: usize, val_is_ref: usize) -> *MapHeader` (§15, §15.1) |
| `bit_rt_map_set`      | `(m: ?*MapHeader, key: u64, val: u64) -> void` (§15)    |
| `bit_rt_map_get`      | `(m: ?*MapHeader, key: u64) -> u64` (§15)               |
| `bit_rt_map_has`      | `(m: ?*MapHeader, key: u64) -> bool` (§15)              |
| `bit_rt_map_delete`   | `(m: ?*MapHeader, key: u64) -> void` (§15)              |
| `bit_rt_map_len`      | `(m: ?*MapHeader) -> i64` (§15)                         |
| `bit_rt_map_iter_init`| `(m: ?*MapHeader) -> i64` (§15)                         |
| `bit_rt_map_iter_next`| `(m: ?*MapHeader, prev: i64) -> i64` (§15)              |
| `bit_rt_map_key_at`   | `(m: *MapHeader, slot: i64) -> u64` (§15)               |
| `bit_rt_map_val_at`   | `(m: *MapHeader, slot: i64) -> u64` (§15)               |
| `bit_rt_fs_append`    | `(path: *const RtBytes) -> i64` (§14)                   |
| `bit_rt_fs_read`      | `(fd: i64, max: i64) -> *const RtBytes` (§14)           |
| `bit_rt_fs_exists`    | `(path: *const RtBytes) -> bool` (§14)                  |
| `bit_rt_fs_is_dir`    | `(path: *const RtBytes) -> bool` (§14)                  |
| `bit_rt_fs_mkdir`     | `(path: *const RtBytes) -> i64` (§14)                   |
| `bit_rt_fs_remove`    | `(path: *const RtBytes) -> i64` (§14)                   |
| `bit_rt_fs_rename`    | `(oldPath: *const RtBytes, newPath: *const RtBytes) -> i64` (§14) |
| `bit_rt_fs_list_dir`  | `(path: *const RtBytes) -> *const RtBytes` (§14)        |
| `bit_rt_fs_is_symlink_w` | `(words: usize, n: i64) -> bool` (§14, `words` is a `[]byte`'s backing, packed one byte per element (§2, #3121/#3226) — not NUL-terminated, not `RtBytes`; the only `bit_rt_fs_*` entry point shaped this way) |
| `bit_rt_fs_sync`      | `(fd: i64) -> i64` (§14, `0` on success, `-1` on failure; Darwin uses `F_FULLFSYNC`, falling back to bare `fsync` only on `ENOTSUP` — bare `fsync` alone does not flush the drive's write cache on that platform) |
| `bit_rt_fs_cwd`       | `() -> *const RtBytes` (§14, the process's current working directory, or the empty string on any failure; #3501) |
| `bit_rt_test_index`   | `() -> i64` (§16)                                      |
| `bit_rt_floor`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_ceil`         | `(x: f64) -> f64` (§17)                                |
| `bit_rt_round`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_trunc`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_float_bits`   | `(v: f64) -> u64` (§17, IEEE-754 bit pattern, no conversion; unreached by generated code since #1442 — `floatBits` lowers to an inline bitcast) |
| `bit_rt_float32_bits` | `(v: f32) -> u32` (§17, same, for f32/`float32Bits`)   |
| `bit_rt_pow`          | `(x: f64, y: f64) -> f64` (§17)                        |
| `bit_rt_atan2`        | `(y: f64, x: f64) -> f64` (§17)                        |
| `bit_rt_log`          | `(x: f64) -> f64` (§17)                                |
| `bit_rt_log2`         | `(x: f64) -> f64` (§17)                                |
| `bit_rt_log10`        | `(x: f64) -> f64` (§17)                                |
| `bit_rt_time_mono_ns` | `() -> i64` (§18)                                      |
| `bit_rt_time_unix_ns` | `() -> i64` (§18)                                      |
| `bit_rt_time_sleep_ns`| `(ns: i64) -> void` (§18)                              |
| `bit_rt_os_argc`      | `() -> i64` (§19)                                      |
| `bit_rt_os_arg_at`    | `(i: i64) -> *const RtBytes` (§19)                     |
| `bit_rt_os_env`       | `(name: *const RtBytes) -> *const RtBytes` (§19)       |
| `bit_rt_os_self_exe`  | `() -> *const RtBytes` (§19)                           |
| `bit_rt_os_exit`      | `(code: i64) -> noreturn` (§19)                        |
| `bit_rt_os_run`       | `(path: *const RtBytes, argv: *const SliceHeader) -> i64` (§19) |
| `bit_rt_os_run_test`  | `(path: *const RtBytes, idx: i64) -> i64` (§19)        |
| `bit_rt_os_run_bounded` | `(path: *const RtBytes, timeout_ms: i64) -> i64` (§19) |
| `bit_rt_os_run_test_bounded` | `(path: *const RtBytes, idx: i64, timeout_ms: i64) -> i64` (§19) |
| `bit_rt_host_target`  | `() -> i64` (§19)                                      |
| `bit_rt_auxv`         | `() -> i64` (§19)                                      |
| `bit_rt_net_listen`   | `(host: *const RtBytes, port: i64) -> i64` (§20)       |
| `bit_rt_net_local_port` | `(fd: i64) -> i64` (§20)                             |
| `bit_rt_net_accept`   | `(fd: i64) -> i64` (§20)                               |
| `bit_rt_net_dial`     | `(host: *const RtBytes, port: i64) -> i64` (§20)       |
| `bit_rt_net_read`     | `(fd: i64, max: i64) -> *const RtBytes` (§20)          |
| `bit_rt_net_write`    | `(fd: i64, s: *const RtBytes) -> i64` (§20)            |
| `bit_rt_net_udp_bind` | `(host: *const RtBytes, port: i64) -> i64` (§20)       |
| `bit_rt_net_udp_send` | `(fd: i64, host: *const RtBytes, port: i64, data: *const RtBytes) -> i64` (§20) |
| `bit_rt_net_udp_recv` | `(fd: i64, max: i64) -> *const RtBytes` (§20)          |
| `bit_rt_net_udp_sender_host` | `() -> *const RtBytes` (§20)                    |
| `bit_rt_net_udp_sender_port` | `() -> i64` (§20)                               |
| `bit_rt_net_resolve`  | `(host: *const RtBytes) -> *const RtBytes` (§20)       |
| `bit_rt_random_bytes` | `(len: i64) -> *const RtBytes` (§21)                   |
| `bit_rt_secure_zero`  | `(h: *SliceHeader) -> void` (§21)                      |
| `bit_rt_crypto_aes_hw_available` | `() -> bool` (§21b)                         |
| `bit_rt_crypto_ghash_hw_available` | `() -> bool` (§21b)                       |
| `bit_rt_crypto_sha256_hw_available` | `() -> bool` (§21b)                      |
| `bit_rt_crypto_aes_encrypt_hw` | `(rk: *byte, nr: i64, block: *byte, out: *byte) -> void` (§21b) |
| `bit_rt_crypto_aes_decrypt_hw` | `(drk: *byte, nr: i64, block: *byte, out: *byte) -> void` (§21b) |
| `bit_rt_crypto_aes_invert_schedule_hw` | `(erk: *byte, nr: i64, out: *byte) -> void` (§21b) |
| `bit_rt_crypto_ghash_mul_hw` | `(acc0, acc1, b0, b1, h0, h1: u64, outHi: *u64) -> u64` (§21b) |
| `bit_rt_crypto_sha256_compress_hw` | `(state: *u32, block: *byte) -> void` (§21b) |
| `bit_rt_crypto_hwcaps` | `() -> u64` (§21c) |
| `bit_rt_aes_hw_expand_key` | `(key: i64, keyBits: i64, roundKeys: i64) -> void` (§21d) |
| `bit_rt_aes_hw_encrypt_block` | `(roundKeys: i64, rounds: i64, blockIn: i64, out: i64) -> void` (§21d) |
| `bit_rt_aes_hw_decrypt_block` | `(roundKeys: i64, rounds: i64, blockIn: i64, out: i64) -> void` (§21d) |

**Narrow return values.** The C ABI returns a `bool` in `al`/`w0` and leaves the
rest of the return register **unspecified**; the same is true of any sub-word
integer. A Bit `bool` is a full-width 0/1, because `!b` and the branch tests read
the whole register. Codegen therefore zero-extends a `bool`-typed call result at
the call boundary, on both targets. Do not rely on a particular callee zeroing
it: `bit_rt_string_eq` happened to, `bit_rt_fs_exists` did not, and
`!fsExists(missing)` silently evaluated to `false` on x86-64. A primitive that
returns a wider integer (e.g. `bit_rt_string_byte` returning `u64` rather than
`u8`) sidesteps the question entirely, which is why it does.

Every symbol above is `callconv(.c)` with plain C linkage — the entire
compiler-facing surface of `libbitrt.a`. Nothing else in `runtime/` is a stable
call target for codegen; reach the collector, scheduler, and channels only
through this table.

---

## 10. Main entry normalization

SPEC.md §17.4 permits four surface `main` signatures. Codegen normalizes
whichever one a program declares into one fixed native shape and emits it
under the fixed symbol name `bit_main`:

```
bit_main() -> i32     // callconv(.c); the process exit code
```

Normalization (all four collapse to this one shape):

| Surface form               | `bit_main` body                                  |
|-----------------------------|---------------------------------------------------|
| `fn main() { ... }`         | run the body, return `0`                          |
| `fn main(): int { ... }`    | return the declared `int` directly                |
| `fn main(): ()! { ... }`    | on ok, return `0`; on err, print it to stderr, return `1` |
| `fn main(): int! { ... }`   | on ok, return the declared `int`; on err, print it to stderr, return `1` |

`boot` (§9) spawns `bit_main` as the first green thread and returns its `i32`
as the process exit code, truncated to a byte for the OS `exit` syscall (a
negative or out-of-`u8`-range value truncates, matching every POSIX shell's own
exit-code truncation — Bit does not special-case it).

### Where the fallible rows are realized

The trampoline that defines `bit_main` is hand-assembled (`emitmacho.bit`,
`emitelf.bit`); it can `bl main` and it can zero the return register, and that
covers the first two rows. It cannot dispatch `error.message()`, because the
interface method's dispatch id is assigned per program (§2.1). So the third and
fourth rows are emitted as ordinary lowered IR instead, by `compiler/lowerentry.bit`:

- the user's fallible `main` body is emitted under the private link name
  **`main$fallible`** (same shape it always had — a void or `T` result, with the
  error travelling in the §7 error slot);
- a synthesized `main`, result `i64`, calls it, reads the slot with
  `bit_rt_get_err`, and branches. The `i64` result is also what stops the
  trampoline zeroing the return register: its void-`main` test reads the IR
  function's result type.

The err arm writes **`error: <msg>\n`** to fd 2 through `bit_rt_eprint`, as one
concatenated write. SPEC §17.4 fixes fd 2 and exit 1 but not the wording; the
prefix matches the runtime's own `panic: <msg>\n` (§12), which is the only other
line a running Bit program puts on fd 2, and keeps a failed `main` from reading
as the program's own logging. No new runtime symbol: `bit_rt_get_err`,
`bit_rt_string_concat` and `bit_rt_eprint` all already exist.

The ok arm returns the declared `int` as the exit code for `main(): int!`
(§17.4's fourth signature), widened to `i64` first, and `0` for `main(): ()!`.
Since #2236's checker rule (E0085), these are the only two ok types that reach
this code — every other shape (`f64!`, `string!`, `bool!`, ...) is rejected at
`bit check` before lowering ever runs, rather than silently returning `0` with
a float ok value handed back in `d0`/`xmm0` and read out of `x0`/`eax` as
whatever was left there.

Before #2235 this row did not exist in code at all: `fail` set the slot, nothing
read it, and a failed `main` exited 0 with an empty stderr.

---

## 11. Channels (`runtime/chan` + `runtime/root`)

### The ABI's one channel type

Every `chan<T>` a Bit program declares is realized at the runtime boundary as
a channel of one 8-byte word (`WordChan = Chan(u64)` in `runtime/chan/chan.bit`) — never a
per-`T` instantiation. A `T` that fits in 8 bytes (every integer width, `bool`,
`f64`, and every reference type) is carried by value, bit-reinterpreted into a
`u64`. A `T` that does not fit is out of scope for v1: box it in a
`bit_rt_gc_alloc`'d object and send the (8-byte) reference instead. This is
what lets one prebuilt `libbitrt.a` serve `chan<T>` for every monomorphized `T`
a program declares, with no per-`T` archive content.

```
bit_rt_chan_make(capacity: usize, is_ref: bool) -> *anyopaque
bit_rt_chan_send(ch: ?*anyopaque, value: u64)    -> void
bit_rt_chan_recv(ch: ?*anyopaque)                -> ChanRecvResult
bit_rt_chan_recv_ok()                            -> bool
bit_rt_chan_close(ch: ?*anyopaque)                -> void

ChanRecvResult { value: u64, ok: bool }   // extern class, 2-word return
```

- `bit_rt_chan_recv_ok` returns the `ok` of the receive *just* performed by this
  goroutine. `rt_call` threads only a single value word back through the IR, so
  the two-result form `let (v, ok) = <- c` (SPEC.md §16.2) lowers as
  `bit_rt_chan_recv` immediately followed by `bit_rt_chan_recv_ok`, with no
  yield between them. The outcome lives in the same per-task scratch mechanism
  the error slot uses (§13), not a threadlocal: word `scrRecvOk`, offset 264
  of the per-task scratch block (`runtime/sched/scratch.bit:77`), read by
  `bit_rt_chan_recv_ok` (`runtime/root/slots.bit:78`). The adjacency is what
  keeps that word from being clobbered by another scratch-writing operation
  before the ABI wrapper reads it back. This matters because a *reference*
  element's zero word on a closed channel is a null pointer: a receiver must
  be able to distinguish "closed" from "a real value" before dereferencing
  it.

- `capacity == 0` is unbuffered (synchronous rendezvous); `capacity > 0` is a
  bounded ring buffer (SPEC.md §16.2).
- `is_ref` marks whether a buffered word is itself a GC reference. Codegen
  passes `true` for `chan<T>` where `T` is a reference type (or is boxed, per
  above), `false` otherwise. This is what makes root scanning (below) precise
  without inspecting the channel's element type at GC time.
- `ch == null` is a nil channel: send and receive block forever, matching
  Go-like nil-channel semantics (SPEC.md §16.2). `close` on a nil channel
  panics (§12), routed the same as every other panic source.
- `ChanRecvResult.ok == false` means the channel was closed and drained; `value`
  is then the zero word (SPEC.md §16.2).
- v1 has **no explicit channel-free primitive** — `bit_rt_chan_make` allocates
  from the process allocator directly (not GC-managed), and a channel handle
  is process-lifetime. It is therefore never dangling, but also never
  reclaimed; a program that churns through many short-lived channels leaks
  their handles (not their buffered elements, which the GC still reclaims
  once unreachable). Acceptable for v1 — see `runtime/chan/chanreg.bit`'s note for
  the rationale — revisit if a real program's channel count matters.

### Select (§16.3)

```
SelectCaseDesc { dir: u64, chan: *WordChan, word: u64, ok: u64 }   // 32 bytes
bit_rt_select_alloc(n)                     -> *SelectCaseDesc[n]  (zeroed)
bit_rt_select(descs, n, has_default: bool) -> usize
```

Codegen evaluates each comm clause's channel (and a send case's value) once,
`bit_rt_select_alloc`s a zeroed `n`-descriptor buffer, and fills `dir` (0 recv /
1 send), `chan`, and — for a send — `word` (the value to send). `word` is
**in/out**: for a recv case the runtime writes the received value there, so
codegen reads it back from `descs[fired].word` after the call. `bit_rt_select`
returns the fired case index, or `n` to signal the `default` clause ran. The
descriptor buffer is a **traced** GC object (allocated with `ref_array_info`, so
every word is scanned): for a `chan<T>` where `T` is a reference type, a `word`
slot holds a live reference — a send case's value, or the value a recv case just
received — and that reference lives *only* in this buffer across `bit_rt_select`
(which may park while a collection runs) and until codegen loads it into a rooted
slot, so a leaf buffer would let the collector sweep a still-live received value.
Tracing every word is exact: `dir`/`ok` are 0/1 and each `chan` is a
process-lifetime page allocation, so the collector's base-pointer check skips
all three and marks only a real `word` reference. Nil-channel cases are the
caller's responsibility to omit (a nil case is never ready).

### Root scanning integration

A buffered word is reachable only through the channel's ring buffer while it
sits unreceived — no stack or register holds it. `bit_rt_chan_make(_, true)`
registers the channel into a process-wide registry (`runtime/chan/chanreg.bit`); `runtime/root/root.bit`'s
`scanRoots` walks that registry once per collection and marks every
registered, `is_ref` channel's currently-buffered words as extra roots.

This is a **known, documented gap, not a silent hazard**: v1's root scanner
covers channel-buffered references only — it does not walk any parked green
thread's stack, because the per-callsite stack-map wire format (§4) and a
live-task registry are both future work. This is safe today only because
nothing yet emits `bit_rt_safepoint` calls (no codegen exists that does), so
there is no live stack-held reference for the gap to lose. The gap becomes
real the moment codegen starts inserting safepoint polls, and closing it
(stack maps + task registry) is that ticket's job, not this one's.

---

## 12. Panics

```
bit_rt_panic(msg: *const RtBytes)          -> noreturn
bit_rt_assert(cond: bool, msg: *const RtBytes) -> void
bit_rt_print(s: *const RtBytes)            -> void   // fd 1
bit_rt_eprint(s: *const RtBytes)           -> void   // fd 2

RtBytes { ptr: *const u8, len: usize }   // extern class — a transient,
                                          // non-owning byte view, never
                                          // GC-managed; not the (undecided)
                                          // `string` heap-object layout
```

- `bit_rt_panic` backs the `panic(msg)` builtin and every other panic source in
  SPEC.md §18.4 (index/slice out of range, integer divide-by-zero, send/close
  on a nil or closed channel, nil function call, type-assertion mismatch,
  failed `assert`). Codegen routes all of them through this one symbol with a
  message describing the specific failure.
- `bit_rt_assert` backs `assert(cond)` / `assert(cond, msg)`. Fixed 2-arg:
  lowering must always supply a message — the 1-arg source form gets a
  compiler-supplied default (e.g. `"assertion failed"`) — since this symbol
  has one frozen native signature regardless of which surface form the
  program used.
- `bit_rt_print` / `bit_rt_eprint` back the `print` / `eprint` builtins: a
  string's bytes verbatim, no trailing newline, to fd 1 and fd 2 respectively.
  They are the only output primitives; `std/io`'s `println`/`printf` layer on
  top. The pair exists because the two streams are not interchangeable —
  diagnostics on stdout would mix into a program's real output the moment it is
  piped, so anything a caller is not asking *for* goes to fd 2.
- Both terminate the process the same way on failure: write `panic: <msg>\n`
  to fd 2, then exit immediately with code 2 (SPEC.md §18.4: "a non-zero exit
  code"). There is no `recover` (SPEC.md §18.4) and v1 emits no stack trace —
  codegen has made no frame-pointer-chain promise this runtime could walk, and
  there is no debug-info format yet to symbolize one if it did.
- `defer` unwinding (SPEC.md §18.5: deferred calls run while a panic unwinds
  to the program's top) is codegen's obligation, not the runtime's: by the
  time a panic reaches `bit_rt_panic`, every `defer` between the panic site
  and the abort must already have run. The runtime only terminates the
  process; it does not itself walk or run deferred calls.

### 12.1 Backend-injected, argument-free panics (#2016, #2018, #2240, #3078)

```
bit_rt_panic_div_zero()  -> noreturn
bit_rt_panic_overflow()  -> noreturn
bit_rt_panic_nil_call()  -> noreturn
bit_rt_panic_nil_iface() -> noreturn
```

Checks a backend inserts directly at the operation that would otherwise
fault, rather than through an `Op.RtCall`/lowering-built `RtBytes` message —
the same "emitted directly, not through the `RtFn` table" class as
`bit_rt_iface_lookup` (§2.1), and the same alloc-free-panic-path shape as
`bit_rt_oom`: each message is a **fixed, compile-time string baked into the
runtime provider itself**, packed into immediate words the way `bit_rt_oom`'s
"out of memory" is, so the report never allocates on the path that is
reporting a broken invariant.

- `bit_rt_panic_div_zero` — a zero divisor to `/` or `%` on any integer width
  (SPEC.md §13.5, §18.4). The backend compares the divisor to zero immediately
  before the hardware divide and branches to this call only on that cold path;
  a non-zero divisor never reaches it. The compile-time-power-of-two fast path
  (`xEmitPow2DivInt`/`xEmitPow2RemInt`) needs no check — its divisor is proven
  non-zero at compile time by construction.
- `bit_rt_panic_overflow` — a signed add, subtract, multiply or negate that
  overflows its result width (SPEC.md §13.5: trap in debug builds, wrap in
  release builds). One symbol covers all four operations, the same way
  `bit_rt_panic_div_zero` covers both `/` and `%` — the message does not name
  which operation trapped. Unlike the other panics in this section, the
  backend's check here is gated on debug-mode codegen, not unconditional: in a
  release build the operation wraps and this symbol is never called. Not yet
  called from any codegen path (#3080-#3085 add the checked codegen; this
  ticket, #3078, only adds the callable symbol).
- `bit_rt_panic_nil_call` — an indirect call through a nil function value
  (SPEC.md §13.4, §18.4: "call of a `nil` function"). The backend tests the
  closure cell for null immediately before loading its `{code, env}` fields
  and branches to this call only when it is null.
- `bit_rt_panic_nil_iface` — a method call dispatched through a nil interface
  value. Not itself named in SPEC.md §18.4's enumerated list (which predates
  this fix), but the same class of broken invariant as a nil function call: an
  interface value *is* its receiver pointer (§2), so a nil receiver has no
  `TypeInfo` to dispatch through. The backend tests the receiver for null
  immediately before loading `*(recv - 32)` and branches to this call only
  when it is null.

All three are `@nosplit`, callable from anywhere a division or an indirect
call can appear (including inside another `@nosplit` function, exactly as
`bit_rt_panic` itself must be), and never return — control does not resume in
the caller on the branch that reaches them, so nothing after the call site
needs to treat their argument-free signature as clobbering anything live.

## 13. Fallible results — the error channel (SPEC.md §18)

A fallible function (`T!`) returns its **ok value** in the normal return
register (`rax` / `x0`, or `xmm0` / `d0` for a float ok), exactly like a
non-fallible one. The **error** rides a separate side channel: a per-task
scratch slot, accessed through two symbols.

```
bit_rt_set_err(e: ?*anyopaque)  -> void   // publish (or, with nil, clear)
bit_rt_get_err()                -> ?*anyopaque   // read; non-null ⇒ failed
```

`bit_rt_set_err`/`bit_rt_get_err` (`runtime/root/slots.bit:49`/`:57`) read and
write `scrErr`, word 7 of the per-task scratch block at the base of the
running task's own stack (`runtime/sched/scratch.bit:57`) — never a
threadlocal: Mach-O refuses `@threadlocal` in the freestanding emit, and even
where a threadlocal were available, a per-OS-thread slot would not survive the
M:N scheduler migrating a goroutine to a different worker between the write
and the read. Per-task scratch does, because it travels with the task rather
than being pinned to the worker (§22).

The convention (a fallible callee's postcondition):

- **ok return** — leaves the slot **null**. Codegen clears it after running
  defers (`bit_rt_set_err(nil)`), so a deferred call can't leave a stale error.
- **`fail e`** — runs defers, then `bit_rt_set_err(e)` (after defers, so a
  deferred call cannot clobber the error), then returns a zero ok value.
- **`expr?`** — after the call, `bit_rt_get_err()`; if non-null, propagate: run
  defers, re-`set_err` the saved error (defers may have overwritten the slot),
  and return a zero ok value. If null, use the call's ok result.
- **`catch`** — after the call, `bit_rt_get_err()`; if non-null, `set_err(nil)`
  (the error is handled) and evaluate the default / run the binding block; if
  null, use the ok result.

The slot is **read immediately after the call, before any yield or GC
safepoint**: codegen emits `set_err`/`get_err` back to back and both are
`@nosplit`, so no scheduling point sits between a fallible call's return and
its `?`/`catch` check. That adjacency is not what makes the slot
migration-safe — per-task scratch already is, independent of it (above) —
it is what makes the *unrooted* error pointer safe from a collection while it
sits there. The error value is an `error`-interface object pointer (a GC
object); because it is live in the slot only across that safepoint-free
window, it needs no distinct root registration — the caller roots it the
instant it reads it.

## 14. Filesystem primitives

```
bit_rt_fs_open(path, write: bool) -> i64        // fd, or -1
bit_rt_fs_append(path)            -> i64        // fd opened O_APPEND, or -1
bit_rt_fs_read_all(fd)            -> string     // whole file (regular files only)
bit_rt_fs_read_all_failed()       -> bool       // #2994/#3065/#2996 below
bit_rt_fs_read(fd, max: i64)      -> string     // up to max bytes; "" at EOF
bit_rt_fs_write(fd, s)            -> i64        // bytes written, or -1
bit_rt_fs_sync(fd)                -> i64        // 0, or -1 (#3462)
bit_rt_fs_cwd()                   -> string     // cwd, or "" on failure (#3501)
bit_rt_fs_close(fd)               -> i64        // always 0
bit_rt_fs_exists(path)            -> bool
bit_rt_fs_is_dir(path)            -> bool
bit_rt_fs_mkdir(path)             -> i64        // 0, or -1
bit_rt_fs_remove(path)            -> i64        // file or empty dir; 0, or -1
bit_rt_fs_rename(oldPath, newPath) -> i64       // 0, or -1
bit_rt_fs_list_dir(path)          -> string     // NUL-terminated entry names
bit_rt_fs_is_symlink_w(words, n)  -> bool        // path is a symlink itself (readlink-based)
bit_rt_fs_stat_w(words, n, out)   -> i64        // fills `out`, follows a trailing symlink; 0 or -errno (#2153)
bit_rt_fs_lstat_w(words, n, out)  -> i64        // fills `out`, does not follow;             0 or -errno (#2153)
```

The low-level layer under `std/fs`. Deliberately plain (not fallible): failures
surface as a `-1` fd/byte-count that the Bit `std/fs` wrappers turn into real
errors (`fail newError(...)`), so all error *ergonomics* live in Bit, not the
runtime. Backed by the per-platform `rtFs*` primitives in `runtime/root/linux/fs.bit`
and `runtime/root/darwin/fs.bit`: Linux issues raw syscall numbers directly (no
libc), Darwin calls the bare libc externs declared at the top of that file and
goes through libSystem — Apple publishes no stable syscall numbers, so this side
is NOT libc-free. Neither platform has a separate `fileSize` helper;
`lseek(SEEK_END)` inline in `rtFsReadAll` computes it.

- `fs_open` copies the (non-NUL-terminated) Bit path into a bounded
  module-level scratch buffer (sound only under the single-worker contract,
  §5) before the syscall; `write=false` opens read-only, `write=true`
  creates+truncates write-only (mode `0644`).
- `fs_read_all` sizes the result with `lseek(SEEK_END)` then reads, so it
  targets regular files. An `lseek` failure and an allocation failure for a
  file already known non-empty both report through the out-of-band companion
  symbol `bit_rt_fs_read_all_failed()` (below); a genuine empty file (`lseek`
  reports 0) never does — `string` has no nil sentinel to carry the
  distinction in-band, which is why the flag exists at all. The one earlier
  attempt to add this signal (#2994) was reverted because the pinned stage0's
  `libbitrt.a` predated the symbol: `std/fs` referencing it made the
  clean-tree driver build fail `E0078` against the OLD pinned archive, and
  repinning to a release that predates the symbol cannot make it appear
  (#2996) — a cycle, not a wait. **#3065 and #2996 broke the cycle in two
  passes.** Pass 1 (#3065) re-added `bit_rt_fs_read_all_failed` and its setter
  (`runtime/root/slots.bit`) with no caller anywhere on the driver's import
  path, so the clean-tree build kept linking the OLD pinned archive without
  complaint; that landed in `v0.1.17`. Once the stage0 pin moved to `v0.1.17`,
  pass 2 (#2996) wired `rtFsReadAll`'s `end < 0` and `s == 0` branches to the
  setter and `stdlib/fs/fs.bit`'s `File.readAll` to the getter — `fail
  newError(...)` on a read failure, same as `open`/`create`/`write`. The read
  loop's own I/O-error paths (an interrupted-but-failed read, or the retry
  budget exhausted before EOF) are NOT wired to the flag; those still trim
  silently to the bytes actually read. A short read — EOF before `end`, or an
  I/O error partway through — is NEVER zero-padded (#2990): the result is the
  string TRIMMED to the bytes actually verified read, retrying on `EINTR` up
  to `maxReadAllRetries` (1000) times.
- `fs_close` reports success unconditionally (the raw wrapper swallows
  `EINTR`/`EBADF`).
- `fs_sync` (#3462) flushes `fd`'s already-written bytes to stable storage,
  0 on success, -1 on any failure — a successful `fs_write` only reaches the
  OS page cache, and pulling power before `fs_sync` returns can still lose
  it. **Bare `fsync(2)` is not durable on Darwin**: it stops at the drive's
  write cache. Apple documents `fcntl(fd, F_FULLFSYNC, 0)` (`man 2 fsync`'s
  CAVEATS section) as the call that actually forces the platter, so Darwin's
  provider calls that first and falls back to bare `fsync` only when it
  returns `ENOTSUP` (some older exFAT/SMB mounts reject `F_FULLFSYNC`
  outright); any other failure is reported as-is, never silently downgraded
  to the weaker call. Linux's raw `fsync` syscall is already the durable
  call, no fallback needed. Windows' provider calls `FlushFileBuffers`,
  which per MSDN forces the OS cache and any intermediate hardware cache to
  the physical device. **No `stdlib/` caller exists yet** — the same
  `tools/build/` bootstrap cycle #2153's `stat_w`/`lstat_w` bullet describes
  below applies here too: `tools/build/artifacts.bit` imports `std/fs`, which
  the PINNED stage0 compiles against its own frozen `libbitrt.a`, so a
  `stdlib/fs/fs.bit` reference to this symbol breaks the driver bootstrap
  with E0078 on every fresh clone until a release ships this commit and the
  pin moves. This landing is pass 1 of 2 (the #3065 pattern): the runtime
  primitives only, no consumer. Pass 2 (a `File.sync()` method in
  `stdlib/fs/fs.bit`) is a follow-up ticket, gated on a release containing
  this commit and a stage0 repin to it.
- `fs_cwd` (#3501) is the only `bit_rt_fs_*` entry point that takes NO
  argument — nothing to encode through `fsPathZ`/`checkedPathW`. Darwin and
  Linux both call `getcwd` (libc on Darwin, the raw syscall on Linux — kernel
  `fs/d_path.c`'s `SYSCALL_DEFINE2(getcwd, ...)` returns the byte count
  INCLUDING the trailing NUL on success, unlike a `read`, so the wrapper trims
  one byte off), sized to `max_path` (4096) and rejected — never truncated —
  if the result would not fit. Windows calls `GetCurrentDirectoryW` into a
  `MAX_PATH` (260-unit) UTF-16LE scratch buffer, then decodes through the same
  `winUtf16ToUtf8` boundary every other Windows path-taking primitive uses.
  Empty string on any failure (`getcwd` returning NULL/negative-errno,
  `GetCurrentDirectoryW` returning 0, or either result not fitting its
  platform's ceiling) — the same flat-failure shape `fs_open`/`fs_mkdir`
  already use, no companion out-of-band flag. **No `stdlib/` caller exists
  yet** — the identical `tools/build/` bootstrap cycle #2153's and #3462's own
  bullets describe: `tools/build/artifacts.bit` imports `std/fs`, which the
  PINNED stage0 compiles against its own frozen `libbitrt.a`, so a
  `stdlib/fs/fs.bit` reference to `bit_rt_fs_cwd` breaks the driver bootstrap
  with E0078 on every fresh clone until a release ships this commit and the
  pin moves. This landing is pass 1 of 2 (the #3065 pattern): the runtime
  primitive only, no consumer. Pass 2 (a `std/fs` function surfacing it) is a
  follow-up ticket, gated on a release containing this commit and a stage0
  repin to it.
- `fs_read` reads once and returns what it got, so it is the primitive for
  pipes, sockets, and stdin — none of which have a size to seek to.
- `fs_list_dir` separates entries with a **NUL** byte, the one byte a POSIX
  filename cannot contain (a newline can). `.` and `..` are omitted. An empty
  result means either an empty directory or an unreadable one; `std/fs` calls
  `is_dir` first to tell them apart.
- `exists` opens `path` rather than probing directory-ness — Darwin via
  `access(F_OK)`, Linux via an `open` immediately closed again on success — so
  a mode-000 file, or a directory hit by an fd-exhausted process, still
  reports present; only `ENOENT`/`ENOTDIR` mean genuinely absent (#2114).
  `is_dir` is the one that actually distinguishes a directory: Darwin's
  `opendir` succeeding, Linux's `getdents64` succeeding on the opened fd.
- `is_symlink_w` is the only `bit_rt_fs_*` entry point that does not take a Bit
  `string`. Its caller is `std/fs`, which can reach a runtime symbol only
  through an `extern function` (SPEC §11.7), and §11.7 admits no `string`
  across that boundary — so `words` is the raw backing store of a Bit
  `[]byte` instead, `n` **packed** bytes (§2, #3121/#3226), not NUL-terminated
  and not an `RtBytes`. The provider copies those bytes into its own
  NUL-terminated buffer before probing it, applying the same `max_path` and
  embedded-NUL rejections every other path-taking entry point applies
  (#2146). It answers with `readlink`, not `lstat` + `S_IFLNK`: `readlink`
  succeeds only on a symbolic link and needs no POSIX `stat` structure layout, so a
  dangling link still answers `true` — the link exists whether its target
  does or not.
- `stat_w`/`lstat_w` (#2153) share `is_symlink_w`'s `words`/`n` path
  encoding, for the identical reason — a `std/fs` caller can reach them only
  through `extern fn`, which admits no `string` (SPEC §11.7). `out` is a
  caller-owned 5-word buffer the provider fills in fixed order: `size`,
  `mtime` (seconds since the Unix epoch), `mode` (the low 12 permission
  bits), `isDir` (0/1), `isSymlink` (0/1). `stat_w` follows a trailing
  symlink (`isSymlink` is therefore always 0 in its result); `lstat_w` does
  not, and reports whether `words` itself is a link. Unlike every other
  `bit_rt_fs_*` primitive above, a failure is **not** a flat `-1`: the return
  is 0 on success or `-errno` on failure, the convention #2343 gives the net
  primitives. Darwin's `stat`/`lstat` set a *positive* errno reachable
  through `__error()`; the provider negates it. Linux's raw `syscall`
  already returns `-errno` directly on failure, passed through unchanged.
  **No `stdlib/` caller exists yet.** #2153 landed once before (`03cbbd41`)
  wiring both the runtime and a `stdlib/fs` consumer in one commit, and was
  reverted (`0dd25c35`): the pinned stage0 that compiles `tools/build/` links
  its own frozen release runtime, which had never shipped these symbols, so
  the `stdlib/` reference broke `./make`'s driver bootstrap with E0078 on
  every fresh clone. This landing is pass 1 of 2 (the #3065 pattern): the
  runtime primitives only, no consumer, so nothing on the driver's import
  path references them. Pass 2 (the `FileInfo` class and `stat`/`lstat`
  wrappers in `stdlib/fs/fs.bit`) is a follow-up ticket, gated on a release
  containing this commit and a stage0 repin to it.
- `fs_rename` is the only `bit_rt_fs_*` entry point that needs two encoded
  paths live at the same time, and that is why it is backed by two separate
  scratch buffers instead of the one every other path-taking entry point
  shares. `oldPath` still goes through `fsPathZ`/`checkedPathZ` into the usual
  module-level `fsPathBuf`; `newPath` goes through a second, distinct pair —
  `fsPathZ2`/`checkedPathZ2` into `fsPathBuf2` (`runtime/root/fs.bit`, #2712)
  — so `rename(2)`/`sysRename` receives two pointers that can never alias.
  Encoding `newPath` through the shared `fsPathBuf` a second time, the way
  every single-path entry point does, would overwrite `oldPath`'s bytes
  before the syscall ever reads them, handing it the same pointer twice.
  Darwin dispatches to the libc `rename` extern; Linux has no libc and issues
  the raw syscall itself — `rename` (nr 82) on x86_64, `renameat(AT_FDCWD,
  old, AT_FDCWD, new)` (nr 38) on aarch64, which dropped the bare `rename`
  syscall. 0 on success, -1 on failure — the same shape `fs_remove` returns.

**These calls block their worker's OS thread for the syscall's duration, and
that is not a netpoller gap.** POSIX has no non-blocking read of a regular file:
`epoll`/`kqueue` always report one as ready. The netpoller (§11) exists for
sockets and pipes. A file read therefore stalls one worker, never the process —
other green threads on other workers keep running.

---

## 15. Maps (`runtime/root`)

`map<K,V>` (SPEC §11.2, §13.5) is a `MapHeader` GC object over three parallel
`cap`-slot buffers — an open-addressing hash table with linear probing.

```
MapHeader {
  keys: [*]u64          // +0   slot keys   (ref-array iff key_is_string) — traced
  vals: [*]u64          // +8   slot values (ref-array iff val_is_ref)    — traced
  ctrl: [*]u8           // +16  per-slot state: 0 EMPTY / 1 FULL / 2 TOMB — traced base
  len:  usize           // +24  live entries
  cap:  usize           // +32  slot count (power of two, >= 8)
  used: usize           // +40  FULL + TOMB (drives growth)
  key_desc: usize       // +48  0 scalar / 1 string / else a descriptor (§15.1)
  val_is_ref:    usize  // +56
}
```

`map_info`'s pointer map is `{0, 8, 16}`: the three buffer bases are traced as
references. The `keys`/`vals` buffers use `ref_array_info` (every word traced)
exactly when their flag is set — for `keys` that is `key_desc != 0`, i.e. every
reference key type, `string` and composite alike. The `ctrl` buffer is always a
leaf; tracing its base only keeps it alive. Empty, tombstoned, and unused slots
hold a zero key/value word, which `markRoot` skips.

`key_desc` itself is NOT traced and must not be: it is either a small integer or
the handle of a string CONSTANT, which is static for the life of the process.

- **Word model.** A key or value is one word, same as slice elements (§2): a
  scalar by value, a `string` as its `*RtBytes` object base, a wider `V` boxed.
- **Hash / equality.** `key_desc` picks the strategy: `0` hashes the word with a
  splitmix64 finalizer (so low-entropy integer keys avalanche) and compares by
  word; `1` Wyhashes a string key over its bytes and compares byte-wise; anything
  else is a composite key hashed and compared through its descriptor (§15.1).
- **Growth.** At `(used+1)*8 >= cap*7` the table doubles and rehashes, dropping
  tombstones (`used` resets to `len`). This keeps an EMPTY slot present at all
  times, so every probe terminates in `<= cap` steps (a statically bounded loop).
- **Delete** leaves a `TOMB` and zeroes the slot's key/value words (dropping the
  refs so a removed entry becomes collectable); the tombstone is reclaimed at the
  next grow.
- **Nil.** Reads on a nil map (`?*MapHeader == null`) yield the zero word /
  `false` / `0`; `map_set` on a nil map is fatal (SPEC §11.2, Go semantics).
- **Iteration** (`for (k, v) of m`, §13.5) is by slot cursor: `map_iter_init`
  returns the first FULL slot or `-1`, `map_iter_next` the next after `prev`,
  then `map_key_at`/`map_val_at` read the pair. Slot order is unspecified and the
  protocol assumes no concurrent mutation (a resize would invalidate the cursor).

### 15.1 Composite values — descriptor programs

| symbol | signature |
|---|---|
| `bit_rt_value_eq` | `(a: usize, b: usize, desc: *const RtBytes) -> bool` |

SPEC §14.6 makes a class comparable **field-wise** and a tuple **element-wise**.
Both are one traced handle to a heap box (§1, §1.1), so comparing the word asks
"same allocation?" — which is what `==` did, and what the map hashed keys by.

**The runtime cannot recover the shape on its own.** A `TypeInfo` (§2) says which
body words hold references but not what kind: a `string` field and a nested
class field are both one traced word. Worse, a string LITERAL is a static
`{ptr,len}` pair in `.data` with no GC header at all, so there is no descriptor
to read off it. The compiler therefore emits a **descriptor program** — a string
constant, one byte per body word — and passes it at the comparison site and to
`map_new`.

```
'{' item* '}'   an aggregate; its items describe consecutive 8-byte body words
'w'             a raw word, compared and hashed BY VALUE
's'             a `string` handle, compared and hashed BY ITS BYTES
'r'             an opaque reference (slice, map, chan, func, interface, payload
                enum), compared and hashed BY IDENTITY
'{' ... '}'     a nested class or tuple: dereferenced and walked
```

`class P { x: int, name: string }` is `{ws}`; `class Q { p: P, n: int }` is
`{{ws}w}`. The producer is `descProgram` in `compiler/lowerprim.bit`; the
consumers are `descEqAgg` and `descHashAgg` in `runtime/root/maps.bit`.

- **Equality and hashing are ONE walk.** The two interpreters read the same
  program and take the same cases in the same order, so `eq(a,b)` implies
  `hash(a) == hash(b)` case by case. A hash that disagreed with equality gives a
  map that silently loses entries, so this correspondence is a contract, not an
  optimisation: the two functions must be edited together.
- **Bounds.** The generator stops at 6 levels of nesting and a 96-word total
  budget, emitting `'r'` past either; the interpreters stop at 8 levels. Every
  loop in both is bounded by the program's length.
- **Floats compare by bit pattern inside a composite**, where a bare `f64 ==` is
  IEEE. This keeps composite equality reflexive — a key not equal to itself
  could never be found or deleted — and matches what a bare `map<f64,int>` key
  already does. `+0.0` and `-0.0` therefore differ in a field.
- **A field whose type is not comparable** (a slice, a map) gets `'r'`: identity,
  which is total and consistent with the hash, rather than failing the whole
  comparison. The checker's `vComparable` is deliberately permissive on structs
  (`compiler/validateattr.bit`), so such a field does reach lowering.

---

## 16. Test selection (`bit test`)

```
bit_rt_test_index() -> i64   // BIT_TEST_INDEX, or -1 when unset/unparsable
```

The one runtime hook `bit test` (SPEC §19) needs. `boot` captures the process
environment block; this reads `BIT_TEST_INDEX` out of it.

A failed `assert` panics, which aborts the process — so the runner cannot loop
over tests in one process without the first failure taking the rest down. It
instead compiles the module **once**, with `compiler/testgen.bit` appending a
synthetic `main` that calls this function and dispatches to that single test,
then execs the binary once per test with `BIT_TEST_INDEX` set. An unset or
out-of-range index matches no test and returns cleanly, so running a test binary
by hand is a harmless no-op.

---

## 17. Math (`runtime/root`)

The low-level layer under `std/math`. `floor`/`ceil`/`round`/`trunc`/`sqrt` are
single instructions on both targets; `pow`/`atan2`/`log`/`log2`/`log10` are the
toolchain's own libm-free implementations.

**`sin`, `cos`, `tan`, and `exp` are deliberately absent.** The toolchain exposes
them only as builtins that lower to libm calls (`sin`, `exp`, …), and a Bit
binary links no libc. They arrive with a freestanding implementation, not as a
silently-approximate stand-in.

> The `log` family is table-driven, which is what made it the first thing to
> notice the AArch64 mapping-symbol bug: a mis-atomized `.rodata` literal pool
> shifted the lookup tables and these returned garbage while table-free fast
> paths stayed exact. `tests/cases/run_math.bit` guards that.

**`bit_rt_float_bits`/`bit_rt_float32_bits` are not math functions — they
reinterpret an f64/f32's IEEE-754 bit pattern as a same-width unsigned integer
with no value conversion** (`FMOV`/`movq` on both targets). They are the only
way a Bit program can observe `-0.0` or distinguish two NaN payloads, since
`==` reports `-0.0 == +0.0` as true and `NaN == NaN` as false either way.
Since #1442 the compiler's own `floatBits`/`float32Bits` primitives lower to
an inline `Op.Bitcast`, not an `ir.RtFn` call (`compiler/lowerprim.bit`), so
neither pinned symbol is reached by generated code — `tests/bit/rootpins/`
proves that (§9). The exports (`runtime/root/floats.bit:121-129`) remain
because `tests/stress/rootfloat` links and calls them directly as ordinary
`bit_rt_*` C ABI entry points, and because they are `runtime/root`'s port of
the same-named symbols the pre-selfhost runtime shipped.

---

## 18. Time (`runtime/root` + `runtime/sched`)

```
bit_rt_time_mono_ns()      -> i64   // monotonic; the only clock that measures elapsed time
bit_rt_time_unix_ns()      -> i64   // wall clock, ns since the Unix epoch; may jump
bit_rt_time_sleep_ns(ns)   -> void  // park this green thread for >= ns
```

`bit_rt_time_sleep_ns` converts the relative `ns` to an absolute monotonic
deadline (`bit_rt_time_mono_ns() + ns`) and clamps that deadline to `i64max`
nanoseconds rather than let the addition overflow and wrap negative, so a
duration near `i64max` never wakes early.

`sleep` records a deadline on the `Task`, then `park`s with a `ParkFn` that
links it onto the scheduler's `TimerQueue` — the same "register only after the
context is safely saved" point the netpoller uses (§11), which is what
guarantees the task is observably `.parked` before another worker can wake it.

A worker expires due timers on its **idle** path, before polling the netpoller,
and its idle backoff is capped at 1ms — so once a worker has nothing else to
run, a timer fires within about a millisecond of its deadline. A deadline never
preempts a running task, consistent with the cooperative scheduler (a CPU-bound
task already starves its worker).

`TimerQueue` is an unsorted intrusive list: O(1) insert, and `expire` is one
bounded pass over the live sleepers. A thousand green threads sleeping 50ms
finish together, in ~50ms, on one OS thread.

---

## 19. OS (`runtime/root`)

```
bit_rt_os_argc()           -> i64
bit_rt_os_arg_at(i)        -> *const RtBytes   // "" when out of range
bit_rt_os_env(name)        -> *const RtBytes   // "" when unset
bit_rt_os_self_exe()       -> *const RtBytes   // own path, symlinks resolved; "" if unknown
bit_rt_os_exit(code)       -> noreturn         // deferred calls do not run
bit_rt_os_run(path, argv)  -> i64              // child exit code; argv ([]string) appended after path; -1 on failure, <= -100 signal-killed
bit_rt_os_run_test(path, i) -> i64             // like os_run + BIT_TEST_INDEX=i (no argv)
bit_rt_os_run_bounded(path, timeout_ms)      -> i64  // os_run, killed if it outlives timeout_ms
bit_rt_os_run_test_bounded(path, i, timeout_ms) -> i64  // os_run_test, same bound
bit_rt_host_target()       -> i64              // host BuildTarget ordinal (0/1/2)
bit_rt_auxv()              -> i64              // ELF auxv address; 0 when none
```

`argc`/`argv`/`envp` are captured by the process entry (§9) on both the raw-stack
Linux path and the Darwin `machoMain` path; `boot` captures the environment block.
Bit has no nil string, so an unset variable and one set to `""` both read empty.

`bit_rt_os_run` runs the executable at `path` as a child process, with `argv` (a
`[]string`, or a null `SliceHeader` for the empty/default slice) appended to the
child's own argv after `path` — `arg(0)` is `path` itself, exactly as it is for a
binary the caller execs directly. The child inherits the captured `envp`. It is
`bit run`'s launcher (`bit test` uses the separate `bit_rt_os_run_test` below) —
`fork` + immediate `execve` (Linux: raw syscalls; Darwin: libSystem), the only
work between fork and exec, so it is safe with scheduler worker threads live.
Result encoding, the same one the bounded pair below uses minus the `-2` case it
has no deadline to produce (#2019):

```
 >= 0     child exited normally with this code (0-255)
 -1       spawn/exec/wait failure, or the child stopped rather than exited
 <= -100  child was killed by a signal; signal number is -(result) - 100
          (e.g. -111 = SIGSEGV)
```

The `<= -100` case used to collapse to `-1`, which made a program that ran and
then crashed indistinguishable from one that never started — `bit run` reported
every segfault as "could not run". A caller that only tests `code < 0` keeps its
old behaviour; one that wants the distinction subtracts.

**`bit_rt_os_run` gained `argv` in place (#2399, `bit run <src> [args...]`)
rather than through a new symbol beside it.** A new symbol was tried first and
reverted: `compiler/build.bit` — part of `compiler/`'s own self-hosting
source — is what needed to call it, and `compiler/`'s own build (`./make
selfhost`) is compiled by the PINNED stage0, a published release
(`dist/stage0/SHA256SUMS`). Stage0 has no idea a brand-new predeclared name
exists, so a call to one fails `E0040: undefined name` on every clean build
until the next stage0 repin — which itself needs a published release first,
a circular requirement a single commit cannot satisfy. Reusing the
ALREADY-recognized `osRun` identifier sidesteps that entirely: this compiler
validates no builtin call's arity (`compiler/validatecall.bit`'s `vCall`),
so stage0 accepts a 2-argument call to a name it has always known, with
nothing new required of its own predeclared-name table. Every caller was
updated in the same commit instead: `compiler/build.bit`'s `runCmd`,
`compiler/pmfetchtail.bit`'s `runGit`, and the fixtures that call the
predeclared `osRun` builtin directly rather than through a `std/os` wrapper
(none exists) — `tests/cases/fs_walk_symlink.bit`,
`tests/imports/pmadd_e2e/main.bit`, `examples/staticserver/staticserver.bit`.

`argv` is a `[]string` SliceHeader (§2), or a null header for the empty/default
slice — the same content the old fixed `[path, NULL]` construction always
sent. The child sees `[path, argv[0], ..., argv[n-1], NULL]`; `path` is
`arg(0)` from the child's own `bit_rt_os_argc`/`bit_rt_os_arg_at`, exactly as
it was before and as it is for a binary the caller execs directly.

The runtime builds this argv vector into a FIXED buffer (Power of 10 rules
2/3: no unbounded allocation, no unbounded loop), so it is capped at
`osRunMaxArgv` (64) forwarded elements of at most `osRunMaxArgLen` (4096)
bytes each (`runtime/root/os.bit`'s consts). Above either bound the call is
REJECTED — `bit_rt_os_run` returns `-1`, the same sentinel a spawn failure
uses — never truncated: a silently shortened argument would be the same
class of bug #2023 closed for a silently dropped one. `compiler/build.bit`'s
`runMaxForwardedArgs` mirrors the count so `bit run` itself reports a
specific, named rejection before ever reaching the runtime's generic one.

`bit_rt_host_target` returns the ordinal of the `BuildTarget` this binary's own
host matches (0 `x86_64-linux`, 1 `aarch64-linux`, 2 `aarch64-macos` — the enum in
compiler/build.bit). The runtime archive is compiled once per target, so the answer
is fixed when the archive is built; the Bit provider (#1635) takes the OS from its
own provider directory and the arch from an `asm` per-arch immediate, the code it
replaces read `builtin.target`. It is the default `bit build`/`bit run` target when
`--target` is absent, so a wrong ordinal silently mis-targets the compiler.

`bit_rt_auxv` returns the address of the ELF auxiliary vector the kernel placed
on this process's initial stack, or 0 where there is none (Darwin, which has no
auxv at all). The initial stack is unreachable once any Bit code is running, so
the pointer has to come from the process entry (§9) — but the SCAN over it is
Bit's own: `runtime/auxv` walks the `(a_type, a_un.a_val)` pairs to `AT_NULL`,
which is `getauxval`. `runtime/thread/linux` reads `AT_PHDR`/`AT_PHNUM`/`AT_PHENT`
through it to find `PT_TLS` and size a spawned thread's TLS block.

`bit_rt_os_run_test` is the same fork+exec launcher with `BIT_TEST_INDEX=<idx>`
prepended to the child's environment (first match wins, so it overrides any
inherited value). `bit test` calls it once per discovered test so the test
binary's synthetic `main` (compiler/testgen.bit) dispatches to test `idx`.

**`bit_rt_os_run_bounded`/`bit_rt_os_run_test_bounded` are `os_run`/`os_run_test`
with a wall-clock deadline (#1744).** `os_run`'s synchronous `waitpid` blocks the
calling green thread forever if the child never exits, exactly the hazard
the harnesses needed closed (#1637/#1652) —
and one a Bit harness needs closed the same way, since nothing
else in this ABI lets Bit code bound a subprocess wait. `os_run`/`os_run_test`
themselves are unchanged: `bit run`/`bit test` still depend on their unbounded
semantics for real user programs, so the bound is a new, separate primitive
rather than an added argument to the existing two.

Same fork+exec as `os_run`, but the parent polls `waitpid(WNOHANG)` on a
`sched.sleepNs`-paced interval instead of blocking, checking the monotonic
clock (`sched.monoNs`, ABI.md §18's layer) against a deadline resolved from
`timeout_ms` once, before the first poll — the same "one absolute deadline,
not a per-iteration timeout" shape the harnesses use, so a chatty or
CPU-bound child cannot restart the clock. The child is placed in its own
process group (`setpgid`, both sides, immediately after fork — the standard
race-free idiom) with pgid equal to its own pid, so anything it or a wrapper
it execs (e.g. a harness's `/bin/sh` script) later forks inherits that same
group unless it detaches on its own. **If the deadline elapses before the
child exits, the parent `SIGKILL`s the whole group, not just the direct
child, and reaps the direct child before returning** (#2986: a single-pid
kill left a grandchild — a compile the direct child's wrapper shell had
spawned — running indefinitely, reparented to pid 1, after the timeout had
already been reported). Result encoding (three outcomes in one `i64`, no
separate signal channel):

```
 >= 0     child exited normally with this code (0-255)
 -1       spawn failure (fork/exec/wait error) — same sentinel as os_run
 -2       timed out: the deadline elapsed, so the child was SIGKILLed and reaped
 <= -100  child was killed by a signal observed during a poll; signal number
          is -(result) - 100 (e.g. -109 = killed by SIGKILL from outside)
```

`-2` and `<= -100` stay distinct on purpose: `-2` means the *runtime* killed the
child on a budget, `<= -100` means something else killed it first. `timeout_ms`
is clamped to one hour (`os_run_bounded_max_ms`), matching the harnesses'
own `max_timeout_s` clamp, so a caller typo cannot reinstate an unbounded wait; the
poll loop's iteration count is bounded by that clamp divided by the poll
interval (Power of 10 rule 2) rather than an open-ended `while (true)` — the
deadline check inside the loop is what actually ends every real call.

**`hostTarget()` and `auxv()` are compiler `prim_rt_fns` entries — the CALLER side
lowers to an `ir.RtFn` that codegen emits as a call to the symbol itself, and
that lowering stays permanent for both (SEAM 6, #1580).** A Bit *provider* whose
body called the primitive would therefore be a call to itself, now that #1369
has dropped the `_root` infix (the pin cycle `tests/bit/rootpins/` guards). Both are
PORTED regardless — `auxv` by #1617, `host_target` by #1635 — each by finding the
answer somewhere other than the primitive:

- `host_target` is a **property of the emit**, not a runtime computation. The
  archive is compiled once per target, so its `builtin.target` *is* the build
  target — each per-target `libbitrt.a` returns its own ordinal (x86_64-linux → 0,
  aarch64-linux → 1, aarch64-macos → 2). Since the compiler selects the archive by
  `--target` (`libbitrtPath`), a cross-built binary reports the target it was
  built FOR, not the host it was built ON.

  **The provider is `runtime/root/linux/os.bit` or `runtime/root/darwin/os.bit` (#1635), selected by
  the OS axis below.** The old claim here, that a running Bit program has no
  compile-time `builtin` and so this could never be ported, mistook "no `builtin`"
  for "no compile-time knowledge". The emit carries both axes the ordinal needs:
  - the **OS** is *which provider directory the source sits in* —
    `runtime/root/linux/os.bit` vs `runtime/root/darwin/os.bit`. Mis-selection is a
    compile error, not a wrong answer: a Darwin `--emit-obj` refuses the Linux
    provider's `syscall` and a Linux one refuses the Darwin provider's
    `extern fn`, both even on an uncalled declaration.
  - the **arch** is an `asm` block's per-arch sub-blocks (SPEC §11.6), which the
    backend selects at codegen — `runtime/sched/sched.bit`'s `entryBias` shape.
    This is the axis the directory split does NOT draw, and x86_64-linux vs
    aarch64-linux is exactly where it is needed.

  x86_64 exists only on Linux among the three recognised targets and Darwin is
  aarch64-only, so (provider, arch) names all three exactly; Darwin therefore needs
  no `asm` at all and returns the literal 2. The provider must never call
  `hostTarget()` — that primitive lowers to a call to this very symbol, now that
  #1583 has dropped the `_root` infix (the pin cycle `tests/bit/rootpins/`
  guards) — and an `asm` immediate is inline by construction, so there is no
  callee for the rename to redirect. Verified running on all three targets, not
  just by disassembly:
  `tests/stress/roothost{darwin,linux}`.
- `auxv` is a **process-entry fact owned by the boot layer (SEAM 3, #1576)**, and
  `bit_rt_auxv`'s provider is `runtime/root/os.bit` (#1617). The kernel places the
  auxiliary vector on the initial stack, unreachable once any Bit code runs, so only
  the entry (`rtStartMain`) can capture it — a single writer, Linux-only;
  `machoMain` captures none. The Bit Linux entry walks past `envp`'s NULL to the
  auxv array and stores its address, through `bit_rt_port_root_os_set_auxv`, into
  the cell `runtime/root/os.bit`'s `gAuxv` owns (beside `g_argc`/`g_argv`/`g_envp`);
  the reader `bit_rt_auxv` hands that cell back. This is the move promised
  above — ownership of the cell moved from `runtime/root/root.bit`'s `g_auxv`
  to the boot layer (the old `g_auxv`/`bit_rt_auxv` stayed live only until the
  #1369 archive swap made the Bit entry the real one, which it now is). The reader
  reads `gAuxv` DIRECTLY, never through the `auxv()` primitive, precisely to avoid
  the self-reference the pin-cycle gate forbids; `runtime/auxv` still does the scan
  (`getauxval`) over what the reader returns, and `runtime/thread/linux` reads
  `AT_PHDR`/`AT_PHNUM`/`AT_PHENT` through it to size a spawned thread's TLS block.
  Darwin's `gAuxv` stays 0 (the reader is platform-free so the portable
  `runtime/auxv` resolves the symbol there too), and the vector must never be
  captured a second time.

---

## 20. Networking (`runtime/net` + `runtime/root`)

The low-level layer under `std/net`/`std/http`. Every socket is `O_NONBLOCK`; an
operation that would block registers its fd with the netpoller (§11) and parks
the calling green thread rather than blocking an OS thread. Addresses are
dotted-quad IPv4 literals — a socket is closed by `bit_rt_fs_close`.

```
bit_rt_net_listen(host, port)   -> fd    // TCP listener; port 0 = kernel picks. -1 on error
bit_rt_net_local_port(fd)       -> port  // the bound port (recovers a port-0 choice). -1 on error
bit_rt_net_accept(fd)           -> fd    // next connection; parks. -1 on error
bit_rt_net_dial(host, port)     -> fd    // connected socket; parks past the handshake. -1 on error
bit_rt_net_read(fd, max)        -> str   // up to max bytes; parks. "" at end of stream OR on error
bit_rt_net_write(fd, s)         -> n     // all of s (retried internally). -1 on error
```

**UDP** (connectionless). `recv` records the sender in per-OS module state,
**one `[4]i64` sockaddr and one valid flag PER WORKER** (fixed by #3272) —
`udpSenderBuf`/`udpSenderValid` (`runtime/net/linux/netabi.bit:407-408`;
`runtime/net/darwin/netabi.bit:396-397`), indexed by the calling task's own
worker id (`wkId`, §9's `runtime/sched/worker.bit`) via `udpSenderSlot()`,
double-bounded against `schedMaxWorkers` and the file's own array capacity —
read back by the two accessors with no intervening park. This is neither a
threadlocal nor the §13 per-task scratch slot: the provider's own header
says so outright ("THE LAST SENDER IS PER-WORKER SCRATCH, NOT A
THREADLOCAL", `runtime/net/linux/netabi.bit:355`).

**Before #3272 this was a single SHARED slot for the whole process** — sound,
the header used to claim, "only because v1 pins the scheduler to one worker
(§5/§9)". That was false as soon as #1900 booted more than one worker: two
green threads on two OS threads racing `recv` clobbered the shared flag —
one succeeds and sets it, the other (a different worker) zeroes it, the
first reads back "no sender" — and one such clobber on a listener socket
wedged it permanently (`stdlib/quic/listener.bit`'s `catch _ { return }`,
found via #1912). Per-worker slots fix the concurrent-task case; they remain
sound under a single task's own migration between the two calls too,
because `netRecvFrom`'s park is the only park in `udp_recv`, and the slot is
chosen only AFTER that park returns — see the provider's own header comment
for the full argument. A failed `recv` returns `""` with `sender_port` `-1`,
which is how it is told from a legitimate zero-length datagram (whose
sender port is `0..65535`).

```
bit_rt_net_udp_bind(host, port)         -> fd    // datagram socket; port 0 = kernel picks. -1 on error
bit_rt_net_udp_send(fd, host, port, s)  -> n     // one datagram (all-or-nothing). -1 on error
bit_rt_net_udp_recv(fd, max)            -> str   // next datagram; parks. records the sender
bit_rt_net_udp_sender_host()            -> str   // last recv's sender ip, or "" on error
bit_rt_net_udp_sender_port()            -> port  // last recv's sender port, or -1 on error
```

**DNS.** `resolve` returns the first A record for `host` as a dotted quad, or `""`
on failure; a dotted-quad `host` passes straight back. Unlike the socket calls it
uses a **blocking** UDP socket with `SO_RCVTIMEO` and bounded retransmits, not the
netpoller — it blocks the calling worker for up to ~2s on a lost packet, the
right trade for an occasional lookup (see the note in `runtime/net/net.bit`).

```
bit_rt_net_resolve(host)        -> str   // first A record, dotted quad. "" on failure
```

**Deadline-bounded dial/read/write (#2291).** A server that completes the
handshake (or accepts) and then never writes parks `bit_rt_net_read`/
`bit_rt_net_dial` above forever — nothing bounds their park on the netpoller.
These three give `std/net`'s `dialDeadline`/`readDeadline`/`writeDeadline` a
way to bound it instead, resolving ONE absolute monotonic deadline before the
first poll and never restarting it — the same "resolve once, never
per-iteration" shape §19's `osForkExecWaitBounded` uses. They are reached
through a plain `extern fn`, not the compiler-recognized builtins the four
entries above lower to, because §11.7 admits no `string` across an `extern`
boundary: `host`/the written body cross as a raw pointer into a packed Bit
`[]byte`'s backing (§2, #3121/#3226) plus a length, and a read result is
written into the caller's own such buffer rather than returned as a fresh
string, the same shape §14's `bit_rt_fs_is_symlink_w` uses. `deadlineNs` is an
absolute
monotonic nanosecond value on the same clock `bit_rt_time_mono_ns` reaches
(§18); `<= 0` (a `Conn`'s zero value) or further out than the wait ceiling
below both clamp to it — a caller typo must not reinstate an unbounded wait,
the same reasoning the §19 clamp documents.

```
bit_rt_net_dial_deadline_w(hostWords, hostLen, port, deadlineNs)  -> fd  // -1 hard failure, -2 timed out
bit_rt_net_read_deadline_w(fd, outWords, cap, deadlineNs)         -> n   // writes into outWords; 0 = peer closed; -1 hard error; -2 timed out
bit_rt_net_write_deadline_w(fd, words, n, deadlineNs)             -> n   // bytes written; -1 hard error; -2 timed out
```

Implemented as a poll-and-sleep loop (`runtime/net/{darwin,linux}/tcp.bit`'s
`net{Read,Write}SockDeadline`/`netDialTcpDeadline`), not by adding a
poll/timer race to the scheduler: on each `EAGAIN` the deadline is checked,
then the calling task sleeps a short, bounded slice (2ms, matching §19's
`osPollNs`) via `schedSleepUntil` before retrying the syscall itself, capped
at a one-hour wait ceiling (`os_run_bounded_max_ms`'s own clamp) expressed as
a worst-case poll count so the loop is statically bounded either way. No
`gcSyscallBegin`/`gcSyscallEnd` bracket: every syscall this touches
(`read`/`write`/`connect`) runs on this provider's always-non-blocking
sockets, so each returns immediately rather than holding the OS thread in
the kernel — exactly as the unbounded `bit_rt_net_read`/`_dial` above do with
no bracket either.

---

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

## 21b. Hardware crypto fast paths (`runtime/cryptohw` + `runtime/cryptohw`, task #1223)

x86-64 AES-NI / PCLMULQDQ / SHA-NI, runtime-CPUID-gated, reached from
`stdlib/crypto/{aes,gcm,sha256}.bit` through plain `extern fn`
declarations (SPEC.md §11.7) rather than the `RtFn` mechanism §12-§21 above
use — every parameter and result is a scalar or raw pointer (`extern
fn`'s exact admission rule), so no compiler-side wiring (`RtFn` enum,
lowering table, in either compiler) is needed. Highest-value primitives only,
per the task's own scope: **ChaCha20/Poly1305 SIMD acceleration is an
explicitly deferred follow-up**, not covered here.

```
bit_rt_crypto_aes_hw_available()      -> bool   // AES-NI usable: AES + AVX + OS XSAVE
bit_rt_crypto_ghash_hw_available()    -> bool   // PCLMULQDQ usable: PCLMUL + AVX + OS XSAVE
bit_rt_crypto_sha256_hw_available()   -> bool   // SHA-NI usable: SHA + AVX2 + OS XSAVE

bit_rt_crypto_aes_encrypt_hw(rk: *byte, nr: i64, block: *byte, out: *byte)
bit_rt_crypto_aes_decrypt_hw(drk: *byte, nr: i64, block: *byte, out: *byte)
bit_rt_crypto_aes_invert_schedule_hw(erk: *byte, nr: i64, out: *byte)
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
result on first use. `BIT_CRYPTO_NO_HW=1` (or `on`) forces every
`bit_rt_crypto_*_hw_available` false, read once at the same first-use point,
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

## 21c. ARM64 crypto hardware-capability detection (`runtime/cryptohw`, #2520, epic #1224)

```
bit_rt_crypto_hwcaps() -> u64   // bit 0 = AES, bit 1 = PMULL, bit 2 = SHA2
```

The ARM64 mirror of §21b's x86-64 probes, and unlike them, a real
implementation rather than an ABI-membership placeholder: it is the feature
*detector* epic #1224's remaining children build the AESE/PMULL/SHA256H
primitives and stdlib routing on top of.

**Per-target behavior**, split across `runtime/cryptohw/{linux,darwin}/cryptohw.bit`
because each side calls something the other cannot even compile (§19's
`syscall`/`extern function` split applies here too):

- **aarch64-linux**: bit `i` is set when `getauxval(AT_HWCAP)` (`runtime/auxv`)
  has the matching Linux `HWCAP_*` bit — `HWCAP_AES` (1<<3), `HWCAP_PMULL`
  (1<<4), `HWCAP_SHA2` (1<<6) — set.
- **aarch64-macos**: bit `i` is set when the matching `sysctlbyname` reads back
  1 — `hw.optional.arm.FEAT_AES`, `hw.optional.arm.FEAT_PMULL`,
  `hw.optional.arm.FEAT_SHA256`.
- **x86_64-linux** (shares the `linux` archive member with aarch64-linux —
  `scripts/g2archive.sh`'s target->PLAT mapping) **and every other target**:
  always 0. An x86-64 `AT_HWCAP` value has no relationship to ARM crypto
  extensions, so the linux provider gates on `onX64()` (`runtime/syscalls`)
  before reading it at all, rather than testing bits that would coincidentally
  sometimes be set.

**Computed once, cached in a module-level variable** in whichever OS provider
is actually linked — a fresh process reads its `AT_HWCAP` word or its three
`sysctlbyname` results exactly once, and every later call returns the cached
bitmask. Racing initializers on the first call are harmless: every racing OS
thread reads the identical hardware state and would cache the identical
value, the same argument `runtime/park/darwin/wait.bit`'s cached mach
timebase makes.

---

## 21d. ARM64 AES block cipher and key schedule (`runtime/cryptohw/armaes.bit`, #2522, epic #1224)

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
function starts `if (onX64()) return` — a no-op on x86_64, since Bit has no
arch-conditional compilation (SPEC §11.8).

**THE EXTENSION IS OPTIONAL ON AARCH64**, unlike NEON — a Cortex-A72 (the
chip in a Raspberry Pi 3/4, and this project's own remote `mypi` fleet
includes one) has no AES instructions, and issuing one is `SIGILL`. So every
exported function also calls `aesRequireHwSupport`, which reads bit 0 (AES)
of `bit_rt_crypto_hwcaps()` and panics with a clear message rather than
letting the CPU fault — a diagnosable panic beats a raw illegal-instruction
crash, which is worse than the alternative of simply being slower.

**NO CALLER YET.** These three pins exist so #2526 (route `stdlib/crypto`'s
AES through them) has something to call; wiring them up hits the same
stage0-bootstrap wall #2521 documented and needs its own release + repin.

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

## 21e. ARM64 GHASH (`runtime/cryptohw/armghash.bit`, #2523, epic #1224)

```
bit_rt_ghash_hw_mul(h, x, out)             // out = H*X in GF(2^128), GCM bit order
bit_rt_ghash_hw_blocks(h, state, data, blocks)  // fold `blocks` 16-byte blocks into state
```

Every pointer is a raw address (`int`) except `blocks`, a `u64` count.
`h`/`x`/`out`/`state` point at 16-byte buffers; `data` at `16*blocks` bytes.
`bit_rt_ghash_hw_mul`'s `out` may alias `h` and/or `x` — both operands are
fully read before `out` is written. `bit_rt_ghash_hw_blocks` implements the
same recurrence `stdlib/crypto/gcm.bit`'s software `gcmAbsorb` does: `state =
(state XOR block) * H`, once per block, in order.

**PLATFORM-FREE**, same reasoning as §21d's AES pins — one source file per
TARGET, every exported function starts `if (onX64()) return`, and every
exported function also calls `ghashRequireHwSupport` (bit 1, PMULL, of
`bit_rt_crypto_hwcaps()`) before issuing PMULL/PMULL2, for the same "optional
extension, SIGILL otherwise" reason §21d documents for AES.

**NO CALLER YET**, same as §21d — these pins exist for a later ticket to wire
`stdlib/crypto/gcm.bit` through.

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

## 22. Shared mutable state audit (#1248)

Every container-scope mutable in `runtime/**/*.bit` (grep: `^let ` at module
scope — this port has no module-scope `var` anywhere in `runtime/`, and
`^threadlocal var` matches nothing at all: Mach-O rejects `@threadlocal` in
the freestanding emit, so no runtime module uses it), classified per-worker /
per-task / synchronized, with why. This is the M:N epic's enumeration ticket
— §5 and §13 above already argue the two hardest cases (mutator
registration, the error slot) in depth; this section is the complete list so
nothing was skipped.

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
  stop-the-world Mutator registry. NOT `root.bit`: #2184 moved it once
  `ptrOf` on module data was fixed (#1421), retiring the caller-owned bind
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

**Per-task scratch (#1577 — NOT module state and NOT `threadlocal`, the
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
- `last_fs_read_all_failed` (§14, #2994) — `bit_rt_fs_read_all_failed`
  (`slots.bit`'s `rtFsReadAllFailed`) reads `scrFsReadFailed`, word 265 of the
  same per-task block (`scratch.bit`'s `scrFsReadFailed`). Same file and
  mechanism as `pending_err`/`last_recv_ok` above. #3065 (pass 1 of #2996)
  re-added the word and the accessor pair with no caller; #2996 (pass 2) wired
  `runtime/root/{darwin,linux}/fs.bit`'s `rtFsReadAll` to publish it on its
  `end < 0` and `s == 0` paths (cleared at entry, so a prior call's outcome on
  this task never leaks into the next) and `stdlib/fs/fs.bit`'s
  `File.readAll` to read it.
- `iface_as_ok` (§2.2, #3280) — `runtime/root/iface.bit`'s `rtIfaceAs`/
  `rtIfaceAsOk` (`bit_rt_iface_as`/`bit_rt_iface_as_ok`) read/write
  `scrIfaceOk`, word 266 of the same per-task block
  (`runtime/sched/scratch.bit:98`). Same file and mechanism as the three
  entries above. **Until #3280 this was a single process-wide word**
  (`runtime/root/root.bit`'s `let ifaceOk: i64 = 0`, now removed), sound only
  against a second assertion on the *same* task — adjacency does nothing to
  stop a different, concurrently running OS thread from writing the same
  global word once `BIT_WORKERS>1`, the identical false conclusion #3272 and
  #3273 disproved for their own buffers. Reproduced and fixed by moving the
  flag to per-task scratch, the same migration-safety reason `scrRecvOk` and
  the error slot are shaped this way.

**Per-OS-thread by design, each because nothing between the write and its
matching read can cross a scheduling point — a green task migrates workers
only at an explicit yield/park, never mid-expression — AND each slot really is
per-worker storage, not a single shared word (§5.1):**
- `runtime/net/{linux,darwin}/netabi.bit`: `udpSenderBuf`/`udpSenderValid`
  (`linux/netabi.bit:407-408`; `darwin/netabi.bit:396-397`) — per-OS, not
  `root.bit`, and NOT a `threadlocal` (Mach-O refuses one, §11.11).

  **UNTIL #3272 this bullet described a SINGLE shared slot for the whole
  process**, claimed sound "only because v1 pins the scheduler to one worker
  (§5/§9)". That claim was false as soon as #1900 booted more than one
  worker: two tasks on two OS threads racing `udp_recv` clobbered the one
  shared flag, and #1912 traced a permanently wedged UDP listener to exactly
  that. Fixed by giving each WORKER its own `[4]i64`/valid-flag slot, indexed
  by the calling task's own worker id (`wkId`, `runtime/sched/worker.bit`)
  via `udpSenderSlot()`, double-bounded against `schedMaxWorkers` and the
  array's own literal capacity (the same shape `runtime/sched/preempt.bit`
  uses for `startNs`/`requested`). It belongs in this category **now**, post-fix,
  because there are genuinely `schedMaxWorkers` separate words, not one.

  `udp_recv` contains a real park (`netRecvFrom`, on the same engine
  `netAbiRead` uses), so the task CAN resume on a different worker mid-call.
  The slot is therefore chosen only AFTER that park returns, from the worker
  id current at that point, and the raw `recvfrom` output is held in a
  throwaway per-call scratch until then — see the provider's own header
  comment (`linux/netabi.bit:355` / `darwin/netabi.bit:343`) for the full
  argument. From the point the slot is chosen to `udp_sender_host`/`_port`'s
  read, adjacency holds: nothing parks in between, so the two see the same
  slot — and that slot is this task's worker's own, not shared with any other.
- `runtime/sched/sched.bit`: `Worker.tls` — re-derived on every read from the
  running task's own stack pointer (`sched.bit:625`'s `schedCurrentTask`),
  never cached across a call boundary, specifically because a parked task can
  resume on a *different* OS thread (#1466): a cached thread pointer would
  hand back the previous thread's stale `Worker`. No global backs this at
  all, in this file or any other — there is nothing to race because there is
  nothing stored.

**NOT yet converted: NOT FOUND.** This category held exactly one entry,
`iface_as_ok`'s `ifaceOk` flag, and #3280 converted it to per-task scratch —
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
  only the unrelated `stwScanCtx` (`runtime/stw/stw.bit:485`, a saved
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
- `runtime/cryptohw/{linux,darwin}/cryptohw.bit`: `hwcapsCache` (#2520) — the
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
   pairing. This is `std/sync`'s implementation contract (#1251), not yet
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
   implementation, #1251) — the seq-cst-only raw builtins (§11.5) cannot be
   reused as-is for `Relaxed`/`Release`/`Acquire` because they hard-code the
   strongest ordering at every callsite.

**Why the GC-safety exception in SPEC.md §13.7 is precise, not hand-waved.**
§5's root scan trusts a stack slot's or register's declared shape at a
safepoint — it does not re-validate that a slice's `ptr` and `len` (or an
interface's `type` and `data`) were written together. A racing, non-atomic
write to a GC-traced multiword field can leave exactly such a torn value
sitting in a live slot; if a safepoint (§5) lands while it is there, the
collector scans it as if it were well-formed. This is the concrete mechanism
behind SPEC.md §13.7's claim that a composite-value race — never a
single-word one — is the one way otherwise-safe Bit code can reach real
memory-unsafety, and it is exactly why the audit in §22 above only needed to
reason about *runtime*-internal state: user Bit code gets no such audit for
free, which is the whole reason §13.7 and this section exist.

## 24. CPU sampling profiler (`runtime/root/darwin/prof.bit`, #1906)

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
render time. `std/prof` (userland API) and `tools/prof/render.bit`
(symbolizing reader) are the two halves built on top of these three symbols;
see their own file headers.
