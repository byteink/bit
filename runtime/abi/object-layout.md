# Managed values and object layout

[Runtime ABI](../ABI.md)

## 1. Managed object layout

Every GC-managed allocation is `header ++ body`:

```
offset  size  field
0       8     info    *const TypeInfo   type descriptor (§2)
8       8     size    usize             runtime-private total alloc size in bits
                                        0..62; the mark bit is bit 63
16      ...   body                      the object's fields
```

- Header size is **16 bytes**, 8-aligned. The body begins at `base + 16`.
- **The reference the compiler works with is the body pointer** (`base + 16`),
  i.e. the value returned by the allocator. Codegen never sees the header; the
  runtime reaches it by subtracting 16.
- `size` and the mark bit are owned by the runtime. Codegen must not read or
  write them, and must not assume their meaning — only `info` and the 16-byte
  offset are stable ABI for codegen. The rest may change with the collector.
- **The mark bit lives in bit 63 of the size word.** A single
  allocation's byte count is positive and far below 2^63, so the top bit is free
  by construction. `runtime/gc/gc.bit`'s `hdrSize`/`hdrMarked`/`hdrSetMark`/
  `hdrTakeMark` are the only sanctioned readers; a bare load of the word reads
  a NEGATIVE value for any marked object.
- **The header is two words and has no spare one.** It was 32 bytes until the
  mark bit was packed into the size word's sign bit and the all-objects list
  link was retired, then both freed words were deleted in a single ABI
  change. `runtime/alloc/classify.bit` rounds `header + body` to a size class,
  so a third header word costs one whole class at every body size from 8 to 48
  bytes. Adding one is a measurable regression on every allocation, not a
  bookkeeping detail.
- **Moving this offset is a MINOR release plus a stage0 repin.** The pinned
  bootstrap compiler emits the displacement into every `call_iface` site it
  compiles, so a compiler built by it and linked against a runtime with a
  different header reads the wrong word — a silent wrong answer, not a link
  error. `tools/build/abiarity.bit` lists `gcHeaderSize` in `abiLayoutConsts`
  to refuse that build and print the two-pass `BIT_STAGE0_BIN` recipe.

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

**A `ret` therefore carries at most one value — for every position §1.2.2 does
not name.** `return a, b` in a function whose result type is `(A, B)`
allocates a 2-element tuple record, stores the elements into it, and returns
that single reference, UNLESS the declaration qualifies for the return-word
convention §1.2.2 describes: on a register-return target
(`targetReturnsInRegisters`, `compiler/build.bit`; today the two AArch64
targets and x86_64-linux) and within the word budget (§1.2.2), the words are
returned directly with no box. Destructuring (`let (a, b) = f()`) and element
access (`t.0`) read the elements back with ordinary field loads at the boxed
layout's offsets, or from the returned words directly when they were never
boxed.

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
codegen implements everywhere §1.2.2's exception does not apply. On a target
outside that exception, boxing in the lowerer is what
makes a multi-value `ret` unreachable rather than what works around it: no
backend has to refuse one, because the front end never produces one.

**Element mutability.** Tuple elements are **read-only** (SPEC §12.5): `t.0` may
be read but not assigned. That is what keeps the boxed representation faithful to
the value semantics SPEC §13.3 declares for tuples — with no way to mutate an
element, a shared box is indistinguishable from a copy, the same argument the
spec already makes for `string`. Boxing a *mutable* tuple would silently convert
a declared value type into a reference type.

### 1.2 Payload-carrying enums

A payload-carrying enum construction (`Enum.Variant(args)`) is **one**
`gc_alloc`'d object, not two: `{ tag: i64 @0, arg0 @8, arg1 @16, ... }` (base
moved from 16 to 8). Body size is `8 + 8*argc`. The tag word at
offset 0 is never a GC reference; each argument word at `8 + 8*i` is listed in
`ptr_offsets` (§2) exactly when that argument's static type holds a GC reference
— there is no separate payload box and no intermediate payload pointer to trace.
This is the same generic `(type, size, ptr_offsets)`-keyed shape every
multi-field class already uses (§2); an enum's payload merely starts its fields
at offset 8 instead of 0 to leave room for the tag.

