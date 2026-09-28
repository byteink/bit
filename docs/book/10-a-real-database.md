<!-- doctest: deps postgres -->

# A real database

Every draft still lives in `~/.ink/drafts` as one file per file. That is
fine on one laptop and wrong the moment two people, or two machines, need
to see the same drafts. This chapter puts a real database behind Inkwell -
without deleting the file store, and without every caller needing to know
which one it is talking to.

`Draft` and the file store are what [chapter 3](/book/03-what-is-a-draft)
and [chapter 2](/book/02-saving-drafts) already built - shown here again
only so this chapter's blocks compile on their own:

```bit
import { exists, mkdir, readDir, readFile, writeFile } from "std/fs"
import { envOr } from "std/os"
import { join as pathJoin } from "std/path"

export enum Status { Draft, Published, Archived }

export class Draft {
  id: string,
  title: string,
  body: string,
  tags: []string,
  status: Status,
  created: i64,
  updated: i64,
}

fn draftsDir(): string {
  return pathJoin(envOr("HOME", "."), ".ink/drafts")
}

// The file store chapter 2 built: one Markdown-ish file per draft under
// `~/.ink/drafts`.
fn saveDraft(d: Draft): ()! {
  if (!exists(draftsDir())) {
    mkdir(draftsDir())?
  }
  writeFile(pathJoin(draftsDir(), "${d.id}.md"), d.body)?
  return
}

fn loadDraft(id: string): Draft! {
  let body = readFile(pathJoin(draftsDir(), "${id}.md"))?
  return Draft{
    id = id, title = id, body = body, tags = []string(0), status = Status.Draft,
    created = 0, updated = 0,
  }
}

fn listDrafts(): []Draft! {
  if (!exists(draftsDir())) {
    return []Draft(0)
  }
  let out = []Draft(0)
  for name of readDir(draftsDir())? {
    out = append(out, loadDraft(name[0:len(name) - 3])?)
  }
  return out
}
```

## Naming what a store can do

Two stores now need to be interchangeable: whatever `ink`'s commands call
has to work whether drafts live in files or in Postgres. `Store` names the
three operations both need - no `implements` clause required, since Bit's
interfaces are structural (SPEC §14.3):

```bit
// What `ink` needs from wherever drafts live. `FileStore` and `SqlStore`
// both satisfy this with no `implements` clause: any type with these three
// methods works.
export interface Store {
  save(d: Draft): ()!,
  load(id: string): Draft!,
  list(): []Draft!,
}

// The store chapters 01-09 already built, behind the `Store` interface.
export class FileStore {
  save(d: Draft): ()! {
    return saveDraft(d)?
  }

  load(id: string): Draft! {
    return loadDraft(id)?
  }

  list(): []Draft! {
    return listDrafts()?
  }
}
```

`FileStore` adds nothing new - it is the three functions the earlier
chapters already wrote, wearing the shape `Store` names.

## Run PostgreSQL

A throwaway container is enough for development:

```
$ docker run --name ink-db -e POSTGRES_USER=ink -e POSTGRES_PASSWORD=ink \
    -e POSTGRES_DB=ink -p 5432:5432 -d postgres:18.6
$ docker exec ink-db pg_isready -U ink -d ink
/var/run/postgresql:5432 - accepting connections
```

## Add the driver

`std/sql` defines the `Pool`/`Executor` contract; the wire protocol itself
is `bitlang.org/pkg/postgres`:

```text
$ bit add bitlang.org/pkg/postgres@v0.1.0
bit add: postgres -> bitlang.org/pkg/postgres@0.1.0 (d13a8daf9505f438586c7ee82eb5e2220a294c40)
```

```
create table drafts (
  id text primary key,
  title text,
  body text,
  tags text,
  status text,
  created bigint,
  updated bigint
)
```

`tags` is stored joined by `|`, the same encoding
[chapter 8](/book/08-import-and-export)'s CSV export
uses - a draft looks the same on disk whichever store wrote it. `status` is
stored by name (`"Draft"`, `"Published"`, `"Archived"`), never as a number
that would mean something different if the enum were ever reordered.

## `SqlStore`

`std/sql`'s `find`/`findOne` auto-map a query into a class, but only when
every field is one of five scalar types (SPEC §15) - `Draft.tags` is
`[]string`, which is not one of them. `sqlFindMany`/`sqlFindOne` take a
hand-written mapper instead, for exactly this shape:

