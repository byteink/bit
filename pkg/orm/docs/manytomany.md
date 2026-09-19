# Many-to-many relations: attach, detach, sync

[Relations](relation.md) covers `hasMany`, `hasOne` and `belongsTo` - one
foreign key, pointing one direction. A blog's `Post` and `Tag` don't fit
that shape: a post has many tags, a tag has many posts, and the fact that
connects one to the other lives on neither table. That fact needs its own
table, just two foreign keys wide, and reading, attaching and removing a
row from it are their own operations - not something `save` or `delete` on
`Post` or `Tag` can do for you. `@manyToMany`, `manyToManyTable`,
`manyToManyLoader`, `attach`, `detach` and `sync` are what this page
covers.

## Declare it, and name the join table yourself

```bit
import {
  Data,
  ManyToManyDesc,
  Postgres,
  Query,
  RelationLoader,
  ServerDialect,
  attach,
  detach,
  find,
  manyToManyLoader,
  manyToManyTable,
  sync,
  withRelations,
} from "orm"
import { AttrDesc, FieldDesc, Rows, sqlReqInt } from "std/sql"

@table class Post {
  @id
  id: i64
  @manyToMany("post_tags")
  tags: []Tag
}

@table class Tag {
  @id
  id: i64
  @manyToMany("post_tags")
  posts: []Post
}

fn idField(): FieldDesc {
  return FieldDesc{ name = "id", typeName = "i64", attrs = []AttrDesc(0) }
}

fn postTagsDesc(): ManyToManyDesc {
  return ManyToManyDesc{
    joinTable = "post_tags", ownerColumn = "post_id", ownerTable = "posts", ownerIdColumn = "id",
    targetColumn = "tag_id", targetTable = "tags", targetIdColumn = "id",
  }
}
```

`@manyToMany("post_tags")` on both sides records that the field is a
many-to-many relation and names its join table - the compiler keeps that as
metadata (Bit has no reflection to read it back at run time), which is why
`postTagsDesc()` hand-writes the same table and column names into a
`ManyToManyDesc` for the functions below to use. Wiring the attribute's own
argument into a `ManyToManyDesc` automatically is follow-up work, not
something this page can promise yet.

The join table name is an **explicit argument**, never inferred from
`Post`/`Tag`. Bit has no reflection, so nothing here can guess whether the
convention is `post_tags` or `tag_posts` - a guessed name that happens to be
wrong doesn't fail, it just reads an empty table forever. Writing the name
once, in `postTagsDesc()`, is what `@hasMany`/`@hasOne`/`@belongsTo`'s own
foreign-key argument already does for the same reason ([Relations](relation.md)).

## The join table's own DDL

```bit
fn postTagsTableSql(): []string {
  let stmts = Postgres{}.render(manyToManyTable(postTagsDesc()))
  let out = []string(0)
  for s of stmts {
    out = append(out, s.sql)
  }
  return out
}
```

`manyToManyTable` builds two plain `int` columns, a **composite primary
key** across both of them (`Table.primaryKey(...)`, the real schema.bit
builder from #5084 - not `t.raw(...)`, schema.bit's escape hatch, which is
what this table needed before that builder existed), a foreign key per
column with `on delete cascade` so removing a `Post` or a `Tag` also
removes its pairs, and an index on the target column so traversal from
either side stays fast. `postTagsTableSql()` returns:

```text
create table "post_tags" (
  "post_id" bigint not null,
  "tag_id" bigint not null,
  constraint "post_tags_post_id_fkey" foreign key ("post_id") references "posts" ("id") on delete cascade,
  constraint "post_tags_tag_id_fkey" foreign key ("tag_id") references "tags" ("id") on delete cascade,
  primary key ("post_id", "tag_id")
);
create index "post_tags_tag_id_idx" on "post_tags" ("tag_id");
```

Two statements, never more - `manyToManyTable` emits exactly this shape and
nothing else. See "The honest boundary" below for what to do the moment
that stops being enough.

## Eager loading with `with()`

```bit
fn tagMapper(rows: Rows): Tag! {
  let cols = rows.columns()
  return Tag{ id = sqlReqInt(rows, cols, "id")?, posts = []Post(0) }
}

fn postMapper(rows: Rows): Post! {
  return Post{ id = sqlReqInt(rows, rows.columns(), "id")?, tags = []Tag(0) }
}

fn tagsLoader(): RelationLoader<Post> {
  return manyToManyLoader<Post, Tag>((p) => p.id, postTagsDesc(), tagMapper, (p, tags) => {
    p.tags = tags
  })
}

fn posts(db: Data): Query<Post> {
  return withRelations(
    find<Post>(db, "posts", [idField()], postMapper),
    map<string, RelationLoader<Post>>{ "tags": tagsLoader() },
  )
}

fn postsWithTags(db: Data): []Post! {
  return posts(db).with("tags").all()?
}
```

