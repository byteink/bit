# Relations

`people(db).all()` gives you every `Person`. The moment your page also
needs each person's posts, the obvious next line is a loop:

```text
for p of people(db).all()? {
  let theirPosts = postsByAuthor(db, p.id)?  // one query PER person
}
```

200 people is 201 queries. That is the N+1 problem, and it is the reason
this page exists: `with()` turns "one query per row" into "one query for
the parent rows, one more for every relation you asked for" - two
statements for 200 people, not 201, no matter how many rows come back.

## Declare the relation, then ask for it with `with()`

```bit
import { Data, Query, RelationLoader, find, hasMany, withRelations } from "orm"
import { AttrDesc, FieldDesc, Rows, sqlReqInt } from "std/sql"

@table class Person {
  @id
  id: i64
  @hasMany("authorId")
  posts: []Post
  @hasOne("personId")
  profile: Profile
}

@table class Post {
  @id
  id: i64
  authorId: i64
  @belongsTo("authorId")
  author: Person
}

@table class Profile {
  @id
  id: i64
  personId: i64
}

fn idField(): FieldDesc {
  return FieldDesc{ name = "id", typeName = "i64", attrs = []AttrDesc(0) }
}

// A class-typed field (`author`, `profile`) has no zero value in Bit - it
// is a reference and would be null - so every mapper below must supply a
// placeholder even for a relation it is not loading. A `with()`-driven
// loader's `assign` overwrites it exactly like any other field write.
fn personPlaceholder(): Person {
  return Person{ id = 0, profile = Profile{ id = 0, personId = 0 } }
}

fn personMapper(rows: Rows): Person! {
  // `posts` is left unset ON PURPOSE: a relation field starts "unloaded"
  // until a `with()`-driven loader assigns it - see the sharp edge below.
  return Person{
    id = sqlReqInt(rows, rows.columns(), "id")?,
    profile = Profile{ id = 0, personId = 0 },
  }
}

fn postMapper(rows: Rows): Post! {
  let cols = rows.columns()
  return Post{
    id = sqlReqInt(rows, cols, "id")?,
    authorId = sqlReqInt(rows, cols, "author_id")?,
    author = personPlaceholder(),
  }
}

fn posts(db: Data): Query<Post> {
  let fields = [idField(), FieldDesc{ name = "authorId", typeName = "i64", attrs = []AttrDesc(0) }]
  return find<Post>(db, "posts", fields, postMapper)
}

// The five arguments, in order: the parent's own key, a FRESH unfiltered
// child query, the FK column (`@hasMany`'s own argument), reading a loaded
// child's FK, and assigning the parent's relation field.
fn postsLoader(): RelationLoader<Person> {
  return hasMany<Person, Post>(
    (p) => p.id,
    (db) => posts(db),
    "authorId",
    (post) => post.authorId,
    (p, ps) => {
      p.posts = ps
    },
  )
}

fn people(db: Data): Query<Person> {
  return withRelations(
    find<Person>(db, "people", [idField()], personMapper),
    map<string, RelationLoader<Person>>{ "posts": postsLoader() },
  )
}

fn peopleWithPosts(db: Data): []Person! {
  return people(db).with("posts").all()?
}
```

`@hasMany("authorId")` names the foreign key column on `Post`, the owning
side - not the target type, which `posts: []Post` already says, and not
something this package infers from a naming convention. `with("posts")`
is checked at compile time against `Person`'s own fields
([Query](query.md)'s compile-time check covers it too, since a relation
name is a declared field like any other), and at runtime by `Query.with`
itself: an unregistered name panics naming it.

`postsLoader` is the part that is not automatic. Bit has no reflection -
no way to read or write a field of `Person` by the string `"posts"` - so
you tell `hasMany` how: read the parent's key, build a fresh, unfiltered
`Query<Post>`, name the foreign key column, read a loaded post's own value
of it, and write the result back. `hasMany` does the batching:
`postsLoader()` runs exactly once per `with("posts")` call, as one
`where author_id in (...)` query against every parent's key at once, then
groups the results in memory. A person with no posts gets `p.posts =
[]Post{}` - loaded and empty, not "never loaded" (see the sharp edge
below).

## `belongsTo` - the same relationship from the other side