```bit
import { join, split } from "std/strings"
import { Executor, Rows, Value, sqlFindMany, sqlFindOne, sqlReqInt, sqlReqText } from "std/sql"
import { adapter } from "postgres"

export fn statusText(s: Status): string {
  match (s) {
    Draft => return "Draft"
    Published => return "Published"
    Archived => return "Archived"
  }
}

export fn statusFromText(s: string): Status! {
  switch (s) {
    case "Draft":
      return Status.Draft
    case "Published":
      return Status.Published
    case "Archived":
      return Status.Archived
    default:
      fail newError("ink: unknown status: ${s}")
  }
}

const draftsTable: string = "drafts"

// Reads one row of `drafts` into a `Draft`.
fn draftFromRow(rows: Rows): Draft! {
  let cols = rows.columns()
  let tags = sqlReqText(rows, cols, "tags")?
  return Draft{
    id = sqlReqText(rows, cols, "id")?,
    title = sqlReqText(rows, cols, "title")?,
    body = sqlReqText(rows, cols, "body")?,
    tags = tags == "" ? []string(0) : split(tags, "|"),
    status = statusFromText(sqlReqText(rows, cols, "status")?)?,
    created = sqlReqInt(rows, cols, "created")?,
    updated = sqlReqInt(rows, cols, "updated")?,
  }
}

// A SQL-backed `Store`, built on `std/sql` and a `bitlang.org/pkg/postgres`
// pool. `db` is an `Executor` rather than a `Pool` so a caller running
// inside its own transaction can hand this a `Tx` instead - `SqlStore`
// never opens or closes the connection itself.
export class SqlStore {
  db: Executor

  save(d: Draft): ()! {
    let tags = join(d.tags, "|")
    this.db.exec(
        "INSERT INTO ${draftsTable} (id, title, body, tags, status, created, updated) " +
        "VALUES ($1, $2, $3, $4, $5, $6, $7) " +
        "ON CONFLICT (id) DO UPDATE SET title = $2, body = $3, tags = $4, status = $5, updated = $7",
      [
        Value.Text(d.id), Value.Text(d.title), Value.Text(d.body), Value.Text(tags),
        Value.Text(statusText(d.status)), Value.Int(d.created), Value.Int(d.updated),
      ],
    )?
    return
  }

  load(id: string): Draft! {
    let found = sqlFindOne<Draft>(
      this.db,
      "SELECT id, title, body, tags, status, created, updated FROM ${draftsTable} WHERE id = $1",
      [Value.Text(id)],
      draftFromRow,
    )?
    match (found) {
      Some(d) => return d
      None => fail newError("ink: no such draft: ${id}")
    }
  }

  list(): []Draft! {
    return sqlFindMany<Draft>(
      this.db,
      "SELECT id, title, body, tags, status, created, updated FROM ${draftsTable} ORDER BY created",
      []Value(0),
      draftFromRow,
    )?
  }
}
```

`save` is one statement either way: `ON CONFLICT (id) DO UPDATE` inserts a
new draft or updates an existing one, so `SqlStore` never has to ask which
case it is in before writing.

## Swapping the store

```bit
import { Datasource, pool } from "std/sql"

fn openStore(databaseUrl: string): Store! {
  if (databaseUrl == "") {
    return FileStore{}
  }
  let db = pool(adapter(), Datasource{ uri = databaseUrl })?
  return SqlStore{ db = db }
}
```

Every `ink` command that used to call `saveDraft`/`loadDraft`/`listDrafts`
directly now takes a `Store` and calls `store.save`/`store.load`/
`store.list` instead - the same three lines run against a laptop's files or
a shared Postgres, decided once, at startup, by whether `DATABASE_URL` is
set.

## Sharp edges

`SqlStore.load` turns "no row" into an error naming the id, the same
contract `FileStore.load` already had from `loadDraft`'s missing-file case -
a caller matching on `Store.load`'s failure does not need to know which
store it is talking to. `sqlFindOne`'s own "more than one row" case cannot
happen here, since `id` is the table's primary key.

## What we built

Inkwell now has two stores behind one `Store` interface, and a real
database it can move drafts into without touching a single call site that
only knew about files.

Specification: [pkg/postgres](/packages/postgres), [std/sql](/std/sql).

Next: [Indexing in parallel](/book/11-indexing-in-parallel).
