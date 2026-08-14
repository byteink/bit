# std/sort

Comparator-based sorting over slices. There is no built-in ordering (no `Ord`
bound) - every function here takes an explicit `less` callback, the same
shape as `filter`/`reduce` in `std/seq`.

The sort itself is an iterative bottom-up merge sort and is **stable**: two
elements for which neither is `less` than the other keep their input order.

<!-- doctest: per-block -->

### `sortInPlace(xs: []T, less: (T, T) => bool)`

Sorts `xs` in place. Stable, O(n log n) time, O(n) extra space for one
scratch buffer reused across every merge.

### `sorted(xs: []T, less: (T, T) => bool): []T`

A new slice holding a sorted copy of `xs`. `xs` itself is left unmodified -
the copy is a fresh, sized allocation, never grown by appending onto the
caller's slice.

### `isSorted(xs: []T, less: (T, T) => bool): bool`

Whether `xs` is already in order under `less`. `true` for an empty slice and
for a one-element slice.

```bit
import { sorted, sortInPlace, isSorted } from "std/sort"

fn ascending(xs: []int): []int {
  return sorted(xs, (a: int, b: int) => a < b)
}

fn sortNamesInPlace(names: []string) {
  sortInPlace(names, (a: string, b: string) => a < b)
}

fn isAscending(xs: []int): bool {
  return isSorted(xs, (a: int, b: int) => a < b)
}
```
