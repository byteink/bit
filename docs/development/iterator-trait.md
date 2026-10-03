# Looping over your own types

<!-- doctest: per-block -->

Inkwell keeps every `Draft` in memory, so `for d of drafts` over a
`[]Draft` just works. A store that reads drafts from a database, or holds
more of them than fit in memory, cannot hand back a slice. It wants to hand
them back one at a time, computed when asked for, and the caller still wants
to write a `for` loop. This page shows how a class opts in, and what changes
when fetching the next draft can fail.

## The loop you write by hand today

Without help, every caller of a lazy store writes the same loop:

```bit
class Draft {
  export title: string,
}

class DraftPage {
  n: i64
  next(): Option<Draft> {
    if (this.n <= 0) {
      return Option.None
    }
    this.n = this.n - 1
    return Option.Some(Draft{ title = "draft ${this.n}" })
  }
}

fn main() {
  let page = DraftPage{ n = 3 }
  let count = 0
  while (true) {
    match (page.next()) {
      Some(d) => count = count + 1
      None => break
    }
  }
  println("saw ${count} drafts")
}
// saw 3 drafts
```

## Give the class a `next()`

A class opts in by declaring `next(): Option<T>` with no parameters. No `use`
and no interface declaration is needed: like any interface, the shape is
enough. `for` then runs the loop above for you.

```bit
class Draft {
  export title: string,
}

class DraftPage {
  n: i64
  next(): Option<Draft> {
    if (this.n <= 0) {
      return Option.None
    }
    this.n = this.n - 1
    return Option.Some(Draft{ title = "draft ${this.n}" })
  }
}

fn main() {
  let page = DraftPage{ n = 3 }
  let count = 0
  for d of page {
    println(d.title)
    count = count + 1
  }
  println("saw ${count} drafts")
}
// draft 2
// draft 1
// draft 0
// saw 3 drafts
```

Each pass calls `next()`. A `Some` binds its payload to the loop variable and
runs the body; `None` ends the loop. `break`, `continue` and `return` work in
the body as they do in every other loop, and none of them touches the
iterator again. The same holds when the variable's type is an interface that
declares `next(): Option<T>`: the call goes through the interface.

## When fetching the next draft can fail

A store backed by a database reads each page over the network, and a read can
fail. Declare `next(): Option<Draft>!` and the iterator can say so. A `for`
over it is written with a `?` after the iterable:

```bit
class Draft {
  export title: string,
}

class DraftFeed {
  n: i64
  reads: i64
  next(): Option<Draft>! {
    this.reads = this.reads + 1
    if (this.reads == 3) {
      fail newError("read ${this.reads} failed")
    }
    if (this.n <= 0) {
      return Option.None
    }
    this.n = this.n - 1
    return Option.Some(Draft{ title = "draft ${this.n}" })
  }
}

fn listTitles(feed: DraftFeed): int! {
  let count = 0
  for d of feed? {
    println(d.title)
    count = count + 1
  }
  return count
}

fn main() {
  let feed = DraftFeed{ n = 5, reads = 0 }
  let count = listTitles(feed) catch e {
    println("stopped: ${e.message()}")
    -1
  }
  println("count ${count}")
}
// draft 4
// draft 3
// stopped: read 3 failed
// count -1
```

The `?` says what it says everywhere else in Bit: if this fails, leave and
hand the error to the caller. Here that means a failed `next()` ends the loop
and `listTitles` returns the error. The body ran twice, for the two drafts
that were read before the third read failed. Because the error is returned,
the function holding the loop has to be fallible itself (`int!` above), the
same rule as any other `?`.

## Sharp edges

Both mistakes are compile errors, so a failure is never dropped and a `?`
never promises something that cannot happen.

Leaving the `?` off an iterable whose `next()` can fail:

```text
error[E0186]: 'DraftFeed' has a fallible next(), so a for-of over it needs '?' on the iterable
  hint: write 'for x of it? { }'; a failed next() returns its error from the enclosing fallible function
```

Writing a `?` on an iterable whose `next()` cannot fail, a slice for
instance:

```text
error[E0187]: '?' on a for-of iterable whose next() cannot fail: '[]i64' is not a 'next(): Option<T>!' iterable
  hint: remove the '?'
```

If the expression you iterate is itself fallible, `for d of openFeed()?`
unwraps it the way `?` always does. When the value it returns also has a
fallible `next()`, write `for d of openFeed()??`: the first `?` unwraps the
call, the second is the loop's.

## When not to use it

Slices, arrays, maps and channels keep their own loops and do not go through
`next()`. A slice is a block of memory with a length, so a counted loop over
it is as cheap as a loop gets. Reach for `next()` when the elements are
computed lazily or come from somewhere that can fail, and keep a `[]Draft`
when you already have one.

A type that should be ranged over as pairs declares `next(): Option<(K, V)>`
and binds with `for (k, v) of it`, the same tuple binder a map uses.

## Where to go next

[Traits](../reference/traits.md) and [Interfaces](../reference/interfaces.md) cover the structural
rules a class follows to satisfy `next()`. [Errors](../reference/errors.md) covers
`fail`, `?` and `catch`.

