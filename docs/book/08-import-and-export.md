# Import and export

A note taken somewhere else - a phone app, a colleague's export, a backup
from last year - is not going to type itself into Inkwell by hand. This
chapter gives Inkwell two doors in and out: JSON, for moving drafts between
programs, and CSV, for opening them in a spreadsheet.

Both doors work on the same `Draft` [chapter 3](/book/03-what-is-a-draft) built:

```bit
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
```

## JSON, the shape `@json` already knows

`std/json`'s `@json` mark writes a class to JSON and reads it back, field by
field, and it already knows what to do with a payload-free `enum` field:
it writes the variant's own name as a JSON string, and rejects anything
else on the way back in. `Draft` itself does not carry `@json` -
[chapter 3](/book/03-what-is-a-draft) did not know import/export was
coming - so this chapter gives it a wire twin instead of changing it:

```bit
import { Json, jsonAsArray, jsonDecode, jsonEncode, jsonParse } from "std/json"

// The wire shape of a `Draft`: `@json` writes an enum field as its variant's
// own name, so `status` needs no manual conversion here.
@json class DraftJson {
  id: string,
  title: string,
  body: string,
  tags: []string,
  status: Status,
  created: i64,
  updated: i64,
}

fn toDraftJson(d: Draft): DraftJson {
  return DraftJson{
    id = d.id, title = d.title, body = d.body, tags = d.tags,
    status = d.status, created = d.created, updated = d.updated,
  }
}

fn fromDraftJson(j: DraftJson): Draft {
  return Draft{
    id = j.id, title = j.title, body = j.body, tags = j.tags,
    status = j.status, created = j.created, updated = j.updated,
  }
}
```

A class carrying `@json` gains a `toJson(): Json` method the compiler writes
for it, so exporting a whole list is a fold over that:

```bit
export fn exportJson(drafts: []Draft): string {
  let items = []Json(0)
  for d of drafts {
    items = append(items, toDraftJson(d).toJson())
  }
  return jsonEncode(Json.JsonArray(items))
}

fn requireArray(j: Json): []Json! {
  match (jsonAsArray(j)) {
    Some(items) => return items
    None => fail newError("ink: import: expected a JSON array of drafts")
  }
}

export fn importJson(text: string): []Draft! {
  let items = requireArray(jsonParse(text)?)?
  let out = []Draft(0)
  for item of items {
    out = append(out, fromDraftJson(jsonDecode<DraftJson>(item)?))
  }
  return out
}
```

`jsonDecode<T>` only works on a single `@json` class (`T` must carry the
mark) - there is no version that decodes straight into `[]T`, so
`importJson` unwraps the outer array itself and decodes one `DraftJson` per
element.

## CSV, and the one field JSON did not have to think about

CSV has no arrays, so `tags` needs an encoding: joined with `|`, the
character a draft's own tags are never going to contain.

```bit
import { csvFormat, csvParse } from "std/csv"
import { join, parseInt, split } from "std/strings"

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

export fn exportCsv(drafts: []Draft): string {
  let rows = [][]string(0)
  rows = append(rows, ["id", "title", "body", "tags", "status", "created", "updated"])
  for d of drafts {
    rows = append(
      rows,
      [
        d.id, d.title, d.body, join(d.tags, "|"), statusText(d.status), "${d.created}",
        "${d.updated}",
      ],
    )
  }
  return csvFormat(rows)
}

export fn importCsv(text: string): []Draft! {
  let rows = csvParse(text)?
  let out = []Draft(0)
  let i = 1
  while (i < len(rows)) {
    let row = rows[i]
    out = append(
      out,
      Draft{
        id = row[0],
        title = row[1],
        body = row[2],
        tags = row[3] == "" ? []string(0) : split(row[3], "|"),
        status = statusFromText(row[4])?,
        created = parseInt(row[5])?,
        updated = parseInt(row[6])?,
      },
    )
    i = i + 1
  }
  return out
}
```

`i` starts at `1` because row `0` is the header `exportCsv` wrote - `csvParse`
has no notion of a header row, so skipping it is `importCsv`'s job, not the
parser's.

## Wiring it into main.bit

`ink export <path>` and `ink import <path>` are two more cases in
`main.bit`'s dispatch, next to `new`/`list`/`search`:

```text
fn cmdExport(path: string): ()! {
  let drafts = listDrafts()?
  writeFile(path, exportJson(drafts))?
  println("exported ${len(drafts)} draft(s) to ${path}")
}

fn cmdImport(path: string): ()! {
  let drafts = importJson(readFile(path)?)?
  for d of drafts {
    saveDraft(d)?
  }
  println("imported ${len(drafts)} draft(s) from ${path}")
}
```

`cmdExport` runs `exportJson` over `listDrafts()` and writes the result with
`std/fs`'s `writeFile`; `cmdImport` reads the file and calls `saveDraft` for
each row `importJson` hands back - the same `listDrafts`/`saveDraft` chapter
2 wrote. [Chapter 10](/book/10-a-real-database) replaces both calls with a
`Store`, once drafts can also live in a database.

## Sharp edges

`importJson` rejects an unknown key in the input (`@json`'s decoder never
silently drops a field) and a `status` that is not one of the
three names `Draft`/`Published`/`Archived` - both fail loudly, by field
path, rather than importing a half-understood draft. `importCsv` fails the
same way on a `status` column it does not recognise, through
`statusFromText`.

## What you built

Inkwell can now move a whole set of drafts out to JSON or CSV and back,
without ever losing a tag or a status - `status` round-trips through both
formats as a name, never a number that would mean something different if
the enum were ever reordered.

Next: [Words and dates](/book/09-words-and-dates).
