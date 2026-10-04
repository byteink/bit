# Actions

Inkwell lets authors write articles, editors publish them, and admins do
anything. Somewhere your code has to say "publish" and mean the same thing
the policy table means by it. Strings in both places drift: `"publish"` in one
file, `"Publish"` in another, and a policy that matches nothing is a hole you
find in production. `authz` takes your own enum as the list of actions, so a
misspelled action is a compile error in code and a refused policy in storage.

<!-- doctest: per-block -->

## The simplest thing that works

Declare the actions as an enum and build one `Authz` handle at startup:

```bit
import { Authz } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

fn main(): ()! {
  let authz = Authz<Action>()?
  println("manage wildcard: ${authz.hasWildcard()}")
}
```

With no arguments the handle keeps everything in memory, so only policies
written in code apply. `Authz<Action>(store = url)` adds stored policies; a
store that cannot be reached is a `StoreUnavailable`, so the app stops at
startup instead of refusing every request later.

## Actions are stored by name

A stored policy says `"Publish"`, never a number. Reordering the enum
changes no stored policy. `actionName` is the one way to get that name:

```bit
import { actionName } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

fn main() {
  println(actionName(Action.Publish))
}
```

Names are case-sensitive. A policy that says `"publish"` is refused, and the
error names what it saw and lists every valid action, so the typo is caught
when the policy is saved.

## Writing your own generic code

`ActionEnum` is the bound for any function generic over an action enum. The
compiler writes its two members for every enum whose variants carry no data;
you never implement them.

```bit
import { ActionEnum, actionName } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

fn audit<A: ActionEnum>(who: string, a: A): string {
  return "${who} did ${actionName(a)}"
}

fn main() {
  println(audit("mira", Action.Update))
}
```

## Manage and the CRUD variants

If your enum declares a variant named `Manage`, it is the wildcard: it
matches every action, so an admin policy needs one line. Without that
variant the wildcard does not exist, and `hasWildcard()` says so.

The database bridge speaks CASL's four names: `Read`, `Create`, `Update`,
`Delete`. `Authz` records which of them your enum declares in `crud`. A
missing one is not an error here; it is an error only when you open a
database handle that needs it.

```bit
import { Authz } from "authz"

enum Action { Read, Publish }

fn main(): ()! {
  let authz = Authz<Action>()?
  println("wildcard: ${authz.hasWildcard()}")
  println("read: ${authz.crud.read}, update: ${authz.crud.update}")
}
```

This prints `wildcard: false` and `read: true, update: false`.

## Sharp edges

- The enum must have only payload-free variants. `Publish(string)` has no
  name to store, and the compiler gives it no `ActionEnum` members.
- Variant names are the stored form. Renaming a variant orphans every stored
  policy that used the old name.

## Next

Policies themselves, and how a check says which resource it is about, are
the next chapters.