`manyToManyLoader` wires into `with()` exactly like `hasMany`'s own loader
([Relations](relation.md)): `postsWithTags(db)` issues the parent `SELECT`
plus one join through `post_tags`, never a query per post and never a
separate pivot-only round trip - 200 posts is 2 statements, same as
`with("posts")` in the `hasMany` case. A post with no tags gets `p.tags =
[]Tag{}`, loaded and empty, not "never loaded".

## Changing the set: attach, detach, sync

An editor picking tags for a post needs three different operations, not
one:

```bit
fn addTags(db: Data, postId: i64, tagIds: []i64): ()! {
  attach(db, postTagsDesc(), postId, tagIds, ServerDialect.Postgres)?
}

fn removeTags(db: Data, postId: i64, tagIds: []i64): ()! {
  detach(db, postTagsDesc(), postId, tagIds)?
}

fn setTags(db: Data, postId: i64, tagIds: []i64): ()! {
  sync(db, postTagsDesc(), postId, tagIds, ServerDialect.Postgres)?
}
```

`attach` is **idempotent**. It inserts the pairs in `tagIds` that aren't
already there, one statement, and calling it twice with the same ids is
safe - the second call inserts zero rows and raises nothing. That is the
join table's composite primary key doing the work: on Postgres, `attach`
renders `on conflict (post_id, tag_id) do nothing`; on MySQL it renders `on
duplicate key update post_id = post_id`, a self-assignment that changes no
column and only ever fires on the pair's own key conflict. Both take
`dialect: ServerDialect` explicitly because nothing reaching `Data` carries
a server dialect (#5384 settled this: it never will) - the same package-wide
type `write.bit`'s `upsert` and `lock.bit`'s `forUpdate` also take. Neither
`attach` nor `sync` reads the `MysqlVersion` that `ServerDialect.Mysql`
carries - `ON CONFLICT` vs `ON DUPLICATE KEY UPDATE` is a syntax choice, not
a version-gated one, so a MySQL call here supplies a version this file never
looks at, cheaper than a separate version-less type just for these two
functions. `attach` never uses `INSERT IGNORE`: that clause suppresses
every insert error on the statement, not just a duplicate key, so a
genuine foreign-key or `NOT NULL` violation would be silently dropped along
with the duplicate it was meant to catch, turning a real bug into a pair
that quietly never got attached.

`detach` takes a plain, **non-variadic** `targetIds` slice and issues no
statement at all when it's empty - never an unfiltered `DELETE`. That guard
exists because a single-sided `WHERE post_id = $1` would clear every tag
from the post, which is not what "detach these specific ids" is supposed to
do; a caller that wants a full clear reaches for `sync` instead.

A tag-picker form that submits the *whole* desired set - not one add or
remove at a time - wants `sync`: it runs `attach`'s idempotent insert for
the given set, then one `delete ... where post_id = $1 and tag_id not in
(...)` removing anything else already attached. That's one insert and one
delete, never a statement per tag and never a prior `SELECT` to compute the
difference. `sync(db, postTagsDesc(), postId, []i64(0), ServerDialect.Postgres)`
is the one path in this file that clears a post's tags entirely - reached
only by calling `sync` with an empty set, never through `detach`.

## The honest boundary: when the join needs its own data

The moment a pair needs data of its own - who added the tag, when - a join
table with only two columns has nowhere to put it, and this package
refuses to grow one: `manyToManyTable` always emits exactly two columns.
Declare a real `@table` entity for the join (say `PostTag` with `postId`,
`tagId`, and the extra column), give it two `@belongsTo` sides, and
traverse it as two ordinary hops the way [Relations](relation.md)'s
`belongsTo` section already covers. That costs one more join at query time,
but it's the only place the extra column can honestly live.

## When not to use this

Not for a relationship that already fits `hasMany`/`hasOne`/`belongsTo` - a
single foreign key on one side needs none of this. Not once the pair
carries its own data - see "The honest boundary" above.

## Where to go next

[Relations](relation.md) covers `hasMany`/`hasOne`/`belongsTo` and the
`with()`/eager-loading vocabulary this page builds on. [Schema](schema.md)
and [Dialect](dialect.md) cover the `SchemaOp`/`Table.primaryKey`
vocabulary `manyToManyTable` uses and the DDL it renders to. [Write](write.md)
covers `ServerDialect` and why it stays a separate type from `Dialect`.
