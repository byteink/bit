# Language

A human-readable companion to the [language specification](../../spec/SPEC.md).
The specification is the authority; this reference explains the same language
in prose with runnable examples. Where the two disagree, the specification
wins and this reference is the bug.

Bit is a systems language with TypeScript-flavored syntax and Go-like
semantics: garbage collected, green-threaded, structurally typed, compiled to
a single native binary.

Every example draws from Inkwell, a small notes app also used by
[the Book](../book/README.md): a `Draft` has a title, a body, tags, and a
status.

## Pages

| Page | Covers |
| ---- | ------ |
| [Variables](variables.md) | `let`/`const`, mutability, zero values, destructuring, assignment |
| [Types](types.md) | primitives, strings, slices, arrays, maps, tuples, conversions, value vs. reference semantics |
| [Classes](classes.md) | declaring a class, fields, composite literals, methods, comparability |
| [Static Methods](static-methods.md) | `static` methods, dispatch through a type name |
| [Functions](functions.md) | parameters, variadics, arrow functions, control flow |
| [Interfaces](interfaces.md) | structural interfaces, `error`, type assertions |
| [Traits](traits.md) | `trait`, `use`, required vs. provided methods |
| [Generics](generics.md) | type parameters, constraints, inference |
| [Concurrency](concurrency.md) | `spawn`, channels, `select` |
| [Errors](errors.md) | fallible functions, `?`, `catch`, `fail`, `defer`, panics |
| [Modules](modules.md) | modules, imports, `export`, the `main` entry point |

For the standard library, see [Standard library](../stdlib/README.md).

## How to read the examples

Snippets with executable statements are shown inside a function, because Bit
allows only declarations at the top level. A complete program looks like
this:

```bit
fn main() {
  println("hello, bit")
}
```

`// ...` marks an omitted body that is not the point of the example.
