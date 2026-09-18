# Test your code

A test is a `test "name" { }` declaration in a file named `<something>.test.bit`.
`bit test` finds every one, runs each in its own process, and reports what
failed - no test class to extend, no registry to import into.

<!-- doctest: per-block -->

## The shortest complete test

Put this in `math.test.bit`, beside the code it tests:

<!-- doctest: test-file -->
```bit
import { eq, ok } from "std/testing"

fn double(n: int): int {
  return n * 2
}

test "double" {
  eq<i64>(double(21), 42, "double")
  ok(double(0) == 0, "zero doubles to zero")
}
```

Run it:

```
$ bit test math.test.bit
ok   double

discovered 1 test, ran 1: 1 passed, 0 failed
```

`eq<T>(got, want, label)` fails and prints both values when they differ;
`ok(cond, label)` fails unless `cond` is true. Every assertion takes a label
as its last argument - it is what a failure prints, so make it say which
case failed, not which function ran.

## Several bad rows in one run

A fatal assertion stops the test at the first failure. For a table of cases
where you want to see every bad row in one run, use the `check` twins and
call `checkDone()` once, normally as `defer checkDone()` at the top of the
test:

<!-- doctest: test-file -->
```bit
import { checkEq, checkDone } from "std/testing"

class Case { name: string, got: int, want: int }

test "table" {
  defer checkDone()
  let cases = [
    Case{ name = "a", got = 1, want = 1 },
    Case{ name = "b", got = 2, want = 20 },
    Case{ name = "c", got = 3, want = 30 },
  ]
  for (let i = 0; i < len(cases); i++) {
    checkEq(cases[i].got, cases[i].want, "case ${cases[i].name}")
  }
}
```

That fails with both bad rows named, not just the first:

```
$ bit test table.test.bit
check failed: case b: got 2, want 20
check failed: case c: got 3, want 30
panic: one or more checks failed above
FAIL table

discovered 1 test, ran 1: 0 passed, 1 failed
```

A `checkX` call on its own never fails the test - only `checkDone()` turns a
recorded failure into a real one. Writing a `checkX` without a paired
`checkDone()` is a test that silently always passes; write them together.

## Comparing a `class` value

`eq<T>` needs to render `T` as text to build its failure message. Every
primitive and `string` already can; a `class` needs its own `show(): string`.
Without one, `eq<Point>(...)` does not compile:

```
error[E0073]: cannot interpolate a value of type 'Point'
  ...this generic is instantiated with a type that has no 'show(): string' method
```

Add `show()` and the comparison works:

<!-- doctest: test-file -->
```bit
import { eq } from "std/testing"

class Point {
  x: int
  y: int

  show(): string {
    return "(${this.x}, ${this.y})"
  }
}

test "points" {
  eq<Point>(Point{ x = 1, y = 2 }, Point{ x = 1, y = 2 }, "same point")
}
```

## A test that should panic

A test named `testpanic_...` (still discovered by its `test "..." { }`
declaration, not by that prefix) passes when its process dies from a panic
and fails when it returns normally:

<!-- doctest: test-file -->
```bit
class Stack {
  items: []i64

  pop(): i64 {
    return this.items[len(this.items) - 1]
  }
}

test "testpanic_pop_on_empty" {
  let s = Stack{}
  s.pop()
}
```

## Sharp edges

- `bit test <file|dir> --run <pattern>` runs only tests whose name contains
  `<pattern>` as a literal substring - not a glob, not a regex, and case
  sensitive. `--run` matching nothing is an error:
  `bit test: no test matched --run <pattern>`, exit 1.
- `bit test` exits `3`, not `1`, for a path that discovers zero tests at all
  - the way a script tells "nothing to test here" apart from "a test failed".
  A project-wide `bit test` with no path is fine on a project with no tests
  yet and exits `0`.
- A bare top-level function in a `.test.bit` file with no parameters and no
  return type is `E0117`, not a discovered test - only a `test "name" { }`
  declaration counts.

## What to read next

[std/testing](../stdlib/testing.md) lists every assertion, including
`near` for floating point and `eqSlice`/`eqMap` for collections. For the
`T!`/`catch` machinery a table-driven test often needs to set up its cases,
see [Handle errors](handle-errors.md).