## How it compiles

The rest of this page is for people working on the compiler. A `for x of it`
over a `next()` iterable lowers to the same `while (true) { match
(it.next()) ... }` the first example writes out, in `compiler/lowerforiter.bit`.
For the fallible form the loop header calls `next()`, branches on the error
slot with the same `propagateErr` that `?` uses (`compiler/lowerfail.bit`),
and reads the `Some` tag only on the ok edge. `compiler/validateloop.bit`
(`vForOfFallible`) reports E0186 and E0187.

## Why `Option<T>` and not a callback

`next(): Option<T>` is Rust's `Iterator::next() -> Option<Item>`, and Bit
already uses `Option` for a lookup that may or may not produce a value
(`Regex.find()` returns `Option<Match>`). A Go-style `yield func(T) bool`
would be a second, inverted control-flow idiom next to that one, and it
changes what `break` and an early `return` mean inside `for … of`. The
measurements below are why the per-element `Option` costs nothing.

## The allocation story

The concern was real: a payload-carrying enum used to allocate a boxed
`{tag, payload}` object on every `Option` returned, and `next()` returns
one per element. A per-element allocation would put a trait-based iterator
far behind a raw slice loop, which allocates nothing.

The per-enum-TYPE unboxed representation removed that box across a
**free function's** return boundary. It did not, on
its own, cover a **method's** return boundary: `explodedRetWords`
(`compiler/lowerexplode.bit`) gated the return side on `explodesParams`,
whose second exclusion refused any declaration with a receiver, because a
method also reaches its callers through `Op.CallIface`, where the
interface's signature is the contract, not the class's. Measured
2026-09-17 at main `0c035ef0`: a method
`Counter.next(): Opt` boxed one object per call against a byte-identical
free function's zero, at 1,000,000 elements:

    free-function driver   obj (swept+live)         7    allocbytes    528,736
    method driver          obj (swept+live) 1,000,007    allocbytes 32,528,736

**That gap is now closed.** Direct method dispatch, and exploded return
words across `Op.CallIface`, both landed and merged to `main` since that
measurement.
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
box that forced the protocol's original rejection is gone for a concrete
class's direct calls and for a trait-typed value's vtable calls alike.
Three identical zeros are also what a probe reports when the
optimizer has folded the whole loop away, so the measurement carries a
control: the same class and the same driver returning a `Pair` enum whose
two payload variants hold different types, which is not eligible for the
unboxed representation. It reports `swept=917487 live=82521
allocbytes=32,528,768` on the same binary and the same stdout, one box per
element. The instrument can see a box; the `Option<i64>` arms do not have
one. The four `.bit` files, including that control, are deliberately not
committed, because they exist to prove a compiler property, not to
exercise a stdlib API.

`next(): Option<T>` is therefore accepted on allocation grounds, not
merely on protocol grounds. A future change to `explodesParams`,
`methodRetExplodes` or `ifaceWordRetMethods` that reopens this box needs a
regression test; `_tests_/cases/run_enum_explode_method.bit` already pins
the shape by name and says so in its own header comment.

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
iteration. Exploded return words keep that real call from allocating regardless,
by carrying exploded return words across the vtable slot on any method
name every implementor and every interface declaration agree on
(`ifaceWordRetMethods`, `compiler/lowerexplodeiface.bit`). So the
trait-typed loop does not reach the raw-loop shape a slice gets, but it
does reach the no-allocation shape, which is the gap the allocation
measurement closes.

Inlining order-independence matters here because a `for … of`
loop's own body is itself a candidate the inliner walks into after
splicing `next()`, and a splice order that depended on iteration order
would make the same program inline differently depending on unrelated
code elsewhere in the file. It does not have to be re-verified here; it
already removed the dependency this feature would otherwise have
reintroduced.

## Why slices, maps and channels do not use `next()`

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
is **not** that. Maps and channels stay
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
(`elementType`, `compiler/checkmatch.bit:69`),
and `for (k, v) of m` is that pair destructured positionally through the
same `checkTupleBinders` a tuple-typed `next(): Option<(K, V)>` would use.
A user type that wants to be ranged over as pairs declares
`next(): Option<(K, V)>` and gets the same binder for free; nothing about
the trait needs a second binder rule for it.

## Measured cost of the three loop shapes

**Measured on `4a208905`**, drained box under `boxlock.sh solo`,
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
width.** In that regime high IPC means saturation,
not headroom. It is why (b)'s 1.64x instruction cost buys only ~1.3x
cycles -- the extra work fits in issue slots the slice loop was not using
-- and it is also why adding instructions to any of these shapes should be
expected to cost roughly proportionally. An optimization here that trades
instructions for stalls will lose: one such attempt measured -1.12%
instructions at +3.01% cycles in comparable code and was rejected.

The interface arm is the one worth knowing about: **~4.7x the instructions
and ~4x the cycles** of a slice loop, because every element pays a dynamic
dispatch that cannot inline. A concrete-typed iterator is close enough to
a raw loop to be uninteresting; an interface-typed one is not.
