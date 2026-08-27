# std/testing

Assertions for `bit test`. A test is any top-level function with no
parameters and no return value, declared in a file named `<name>.test.bit`;
`bit test` finds them, runs each in its own process, and reports what failed.
Discovery is by filename and shape alone - no naming convention is required.
The examples below keep the `test_`/`testpanic_` style because it groups
tests visually and reads well; any name works equally.

A failing assertion panics, which is why each test gets its own process - one
failure cannot take the rest of the run down with it. It also means the first
failure in a test is the last thing that test does - unless you use the
non-fatal `checkX` twins below, which report every bad row in a table-driven
test instead of only the first.

Every assertion takes a `label` as its final argument. It is printed on failure,
so make it say which case failed, not which function.

<!-- doctest: per-block -->

Put this in `math.test.bit`, beside the `math.bit` it tests:

```bit
import { eq, ok } from "std/testing"

fn double(n: int): int {
  return n * 2
}

fn test_double() {
  eq<i64>(double(21), 42, "double")
  ok(double(0) == 0, "zero doubles to zero")
}
```

```
$ bit test math.test.bit
ok   test_double

discovered 1 test, ran 1: 1 passed, 0 failed
```

## Conditions

### `ok(cond: bool, label: string)`

Fails unless `cond` is true.

### `notOk(cond: bool, label: string)`

Fails unless `cond` is false.

### `failNow(msg: string)`

Fails immediately. For a branch that should be unreachable.

```bit
import { ok, notOk, failNow } from "std/testing"
import { hasPrefix } from "std/strings"

fn classify(n: int): string {
  if (n > 0) {
    return "positive"
  }
  if (n < 0) {
    return "negative"
  }
  return "zero"
}

fn test_classify() {
  ok(hasPrefix(classify(3), "pos"), "3 is positive")
  notOk(classify(0) == "positive", "0 is not positive")

  if (classify(-1) != "negative") {
    failNow("expected negative")
  }
}
```

## Values

These are generic, so a failure can print what it compared - not merely that the
comparison failed. Annotate the type argument when it cannot be inferred from the
arguments alone: `eq<i64>(got, 42, "...")`.

`eq`, `neq` and `eqSlice` build their failure message by interpolating `got`
and `want` (`"${label}: got ${got}, want ${want}"`), so `T` needs a way to
render as text: every primitive and `string` has one built in, but a `class`
type needs its own `show(): string` method. Without one, the call is a
compile error at the `eq`/`neq`/`eqSlice` call site, naming the missing
method and the type:

```bit ignore
class Point { x: int, y: int }

fn test_points() {
  eq<Point>(Point{ x: 1, y: 2 }, Point{ x: 1, y: 2 }, "same point")
}
```

```
error[E0073]: cannot interpolate a value of type 'Point'
  ...this generic is instantiated with a type that has no 'show(): string' method
```

Add `show()` to the class and the call compiles:

```bit
import { eq } from "std/testing"

class Point {
  x: int
  y: int

  show(): string {
    return "(${this.x}, ${this.y})"
  }
}

fn test_points() {
  eq<Point>(Point{ x: 1, y: 2 }, Point{ x: 1, y: 2 }, "same point")
}
```

### `eq(got: T, want: T, label: string)`

Fails unless `got == want`, printing both.

### `neq(got: T, unwanted: T, label: string)`

Fails if `got == unwanted`.

### `near(got: f64, want: f64, eps: f64, label: string)`

Fails unless `|got - want| <= eps`. Floating-point results are almost never
exactly equal; this is the assertion to use for them.

### `eqSlice(got: []T, want: []T, label: string)`

Fails unless the slices have the same length and equal elements. Reports the
first index that differs.

```bit
import { eq, neq, near, eqSlice } from "std/testing"
import { sqrt } from "std/math"
import { mapped } from "std/seq"

fn test_values() {
  eq<string>("bit", "bit", "same string")
  neq<i64>(1, 2, "one is not two")
}

fn test_sqrt() {
  // 1.41421356... is not exactly representable; compare with a tolerance.
  near(sqrt(2.0), 1.4142135, 0.0000001, "sqrt 2")
}

fn test_mapped() {
  let doubled = mapped([1, 2, 3], (x: int) => x * 2)
  eqSlice<i64>(doubled, [2, 4, 6], "each element doubled")
}
```

