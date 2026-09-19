# Apply migrations

[Generate](generate.md) writes a reviewed `.bit` file describing a schema
change. Nothing about writing that file runs it. You still need something that
applies each migration exactly once, in order, safely when two instances
of your app deploy at the same moment and both try to run it, and records
what actually happened so the next deploy knows where it left off. That is
what `up`, `status`, `sql` and `down` do.

## Known gap, stated up front

[Generate](generate.md) does not yet write or update a checked-in registry
file, and the `up()` its output declares takes no arguments and returns
nothing, while a `Migration`'s own `apply` is `() => []SchemaOp`. The two
pieces don't wire together yet - that's follow-up work, not something this
page can paper over. Everything below hand-writes the registry, which is
exactly what you have to do today.

## The registry: an explicit list, never a directory scan

Bit has no reflection, so nothing in this package can open `migrations/`
and discover what's in it - the same reason [Generate](generate.md)'s
`generate` takes its entities as an explicit list rather than scanning for
`@table` classes. A checked-in file (conventionally `migrations/all.bit`)
builds the list once and hands it to every function on this page:

```bit
import {
  AppliedMigration,
  Data,
  HistoryEntry,
  Migration,
  MigrationStatus,
  Postgres,
  RevertedMigration,
  RunnerDialect,
  ServerDialect,
  UpReport,
  alter,
  deleteHistory,
  down,
  ensureHistoryTable,
  hasVersion,
  latestEntry,
  loadHistory,
  recordApplied,
  sql,
  status,
  up,
} from "orm"
import { Timestamp, now } from "std/time"

fn migrations(): []Migration {
  return [
    Migration{
      version = 7,
      name = "add_widget_phone",
      // A stable identifier for this migration's content - nothing computes
      // one for you yet, so today it's a hand-picked string, kept unique.
      checksum = "a1b2c3",
      apply = () => [
        alter("widgets", (t) => {
          t.addString("phone", 255)
        }),
      ],
      revert = () => [
        alter("widgets", (t) => {
          t.dropColumn("phone")
        }),
      ],
    },
  ]
}

fn postgresDialect(): RunnerDialect {
  return RunnerDialect{ render = Postgres{}, server = ServerDialect.Postgres }
}
```

This entry mirrors [Generate](generate.md)'s `0007_add_widget_phone.bit`
by hand: `apply` is what that file's `up()` would build if its signature
matched `Migration`'s, and `revert` is its own reverse, which you write
yourself - nothing derives one from the other.

`postgresDialect()` builds the second argument every `up`/`down` call below
needs: a `RunnerDialect`, two facts about the target server bundled into one
parameter - `render`, the [Dialect](dialect.md) that turns a migration's
`SchemaOp`s into real DDL (`Postgres{}` here), and `server: ServerDialect`,
which server `up`/`down` take their advisory lock against. The two are
never derived from each other: "how do I render this migration's
SQL" and "which server locks the run" are different questions, and a real
MySQL deployment answers both the same way, but nothing here assumes it -
see "The sharp edge" below for what `server` actually controls.

## The simplest thing that works: apply everything pending

```bit
fn deploy(db: Data): UpReport! {
  return up(db, postgresDialect(), migrations(), now())?
}
```

`up` acquires an advisory lock, checks every already-applied migration's
checksum against what was recorded when it ran, then applies whatever is
still pending in ascending version order. It returns an `UpReport` -
`applied: []AppliedMigration`, one entry per migration that actually ran,
each carrying `version`, `name`, `checksum`, `appliedAt` and `durationMs`.
On a database with no `widgets.phone` column yet, `deploy(db)` returns a
report with one `AppliedMigration{ version = 7, name = "add_widget_phone",
... }`. Run it again and the report's `applied` list is empty - version 7
is already in the ledger.

## Checking what's pending before you deploy

```bit
fn report(db: Data): []MigrationStatus! {
  return status(db, migrations())?
}
```

`status` returns one `MigrationStatus` per registry entry -
`version`, `name`, `applied` - without changing anything, so a deploy
script or a health check can ask "is the database caught up" without
risking the lock `up` takes.

## Previewing the DDL without touching a database

```bit
fn preview(): string! {
  return sql(Postgres{}, migrations(), 7)?
}
```

`sql` takes no `db` parameter at all - not "won't use it", structurally
cannot. It renders one migration's `apply()` through the `Dialect` you
give it ([Dialect](dialect.md) covers `Postgres.render` in full) and
returns the DDL as text, so a reviewer can read exactly what version 7
will run before anyone runs it.

## Local iteration: rolling back the last migration

```bit
fn undo(db: Data): RevertedMigration! {
  let oneHour = 3600000000000
  return down(db, postgresDialect(), migrations(), now(), oneHour)?
}
```

`down` reverts only the single most-recently-applied migration, and only
when it was applied within the window you pass (`oneHour` above, in
nanoseconds) - a `down` call against a migration applied longer ago than
that refuses, naming how old it actually is:

```text
pkg/orm: migrate: down: 0007_add_widget_phone.bit was applied 7200000ms ago, older than the configured window of 3600000ms; a production rollback is a new migration, not down
```

