<!-- doctest: per-block -->
# Multi-value returns without a heap box

`let (r, n) = decodeRune(s, i)` looks free. It is not always. Depending on the
target and on the element types, the callee may allocate a 16-byte tuple object
on every call, fill it, and hand back one pointer, which the caller then reads
twice and drops. #5850 profiled the pkg/web server on x86_64 Linux and found
`toLower` calling `decodeRune` was 37% of all allocation samples. #5856 removed
that one call site from the hot path. This note is about the language-level
cost that is still there, and the plan for removing it everywhere.

Design record for #5862, measured on main `158a5fc24`.

## The running example

Two functions carry this note. The first returns two full words:

```bit
fn pairI(a: int): (int, int) {
  return a + 1, a * 2
}

fn main() {
  let (x, y) = pairI(20)
  print("${x + y}")
}
```

The second returns a `rune`, which is an `i32`, next to an `int`. That is the
shape of `decodeRune` (`stdlib/strings/utf8.bit`):

```bit
fn pairR(a: int): (rune, int) {
  return rune(a), 1
}

fn main() {
  let (r, n) = pairR(65)
  print("${int(r) + n}")
}
```

## What the compiler does today

`runtime/ABI.md` §1.1 still opens with the original rule: a tuple is a boxed
record, and `return a, b` allocates it and returns one handle. Since then,
#4404, #4405, #5313, #5445 and #5446 built a second convention next to it. On
the targets where `targetReturnsInRegisters` (`compiler/build.bit`) is true,
the lowerer splits a qualifying result into independent one-word SSA values.
It returns them in the ABI return registers, and the caller binds them with an
`Op.Call` followed by an `Op.CallWord` run (`emitCallResultWords`,
`compiler/lowerexplode.bit`). Nothing multi-location ever reaches the register
allocator. Each word keeps its own type, so a traced word is a traced value,
and the stack map format does not change. ABI.md §1.2.1 and §1.2.2 record this
for enums.

On aarch64, `bit --dump-ir` at `158a5fc24` shows both conventions side by side (constants elided):

```text
func pairI(%0: i64) (i64, i64) {        func pairR(%0: i64) (i32, i64) {
bb0(%0: i64):                           bb0(%0: i64):
  %2 = add i64 %0, %1                     %1 = convert i32 %0
  %4 = mul i64 %0, %3                     %3 = gc_alloc size=16 ptrs=[] (i32, i64)
  ret %2, %4                              field_set %3[0] = %1
}                                         field_set %3[8] = %2
                                          ret %3
                                        }
```

`pairI` returns in x0 and x1. `pairR` allocates, because of four independent
gaps:

1. **x86_64 has no multi-word return at all.** `targetReturnsInRegisters` is
   false for both x86_64 targets, because `xEmitRet`
   (`compiler/x64controlflow.bit`) refuses a width above one and no x64 call
   site binds a second register. `bit build --target x86_64-linux -c` of
   `pairI` emits a `callq` to `bit_rt_gc_alloc`, two stores and
   `movq %r14, %rax`. That is the target the web benchmark runs on.
2. **A member narrower than a word boxes on every target.** `tupleWordTypes`
   (`compiler/lowerexplode.bit`) refuses a tuple if any member's field size is
   not 8. So `(rune, int)`, `(bool, int)` and every `(T, bool)` "found" pair
   are boxed. `decodeRune` has 7 return statements, and each one is a
   `gc_alloc`.
3. **A fallible tuple `(A, B)!` boxes on every target.** `declPlainResultType`
   (`compiler/lowerexplode.bit`) excludes every fallible result. The record
   there is about `string`, which #4601 measured as a net loss in words.
4. **Declaration exclusions.** `explodesParams` refuses `extern`, generic,
   variadic and `@symbol` declarations. A method taken as a value, or any
   function called through a closure, stays on the one-handle convention.

A fifth cost has nothing to do with the call boundary. When a small callee with
two `return` sites is inlined, each path builds its own box and passes the
handle into the join as a block parameter. The optimizer cannot see through
that parameter:

```bit
fn sel(a: int): (bool, int) {
  if (a > 3) {
    return true, a
  }
  return false, 0
}

fn main() {
  let s = 0
  let i = 0
  while (i < 1000) {
    let (b, m) = sel(i)
    if (b) {
      s = s + m
    }
    i = i + 1
  }
  print("${s}")
}
```