## Non-fatal checks

Every assertion above is fatal: it panics on the first bad value, so a
table-driven test with several bad rows reports only the first - fixing it and
re-running is the only way to see the second. Each has a non-fatal twin, named
with a `check` prefix, that prints the failure and *returns* instead of
panicking, so a loop can keep going and report every bad row in one run.

A non-fatal check does not fail the test by itself: v0.1 has no `recover`
(SPEC.md §18.4), and `bit test` runs a test function and returns, with no
automatic "did anything fail" step afterward. Call `checkDone()` to turn any
failures the `checkX` calls recorded into a real test failure - normally
`defer checkDone()` at the top of the function, so it runs on every return
path. **A test that calls a `checkX` and never calls `checkDone()` silently
passes** - the one sharp edge of this pair, and the reason to always write them
together.

Put this in `table.test.bit`:

```bit
import { checkEq, checkDone } from "std/testing"

class Case { name: string, got: int, want: int }

fn test_table() {
  defer checkDone()
  let cases = [
    Case{ name: "a", got: 1, want: 1 },
    Case{ name: "b", got: 2, want: 20 },
    Case{ name: "c", got: 3, want: 30 },
  ]
  for (let i = 0; i < len(cases); i++) {
    checkEq(cases[i].got, cases[i].want, "case ${cases[i].name}")
  }
}
```

```
$ bit test table.test.bit
check failed: case b: got 2, want 20
check failed: case c: got 3, want 30
panic: one or more checks failed above
FAIL test_table

discovered 1 test, ran 1: 0 passed, 1 failed
```

### `checkDone()`

Fails the test if any `checkX` call below has recorded a failure. Normally
called as `defer checkDone()`. A no-op when nothing failed.

### `checkOk(cond: bool, label: string)`

The non-fatal twin of `ok`: records the failure and returns instead of
panicking. Needs a paired `checkDone()` to actually fail the test.

### `checkNotOk(cond: bool, label: string)`

The non-fatal twin of `notOk`.

### `checkEq(got: T, want: T, label: string)`

The non-fatal twin of `eq`.

### `checkNeq(got: T, unwanted: T, label: string)`

The non-fatal twin of `neq`.

### `checkNear(got: f64, want: f64, eps: f64, label: string)`

The non-fatal twin of `near`.

### `checkEqSlice(got: []T, want: []T, label: string)`

The non-fatal twin of `eqSlice`: same "first index that differs" report,
recorded rather than panicked.

## Expected panics

`bit test` discovers a `testpanic_`-named function exactly like any other
test - by file and shape, not by its name. The `testpanic_` prefix is a
**verdict modifier**, not a discovery marker: it flips what counts as passing
for that one already-discovered test. It runs in its own child process the
same as every other test, but it passes when that process dies by a panic
(exit code 2) and fails when it returns normally or exits any other way. No
`ok`/`notOk`/`failNow` call is needed inside it; the panic itself is the
assertion.

Put this in `stack.test.bit`:

```bit
class Stack {
  items: []i64

  pop(): i64 {
    return this.items[len(this.items) - 1]
  }
}

fn testpanic_pop_on_empty() {
  let s = Stack{}
  s.pop()
}
```

## Running a subset of tests: `--run <pattern>`

`bit test <file.bit|dir> --run <pattern>` runs only the discovered tests
whose name contains `<pattern>` as a **literal substring** — not a glob and
not a regex, so nothing in `<pattern>` needs escaping and no `*`/`?`/`.` is
special. The match is against whatever the function is actually called, with
no assumption of a `test_` prefix: `--run al` matches a test named
`test_alpha` and nothing else. The match is case sensitive: `--run Alpha`
does not match `test_alpha`.

The summary line reports the true pre-filter discovered count beside the
post-filter ran count:

```
discovered 3 tests, ran 1: 1 passed, 0 failed
```

"discovered 1, ran 1" would be the tidier-looking alternative, and it is
not what happens: folding both numbers to the post-filter count would hide
that a filter narrowed the run at all, which is exactly the information
this line exists to keep visible.

A pattern that matches no test is an error: `bit test` exits 1 with
`bit test: no test matched --run <pattern>` on stderr, rather than quietly
running — and passing — zero tests. `--run` with nothing after it is a
different, narrower error — a missing value, not a missing match — with
`bit test: --run needs a pattern` on stderr and exit 2.
