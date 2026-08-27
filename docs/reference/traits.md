# Traits

A trait declares methods that are injected into a class at compile time by a
`use` statement in that class's body. Unlike an interface, a trait supplies
method *bodies*, not just a method *set* to check a value against. (Spec:
§10.7, §14.3.)

## Declaring a trait

A trait member is either **required** (a signature with no body — the class
must supply it) or **provided** (has a body, and is injected):

```bit
trait Damageable {
  hurt(n: i64)                           // required: no body
  dead(): bool { return this.hp() <= 0 } // provided: has a body
}
```

`this` inside a provided method works the same way it does in an ordinary
in-body method — it is never independently type-checked as part of the trait;
it is checked once per class that actually uses the trait.

## Using a trait

```bit
class Enemy {
  use Damageable

  hp0: i64
  hurt(n: i64) { this.hp0 = this.hp0 - n }
  hp(): i64 { return this.hp0 }
}

fn checkEnemy() {
  let e = Enemy{ hp0: 10 }
  e.hurt(3)
  print("${e.dead()}\n") // false
  e.hurt(10)
  print("${e.dead()}\n") // true
}
```

`Enemy` never declares `dead()` itself; `use Damageable` injects it. `hurt` is
required by the trait, and `Enemy`'s own in-body `hurt` satisfies it — a class
declaring a method itself always wins over one a trait would otherwise supply,
silently, with no `insteadof`/`as` syntax to choose between them.

`use` is a statement of its own inside the class body, never mixed into the
field list: `use A, B` names one or more traits, separated by commas.

An injected method participates in structural interface satisfaction exactly
like a declared one:

```bit
interface Mortal {
  dead(): bool,
}

fn reportOn(m: Mortal): string {
  if (m.dead()) {
    return "dead"
  }
  return "alive"
}
```

`Enemy` satisfies `Mortal` even though it never writes `dead(): bool` itself.

## `Self`

Inside a trait, `Self` names the class that ends up `use`ing it — resolved
once, when `use` names it, unlike an interface's `Self` (§11.3), which stays
abstract until a value is checked against the interface. It may appear only as
a trait method's own parameter or result type: not a local variable's type, a
field type, or inside an interface.

A `Self` result type gives a trait fluent, chainable methods:

```bit
trait Buildable {
  withHp(n: i64): Self {
    this.hp = n
    return this
  }
  withName(s: string): Self {
    this.name = s
    return this
  }
}

class Widget {
  use Buildable
  hp: i64
  name: string
}

fn buildWidget() {
  let w = Widget{ hp: 0, name: "" }.withHp(30).withName("gizmo")
  print("${w.hp} ${w.name}\n") // 30 gizmo
}
```

A `Self` parameter lets a trait compare two instances of whatever class uses
it:

```bit
trait Comparable {
  equals(other: Self): bool { return this.n == other.n }
}

class Box {
  use Comparable
  n: i64
}

fn compareBoxes() {
  let a = Box{ n: 5 }
  let b = Box{ n: 5 }
  print("${a.equals(b)}\n") // true
}
```

`withHp(n: i64): Self` injected into `Widget` becomes the ordinary, concrete
`withHp(n: i64): Widget` — there is nothing abstract left once a class has
`use`d the trait.

## What a trait is not

A trait is never a type. It cannot be a variable's type, a parameter, a
return type, a field type, a type-assertion target, or a generic argument —
a function that needs "anything with these methods" declares a structural
interface instead:

```bit ignore
fn f(t: Damageable) { }   // error: a trait cannot be used as a type
```

There is no vtable and no runtime dispatch: injection happens once, at check
time, and an injected method is indistinguishable from one the class wrote by
hand. Two `use`d traits providing the same method with neither overridden by
the class, a required method nobody supplies, and a cycle of traits `use`ing
each other are all compile errors — see §10.7 for the exact rules.