After inlining, `main` holds two `gc_alloc size=16 ... (bool, i64)` and a join
`bb5(%22: (bool, i64))` whose only uses are two `field_get`s. That is one
allocation per loop iteration.

## The census

### Per request on the pkg/web bench app

Method: the recipe from #5857.
- The app is `pkg/web/bench/apps/bit/main.bit`, with `bit.json` and `bit.lock`
  beside it, built with `BIT_STDLIB=stdlib bit-out/bin/bit build main.bit`.
- It runs with `BIT_WORKERS=1` and is warmed with `ab -k -c64 -n20000`.
- `bit_rt_port_stw_alloc_bytes`, `_swept` and `_live_objects` are read through
  lldb before and after `ab -k -c64 -n100000 /plaintext`.
- RSS was 8,480 KB before the first lldb call.

| aarch64-macos, `158a5fc24` | per request |
|---|--:|
| bytes allocated | 9,034.6 |
| objects (swept + live) | 65.0 |

To attribute objects to multi-value returns, I took the eight tuple-returning
functions that are linked into the binary (`nm`). Each one got an
auto-continue lldb breakpoint, and I read the hit counts after
`ab -k -c64 -n2000`. The counts are the same for `/plaintext` and `/json`:

| function | result | calls per request | aarch64 | x86_64 |
|---|---|--:|---|---|
| `splitTarget` (`stdlib/http/query.bit`) | `(string, string)` | 2 | x0, x1 | box |
| `framingLengthParts` (`stdlib/http/http.bit`) | `(string, int)` | 1 | x0, x1 | box |
| `decodeRune` (`stdlib/strings/utf8.bit`) | `(rune, int)` | 0 since #5856 | box | box |
| `readUntil`, `headerLineRange`, `acceptEntry`, `detailOf`, `missDecision` | | 0 | | |

`objdump` of `framingLengthParts` shows it returning in x0 and x1 with no tuple
allocation. So:
- **on aarch64, multi-value returns cost 0 of the 65.0 objects per request
  today.** #5856 took the last one off the path.
- **on x86_64 the same three calls allocate 3 objects and 96 bytes per
  request** (a 16-byte body plus the 16-byte header). That is before any
  inlined multi-return callee is counted.
- **the x86_64 figure is a lower bound.** Eligible enum returns (§1.2.1) box on
  x86_64 too, and inlined multi-return callees cannot be seen by a breakpoint.
  The flip ticket measures the x86_64 total directly.

The request path is short today because #5856, #5857, #5858 and #5860 already moved the
big allocators off it. The table does not show the cost of the next `toLower`,
the next found-pair, or the next parser a user writes on this server.

### Declarations and call sites across `stdlib/` and `pkg/`

Method: every `fn` or method whose declared result is a parenthesized type with
a top-level comma, with wrapped signatures joined. The result was
cross-checked against a one-line `grep` (159 both ways, test files included).
Call sites count `name(` and `.name(` in the declaring directory, or the whole
tree for an exported name. Test files are excluded below.

| shape | declarations | call sites | aarch64 today | x86_64 today |
|---|--:|--:|---|---|
| word members, not fallible | 33 | 48 | words | box |
| sub-word members, not fallible | 43 | 89 | box | box |
| fallible, word members | 49 | 73 | box | box |
| fallible, sub-word members | 14 | 13 | box | box |
| total | 139 | 223 | 106 decls box | 139 decls box |

So:
- **45% of tuple-returning declarations are fallible.**
- **31% have a sub-word member.**
- **aarch64 boxes 175 of the 223 call sites**, and x86_64 boxes all of them.

Of the 43 plain sub-word declarations, 42 place member k at byte offset 8k
under the class layout rule. The one exception is `(u32, u32)`
(`hash323`, `pkg/mysql/auth.bit`). This matters for option A2 below.

The largest tuple result is 4 members (`mysqlClock`, `pkg/mysql/codec.bit`).
No result in either tree needs more than 5 integer return registers.

## The options

Every option below keeps the language's meaning: tuples are values with
read-only elements (SPEC §12.5, §13.3), so whether a box exists is not
observable. The question is only where the words live between the `ret` and
the caller's first read.

### A. Return up to N words in registers, box the rest

This is the convention aarch64 already has, extended in three independent
directions.