```bit
import { belongsTo } from "orm"

fn personById(db: Data): Query<Person> {
  return find<Person>(db, "people", [idField()], personMapper)
}

// The FK already on the child, a fresh unfiltered parent query, the
// parent's own key column, reading a loaded parent's key, and assigning
// the child's relation field.
fn authorLoader(): RelationLoader<Post> {
  return belongsTo<Post, Person>(
    (post) => post.authorId,
    (db) => personById(db),
    "id",
    (p) => p.id,
    (post, p) => {
      post.author = p
    },
  )
}

fn postsWithAuthor(db: Data): []Post! {
  return withRelations(
    posts(db),
    map<string, RelationLoader<Post>>{ "author": authorLoader() },
  ).with("author").all()?
}
```

`belongsTo` queries DISTINCT foreign-key values, never one parent query
per child row: 500 posts written by 12 people load exactly 12 people. The
shape is the mirror image of `hasMany` - the loader runs off the CHILD
rows already in hand, keyed by their own foreign key, matched against a
fresh parent query.

## `hasOne` - `hasMany`'s single-value twin

```bit
import { hasOne } from "orm"

fn profileMapper(rows: Rows): Profile! {
  let cols = rows.columns()
  return Profile{
    id = sqlReqInt(rows, cols, "id")?,
    personId = sqlReqInt(rows, cols, "person_id")?,
  }
}

fn profileLoader(): RelationLoader<Person> {
  return hasOne<Person, Profile>(
    (p) => p.id,
    (db) => find<Profile>(
      db, "profiles", [
        idField(),
        FieldDesc{ name = "personId", typeName = "i64", attrs = []AttrDesc(0) },
      ],
      profileMapper,
    ),
    "personId",
    (pr) => pr.personId,
    (p, pr) => {
      p.profile = pr
    },
  )
}
```

Same five arguments as `hasMany`, in the same order - the only difference
is `assign` takes one `Profile`, not a slice, and a parent with no
matching row is simply skipped rather than assigned an empty value (see
the sharp edge below for why that is not the same guarantee `hasMany`
gives).

## Chaining more than one relation

```bit
fn peopleWithBoth(db: Data): Query<Person> {
  return withRelations(
    find<Person>(db, "people", [idField()], personMapper),
    map<string, RelationLoader<Person>>{ "posts": postsLoader(), "profile": profileLoader() },
  )
}

fn peopleWithEverything(db: Data): []Person! {
  return peopleWithBoth(db).with("posts").with("profile").all()?
}
```

Every `with()` call adds exactly one more statement - two relations on 200
people is 3 statements total (1 parent + 1 per relation), never 3 x 200.

## The sharp edge: a relation you never asked for panics on read

```bit
fn readWithoutLoading(db: Data): ()! {
  let p = people(db).all()?[0] // no .with("posts")
  print("${len(p.posts)}\n")   // panics
}
```

```text
panic: relation field 'posts' on 'Person' was read before it was loaded -- add '.with("posts")' to the query that produced it
```

This is deliberate, not a bug to work around: Bit has no property
interception, so silent lazy loading - the thing that turns into an
accidental N+1 the moment someone reads a relation inside a loop - is not
possible here at all. A relation you did not ask for is not a query
waiting to fire; reading it is a mistake, and it fails loudly, naming the
exact `.with(...)` call that fixes it.

An EXPLICITLY empty relation is not this - `p.posts = []Post{}` (what a
parent with no matching rows gets from `with()` above) reads as length 0
with no panic. "No posts" and "never loaded" stay two different things.

This guarantee is `[]T` (`hasMany`) only. A `hasOne`/`belongsTo` field
(`profile: Profile`, `author: Person`) is a class-typed field, and a
class-typed field cannot be null in Bit at all - it has no zero value the
compiler could reserve a sentinel in. Reading one you never requested does
not panic; it reads whatever your row mapper placed there (`personPlaceholder`
above, in this page's own examples). If that matters for a given field, do
not give it a placeholder your program would ever read by mistake.

## When not to use this

For a many-to-many relationship, see [Many-to-many](manytomany.md):
`manyToManyTable`, `manyToManyLoader` and `attach`/`detach`/`sync` cover the
join table's DDL, eager loading and changing the set. There is no automatic
`with()` wiring from a bare `@manyToMany` field yet - unlike `@hasMany`/
`@hasOne`/`@belongsTo` above, nothing reads the attribute's own join-table
argument into a loader for you, so [Many-to-many](manytomany.md)'s
`ManyToManyDesc` is still hand-written today.

## Where to go next

[Query](query.md) covers `find<T>` and the rest of the chain `with()`
joins. [Naming](naming.md) covers how a Bit field name becomes the SQL
column text `hasMany`/`hasOne`/`belongsTo`'s foreign-key argument names.
