# Many-to-many relations

[Relations](relation.md) covers `@hasMany` - one foreign key, pointing one
direction. An `Article` and a `Tag` don't fit that shape: an article has
many tags, a tag has many articles, and the fact that connects one to the
other lives on neither table. That fact needs its own table, just two
foreign keys wide - `@manyToMany`, `link` and `unlink` are what this page
covers.

## Declare it, and name the join table yourself

```bit
import { Db, open } from "orm"

@table class Article {
  id: i64
  title: string
  @manyToMany("article_tags")
  tags: []Tag
}

@table class Tag {
  id: i64
  name: string
  @manyToMany("article_tags")
  articles: []Article
}
```

`@manyToMany("article_tags")` on both sides names the join table - an
**explicit argument**, never inferred from `Article`/`Tag`. Bit has no
reflection, so nothing here can guess whether the convention is
`article_tags` or `tag_articles`; a guessed name that happens to be wrong
doesn't fail, it just reads an empty table forever. `tags`/`articles` are
the field names the compiler's load and `link`/`unlink` refer to below - the
target type (`[]Tag`, `[]Article`) is what makes each side point at the
other.

## Reading it: the compiler loads it

```bit
fn printTagged(db: Db): ()! {
  for article of db.table<Article>().orderBy("title").all()? {
    println("${article.title}: ${len(article.tags)} tags")
  }
}
```

`@manyToMany` loads the way `@hasMany` does ([Relations](relation.md)):
`printTagged` reads `article.tags`, so the compiler adds the relation to the
query, and it is one join through `article_tags` rather than a query per
article: 200 articles cost 2 statements, the parent `SELECT` plus the join,
never a separate pivot-only round trip. An article with no
tags gets `article.tags = []Tag{}`, loaded and empty. Where the compiler
cannot follow the rows to a query, `bit check` fails with E0300 and names
where to add `.with("tags")`, the same escape [Relations](relation.md)
shows; rows from raw SQL carry no `tags` at all, so the build refuses a read
of them too rather than hand you an empty list.

## Changing the set: `link` and `unlink`

An editor picking tags for an article needs to add some and remove others,
not rewrite the whole set every time:

```bit
fn addTags(db: Db, article: Article, tagIds: []i64): ()! {
  db.table<Article>().link(article, "tags", tagIds)?
}

fn removeTags(db: Db, article: Article, tagIds: []i64): ()! {
  db.table<Article>().unlink(article, "tags", tagIds)?
}
```

`link` is **idempotent** - it inserts the pairs in `tagIds` that aren't
already there, one statement, and calling it twice with the same ids is
safe: the second call inserts zero rows and raises nothing. `unlink` takes
the same, plain `targetIds` slice and issues no statement at all when it's
empty - never an unfiltered `DELETE` removing every tag from the article.
Both read `article`'s own id generically off `Article`'s declared `@id`
field, and both pick the right SQL for the database `open()` connected to -
`ON CONFLICT` on Postgres, `ON DUPLICATE KEY UPDATE` on MySQL - without
either call spelling out which.

## The join table's own DDL

`@manyToMany`'s compile-time wiring covers the load and `link`/`unlink`; it
does not create the table. [Schema](schema.md) creates tables from a hand-written
`SchemaOp`, so the join table needs one too - `manyToManyTable` builds it
from the identical `joinTable`/column names you already gave `@manyToMany`:

```bit
import { ManyToManyDesc, Postgres, manyToManyTable } from "orm"

fn articleTagsDesc(): ManyToManyDesc {
  return ManyToManyDesc{
    joinTable = "article_tags", ownerColumn = "article_id", ownerTable = "article",
    ownerIdColumn = "id", targetColumn = "tag_id", targetTable = "tag", targetIdColumn = "id",
  }
}

fn articleTagsTableSql(): []string {
  let stmts = Postgres{}.render(manyToManyTable(articleTagsDesc()))
  let out = []string(0)
  for s of stmts {
    out = append(out, s.sql)
  }
  return out
}
```

`articleTagsTableSql()` returns:

```text
create table "article_tags" (
  "article_id" bigint not null,
  "tag_id" bigint not null,
  constraint "article_tags_article_id_fkey" foreign key ("article_id") references "article" ("id") on delete cascade,
  constraint "article_tags_tag_id_fkey" foreign key ("tag_id") references "tag" ("id") on delete cascade,
  primary key ("article_id", "tag_id")
);
create index "article_tags_tag_id_idx" on "article_tags" ("tag_id");
```

Two statements, never more: a composite primary key across both columns, a
foreign key per column with `on delete cascade` so removing an `Article` or
a `Tag` also removes its pairs, and an index on the target column so
traversal from either side stays fast. `ManyToManyDesc` here is a second,
hand-written copy of what `@manyToMany("article_tags")` already told the
compiler - the load and `link`/`unlink` compute their own copy internally, so a
mismatch here (a wrong table or column name) breaks the DDL, never the
runtime calls above.

## Replacing the whole set at once

A tag-picker form that submits the *whole* desired set, not one add or
remove at a time, wants `sync` instead of `link`/`unlink` - it takes the
same `ManyToManyDesc` the DDL above already built:

```bit
import { Data, ServerDialect, sync } from "orm"

fn setTags(db: Data, articleId: i64, tagIds: []i64): ()! {
  sync(db, articleTagsDesc(), articleId, tagIds, ServerDialect.Postgres)?
}
```

`sync` runs `link`'s own idempotent insert for the given set, then one
`delete ... where article_id = $1 and tag_id not in (...)` removing anything
else already attached - one insert and one delete, never a statement per tag
and never a prior `SELECT` to compute the difference. `setTags(db, id,
[]i64(0))` is the one path that clears an article's tags entirely - reached
only by calling `sync` with an empty set, never through `unlink`. `sync`
takes the raw connection and the dialect explicitly, since - unlike
`link`/`unlink` - it isn't a `Repo<T>` method: pass it the same `Data`
handle [Testing](testing.md)'s `withRollback` closure receives.

## The honest boundary: when the join needs its own data

The moment a pair needs data of its own - who added the tag, when - a join
table with only two columns has nowhere to put it, and `manyToManyTable`
refuses to grow one: it always emits exactly two columns. Declare a real
`@table` entity for the join instead (say `ArticleTag` with `articleId`,
`tagId`, and the extra column), and traverse it as two ordinary
[`@hasMany`](relation.md) hops. That costs one more join at query time, but
it's the only place the extra column can honestly live.

## When not to use this

Not for a relationship that already fits `@hasMany` - a single foreign key
on one side needs none of this. Not once the pair carries its own data -
see "The honest boundary" above.

## Where to go next

[Relations](relation.md) covers `@hasMany` and the rule for loading a relation
that this page builds on. [Schema](schema.md) and
[Dialect](dialect.md) cover the `SchemaOp`/`Table.primaryKey` vocabulary
`manyToManyTable` uses and the DDL it renders to. [Write](write.md) covers
`insert`/`update` on `Article`/`Tag` themselves, once their tags are wired
up.
