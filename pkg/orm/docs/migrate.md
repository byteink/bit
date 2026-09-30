# Apply migrations

You add a column, rename one, or add a whole new table. Someone has to run
that change against every database your app talks to - production, a
teammate's local setup, CI - exactly once, in the right order, safely when
two instances of your app deploy at the same moment and both try to apply
it, and with a record of what already happened so the next deploy knows
where it left off. `bit migrate` is that someone.

## Write a migration

`bit make migration` creates the file - you never create one by hand:

```text
$ bit make migration add_phone_to_widgets
created migrations/2026_09_30_101500_add_phone_to_widgets.bit
```

The name is stamped with the current time in UTC, so a fresh checkout's
files already sort into the order they were written: `migrations/<year>_
<month>_<day>_<hour><minute><second>_<name>.bit`. Two teammates adding a
migration on the same day never collide - the seconds make every file name
unique. The file it writes has empty `up`/`down` bodies:

```bit ignore
import { Schema } from "orm"

export class AddPhoneToWidgets {
  up(s: Schema): ()! {}
  down(s: Schema): ()! {}
}
```

You fill them in. `up` describes the change forward, `down` describes its
exact reverse - each one takes a `Schema`, the same intent-tree builder
[Schema](schema.md) covers, and neither ever touches a database itself:

```bit
import { Schema } from "orm"

export class AddPhoneToWidgets {
  up(s: Schema): ()! {
    s.table("widgets", (t) => {
      t.string("phone", 255).nullable()
    })?
  }

  down(s: Schema): ()! {
    s.table("widgets", (t) => {
      t.dropColumn("phone")
    })?
  }
}
```

`AddPhoneToWidgets` needs no `implements Migration` or `: Migration`
clause. Interfaces are structural: a class satisfies `Migration` simply by
declaring both methods, the same way `Postgres`/`Mysql` already satisfy
`Dialect` with no annotation naming it.

## Run it: `bit migrate`

```text
$ bit migrate --url postgres://localhost/widgetshop
applied 2026_09_30_101500_add_phone_to_widgets
```

`bit migrate` finds every `.bit` file under `migrations/`, checks its name
matches `YYYY_MM_DD_HHMMSS_<snake_name>.bit` and declares exactly one
`export class`, and applies whichever ones are not yet recorded in the
ledger, in ascending file-name order - lexical order and chronological
order are the same thing, by construction. You never write a registry
naming each class by hand: that list is built for you, from the directory,
each time `bit migrate` runs. Run it again with nothing new pending and it
prints nothing - there is nothing to apply. A project with no
`migrations/` directory yet, or an empty one, prints `no migrations
pending` and never opens a database connection at all.

A migration file with the wrong name, more than one `export class`, or two
files declaring the same class name stops `bit migrate` before it touches
the database, naming the file (or both files) that is wrong.

`--url` takes the connection string directly; leave it off and `bit
migrate` reads `DATABASE_URL` instead:

```text
$ DATABASE_URL=postgres://localhost/widgetshop bit migrate
applied 2026_09_30_101500_add_phone_to_widgets
```

Neither set is a refusal naming both:

```text
$ bit migrate
pkg/orm: migrate: no database URL: pass --url or set DATABASE_URL
```

The database URL itself never appears in any line `bit migrate` prints,
success or failure - it can carry a password, and an unrecognized argument
is never echoed back either, in case that argument was a stray URL typed
in place of `--url`.

## Check what has run: `bit migrate status`

```text
$ bit migrate status --url postgres://localhost/widgetshop
applied  2026_09_30_101500_add_phone_to_widgets  batch 3
pending  2026_09_30_140200_add_widgets_sku_index
```

One line per migration file, in the same file-name order `bit migrate`
applies them in: `applied` names the batch it landed in, `pending` means
the next `bit migrate` run will pick it up.

## Undo the last deploy: `bit migrate rollback`