A **no-payload** variant construction (`Enum.NoArgVariant` or the bare tag
reference `Enum.Variant`) is the SAME layout at `argc == 1` with a nil argument:
a 16-byte `{ tag: i64 @0, payload: i64 @8 }` object with the payload word always
zero. `buildEnumObj` derives both its size and that offset from the one
`enumPayloadBase` the payload path uses, so the two forms cannot drift apart, and
an argc=1 variant whose argument is a reference produces a byte-identical
`TypeInfo` to the no-payload form of the same enum.

`buildEnumObj` lists the payload word in `ptr_offsets` unconditionally, so the
collector traces a value that is always nil on that path. That is deliberate and
it is the SAFE direction — tracing a nil word is wasted work, whereas omitting a
word that turned out to hold a reference is a missed root and a wrong answer.
**The merged base keeps that asymmetry** on purpose: under it, the no-payload
form's always-nil word is the same word `arg0` occupies, so the pointer map is
right for both forms with no per-variant reasoning.

**Why offset 8 and not 16.** `runtime/alloc/classify.bit` rounds every
request to a size class, and classes 1..7 are the multiples of 16 up to 112, so
an odd argc is what crosses a class boundary. The figures below were measured
against the **then-32-byte** header, before it shrank to 16: at base 16 an
argc=1 object needed 56 bytes and took the 64 class; at base 8 it needed 48 and
took the 48 class — 16 bytes, 25%, on every `Option.Some`, `Result.Ok`,
`Result.Err` and every payload variant of `Json`. argc=3 dropped 80 -> 64 the
same way; the even arities were unmoved. Measured as an RSS slope over a million
live objects: 64.50 -> 48.50 bytes per object at argc=1, 80.54 -> 64.54 at
argc=3, 64.50 unchanged at argc=2. **The conclusion survives the smaller
header** — at 16 bytes base 8 gives argc=1 a 32-byte total against base 16's 48,
so the class step is if anything wider — but re-derive the numbers rather than
quoting these. Nothing in `runtime/**` constructs or matches an enum
(zero enum declarations in the tree), so this is a codegen shape change that the
collector follows through `TypeInfo` — not a runtime ABI break, and it needs no
two-pass `BIT_STAGE0_BIN` landing.

`match` reads the tag at offset 0 (`matchTag`) regardless of shape, and binds
arm `i`'s payload from `8 + 8*i` directly off the subject object
(`bindArmPayload`) — there is no intermediate box read. `lowerVariantConstruction`
is the only writer of a payload word and `bindArmPayload` the only reader; both
take the offset from `enumPayloadBase` in `compiler/lowerlayout.bit`, because a
writer and a reader that disagree here produce a wrong answer with no
diagnostic, not a crash.

### 1.2.1 The value form: an eligible enum as two words

Everything above describes the **boxed** form. An enum TYPE that satisfies the
predicate below is not boxed at all while it is passed, returned or matched: it
is **two independent single-word SSA values** — the i64 tag, then the one payload
word — exploded in the lowerer exactly as a two-member tuple or a `decimal`
already is (`explodedWordTypes`, `compiler/lowerexplode.bit`), so no
multi-location value ever reaches the register allocator. No header, no
`gc_alloc`, no `TypeInfo`, and nothing for the collector to trace beyond the one
word's own `isRef`.

**Eligibility is a property of the monomorphized TYPE, never of a construction
site** — `match`, a parameter and a return must agree on the shape with no
analysis, and a per-site rule would give two values of one static type two
different register footprints. `enumExplosionEligible`
(`compiler/lowerlayout.bit`) is the whole predicate; each clause is a refusal the
boxed form absorbs unchanged:

| clause | a type it refuses | why |
|---|---|---|
| `enumBoxed`: at least one payload-carrying variant | `enum Color { Red, Green, Blue }` | already lowers to a bare tag word — there is no allocation to remove |
| every variant's payload is 0 or 1 words | `Frame` (`stdlib/quic/frames.bit`): `NewConnectionId(u64, u64, []byte, []byte)` is four | N = 2 (tag + one payload word); a wider payload has no word to live in |
| every recorded payload type is fully substituted | the generic DECLARATION `Option<T>`, whose own `ctx.variantPayloads` entry holds a bare `TypeParam` | only an INSTANTIATION (`fillInstVariants`) has a word anything has sized |
| every payload-carrying variant carries the SAME type (`enumCommonPayloadType` returns a type, not `-1`) | `Result<i64, string>` | the arm must read back the type the constructor wrote — see below |

