# Bit Language Reference

A human-readable companion to the [formal specification](../../spec/SPEC.md).
The spec is the authority; this reference explains the same language in prose
with runnable examples. Where the two ever disagree, the spec wins and this
reference is the bug.

Bit is a systems language with TypeScript-flavored syntax and Go-like
semantics: garbage collected, green-threaded, structurally typed, compiled to a
single static native binary. The guiding goal is **easy to write**.

## Chapters

| Chapter | Covers |
| ------- | ------ |
| [Variables](variables.md) | `let`/`const`, mutability, zero values, destructuring, assignment, comments, semicolons |
| [Types](types.md) | primitives, literals, slices, arrays, maps, tuples, structs, aliases, conversions, operators |
| [Functions](functions.md) | functions, methods, parameters, variadics, arrow functions, control flow |
| [Interfaces](interfaces.md) | structural interfaces, satisfaction, `error`, type assertions |
| [Generics](generics.md) | type parameters, constraints, inference, monomorphization |
| [Concurrency](concurrency.md) | `spawn`, channels, `select`, the memory model |
| [Errors](errors.md) | fallible functions, `?`, `catch`, `fail`, `defer`, panics |
| [Modules](modules.md) | modules, imports, `export` visibility, the `main` entry point |

## How to read the examples

Every feature has a runnable example. Snippets that contain executable
statements are shown inside a function, because Bit allows only declarations at
the top level (§9). A complete program looks like this:

```bit
import { println } from "std/io"

function main() {
  println("hello, bit")
}
```

Comments explain intent; `// ...` marks an omitted body that is not the point of
the example.

## Spec coverage map

Each SPEC.md section is documented by at least one chapter, so no feature is
left without a reference page:

| SPEC section | Chapter |
| ------------ | ------- |
| §4–§7 lexical, literals, semicolons | Variables, Types |
| §10.1 value declarations | Variables |
| §10.2 type aliases | Types |
| §10.3–§10.5 functions, methods, structs | Functions, Types |
| §10.6 interfaces | Interfaces |
| §11 types | Types |
| §11.3 generics | Generics |
| §12 expressions, operators, conversions | Types, Functions |
| §13.1–§13.5 statements, memory, arithmetic | Variables, Types, Functions |
| §13.6 garbage collection | Types |
| §13.7 concurrency memory model | Concurrency |
| §14 type system, assertions, comparability | Types, Interfaces |
| §15 type inference | Variables, Types, Generics |
| §16 concurrency | Concurrency |
| §17 modules and visibility | Modules |
| §18 error handling | Errors |