```text
$ bit migrate rollback --url postgres://localhost/widgetshop
rolled back 2026_09_30_101500_add_phone_to_widgets
```

`bit migrate rollback` undoes every migration in the most recently applied
batch - newest file first, running each one's `down` - and nothing older.
One `bit migrate` run and the `bit migrate rollback` right after it are
exact opposites, whether that batch held one file or ten. A schema change
real writes now depend on is undone with a new, forward migration; you
never roll back a batch that shipped deploys ago. Calling it with nothing
ever applied is a no-op, not an error.

## Every migration file writes its own imports

`migrations/` is an ordinary Bit directory module, so every file in it
shares one namespace - but a migration file only ever needs `Schema` (and
whatever else its own `up`/`down` uses), and every migration in a project
tends to need exactly the same handful of names. Rather than factor those
into a shared file every migration then has to import from, each file
just writes its own `import { Schema } from "orm"` line:

```bit ignore
// migrations/2026_09_30_101500_add_phone_to_widgets.bit
import { Schema } from "orm"
```

```bit ignore
// migrations/2026_09_30_140200_add_widgets_sku_index.bit
import { Schema } from "orm"
```

An import identical to one a sibling file already wrote - the same source
module, the same imported name - binds the same symbol rather than
conflicting, so repeating it costs nothing. A file that also needs
`ReferentialAction` or `manyToManyTable` imports those too, on top of the
same `Schema` line every other file in the directory carries. Only an
import that genuinely disagrees with a sibling's - the same local name
bound to a different source - is rejected, naming both files.

## The sharp edge: one transaction per migration, and what's outside it

Each migration's transactional statements, then its own `migrations`
ledger row, run inside one `BEGIN`/`COMMIT` - the ledger row commits with
the DDL it describes, or neither commits at all. A statement your dialect
flags non-transactional (Postgres refuses `CREATE INDEX CONCURRENTLY`
inside a transaction) runs individually, after that commit, with no
wrapping transaction of its own. If one of those fails, the migration's
ledger row is already committed - the schema change it describes is
recorded as applied - but that trailing statement did not run, and nothing
here can roll it back. That failure is reported as what it is; treat it as
a partially-applied migration to finish by hand, not a rejected one.

The advisory lock taken around the whole run (released whether it succeeds
or fails) means two instances of your app running `bit migrate` at the
same moment never interleave their DDL - the second one waits for the
first to finish. There is no equivalent lock on MySQL yet, so `bit
migrate`/`bit migrate rollback` against a MySQL `DATABASE_URL` refuse
immediately, before issuing any statement, rather than let two concurrent
deploys race unlocked.

### On MySQL, the ledger row moves to the end

MySQL DDL auto-commits, so every statement a MySQL migration renders comes
back non-transactional - leaving no `BEGIN`/`COMMIT` block for the ledger
row to share with the DDL. `bit migrate` does not put it in an empty
transaction: when a migration has no transactional statement at all, every
statement runs first and the ledger row is written only once they have all
succeeded. A statement failing anywhere in the migration leaves no ledger
row for it - the next `bit migrate` run sees it as still pending, the same
as a Postgres migration that never started.

## When you don't want a migration file at all

`bit migrate` is a reviewed, checked-in history - the right choice once a
schema is something other people depend on. Early on, or in a throwaway
environment, writing a migration file for every column you're still
shaping is friction with no payoff. [Sync your database
automatically](sync.md) covers `open(url, Options{ synchronize = true })`,
the other mode: it adds whatever table or column your `@table` classes
declare and the live database is missing, in any environment, with no
file to write - it only ever adds, never drops or renames, so it is safe
to run against a database that already has migrations applied through
`bit migrate` too.

## Where to go next

[Check the schema in CI](check.md) covers failing the build before a
deploy ever reaches this page, when an entity and the live schema
disagree. [Schema](schema.md) and [Dialect](dialect.md) cover the
`create`/`table`/`drop` vocabulary a migration's `up`/`down` write with,
and the DDL it renders to.
