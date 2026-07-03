# Runtime ABI

The binary contract between the **compiler** (codegen) and the **runtime** (GC,
scheduler, channels). Change this document first; codegen and runtime both
implement what it says. Anything not written here is not guaranteed.

Status: v1 covers the garbage collector (`runtime/gc.zig`). Scheduler and channel
sections land with their tickets.

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

---

## 2. Per-type pointer maps (`TypeInfo`)

The compiler emits one static `TypeInfo` per distinct (monomorphized) type and
passes a pointer to it at each allocation site.

```
TypeInfo {
    size        : usize          // body size in bytes, excluding the header
    ptr_offsets : []const usize  // ptr + len: byte offsets of GC-ref fields
    name        : []const u8     // static type name; debug/stats only, may be ""
}
```

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

---

## 4. Root scanning and stack maps

The collector is **precise**: at a safepoint it must learn exactly which
registers and stack slots hold live references, from compiler-emitted per-callsite
stack maps.

Runtime interface (`runtime/gc.zig`):

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
- Roots passed to `markRoot` obey §3 (base pointers or null).
- The exact stack-map encoding (per-callsite table format, how safepoints are
  keyed by return address) is defined by the codegen ticket that produces it; the
  runtime only requires that `scan` surfaces a precise, complete root set.

---

## 5. Safepoints and stop-the-world

- v1 is **stop-the-world**: no mutator observes the heap mid-collection.
- A **safepoint** is a program point where the stack maps are valid and the
  mutator may yield to the collector. Codegen inserts safepoint polls (at least at
  loop back-edges and function entry/allocation) so collection cannot be starved.
- v1 has a single mutator thread, so "stop the world" is "run the collector
  synchronously at the safepoint". When green threads land, the safepoint poll
  becomes the barrier that parks every thread before marking. The
  `Gc.safepoint(scanner)` entry point is that poll.
- The collector never moves objects (non-moving mark-sweep), so references are
  stable across a collection and no pointer fix-up is required.

---

## 6. Allocation and collection entry points

v1 exposes the runtime API in Zig (`runtime/gc.zig`); the runtime-init/codegen
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

---

## 7. GC tuning (environment)

Read once at startup by `configFromEnv`. Knobs tune policy, never correctness.

| Variable            | Default | Effect                                             |
|---------------------|---------|----------------------------------------------------|
| `BIT_GC`            | on      | `off` or `0` disables automatic collection         |
| `BIT_GC_MIN_KB`     | 4096    | Min live KiB before the first/next collection      |
| `BIT_GC_GROWTH_PCT` | 200     | Heap growth percent between collections (>= 100)   |
| `BIT_GC_MARKSTACK`  | 8192    | Mark worklist capacity in entries (> 0)            |
| `BIT_GC_STATS`      | off     | `1`/`on` prints one line per collection to stderr  |

POSIX only in v1; Windows keeps the compiled defaults until the runtime adds
`GetEnvironmentVariableW`.

---

## 8. Collector algorithm (informative)

Not ABI — may change without touching §1–§7. v1 is a precise, non-moving,
stop-the-world **mark-and-sweep**: objects are threaded on an all-objects list;
mark traces from roots via the pointer maps using a fixed-capacity worklist
(worklist overflow falls back to bounded rescan passes, so mark-phase memory is
constant); sweep frees unmarked objects back to the size-class heap. Upgrade path
is incremental/generational collection when pause times matter.