The last clause is the one that is not merely conservative. Typing the shared
word as a declaration-wide union (`ctx.errorId` whenever ANY variant's payload
word was a pointer) is the only SAFE answer for a mixed declaration but a
WRONG one for the shape real code is made of: `forwardOneLoad`
(`compiler/optstore.bit`) forwards a store into a load only when the two IR
types are EQUAL, and `explodedArgWords` (`compiler/lowerexplode.bit`) gates a
call site's argument explosion on the argument VALUE's IR type. A word typed
`error` can therefore never answer an arm that binds a `Json`: the rebuild
survives every pass, and a call-result subject rebuilds a box per match. So a
declaration with one payload type explodes with that type EXACTLY, and a mixed
one goes back on the boxed path it used before the value-form mechanism
existed — never a lost root, and no shape can regress.

**GC references.** The payload word carries its own static `isRef`, which
`regalloc` records into a safepoint's registers or slots with no stack-map format
change. `enumPayloadWordIsRef` (`compiler/lowerlayout.bit`) remains the
conservative union — the word is traced if ANY variant's payload there is a
pointer, never only if every variant's is. Over-tracing a plain integer costs a
scan; under-tracing loses a root and frees a live object, so the union errs in
the one direction that cannot be wrong.

**The target gate is on the RETURN side only.** `explodedRetWords`
(`compiler/lowerexplode.bit`) returns the empty list unless `Lowerer.multiWordRet`
— that is `targetReturnsInRegisters` (`compiler/build.bit`), true for
all four supported targets, including `x86_64-windows` (#5875). The PARAMETER side has
no target gate: it rides `explodesParams` on every target, exactly as a tuple
or a `decimal` parameter already does.

**Materialization back to the box.** A use that needs one shared memory location
— a class field, a slice or array element, a map key or value, a channel send, a
closure capture, a conversion to an interface — rebuilds the identical
`{ tag @0, arg0 @8 }` object through `materializeExplodedEnum`
(`compiler/lowerlayout.bit`), from the same `enumPayloadBase` the boxed path
uses. Containers, `TypeInfo` (§2) and the collector are unchanged; only the
transient form is new.

**`match` over an exploded subject.** `matchSubjectWords` / `lowerMatchSubject`
(`compiler/lowerbranch.bit`) read the subject's raw `[tag, payload]` words when
the subject is a local bound to an exploded value, or a call result whose fresh
box's own `field_set` operands are still recoverable (`freshEnumBoxWords`), and
`bindArmPayloadDirect` binds a one-word payload straight from the word — no box,
no `field_get`, nothing for a later pass to have to cancel. An arm that binds no
payload reads the tag word alone.

**Measured, aarch64-macos, `bench/cases/json`** — `swept+live` and `allocbytes`
from one `BIT_GC_STATS=1` run of the built benchmark (object counts are
deterministic; stdout was byte-identical at all three points), cycles the median
of 7 interleaved runs against a byte-identical null control that read 0.56%
apart:

| compiler | objects | allocbytes | cycles |
|---|---|---|---|
| `d0b16a06`, before the value-form mechanism | 5,400,061 | 273,929,536 | 1,377,592,364 |
| `608a4ab3`, with the union-typed word | 9,300,064 | 398,729,632 | 3,989,032,924 |
| `1d92321c`, after the exact-typing clause | 4,350,060 | 240,329,504 | 1,297,601,527 |

Against the pre-mechanism compiler that is **-1,050,001 objects (-19.4%) and
-33,600,032 bytes (-12.3%)**, which is 32.0 bytes per removed object exactly: the
16-byte header plus the two words of an argc=1 box. `bench/cases/allocflat`,
which declares no enum, read 4,006 objects and 246,416,704 bytes at all three
commits and its cycles moved 0.33% across all four binaries — the control that
says this is an enum-representation change and not a build difference. The middle
row is why the exact-typing clause exists: the value form without it cost json
+3,900,003 objects and 2.9x its cycles.

---

### 1.2.2 Which functions return an eligible enum in words

§1.1's "a `ret` carries at most one value" is the BOXED form and still describes
every position not named here. The return-word convention is the exception, and
who may use it is decided from declarations alone — never from a call site,
because the callee's `ret` is lowered once and every caller must agree with it
without seeing any other caller.

**A free function** returns its result in words when `explodesParams`
(`compiler/lowerexplode.bit`) admits its declaration: not `extern`, no type
parameters, no variadic parameter list, no `@symbol`. Its result type must
explode (§1.2.1's eligibility, `explodedWordTypes`) and the word list must fit
the return-register budget (`retWordsFitRegisters`; a return word past the
fifth int or sixth float word has no path).

**A fallible result** `T!E` is decided on its ok type and one more int word
(#6693): the error is the LAST return word (§13), so a fallible ok type gets at
most 4 int words. A tuple-of-words ok type (`tupleWordTypes`) returns in words
followed by the error word; every err-path `ret` carries one zero constant per
ok word (`fallibleZeroArgs`, `compiler/lowerfail.bit`) before the error. A
`string`, `decimal` or enum ok type keeps one handle, as does every method an
interface declares fallible. `BIT_ERR_REG=0` uses §13's slot.

**A method reached only by a direct `call`** returns its result in words when
`methodRetExplodes` (`compiler/lowerexplodemethod.bit`) admits it: the same
per-declaration exclusions, plus the whole-project requirement that nothing can
reach its symbol except a direct call — it is never taken as a method VALUE, and
it is none of the three names lowering synthesizes calls to (`show`, `message`,
`init`).

**A method reached through the vtable** — `Op.CallIface` — is decided on the
method NAME, project-wide, and it is unanimous or nothing:

> A method name returns its result in words only when EVERY declaration of that
> name in the project — every interface signature and every concrete method —
> yields the SAME non-empty word list. One disagreeing declaration puts the name
> back on the one-handle convention for all of them.

`ifaceWordRetMethods` (`compiler/lowerexplodeiface.bit`) computes that set once,
before the first body is lowered, into `TypeContext.wordRetMethods`.

**Why the name and not the interface.** `methodId` (`compiler/lower.bit`) derives
the dispatch id from the method NAME and `bit_rt_iface_lookup`
(`runtime/root/iface.bit`, §2.1) resolves that id against whatever receiver
arrives. Two interfaces may each declare `step` with different result types and
share one id, so the unit of agreement has to be the unit of dispatch identity.

**Why unanimity and not "the interface's declared type wins".** The callee's
`ret` is lowered from the CLASS's declaration. A rule that let the interface
decide would oblige an implementation the per-declaration gate refuses — a
generic class's method, a variadic or `@symbol` one — to marshal words its own
lowering never emits, and the call site would read a return register the callee
never wrote. Refusing the whole name is the only answer that needs no coercion
anywhere and leaves every refused shape exactly as it was.

**What no agreement can rescue.** A method taken as a VALUE is called back
through `Op.CallValue`'s one-handle convention (`lowerStructMethodValue`,
`compiler/lowerfuncval.bit`), and an interface method taken as a value gets a
trampoline whose own `ret` is single-word (`compiler/lowertrampoline.bit`); neither
call site can know the callee returned words. Those names, and the three
synthesized ones, are excluded before agreement is computed.

**Target gate.** All three forms are additionally gated on
`Lowerer.multiWordRet`, seeded from `targetReturnsInRegisters`
(`compiler/build.bit`): true for all four targets, including
`x86_64-windows` (#5875). The word list must also fit the one target-independent
return-register budget (`retWordsFitRegisters`; `maxRetIntWords()` = 5,
`maxRetFloatWords()` = 6, `compiler/lowerexplode.bit`), the smallest lists
any register-return target implements.

**Measured, aarch64-macos**, a 1,000,000-crossing driver built at
`03ed887b` + this change, `BIT_GC_STATS=1`, stdout byte-identical between the
two programs:

| driver | `swept+live` | `allocbytes` |
|---|---|---|
| vtable-dispatched `Source.step(): Step` | 9 | 528,864 |
| the same loop against a free `stepOf(): Step` | 9 | 528,864 |

At `03ed887b` the same vtable driver read 1,000,010 objects and 32,528,896
bytes — one `{tag, payload}` box per element. The difference is 1,000,001
objects and 32,000,032 bytes, 32.0 bytes each exactly: the 16-byte header plus
the two words of an argc=1 box, the same figure §1.2.1's table reports per
removed object.

---


[Next: Type information and references](type-info.md)
