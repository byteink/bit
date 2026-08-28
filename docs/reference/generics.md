# Generics

Generics let functions and types work over many element types without giving up
static checking. Type parameters go in angle brackets `<...>`, may be bounded by
one or more interfaces, and are resolved by **monomorphization** at compile time - no boxing, no runtime type erasure. (Spec: §11.3, §13.6, §15.3.)

## Generic functions

```bit
fn first<T>(xs: []T): T {
  return xs[0]
}

fn use() {
  let a = first([]int{ 1, 2, 3 })     // T inferred as int
  let b = first([]string{ "x", "y" }) // T inferred as string
}
```

An unbounded parameter `<T>` admits any type but permits only operations valid
for all types (assignment, passing, and equality only at a comparable site).

## Constraints

Bound a type parameter to one or more interfaces with `&`. Inside the body you
may use exactly the methods the bound guarantees.

```bit
interface Ord {
  less(other: Self): bool,
}

fn max<T: Ord>(a: T, b: T): T {
  if (a.less(b)) {
    return b
  }
  return a
}
```

Multiple bounds combine with `&`:

```bit
interface Reader { read(): string }
interface Closer { close() }

fn drain<T: Reader & Closer>(src: T): string {
  let data = src.read()
  src.close()
  return data
}
```

## Generic classes and interfaces

Type parameters attach to classes, interfaces, and type aliases too.

```bit
class Box<T> {
  export value: T,
}

interface Container<T> {
  get(): T,
}

type Pair<A, B> = (A, B)

fn boxed() {
  let b = Box<int>{ value: 42 } // generic composite literal
  let v = b.value
}
```

## Type inference

Call-site type arguments are usually inferred by unifying parameter types with
argument types, so you seldom write them. If a type parameter cannot be inferred
(for example it appears only in the result), supply it explicitly with
`f<T>(...)`.

```bit
fn make<T>(): []T {
  return []T(0)
}

fn explicit() {
  let xs = make<int>() // explicit: T appears only in the result
}
```

## Monomorphization

Each distinct set of type arguments produces a specialized compiled copy. There
is no runtime type tag on a type parameter and no boxing, so generic code is as
direct as hand-written code and code size is bounded statically at compile time.
