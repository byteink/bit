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

## Collections

The other half of std/seq: pulling a slice out of a map, or changing a
slice's shape (insert, remove, concat, unique) instead of transforming its
elements in place.

### `keys(m: map<K, V>): []K`

`m`'s keys, as a slice. Iteration order is deterministic for a given build but
is neither insertion order nor sorted — sort the result with `std/sort` if
callers need a stable printed order.

### `values(m: map<K, V>): []V`

`m`'s values, as a slice, in the same order as `keys`.

```bit
import { keys, values } from "std/seq"

fn scoreNames(scores: map<string, int>): []string {
  return keys(scores)
}

fn scoreValues(scores: map<string, int>): []int {
  return values(scores)
}
```

### `concat(a: []T, b: []T): []T`

A new slice holding `a`'s elements followed by `b`'s; both are left
unmodified.

### `insertAt(xs: []T, at: i64, v: T): []T`

A new slice like `xs` with `v` inserted before index `at`; `xs` is left
unmodified. `at <= 0` inserts at the front, `at >= len(xs)` appends at the
end.

### `removeAt(xs: []T, at: i64): []T`

A new slice like `xs` with the element at index `at` removed; `xs` is left
unmodified.

```bit
import { concat, insertAt, removeAt } from "std/seq"

fn merged(a: []int, b: []int): []int {
  return concat(a, b)
}

fn withInserted(xs: []int, at: i64, v: int): []int {
  return insertAt(xs, at, v)
}

fn withRemoved(xs: []int, at: i64): []int {
  return removeAt(xs, at)
}
```

### `equal(a: []T, b: []T): bool`

Whether `a` and `b` hold the same elements in the same order. A plain
`a == b` is not this: a slice is not comparable. Element equality uses `==`,
which is field-wise content comparison for structs (#2105), so `equal` over
a slice of structs is correct.

### `unique(xs: []T): []T`

A new slice holding `xs`'s elements with duplicates removed, keeping the
first occurrence of each and its original order. O(n^2): an unbounded type
parameter cannot be the key of a `map<T, bool>` seen-set, so this is a scan
comparing every kept element with `==`.

```bit
import { equal, unique } from "std/seq"

fn sameElements(a: []int, b: []int): bool {
  return equal(a, b)
}

fn dedup(xs: []int): []int {
  return unique(xs)
}
```

### `groupBy(xs: []T, key: (T) => K): map<K, []T>`

Partitions `xs` into buckets keyed by `key`, preserving each bucket's
relative order of insertion.

### `indexBy(xs: []T, key: (T) => K): map<K, T>`

Indexes `xs` by `key`; a later element with a key already seen overwrites the
earlier one.

```bit
import { groupBy, indexBy } from "std/seq"

class Item {
  id: int,
  category: string,
}

fn byCategory(items: []Item): map<string, []Item> {
  return groupBy(items, (i: Item) => i.category)
}

fn byId(items: []Item): map<int, Item> {
  return indexBy(items, (i: Item) => i.id)
}
```
