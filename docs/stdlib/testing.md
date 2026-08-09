# std/testing

Assertions for `bit test`. A test is any top-level function named `test_...`;
`bit test` finds them, runs each in its own process, and reports what failed.

A failing assertion panics, which is why each test gets its own process - one
failure cannot take the rest of the run down with it. It also means the first
failure in a test is the last thing that test does.

Every assertion takes a `label` as its final argument. It is printed on failure,
so make it say which case failed, not which function.

<!-- doctest: per-block -->

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
$ bit test math.bit
ok   test_double

1 test: 1 passed, 0 failed
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
