# Relations

`db.table<Author>().all()?` gives you every `Author`. The moment your page
also needs each author's articles, the obvious next line is a loop:

```text
for a of db.table<Author>().all()? {
  let theirArticles = db.table<Article>().where("authorId", a.id).all()?  // one query PER author
}
```

200 authors is 201 queries. That is the N+1 problem, and it is the reason
this page exists: `with()` turns "one query per row" into "one query for the
parent rows, one more for every relation you asked for" - two statements for
200 authors, not 201, no matter how many rows come back.

## Declare the relation, then ask for it with `with()`

```bit
import { Db, open } from "orm"

@table class Author {
  id: i64
  name: string
  @hasMany("authorId")
  articles: []Article
}

@table class Article {
  id: i64,
  authorId: i64,
  title: string,
}

fn authorsWithArticles(db: Db): []Author! {
  return db.table<Author>().with("articles").all()?
}
```

`@hasMany("authorId")` names the foreign key column on `Article`, the owning
side - not the target type, which `articles: []Article` already says, and
not something this package infers from a naming convention. `with("articles")`
is checked at compile time against `Author`'s own fields, the same check
[Query](query.md)'s `where`/`orderBy` already get - a typo is a compiler
error, not a runtime surprise:

```text
db.table<Author>().with("artikels")
```

```text
error[E0163]: 'artikels' is not a field of 'Author'
```

`authorsWithArticles` runs exactly two statements no matter how many authors
come back: the `select * from author` `all()` always ran, plus one more
`select * from article where author_id in (...)` for every id it saw - never
one query per author.

## Growing it: combine `with()` with the rest of the chain

```bit
fn authorWithRecentArticles(db: Db, id: i64): Option<Author>! {
  return db.table<Author>().where("id", id).with("articles").first()?
}
```

`with()` composes with `where`/`orderBy`/`limit` exactly like any other chain
method - it only changes what happens after the parent rows come back, never
how they're selected. `authorWithRecentArticles` still runs two statements:
the one matching author, then one more `select ... where author_id in ($1)`
for that author's own id.

## The real use case: a homepage that lists authors and their latest work

```bit
fn homepage(db: Db): []Author! {
  return db.table<Author>().orderBy("name").with("articles").all()?
}

fn printHomepage(db: Db): ()! {
  for a of homepage(db)? {
    println("${a.name}")
    for article of a.articles {
      println("  ${article.title}")
    }
  }
}
```

`printHomepage` never issues a query inside its own loop - every `a.articles`
it reads was already filled in by the single `with("articles")` call in
`homepage`, whether `a` has three articles or none.

## The sharp edge: a relation you never asked for panics on read

```bit
fn readWithoutLoading(db: Db): ()! {
  let a = db.table<Author>().all()?[0] // no .with("articles")
  print("${len(a.articles)}\n")        // panics
}
```

```text
panic: relation field 'articles' on 'Author' was read before it was loaded -- add '.with("articles")' to the query that produced it
```

This is deliberate, not a bug to work around: Bit has no property
interception, so silent lazy loading - the thing that turns into an
accidental N+1 the moment someone reads a relation inside a loop - is not
possible here at all. A relation you did not ask for is not a query waiting
to fire; reading it is a mistake, and it fails loudly, naming the exact
`.with(...)` call that fixes it.

An EXPLICITLY empty relation is not this - an author with no articles gets
`a.articles = []Article{}` from `with("articles")` above, which reads as
length 0 with no panic. "No articles" and "never loaded" stay two different
things.

## When not to use this

For a many-to-many relationship - an article that carries several tags, a
tag that spans several articles - see [Many-to-many](manytomany.md) instead:
neither foreign key lives on either table, and there's a join table to
declare.

## Where to go next

[Query](query.md) covers `where`/`orderBy`/`limit`/`after`, the rest of the
chain `with()` composes with. [Many-to-many](manytomany.md) covers
`@manyToMany`, the join-table relation `with()` also eager-loads, plus
`link`/`unlink` for changing the set. [Soft delete](softdelete.md) covers
what `all`/`first` hide by default on a `@softDelete` class.