That refusal is the point, not a rough edge: once a migration has been
live long enough for real writes to depend on the schema it changed,
`down` cannot know what those writes would need reverted along with it. A
production rollback is a new, forward migration you write with
[Generate](generate.md) or by hand - never this.

## Reading the ledger directly

`up` and `down` call `ensureHistoryTable`, `loadHistory`, `recordApplied`
and `deleteHistory` for you - you only reach for them directly when
writing your own tooling around the ledger, for example seeding a local
database's history to match a snapshot restored from staging:

```bit
fn seedLocalHistory(db: Data, m: Migration, at: Timestamp): ()! {
  ensureHistoryTable(db)?
  recordApplied(
    db,
    HistoryEntry{
      version = m.version, name = m.name, checksum = m.checksum, appliedAt = at.ns, durationMs = 0,
    },
  )?
}

fn dropLocalHistory(db: Data, version: int): ()! {
  deleteHistory(db, version)?
}

fn lastApplied(db: Data): (HistoryEntry, bool)! {
  let history = loadHistory(db)?
  return latestEntry(history)
}

fn isApplied(db: Data, version: int): bool! {
  let history = loadHistory(db)?
  return hasVersion(history, version)
}
```

`recordApplied` and `deleteHistory` write outside any transaction here -
fine for seeding a local database by hand, but `up`/`down` only ever call
them from inside their own migration's `BEGIN`/`COMMIT` block, which the
next section explains.

## The sharp edge: one transaction per migration, and what's outside it

Each migration's transactional statements, then its own `schema_history`
row, run inside one `BEGIN`/`COMMIT` - the ledger row commits with the DDL
it describes, or neither commits at all. A statement your dialect flags
non-transactional (Postgres refuses `CREATE INDEX CONCURRENTLY` inside a
transaction) runs individually, after that commit, with no wrapping
transaction of its own. If one of those fails, the migration's ledger row
is already committed - the schema change it describes is recorded as
applied - but that trailing statement did not run, and nothing here can
roll it back. That failure is reported as what it is; treat it as a
partially-applied migration to finish by hand, not a rejected one.

The advisory lock (`pg_advisory_lock`, released at the end of the run
whether it succeeds or fails) is taken when `server: ServerDialect.Postgres`.
Pass `ServerDialect.Mysql(version)` instead and `up`/`down` refuse
immediately, before issuing any statement - there is no MySQL
advisory lock implemented yet, and running a MySQL migration unlocked would
mean two instances deploying at the same moment could interleave their DDL
with nothing stopping them, exactly what this lock exists to prevent. That
is a behavior change from an earlier version of this package, which ran
every MySQL migration through the Postgres-only `pg_advisory_lock` SQL
text unconditionally: against a fake driver in a test that "worked" (the
fake didn't check the SQL), but against a real MySQL server it would have
failed anyway, with an opaque driver error instead of this typed,
catchable one. **MySQL migrations cannot run through `up`/`down` today** -
see the next section for the statement sequencing they will use once a
MySQL lock exists.

### On MySQL, the ledger row moves to the end

The sequencing below is real, tested code (`applyMigration` in
`pkg/orm/runner.bit`) - it is what `up` will do for a MySQL migration once
a MySQL advisory lock exists to get past the refusal above. It documents
the shape now so the lock implementation has nothing left to design when
it lands, not a path you can reach by calling `up`/`down` today.

MySQL DDL auto-commits, so `Mysql` honestly flags every statement it
renders non-transactional - and that leaves no `BEGIN`/`COMMIT` block for
the `schema_history` write to share with the DDL. The runner does not put
it in an empty transaction: when a migration renders no transactional
statements at all, `up` runs every statement first and writes the ledger
row only once they have all succeeded. A statement failing anywhere in the
migration leaves no `schema_history` row for it - the next `up` sees it as
still pending, same as a Postgres migration that never started.

The trade-off is the one every forward-only runner accepts: a crash
between the last statement and the ledger write leaves the migration's DDL
applied but unrecorded, so the next `up` re-runs it. On MySQL that re-run
can hit a statement that already succeeded (MySQL's own implicit
per-statement commit means a partially-applied migration cannot be rolled
back either way) - write migrations whose statements are safe to repeat
(`create table if not exists`, `add column if not exists` where your MySQL
version supports it) if that matters to you.

This section describes sequencing, not something you can trigger from
`up`/`down` today - see "The sharp edge" above for the explicit refusal
that stops a MySQL run before it gets here.

## When not to use `down`

Never for a production rollback. See "Local iteration" above - `down`
only reaches back one migration, and only within a caller-supplied age
window, on purpose. A schema change that real writes now depend on is
undone with a new migration, not by reverting the old one.

## Where to go next

[Generate](generate.md) covers writing the migration file this page
applies. [Check the schema in CI](check.md) covers failing the build
before a deploy ever reaches this page, when an entity and the live schema
disagree. [Schema](schema.md) and [Dialect](dialect.md) cover the
`alter()`/`SchemaOp` vocabulary and the DDL it renders to.
