# std/seq

Generic operations over slices. Slices have no methods, so these are free
functions taking the slice first: `filter(xs, isEven)`, not `xs.filter(...)`.

Each returns a fresh slice; none mutates its input.

<!-- doctest: per-block -->

## Transforming

### `mapped(xs: []T, f: (T) => U): []U`

`f` applied to every element, in order. Named `mapped` because `map` is a
keyword — Bit's built-in hash map type.

### `filter(xs: []T, keep: (T) => bool): []T`

The elements for which `keep` holds, in order.

### `reduce(xs: []T, init: A, step: (A, T) => A): A`

Folds left: `step` is called with the accumulator and each element in turn,
starting from `init`.

### `reverse(xs: []T): []T`

A new slice with the elements in the opposite order.

```bit
import { mapped, filter, reduce } from "std/seq"

function sum(xs: []int): int {
  return reduce(xs, 0, (acc: int, x: int) => acc + x)
}

function evenSquares(xs: []int): []int {
  let evens = filter(xs, (x: int) => x % 2 == 0)
  return mapped(evens, (x: int) => x * x)
}
```

## Searching

### `find(xs: []T, pred: (T) => bool): Option<T>`

The first element satisfying `pred`, or `None`.

### `any(xs: []T, pred: (T) => bool): bool`

Whether `pred` holds for at least one element. `false` for an empty slice.

### `all(xs: []T, pred: (T) => bool): bool`

Whether `pred` holds for every element. `true` for an empty slice.

### `contains(xs: []T, x: T): bool`

Whether `x` is present, compared with `==`.

### `indexOf(xs: []T, x: T): i64`

The position of the first `x`, or `-1`.

### `count(xs: []T, x: T): i64`

How many elements equal `x`.

```bit
import { find, any, all, contains } from "std/seq"

function firstNegative(xs: []int): Option<int> {
  return find(xs, (x: int) => x < 0)
}

function allPositive(xs: []int): bool {
  return all(xs, (x: int) => x > 0)
}

function hasZero(xs: []int): bool {
  return contains(xs, 0)
}

function anyLong(names: []string): bool {
  return any(names, (s: string) => len(s) > 8)
}
```

## Iterating for effect

### `forEach(xs: []T, f: (T) => ())`

Calls `f` on each element, in order. A plain `for x of xs` loop is usually
clearer; this exists so a callback can be passed around.

```bit
import { forEach, reverse, indexOf, count } from "std/seq"

function printAll(xs: []string) {
  forEach(xs, (s: string) => println(s))
}

function lastFirst(xs: []int): []int {
  return reverse(xs)
}

function where(xs: []int, target: int): i64 {
  return indexOf(xs, target)
}

function occurrences(xs: []int, target: int): i64 {
  return count(xs, target)
}
```
