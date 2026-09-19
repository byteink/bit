# The iterator trait (design)

<!-- doctest: per-block -->

## Status of this document

This is a design document, not a feature guide. Nothing on this page is
implemented yet. `for x of` accepts exactly four shapes today (slice,
array, map, channel) and every other iterable, including every user
class, is rejected at lowering with `E0092`. This page settles the
protocol, reports the allocation and inlining evidence the protocol
depends on, and answers the open questions epic smash#4107 listed. Once
the trait lands, this page is rewritten into a normal guide page under
`bit/docs/STYLE.md`, the way `docs/stdlib/time.md` was rewritten from
design doc to shipped reference once std/time (#4062) landed.

## The problem

A `Store` that keeps every `Link` in memory can hand back a `[]Link` and
`for l of links` just works. A `Store` backed by a database, or one that
holds more links than fit in memory at once, cannot. It wants to hand
back links one at a time, computed lazily, without building the whole
slice first. There is no way to write that in Bit today: `for` only
accepts a slice, an array, a map or a channel, so a store's own type
cannot be ranged over at all.

```bit
class Link {
  export url: string,
  export created: i64,
  export hits: int,
}

class LinkPage {
  n: i64
  next(): Option<Link> {
    if (this.n <= 0) {
      return Option.None
    }
    this.n = this.n - 1
    return Option.Some(Link{ url = "https://example.com", created = 0, hits = 0 })
  }
}

fn main() {
  let page = LinkPage{ n = 3 }
  let count = 0
  while (true) {
    match (page.next()) {
      Some(l) => count = count + 1
      None => break
    }
  }
  println("saw ${count} links")
}
// saw 3 links
```

That `while (true) { match ... }` loop is what every caller of `LinkPage`
has to write by hand, forever, because `for l of page` does not compile:

```bit ignore
for l of page { }
// error[E0092]: cannot lower a `for … of` whose iterable is not a
// slice, array, map or channel
```

The trait closes that gap: any class that supplies `next(): Option<T>`
becomes something `for` can range over, the same way `use`-ing a trait
today lets a class supply one method and be handed the rest (see
[Traits](traits.md)).

## The protocol

```bit ignore
trait Iterator<T> {
  next(): Option<T>,
}
```

A class opts in the same way it opts into any interface: by declaring a
`next(): Option<T>` method with a matching signature, no `use` required.
`Iterator<T>` names the shape; a class satisfies it structurally, exactly
as it satisfies any other interface (see [Interfaces](interfaces.md)).
`for l of page` then desugars to the loop written out above: call `next`,
`match` the result, bind `Some`'s payload as the loop variable, `break` on
`None`.

**Why `Option<T>`, not a Go-style `yield func(T) bool`.** Bit already has
`Option` and already uses it for exactly this shape, a lookup that may or
may not produce a value: `Regex.find()` returns `Option<Match>`,
`yamlAsBool`/`yamlAsInt`/`yamlAsString` all return `Option`. A callback
protocol would be a second, inverted control-flow idiom living next to the
one Bit already has, and it changes what `break` and an early `return`
mean inside `for … of`. `next(): Option<T>` is also the industry-standard
shape: it is Rust's `Iterator::next() -> Option<Item>` exactly.

This page's own earlier draft rejected `Option<T>` on allocation grounds.
That measurement is stale; see below.

## The allocation story

The concern was real: a payload-carrying enum used to allocate a boxed
`{tag, payload}` object on every `Option` returned, and `next()` returns
one per element. A per-element allocation would put a trait-based iterator
far behind a raw slice loop, which allocates nothing.

#4335 (per-enum-TYPE unboxed representation) removed that box across a
**free function's** return boundary (measured by #5314). It did not, on
its own, cover a **method's** return boundary: `explodedRetWords`
(`compiler/lowerexplode.bit`) gated the return side on `explodesParams`,
whose second exclusion refused any declaration with a receiver, because a
method also reaches its callers through `Op.CallIface`, where the
interface's signature is the contract, not the class's. Measured
2026-09-17 at main `0c035ef0` (smash#4107 comment 5): a method
`Counter.next(): Opt` boxed one object per call against a byte-identical
free function's zero, at 1,000,000 elements:

    free-function driver   obj (swept+live)         7    allocbytes    528,736
    method driver          obj (swept+live) 1,000,007    allocbytes 32,528,736

**That gap is now closed.** #5445 (direct method dispatch) and #5446
(`Op.CallIface`) both landed and merged to `main` since that measurement.
Re-run 2026-09-18 at main `13f215824b89bb7ad72288743bda1feb4d794f82`,
same methodology, three arms this time (free function, direct method call,
interface/vtable call), 1,000,000 elements, `BIT_GC_STATS=1`, identical
stdout (`499999499999`) on every arm:

    free-function driver   obj (swept+live)  7    allocbytes  528,736
    direct-method driver   obj (swept+live)  7    allocbytes  528,736
    interface driver       obj (swept+live)  7    allocbytes  528,736

`live=7` and `allocbytes=528,736` are the program's fixed startup cost
(runtime init, the two `Counter` values, `Option` type metadata), constant
across all three arms and confirmed stable across five repeated runs of
each binary. **None of the three allocates per element.** The per-call
box that forced this epic's original rejection is gone for a concrete
class's direct calls (#5445) and for a trait-typed value's vtable calls
(#5446) alike. Three identical zeros are also what a probe reports when the
optimizer has folded the whole loop away, so the measurement carries a
control: the same class and the same driver returning a `Pair` enum whose
two payload variants hold different types, which is not eligible for the
unboxed representation. It reports `swept=917487 live=82521
allocbytes=32,528,768` on the same binary and the same stdout, one box per
element. The instrument can see a box; the `Option<i64>` arms do not have
one. The four `.bit` files, including that control, are on smash#4107; they
are deliberately not committed, because they exist to prove a compiler
property, not to exercise a stdlib API.

`next(): Option<T>` is therefore accepted on allocation grounds, not
merely on protocol grounds. A future change to `explodesParams`,
`methodRetExplodes` or `ifaceWordRetMethods` that reopens this box needs a
regression test; `_tests_/cases/run_enum_explode_method.bit` already pins
the shape by name and calls this epic out by number in its own header
comment.

## The inlining story

Two call shapes reach `next()`, and they inline differently.

**A concrete class, called directly** (`for l of somePage` where
`somePage: LinkPage`) is an ordinary `Op.Call`. The inliner
(`compiler/optinline.bit`, budget and eligibility in
`compiler/optinlinecost.bit`) can splice a small `next()` body into the
loop exactly as it splices any other small function, and once it does,
LICM (`compiler/optloop.bit`) sees the loop's real body, not a call.
`emitStaticMethodCall` (`compiler/lowerexplodemethod.bit`) already relies
on this for the allocation story above: the `Option` value is rebuilt from
its exploded words at the call site, and the optimizer deletes that
rebuild whenever nothing reads it, which is the ordinary case for a `for
… of` loop that only reads the payload. Inlining is size-budgeted, so a
`next()` with a large body stays a real call, the same tradeoff every
other Bit function makes; it does not stay a real call *because* it is an
iterator.

**A trait-typed value** (`for l of anyIterator` where `anyIterator` is
typed as the trait, not a concrete class) is `Op.CallIface`, a vtable
dispatch the inliner cannot see through: the callee depends on the
receiver's runtime type, which is exactly the information a
monomorphic-only inliner does not have. That call stays a real call every
iteration. #5446 is what keeps that real call from allocating regardless,
by carrying exploded return words across the vtable slot on any method
name every implementor and every interface declaration agree on
(`ifaceWordRetMethods`, `compiler/lowerexplodeiface.bit`). So the
trait-typed loop does not reach the raw-loop shape a slice gets, but it
does reach the no-allocation shape, which is the gap the allocation
measurement closes.

#3163 (inlining order-independence) matters here because a `for … of`
loop's own body is itself a candidate the inliner walks into after
splicing `next()`, and a splice order that depended on iteration order
would make the same program inline differently depending on unrelated
code elsewhere in the file. It does not have to be re-verified for this
epic; it already removed the dependency this feature would otherwise have
reintroduced.

## Do the four built-ins migrate to the trait?

**No. They stay special.** Slice and array iteration is in every hot loop
in the tree, and today it lowers to a bare counted loop, no call, no
`Option`, no match, over `slice_get`/`IndexGet` directly
(`compiler/lowerforin.bit`, `compiler/lowerctrl.bit:16-195`). Migrating
slices onto `next(): Option<T>` would mean either:

- routing every slice `for … of` through a real (even if inlinable)
  `next()` call, which asks the inliner and LICM to reconstruct the exact
  loop shape the compiler already emits directly today, on every build,
  including `--no-optimize`, where nothing gets inlined; or
- special-casing slices inside the trait's own lowering so that they
  bypass `next()` entirely, which is two mechanisms wearing one name
  instead of two mechanisms under two names. That is a worse outcome than
  today's, because it hides the special case instead of naming it.

Two mechanisms under two names, kept as they are, is the honest version of
what is already true: a slice is not a lazily-computed sequence, it is a
contiguous block of memory with a length, and the compiler should keep
saying so directly. The trait is the extension point for every type that
is **not** that, which is what this epic asked for. Maps and channels stay
special for the same reason: `for (k, v) of m` reads the map's own bucket
layout (`typeForOfBinder`, `compiler/checkmatch.bit:106`) and a channel
`for … of` is a receive-until-closed loop with its own runtime protocol,
neither of which is expressible as a sequence of `next()` calls without
inventing a second, hidden protocol underneath the visible one.

A user type that wants iterator semantics **backed by** a slice (a
`LinkPage` that pages through an in-memory `[]Link`) writes `next()` in
terms of slice indexing itself, same as `LinkPage` does above. It does not
need the compiler to unify the two mechanisms to get that; it needs the
trait to exist.

## `for (k, v) of m`

Unaffected. A map's `of` already yields the `(K, V)` pair as one value
(`elementType`, `compiler/checkmatch.bit:69`, epic #4332's owner ruling),
and `for (k, v) of m` is that pair destructured positionally through the
same `checkTupleBinders` a tuple-typed `next(): Option<(K, V)>` would use.
A user type that wants to be ranged over as pairs declares
`next(): Option<(K, V)>` and gets the same binder for free; nothing about
the trait needs a second binder rule for it.

## Open questions for the children

This document answers the protocol, the allocation cost and the inlining
story with measurements. What it does not settle, because settling it
needs code to measure against:

- The exact trait declaration syntax and whether `for` requires the
  `Iterator<T>` name or accepts any class with a matching `next()`
  structurally (Bit's traits are `use`-based opt-in; interfaces are
  structural, and this decides which discipline governs `for`).
- Whether a `for … of` over a trait-typed value needs a new diagnostic
  when `next()`'s return type does not unify to `Option<T>` for a single
  `T`, and what error code that gets.
- Whether early `return`/`break` inside the loop body need anything beyond
  what today's four built-in lowerings already do (they do not consume
  the iterator further, so likely nothing, but this needs a fixture, not
  an assertion).
## Measured cost of the three loop shapes

**Measured for #5564 on `4a208905`**, drained box under `boxlock.sh solo`,
nothing else running. Three programs summing 1,000,000 `i64` elements per
repetition: (a) `for x of xs` over a `[]i64`, (b) `for x of it` over a
concrete class whose `next(): Option<i64>`, (c) the same with `it`
declared as an interface type, so `next()` dispatches dynamically.

Counters from `/usr/bin/time -l` (`instructions retired`, `cycles
elapsed`). **Each figure is a two-point delta** -- the same binary run at
40 and 80 repetitions, subtracted -- so slice construction, process boot
and the first-execve tax cancel rather than being estimated away. Median
of 15 runs at each point, every binary warmed first.

| shape | instructions/element | cycles/element | IPC | vs (a) |
|---|--:|--:|--:|--:|
| (a) raw `[]i64` slice loop | 11.00 | ~1.9 | 5.6-6.0 | 1.00x |
| (b) concrete `next(): Option<i64>` | 18.00 | ~2.5 | 7.2-7.5 | **~1.3x** |
| (c) interface-typed `next()` | 52.01 | ~7.6 | 6.7-6.8 | **~3.9-4.3x** |

**Instruction counts are exact and reproduced to three decimal places
across two independent collections.** Cycle figures moved about 5% between
those collections and the per-point spread was 8-30%, so the ratios are
quoted as ranges; do not restate them as single numbers.

**All three loops run at IPC 5.6-7.5, which is near this core's issue
width.** That is the regime #4389 documented: high IPC here is saturation,
not headroom. It is why (b)'s 1.64x instruction cost buys only ~1.3x
cycles -- the extra work fits in issue slots the slice loop was not using
-- and it is also why adding instructions to any of these shapes should be
expected to cost roughly proportionally. An optimization here that trades
instructions for stalls will lose; see #5571, which measured -1.12%
instructions at +3.01% cycles in comparable code and was rejected.

The interface arm is the one worth knowing about: **~4.7x the instructions
and ~4x the cycles** of a slice loop, because every element pays a dynamic
dispatch that cannot inline. A concrete-typed iterator is close enough to
a raw loop to be uninteresting; an interface-typed one is not.

## Specification

`for … of` today: SPEC §12.6. `for … in`: owner decision 2026-08-10,
SPEC §12.6. Traits: SPEC, added by #3367.