**A1, x86_64.**
- **ABI change:** Bit-to-Bit calls on x86_64 return word k in the next
  register of its class. SysV gets rax, rdx, rcx, rsi, rdi, r8, r9 and
  xmm0 to xmm7. Win64 gets rax, rdx, rcx, r8, r9 and xmm0 to xmm5, because
  rsi and rdi are callee-saved there. Every register on both lists is
  caller-saved, and r10/r11 stay the scratch pair. The first two integer words
  are rax:rdx, SysV's own 16-byte pair. Only Bit calls Bit on this path
  (`explodesParams` refuses `extern` and `@symbol`), so Win64's C rule for
  large aggregates never applies.
- **Backend work, x64:**
  - `xEmitRet` emits a parallel move into those registers with
    `xSequentializeAndEmit` (`compiler/x64framemoves.bit`).
  - The `Op.Call` and `Op.CallIface` arms bind the `Op.CallWord` run in one
    parallel move right after the call, which is what `bindCallResults`
    (`compiler/arm64call.bit`) does.
- **Backend work, arm64:** none.
- **Budget:** `retWordsFitRegisters` currently reads aarch64's `maxArgRegs()`.
  It needs one target-independent budget: 5 integer and 6 float words, the
  smallest lists any target implements.
- **GC and stack maps:** unchanged. Word k is an ordinary SSA value with its
  own `isRef`, and the register allocator records it like any value live
  across a safepoint.
- **Inlining:** unchanged. The splice binds the callee's `ret` operands
  directly.
- **Closures:** unchanged, because a closure call stays on the one-handle
  convention, the same as on aarch64 today.

**A2, sub-word members.**
- **The change:** `tupleWordTypes` admits a member narrower than a word when
  its layout offset is exactly 8k.
- **Why 8k:** every word reader, starting with `emitWordReads`
  (`compiler/lowerkeepalive.bit`), reads word k at `k * 8`. A packed
  `(bool, bool, int)` sits at 0, 1 and 8, and admitting it would read the
  wrong bytes at exit 0. That is the #4412 failure class.
- **Coverage:** refusing the packed shapes keeps every reader correct unchanged,
  and still admits 42 of 43 declarations, `decodeRune` among them.
- **ABI:** each word is typed as its member (`i32`, `bool`, `f32`). It follows
  the in-register invariant a sub-word parameter already relies on.
- **Scope:** the shape rule is shared by parameters, let-locals and returns, so
  all three widen together. That is deliberate: two predicates for one shape
  is how #4412 shipped a truncating miscompile.
- **Backends, GC, inlining:** no backend work, since `bindCallResults` already
  normalizes a `bool` word. No GC change, because a sub-word member is never a
  reference. No inlining change.

**A3, fallible tuples.**
- **The change:** `declPlainResultType` admits a fallible result whose ok type
  is a tuple.
- **Error channel:** unchanged. The error stays in the per-task slot (ABI.md
  §13, SPEC §18.2), and only the ok value widens.
- **Lowering work:**
  - `emitFallibleZeroRet` returns W zero words;
  - `lowerTryExpr`, `lowerCatch` and `lowerCatchBlock`
    (`compiler/lowerfail.bit`) join with one block parameter per word.
- **Why #4601's refusal does not apply:** #4601 built exactly this for
  `string` (commit `5bc0518e`) and reverted it. A string's one-handle form
  already allocates nothing, so words only moved the box to whichever caller
  wanted a handle. A tuple's box exists only to carry the return, so the
  argument does not transfer. Strings, decimals and enums stay excluded.

### B. Caller-provided result slots (sret)

The caller reserves a result area in its own frame and passes its address in a
hidden argument, x8 on AAPCS64 and a hidden first argument on x86_64. The
callee stores its words through that pointer and the caller loads them.

- **ABI:** a hidden parameter on every eligible signature, and a new
  caller-owned area in both frame layouts. #4238 records that neither frame
  has one, and why it was not built for the return-word overflow case.
- **Backends:**
  - both need frame-layout work;
  - both need a hidden-argument shift in `marshalArgs` and its x64 twin;
  - x64 also needs a Win64 unwind-info check for the larger frame.
- **GC and stack maps:** this is where B costs most.
  - If the area can hold a reference while the callee runs, it must be a root
    in the caller's stack map at the call's return address. It must also be
    zeroed before every call, because the callee can reach a safepoint before
    it writes the area.
  - The alternative is to write the area only at the `ret`, with no safepoint
    between the stores and the return, and read it immediately after the call.
    That keeps it off the stack map, but then it is the register convention
    with extra loads and stores.
  - Task stacks are fixed guard-paged mappings and never move, so the pointer
    itself is safe.
