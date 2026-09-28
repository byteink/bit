# Static Methods

A background job queue stores each queued job as a row: a type name and a
JSON payload. When a worker picks the row back up, it needs to turn
`"NotifyJob"` into code that runs `NotifyJob`'s logic - but it does not have
a `NotifyJob` value yet. It only has the *name*. Every method covered on
[Classes](classes.md) needs an instance to call through (`this`); none of
them can answer "what is your dispatch name" before one exists.

## The simplest thing that works

A `static` method belongs to the type, not to an instance. It has no `this`,
and is called through the class's own name:

```bit ignore
class NotifyJob {
  static label(): string {
    return "notify"
  }
}

fn main() {
  println(NotifyJob.label()) // "notify", with no NotifyJob value anywhere
}
```

`static label(): string { ... }` reads exactly like an ordinary method
([Classes](classes.md#methods)) except for the one word in front, and
`NotifyJob.label()` calls it through the type name instead of through a
value's `.`.

This page's examples are marked `ignore` rather than run automatically:
several are fragments or deliberately show a diagnostic, not a complete
program - see [Specification](#specification).

## Dispatching by name, not by instance

The real use case is a worker loop that has several job *types* and a
string read from storage, and needs to call each type's own logic with none
of them in hand:

```bit ignore
interface Job {
  static label(): string
}

class NotifyJob {
  static label(): string {
    return "notify"
  }
}

class DigestJob {
  static label(): string {
    return "digest"
  }
}

fn dispatchName<T: Job>(): string {
  return T.label()
}

fn main() {
  println(dispatchName<NotifyJob>()) // "notify"
  println(dispatchName<DigestJob>()) // "digest"
}
```

`interface Job { static label(): string }` is a **static requirement**: a
class satisfies it the same structural way it satisfies an ordinary
interface ([Interfaces](interfaces.md#satisfaction)), but with a `static`
method rather than an instance one. `T.label()` inside `dispatchName<T:
Job>()` calls through the type parameter, resolved once per concrete `T`
at compile time - `dispatchName<NotifyJob>()` and `dispatchName<DigestJob>()`
each call a different, statically known function. There is no vtable and no
runtime type information involved, unlike calling a method through an
interface *value*.

## Sharp edge: no `this`

A static method's body has no receiver to read:

```bit ignore
class NotifyJob {
  tries: int,
  static label(): string {
    return this.tries // error[E0040]: undefined name 'this'
  }
}
```

This is the same diagnostic a top-level function's body gets for the same
reason: nothing ever binds `this` outside an instance method.

## Sharp edge: not a value type

`Job` above can only be a generic bound (`T: Job`). It cannot be the type of
a variable, parameter, field, or return value - there is no instance behind
an interface *value* to call a static method on, only a type:

```bit ignore
interface Job {
  static label(): string
}

fn take(j: Job) { // error[E0170]: 'Job' declares a static requirement and
}                 // cannot be used as a value type; use it only as a
                  // generic bound ('T: Job')
```

`describe<T: Job>()`-style generic code is unaffected: the restriction
applies only to a `let`/parameter/field/result *type*, never to a bound.

## When not to use a static method

If the logic needs the instance's own data - `LinkStats.recordHit()`
reading and writing `this.hits` - it is an ordinary method, not a static
one. Reach for `static` only for the handful of operations that are true of
the *type* and need no instance to answer: a stable name, a default
configuration, a constant derived purely from which class it is.

## Specification

`static` methods, static interface requirements, and the value-type
restriction are defined in [SPEC §10.4.1](../../spec/SPEC.md) and
[§10.6](../../spec/SPEC.md).

## Next

Static requirements are declared the same place ordinary ones are: read
[Interfaces](interfaces.md) for structural satisfaction, `error`, and type
assertions.

`NotifyJob.label()` above is hand-written. [Classes](classes.md)' `@job`
attribute synthesizes exactly this static method for you, from one string,
for a real background-job queue.
