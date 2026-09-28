# Test

<!-- doctest: per-block -->

A test is a `test "name" { }` declaration in a file named
`<something>.test.bit`. `bit test` finds every one, runs each in its own
process, and reports what failed - no test class to extend, no registry to
import into.

## The shortest complete test

Put this in `drafts.test.bit`, beside the code it tests:

<!-- doctest: test-file -->
```bit
import { eq, ok } from "std/testing"

fn wordCount(text: string): int {
  return len(text) / 5 // placeholder estimate
}

test "wordCount" {
  eq<i64>(wordCount(""), 0, "empty text has no words")
  ok(wordCount("a draft about bit") > 0, "non-empty text counts something")
}
```

Run it:

```
$ bit test drafts.test.bit
ok   wordCount

discovered 1 test, ran 1: 1 passed, 0 failed
```

`eq<T>(got, want, label)` fails and prints both values when they differ;
`ok(cond, label)` fails unless `cond` is true. Every assertion takes a label
as its last argument - it is what a failure prints, so make it say which
case failed, not which function ran.

## Several bad rows in one run

A fatal assertion stops the test at the first failure. For a table of cases
where you want every bad row in one run, use the `check` twins and call
`checkDone()` once, normally as `defer checkDone()` at the top of the test:

<!-- doctest: test-file -->
```bit
import { checkEq, checkDone } from "std/testing"

class Case { title: string, got: int, want: int }

test "titleLengths" {
  defer checkDone()
  let cases = [
    Case{ title = "short", got = 5, want = 5 },
    Case{ title = "off by one", got = 9, want = 10 },
  ]
  for (let i = 0; i < len(cases); i++) {
    checkEq(cases[i].got, cases[i].want, "case ${cases[i].title}")
  }
}
```

A `checkX` call on its own never fails the test - only `checkDone()` turns a
recorded failure into a real one. Writing a `checkX` without a paired
`checkDone()` is a test that silently always passes; write them together.

## Comparing a `class` value

`eq<T>` needs to render `T` as text to build its failure message. Every
primitive and `string` already can; a `class` needs its own `show(): string`.
Without one, `eq<Draft>(...)` does not compile - add `show()` and the
comparison works:

<!-- doctest: test-file -->
```bit
import { eq } from "std/testing"

class Draft {
  title: string
  body: string

  show(): string {
    return "Draft(${this.title})"
  }
}

test "drafts" {
  eq<Draft>(Draft{ title = "a", body = "b" }, Draft{ title = "a", body = "b" }, "same draft")
}
```

## A test that should panic

A test named `testpanic_...` (still discovered by its `test "..." { }`
declaration, not by that prefix) passes when its process dies from a panic
and fails when it returns normally:

<!-- doctest: test-file -->
```bit
class DraftStore {
  drafts: []string

  latest(): string {
    return this.drafts[len(this.drafts) - 1]
  }
}

test "testpanic_latest_on_empty" {
  let s = DraftStore{}
  s.latest()
}
```

## Sharp edges

- `bit test <file|dir> --run <pattern>` runs only tests whose name contains
  `<pattern>` as a literal substring - not a glob, not a regular expression,
  and case sensitive. `--run` matching nothing is an error:
  `bit test: no test matched --run <pattern>`, exit 1.
- `--timeout <seconds>` kills and fails a single test that outlives that
  many seconds (default 30); the rest of the run continues.
- `bit test` exits `3`, not `1`, for a path that discovers zero tests at
  all - the way a script tells "nothing to test here" apart from "a test
  failed". A project-wide `bit test` with no path is fine on a project with
  no tests yet, and exits `0`.
- A bare top-level function in a `.test.bit` file with no parameters and no
  return type is `E0117`, not a discovered test - only a `test "name" { }`
  declaration counts.

## Where next

[std/testing](../stdlib/testing.md) lists every assertion, including `near`
for floating point and `eqSlice`/`eqMap` for collections. [Part 1 of the
Book](../book/README.md) writes Inkwell's own test suite as it goes.
