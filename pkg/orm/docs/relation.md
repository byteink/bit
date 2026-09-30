# Relations

`db.table<Author>().all()?` gives you every `Author`. The moment your page
also needs each author's articles, the obvious next line is a loop:

```text
for a of db.table<Author>().all()? {
  let theirArticles = db.table<Article>().where("authorId", a.id).all()?  // one query PER author
}
```

200 authors is 201 queries. That is the N+1 problem, and it is the reason
this page exists: a relation loads in one query for all the parent rows
together, so 200 authors cost two statements, not 201, no matter how many
rows come back.

The rule, once: **read a relation and the compiler loads it.** When it can
trace a read of `author.articles` back to the query that produced the
author, it adds the relation to that query itself. When it cannot prove the
load, the build fails and names where to add `.with("articles")`. Nothing
loads unless something reads it, and all the database work still happens at
the query's own `?`.

## Declare the relation, then read it

```bit
import { Db, open } from "orm"

@table class Author {
  id: i64
  name: string
  @hasMany("authorId")
  articles: []Article
}

@table class Article {
  id: i64
  authorId: i64
  title: string
  @belongsTo("authorId")
  author: Author
}

fn printAuthors(db: Db): ()! {
  for a of db.table<Author>().orderBy("name").all()? {
    println("${a.name}")
    for article of a.articles {
      println("  ${article.title}")
    }
  }
}
```

`@hasMany("authorId")` names the foreign key column on `Article`, the owning
side - not the target type, which `articles: []Article` already says, and
not something this package infers from a naming convention.

`printAuthors` reads `a.articles`, so the compiler loads `articles` with the
query: exactly two statements no matter how many authors come back, the
`select * from author` that `all()` always ran, plus one more `select * from
article where author_id in (...)` for every id it saw - never one query per
author. You wrote no `.with(...)` call; the compiler added the equivalent.

The read does not have to sit next to the query. The compiler follows the
rows through a `let`, a `for` loop, indexing, a trailing `?`, the parameters
and return value of your own functions, and a `match` arm such as
`Some(author)`:

```bit
fn homepage(db: Db): []Author! {
  return db.table<Author>().orderBy("name").all()?
}

fn printHomepage(db: Db): ()! {
  for a of homepage(db)? {
    println("${a.name}: ${len(a.articles)} articles")
  }
}
```

`homepage` never mentions `articles`, yet `printHomepage`'s read of
`a.articles` reaches the query inside it, so that query loads `articles`. A
relation that nothing reads is never loaded.

## Growing it: the rest of the chain

```bit
fn printAuthor(db: Db, id: i64): ()! {
  match (db.table<Author>().where("id", id).first()?) {
    Some(a) => println("${a.name} wrote ${len(a.articles)} articles")
    None => println("not found")
  }
}
```

Loading composes with `where`/`orderBy`/`limit` exactly like any other chain
method - it only changes what happens after the parent rows come back, never
how they are selected. `printAuthor` still runs two statements: the one
matching author, then one more `select ... where author_id in ($1)` for that
author's own id.

## The other direction: `@belongsTo`

A single article's own author is the opposite shape - one `Article` points
at exactly one `Author`, never a list:

```bit
fn printByline(db: Db, id: i64): ()! {
  match (db.table<Article>().where("id", id).first()?) {
    Some(article) => println("${article.title} by ${article.author.name}")
    None => println("not found")
  }
}
```

`@belongsTo("authorId")` names the same foreign key `@hasMany("authorId")`
does, read from the other side: `printByline` still runs two statements, the
article's own row plus one `select * from author where id in (...)` for the
(at most one, here) author id it saw. It is the direction of the foreign
key, not a different mechanism.

## When the compiler cannot prove the load: E0300

The compiler follows rows through your own code. It cannot follow a row
that goes somewhere it cannot see: stored in a class field, a map, a list or
a channel; captured by a closure; passed through an interface or a generic
type parameter; or produced by raw SQL. Say a cache keeps the authors for
later. In a file with the import and the two classes above, add:

