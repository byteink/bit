# Modules

A module is a **directory** of `.bit` files that share one flat declaration
namespace. There is no per-file package clause - membership is by directory, and
declarations in the same module may reference each other in any order. (Spec:
§17.)

## Imports

Import from another module with `import ... from "path"`. The path is a
standard-library module like `"std/io"` or a relative project path like
`"./util"` or `"../shared"`.

```bit
import { readFile, writeFile } from "std/fs"  // named members
import { readFile as slurp } from "std/fs"    // rename on import
```

A namespace import binds the module itself, and members are reached through it:

```bit
import io from "std/io"       // namespace: io.stdout()
import * as fs from "std/fs"  // explicit namespace form

fn dump(path: string): ()! {
  let w = io.stdout()
  w.write(fs.readFile(path)?)
  w.flush()
  return
}
```

- A namespace import binds one name; members are accessed as `io.stdout()`.
- A named import binds members directly.
- `as` renames, either the namespace or an individual member.
- A namespace member names an *exported* symbol of that module: `io.Stdout` reads
  the constant, `io.stdout()` calls the function. Naming an unexported one is an
  error, not a silent miss.

Only exported members are importable, and import cycles between modules are an
error.

```bit
fn show(path: string): ()! {
  println(readFile(path)?)   // readFile imported above
  return
}
```

## Visibility with `export`

Visibility is by the explicit `export` keyword, not by identifier casing.
Unmarked declarations are module-private.

```bit
export fn publicApi(): int { return 42 }   // visible to importers

fn helper(): int { return 1 }               // module-private

export class Config {
  export name: string      // field visible outside the module
  secret: string           // field module-private
}
```

- `export` on a top-level declaration exports it.
- `export` on a class field makes that field readable and writable outside the
  module; an unexported field cannot appear in a foreign composite literal or be
  selected outside its module.
- Export a method by placing `export` before its `fn` keyword:

```bit
export fn (c: Config) describe(): string {
  return c.name
}
```

## The `main` entry point

The executable module is the root directory passed to `bit build`. It must
declare exactly one `main` function. Three signatures are permitted:

```bit ignore
fn main() { }              // exit code 0 on normal return

fn main(): int {           // returned int is the process exit code
  return 0
}

fn main(): ()! {           // a returned error prints to stderr, exit 1
  return
}
```

(Three alternatives for one declaration, so this block is not doc-tested - a
module may only declare `main` once.)

`main` takes no parameters; read command-line arguments and the environment via
the standard library (`std/os`). A library module has no `main`.

## Builtins

A handful of functions are predeclared in every module and need no import:
`len`, `cap`, `append`, `delete`, `close`, `panic`, `assert`.

```bit
fn builtins(xs: []int, m: map<string, int>) {
  let n = len(xs)
  let c = cap(xs)
  let ys = append(xs, 4, 5)
  delete(m, "key")
  assert(n >= 0)
}
```

## A complete program

```bit
interface Shape { area(): f64 }

class Circle { export r: f64 }
class Rect   { export w: f64; export h: f64 }

fn (c: Circle) area(): f64 { return 3.14159 * c.r * c.r }
fn (r: Rect)   area(): f64 { return r.w * r.h }

fn totalArea<T: Shape>(shapes: []T): f64 {
  let sum = 0.0
  for s of shapes {
    sum += s.area()
  }
  return sum
}

fn main(): ()! {
  // `T: Shape` binds T to a concrete type that satisfies Shape, so instantiate
  // over `Circle` rather than over `Shape` itself.
  let circles: []Circle = [Circle{ r: 1.0 }, Circle{ r: 2.0 }]
  println("area = ${totalArea<Circle>(circles)}")
  return
}
```
