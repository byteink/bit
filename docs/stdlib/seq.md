# std/seq

Generic operations over slices. Slices have no methods, so these are free
functions taking the slice first: `filter(xs, isEven)`, not `xs.filter(...)`.

Each returns a fresh slice; none mutates its input.

<!-- doctest: per-block -->

## Transforming

### `mapped(xs: []T, f: (T) => U): []U`

`f` applied to every element, in order. Named `mapped` because `map` is a
keyword - Bit's built-in hash map type.

### `filter(xs: []T, keep: (T) => bool): []T`

The elements for which `keep` holds, in order.

### `reduce(xs: []T, init: A, step: (A, T) => A): A`

Folds left: `step` is called with the accumulator and each element in turn,
starting from `init`.

### `reverse(xs: []T): []T`

A new slice with the elements in the opposite order.

### `clone(xs: []T): []T`

A copy of `xs` with its own backing array. `append` grows its argument in
place and aliases the original's storage, so a slice handed to a callee that
appends can have the caller's own view mutated underneath it; `clone` takes an
independent snapshot before that happens. Appending to (or writing into) the
clone never affects `xs`, and vice versa.

```bit
import { mapped, filter, reduce, clone } from "std/seq"

fn sum(xs: []int): int {
  return reduce(xs, 0, (acc: int, x: int) => acc + x)
}

fn evenSquares(xs: []int): []int {
  let evens = filter(xs, (x: int) => x % 2 == 0)
  return mapped(evens, (x: int) => x * x)
}

fn independentCopy(xs: []int): []int {
  let snapshot = clone(xs)
  return append(snapshot, 0)
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

fn firstNegative(xs: []int): Option<int> {
  return find(xs, (x: int) => x < 0)
}

fn allPositive(xs: []int): bool {
  return all(xs, (x: int) => x > 0)
}

fn hasZero(xs: []int): bool {
  return contains(xs, 0)
}

fn anyLong(names: []string): bool {
  return any(names, (s: string) => len(s) > 8)
}
```

## Iterating for effect

### `forEach(xs: []T, f: (T) => ())`

Calls `f` on each element, in order. A plain `for x of xs` loop is usually
clearer; this exists so a callback can be passed around.

```bit
import { forEach, reverse, indexOf, count } from "std/seq"

fn printAll(xs: []string) {
  forEach(xs, (s: string) => println(s))
}

fn lastFirst(xs: []int): []int {
  return reverse(xs)
}

fn where(xs: []int, target: int): i64 {
  return indexOf(xs, target)
}

fn occurrences(xs: []int, target: int): i64 {
  return count(xs, target)
}
```
