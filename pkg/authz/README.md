# pkg/authz

Authorization for Bit apps: code policies, roles, stored policies and
relationships, checked in one place and applied to database reads and writes.

## Install

`bit add bitlang.org/pkg/authz` writes the dependency; the package is not
released yet.

## A first look

Your own enum is the list of actions; one handle is built at startup:

```bit
import { Authz } from "authz"

enum Action { Manage, Read, Create, Update, Delete, Publish }

fn main(): ()! {
  let authz = Authz<Action>()?
  println("manage wildcard: ${authz.hasWildcard()}")
}
```

## Docs

The [chapters](docs/README.md) start with [Actions](docs/actions.md), then
[Subjects](docs/subjects.md), then
[Resources](docs/resources.md), then
[Conditions](docs/conditions.md).
[Relationships](docs/relationships.md).
[Policies](docs/policies.md).