- **Inlining:** after a splice, the area is a frame slot that the SSA IR cannot
  name. Getting the words back into registers needs a memory-to-register
  promotion pass this compiler does not have.
- **Closures:** a closure call would need the hidden argument as well, or stay
  boxed.
- **What it buys over A:** results wider than the register budget. The census
  has none.

### C. Scalar replacement of the tuple

Where the box never leaves the function, replace it with its fields. This
already happens inside one block: `pairR` inlined into a caller leaves no
`gc_alloc`, because store-to-load forwarding (`forwardOneLoad`,
`compiler/optstore.bit`) and `deadAllocs` (`compiler/optalloc.bit`) remove it.

- **What is missing:** the join. A block parameter of tuple type whose every
  incoming argument is a fresh, never-escaping box, and whose own uses are all
  `field_get`s, can become one parameter per field. That is the `sel` example.
- **ABI, backends, GC:** no ABI change and no backend work. No GC change,
  because each field keeps its own type.
- **Reach:** limited by inlining. `maxInlineInsts` and `maxInlineLeafInsts`
  (`compiler/optinlinecost.bit`) are 8 and 16 IR instructions, and #4344
  measured that raising them adds calls. `decodeRune` will never be spliced.
- **Closures:** a box captured by a closure escapes and is correctly left alone.

C cannot replace A: an out-of-line call is exactly where the box survives. It
complements A on every target. It covers inlined multi-return callees,
`let t = if (...) { (a, b) } else { (c, d) }`, and on x86_64 the months before
A1 lands.

## Recommendation

**Extend A, add C, do not build B.** A reuses a convention that already runs
the whole aarch64 tree:
- no new IR concept;
- no stack-map change;
- no new frame area.

Every refused shape falls back to the box, which stays correct. B costs a new
frame region, a hidden argument and GC rooting rules, and it buys only results
wider than five integer words, which nothing in the tree returns.

The order follows the benchmark. The web comparison runs on x86_64 Linux,
where every multi-value return still allocates, so x86_64 goes first. Sub-word
members are next: they are the `decodeRune` shape, and they pay on both
targets.

## The plan

Each ticket is one agent run, and all of them are children of #5849.

| phase | ticket | what | depends on |
|---|---|---|---|
| 1 | #5868 | x64 `xEmitRet` for W > 1 words, return-register lists per convention | |
| 1 | #5869 | x64 `Op.Call` / `Op.CallIface` bind the `Op.CallWord` run | #5868 |
| 1 | #5870 | one target-independent return budget (5 int, 6 float) | |
| 1 | #5872 | flip `targetReturnsInRegisters` for x86_64-linux, update ABI.md | #5868 #5869 #5870 |
| 1 | #5875 | the same flip for x86_64-windows | #5872 |
| 2 | #5871 | sub-word tuple members at offset 8k | |
| 3 | #5874 | fallible tuple results in words | |
| 4 | #5873 | scalar replacement of fresh boxes through a join | |

Phases 2, 3 and 4 do not wait for phase 1, and each one pays on aarch64 the day
it lands. #5872 also has to update SPEC §13.3. Its sentence "`return a, b`
builds one boxed tuple and returns a single handle" has been an aarch64
inaccuracy since #4405.

## Sharp edges

- **A widened predicate must reach every consumer.** #4412 widened the width
  rule for one reader and not another, and `take4((1,2,3,4))` returned 1200 at
  exit 0. Keep one shape rule, and refuse a shape rather than re-laying it out.
- **Nothing may sit between the call and the last word's binding** (#4236).
  `callWordEscapesInFunc` enforces that in the IR, and each backend's single
  parallel move enforces it in the machine code.
- **x86_64 is not proven by an aarch64 gate.** #5872's acceptance is
  `scripts/x64gate.sh` on real hardware, plus an `objdump` of the probe.
- **Moving a box is not removing it.** #4601's lesson: explode only where the
  box exists solely to carry the return.

## Where to go next

`runtime/ABI.md` §1.1 to §1.2.2 for the convention as it stands, and
`compiler/lowerexplode.bit` for the lowering. The epic is #5849.

Specification: SPEC §12.5, §12.10, §13.1, §13.3, §18.2.
