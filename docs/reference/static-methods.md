# Static Methods

<!-- doctest: per-block -->

A background job queue stores each queued job as a row: a type name and a
JSON payload. When a worker picks the row back up, it needs to turn
`"PublishJob"` into code that runs `PublishJob`'s logic - but it does not
have a `PublishJob` value yet, only the *name*. An ordinary method needs an
instance to call through (`this`); none of them can answer "what is your
dispatch name" before one exists.

## The simplest thing that works

A `static` method belongs to the type, not to an instance. It has no `this`,
and is called through the class's own name:

```bit
class PublishJob {
  static label(): string {
    return "publish"
  }
}

fn main() {
  println(PublishJob.label()) // "publish", with no PublishJob value anywhere
}
```

`static label(): string { ... }` reads like an ordinary method except for the
one word in front, and `PublishJob.label()` calls it through the type name
instead of through a value's `.`.

## Dispatching by name, not by instance

A worker loop has several job *types* and a string read from storage, and
needs to call each type's own logic with none of them in hand:

```bit ignore
interface Job {
  static label(): string
}

class PublishJob {
  static label(): string {
    return "publish"
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
  println(dispatchName<PublishJob>()) // "publish"
  println(dispatchName<DigestJob>())  // "digest"
}
```

`interface Job { static label(): string }` is a **static requirement**: a
class satisfies it the same structural way it satisfies an ordinary
interface, but with a `static` method rather than an instance one.
`T.label()` inside `dispatchName<T: Job>()` calls through the type
parameter, resolved once per concrete `T` at compile time - there is no
vtable and no runtime type information involved, unlike calling a method
through an interface *value*.

## Sharp edges

A static method's body has no receiver to read:

```bit ignore
class PublishJob {
  tries: int,
  static label(): string {
    return this.tries // error[E0040]: undefined name 'this'
  }
}
```

`Job` above can only be a generic bound (`T: Job`). It cannot be the type of
a variable, parameter, field, or return value: there is no instance behind
an interface *value* to call a static method on, only a type.

```bit ignore
fn take(j: Job) { // error[E0170]: 'Job' declares a static requirement and
}                 // cannot be used as a value type; use it only as a
                  // generic bound ('T: Job')
```

An enum body takes `static` methods the same way, called through the enum's
name (`Status.parse("draft")`): see [Static methods on an enum](types.md#enum-statics).

## When not to use a static method

If the logic needs the instance's own data - `Draft.recordView()` reading and
writing `this.views` - it is an ordinary method, not a static one. Reach for
`static` for the handful of operations true of the *type*, needing no
instance to answer: a stable name, a default configuration.

## Next

[Interfaces](interfaces.md) covers structural satisfaction in full.
`PublishJob.label()` above is hand-written; a class's `@job` attribute
synthesizes exactly this static method for a real background-job queue.
