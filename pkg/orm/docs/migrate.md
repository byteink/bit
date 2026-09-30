# Apply migrations

You hand-write a `.bit` file describing a schema change. Writing that file
does not run it. You still need something that applies each migration
exactly once, in order, safely when two instances of your app deploy at
the same moment and both try to run it, and records what actually
happened so the next deploy knows where it left off. That is what
`migrate` and `rollback` do.

This page covers the library API that applies migrations.

## One class per migration file

Each migration is a class with `up`/`down` methods taking a `Schema` -
`up` describes the change, `down` describes its exact reverse. Neither
method ever touches a database: `Schema.create`/`Schema.table`/`Schema.drop`
just collect the intent, the same tree [Schema](schema.md) already builds.

```bit
import { Data, MigrationFile, Postgres, RunnerDialect, Schema, ServerDialect, migrate, rollback } from "orm"
import { now } from "std/time"

class AddWidgetPhone {
  up(s: Schema): ()! {
    s.table("widgets", (t) => {
      t.string("phone", 255)
    })?
  }

  down(s: Schema): ()! {
    s.table("widgets", (t) => {
      t.dropColumn("phone")
    })?
  }
}
```

## The registry: an explicit list, never a directory scan

Bit has no reflection, so nothing in this package can open `migrations/`
and discover what's in it. A checked-in file (`bit make migration`
generates one file per migration; wiring them into a registry is O3b/O4's
own CLI, not written by hand today) pairs each class with its FILE NAME -
the string `migrate`/`rollback` record in the ledger, and the order they
apply in:

```bit
fn registry(): []MigrationFile {
  return [
    MigrationFile{ name = "2026_09_30_000000_add_widget_phone", m = AddWidgetPhone{} },
  ]
}

fn postgresDialect(): RunnerDialect {
  return RunnerDialect{ render = Postgres{}, server = ServerDialect.Postgres }
}
```

`postgresDialect()` builds the second argument `migrate`/`rollback` both
need: a `RunnerDialect`, two facts about the target server bundled into one
parameter - `render`, the [Dialect](dialect.md) that turns a migration's
`SchemaOp`s into real DDL (`Postgres{}` here), and `server: ServerDialect`,
which server the advisory lock is taken against. The two are never derived
from each other: "how do I render this migration's SQL" and "which server
locks the run" are different questions - see "The sharp edge" below for
what `server` actually controls.

## Applying everything pending, as one new batch

```bit
fn deploy(db: Data): ()! {
  let report = migrate(db, postgresDialect(), registry(), now())?
  print("applied ${len(report.applied)} migration(s)\n")
}
```

`migrate` acquires an advisory lock, then applies every migration not yet
recorded in the ledger, in ascending FILE NAME order, all as ONE new
batch - `max(recorded batch) + 1`. It returns a `MigrateReport` -
`applied: []AppliedMigration`, one entry per migration that actually ran,
each carrying `name`, `batch`, `appliedAt` and `durationMs`. Run `deploy`
again with nothing new pending and `report.applied` is empty.

## Rolling back the last batch

```bit
fn undo(db: Data): ()! {
  let report = rollback(db, postgresDialect(), registry())?
  print("reverted ${len(report.reverted)} migration(s)\n")
}
```

`rollback` undoes every migration in the HIGHEST recorded batch, newest
file first, running each one's `down`. It never touches an earlier batch -
one `migrate` call and the `rollback` call right after it are exact
opposites, whether that batch held one migration or ten. Calling `rollback`
with nothing ever applied is a no-op, not an error.

## The sharp edge: one transaction per migration, and what's outside it

Each migration's transactional statements, then its own `migrations` ledger
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
Pass `ServerDialect.Mysql(version)` instead and `migrate`/`rollback` refuse
immediately, before issuing any statement - there is no MySQL advisory lock
implemented yet (O3c), and running a MySQL migration unlocked would mean two
instances deploying at the same moment could interleave their DDL with
nothing stopping them, exactly what this lock exists to prevent.

### On MySQL, the ledger row moves to the end

MySQL DDL auto-commits, so `Mysql` honestly flags every statement it
renders non-transactional - and that leaves no `BEGIN`/`COMMIT` block for
the `migrations` row to share with the DDL. The runner does not put it in
an empty transaction: when a migration renders no transactional statements
at all, `migrate` runs every statement first and writes the ledger row only
once they have all succeeded. A statement failing anywhere in the migration
leaves no `migrations` row for it - the next `migrate` sees it as still
pending, same as a Postgres migration that never started.

## Where to go next

[Check the schema in CI](check.md) covers failing the build before a
deploy ever reaches this page, when an entity and the live schema
disagree. [Schema](schema.md) and [Dialect](dialect.md) cover the
`create`/`table`/`drop`/`SchemaOp` vocabulary a migration's `up`/`down`
write with, and the DDL it renders to.
