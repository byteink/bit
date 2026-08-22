# Interfaces

An interface is a set of method signatures. Bit interfaces are **structural**: a
type satisfies an interface simply by having all its methods with matching
signatures - there is no `implements` clause and no declaration of intent.
(Spec: §10.6, §14.3, §14.4, §14.6.)

## Declaring an interface

```bit
interface Shape {
  area(): f64
  perimeter(): f64
}
```

Interfaces declare only method signatures, never fields. Interface values are
references; their zero value is `nil`.

## Satisfaction is automatic

Any type with the required methods satisfies the interface. Satisfaction is
checked where a value is used as the interface, not at declaration.

```bit
class Circle { export r: f64 }
class Rect   { export w: f64; export h: f64 }

fn (c: Circle) area(): f64      { return 3.14159 * c.r * c.r }
fn (c: Circle) perimeter(): f64 { return 2.0 * 3.14159 * c.r }
fn (r: Rect)   area(): f64      { return r.w * r.h }
fn (r: Rect)   perimeter(): f64 { return 2.0 * (r.w + r.h) }

fn describe(s: Shape): f64 {     // takes anything satisfying Shape
  return s.area()
}

fn use() {
  let total = describe(Circle{ r: 1.0 }) + describe(Rect{ w: 2.0, h: 3.0 })
}
```

Assigning a satisfying type into an interface-typed location boxes it into an
interface value carrying its dynamic type and method table.

## `Self` in interfaces

Inside an interface body, `Self` names the concrete implementing type. It may
appear only in method signatures.

```bit
interface Ord {
  less(other: Self): bool
}
```

A type satisfies `Ord` when its `less` method takes its own type as `other`.

## The `error` interface

`error` is predeclared and drives the error model (see [Errors](errors.md)):

```bit
interface error { message(): string }
```

Any type with a `message(): string` method is an `error`.

## Type assertions

An interface value can be narrowed to a concrete type. The two-result form
reports success instead of panicking; the single-result form panics on mismatch.

```bit ignore
fn areaOfCircle(s: Shape): f64 {
  let (c, ok) = s.(Circle)      // ok is false if s is not a Circle
  if (!ok) { return 0.0 }
  return 3.14159 * c.r * c.r
}

fn mustCircle(s: Shape): Circle {
  return s.(Circle)             // panics if s is not a Circle
}
```

The two-result form is valid only as the sole right-hand side of a declaration
or assignment.

The target must be a class type - only classes carry methods, so only a class
can be the concrete type behind an interface value. Asserting a type that could
never satisfy the interface is a compile-time error rather than a check that
always fails.

On a mismatch the two-result form gives back `nil`, not the original value, so
code that ignores `ok` cannot read one concrete type as another.

## Comparing interface values

Interface values compare with `==`/`!=`: two are equal when their dynamic types
are identical and their dynamic values are equal. Comparing values whose dynamic
type is not comparable (a slice, map, or function) panics at runtime.

```bit
fn sameShape(a: Shape, b: Shape): bool {
  return a == b
}
```