```text
class Cache {
  latest: []Author,
}

fn warm(db: Db, cache: Cache): ()! {
  cache.latest = db.table<Author>().orderBy("name").all()?
}

fn printCached(cache: Cache) {
  for a of cache.latest {
    println("${a.name}: ${len(a.articles)} articles")
  }
}
```

`bit check` refuses it:

```text
error[E0300]: relation field 'articles' on 'Author' was read without the compiler proving its rows were loaded
  --> ./main.bit:28:31
   |
28 |     println("${a.name}: ${len(a.articles)} articles")
   |                               ^^^^^^^^^^ these rows came from the query on line 23, which does not load 'articles' -- add '.with("articles")' to that query
```

This is a build error, not a runtime surprise: the program never runs with
a relation that was read before it was loaded. The message names the field,
the class, the read, and the query that filled the cache. Follow it - add
the `.with("articles")` it names to that query, and the build passes:

```bit
class Cache {
  latest: []Author,
}

fn warm(db: Db, cache: Cache): ()! {
  cache.latest = db.table<Author>().orderBy("name").with("articles").all()?
}

fn printCached(cache: Cache) {
  for a of cache.latest {
    println("${a.name}: ${len(a.articles)} articles")
  }
}
```

Here the explicit form earns its place: the read is in `printCached`, where
the rows have already left the query, so you say on the query line what the
compiler could not work out.

Raw SQL is the one source no `.with(...)` can reach: `db.query<Author>(sql)`
returns whatever columns your statement selects and has no chain to add a
load to. A relation read on its rows gets its own message:

```text
fn printRaw(db: Db): ()! {
  for a of db.query<Author>("select * from author where name like $1", "A%")? {
    println("${a.name}: ${len(a.articles)} articles")
  }
}
```

```text
error[E0300]: relation field 'articles' on 'Author' was read without the compiler proving its rows were loaded
  --> ./main.bit:20:31
   |
20 |     println("${a.name}: ${len(a.articles)} articles")
   |                               ^^^^^^^^^^ rows from raw SQL do not load relations; read 'articles' through db.table<Author>().with("articles"), or select its columns in the SQL and read them as fields
```

The first way out is the query builder, which loads the relation for you:

```bit
fn printNamed(db: Db, name: string): ()! {
  for a of db.table<Author>().where("name", name).all()? {
    println("${a.name}: ${len(a.articles)} articles")
  }
}
```

The second is to leave the relation out of it: select the columns you need
into a class of your own and read them as plain fields.

## The explicit form: `with()`

`.with("articles")` is what the compiler writes for you, and you can write
it yourself:

```bit
fn authorsWithArticles(db: Db): []Author! {
  return db.table<Author>().with("articles").all()?
}
```

It loads `articles` whether or not anything in the program reads it, so it
costs its one extra statement even when nothing does. It is checked at
compile time against `Author`'s own fields, the same check
[Query](query.md)'s `where`/`orderBy` already get - a typo is a compiler
error:

```text
db.table<Author>().with("artikels")
```

```text
error[E0163]: 'artikels' is not a field of 'Author'
```

Reach for it when you want the load visible on the query line, or when
E0300 names a query to add it to. A nested read such as
`article.author.articles` needs no call at all: the compiler loads every
level the read passes through, and `with("author.articles")` is the explicit
spelling of the same path.

An EXPLICITLY empty relation is not "never loaded": an author with no
articles gets `a.articles = []Article{}`, which reads as length 0. "No
articles" and "not loaded" stay two different things. A read through an
interface value, where the receiver's own type is not a known `@table`
class, is beyond the compiler's reach and still fails at run time, with a
panic naming the `.with(...)` to add.

## When not to use this

For a many-to-many relationship - an article that carries several tags, a
tag that spans several articles - see [Many-to-many](manytomany.md) instead:
neither foreign key lives on either table, and there's a join table to
declare.

## Where to go next

[Query](query.md) covers `where`/`orderBy`/`limit`/`after`, the rest of the
chain `with()` composes with. [Many-to-many](manytomany.md) covers
`@manyToMany`, the join-table relation, which loads the same way, plus
`link`/`unlink` for changing the set. [Soft delete](softdelete.md) covers
what `all`/`first` hide by default on a `@softDelete` class.
