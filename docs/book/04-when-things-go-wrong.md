# When things go wrong

`ink list` (chapter 2) shows an id for every draft. What happens if you ask
for an id that was never saved, or whose file someone deleted by hand? The
file will not be there, and `readFile` has to tell you that instead of
handing back nothing and hoping you do not notice.

## A return type that can fail

Bit's answer is a return type that is either a value or an error: write
`T!` instead of `T`. This is the real
[`docs/book/ink/draft.bit`](ink/draft.bit) and
[`docs/book/ink/store.bit`](ink/store.bit):

```bit
export enum Status {
  Draft,
  Published,
  Archived,
}

export class Draft {
  export id: string
  export title: string
  export body: string
  export tags: []string
  export status: Status
  export created: i64
  export updated: i64

  export statusLabel(): string {
    return match (this.status) {
      Draft => "draft"
      Published => "published"
      Archived => "archived"
    }
  }
}
```

```bit
import { exists, mkdir, readDir, readFile, writeFile } from "std/fs"
import { envOr } from "std/os"
import { splitN, split, parseInt, join } from "std/strings"
import { format, uuidV7 } from "std/uuid"
import path from "std/path"

export fn randomId(): string {
  return format(uuidV7())
}

fn homeInkDir(): string {
  return path.join(envOr("HOME", "."), ".ink")
}

fn draftsDir(): string {
  return path.join(homeInkDir(), "drafts")
}

fn draftPath(id: string): string {
  return path.join(draftsDir(), "${id}.md")
}

fn ensureDraftsDir(): ()! {
  if (!exists(homeInkDir())) {
    mkdir(homeInkDir())?
  }
  if (!exists(draftsDir())) {
    mkdir(draftsDir())?
  }
}

fn parseStatus(label: string): Status! {
  switch (label) {
    case "draft":
      return Status.Draft
    case "published":
      return Status.Published
    case "archived":
      return Status.Archived
    default:
      fail newError("unknown draft status: ${label}")
  }
}

fn encode(d: Draft): string {
  let header = [
    "id: ${d.id}",
    "title: ${d.title}",
    "status: ${d.statusLabel()}",
    "tags: ${join(d.tags, ",")}",
    "created: ${d.created}",
    "updated: ${d.updated}",
  ]
  return join(header, "\n") + "\n---\n" + d.body
}

fn decode(content: string): Draft! {
  let parts = splitN(content, "\n---\n", 2)
  if (len(parts) != 2) {
    fail newError("draft file has no --- separator")
  }
  let fields = map<string, string>()
  for line of split(parts[0], "\n") {
    let kv = splitN(line, ": ", 2)
    if (len(kv) == 2) {
      fields[kv[0]] = kv[1]
    }
  }
  let (tags, _) = fields["tags"]
  let tagList = len(tags) == 0 ? []string(0) : split(tags, ",")
  let (statusName, _) = fields["status"]
  let (createdText, _) = fields["created"]
  let (updatedText, _) = fields["updated"]
  let (id, _) = fields["id"]
  let (title, _) = fields["title"]
  return Draft{
    id = id,
    title = title,
    body = parts[1],
    tags = tagList,
    status = parseStatus(statusName)?,
    created = parseInt(createdText)?,
    updated = parseInt(updatedText)?,
  }
}

// Write `d` to disk, creating ~/.ink/drafts first if it does not exist yet.
export fn saveDraft(d: Draft): ()! {
  ensureDraftsDir()?
  writeFile(draftPath(d.id), encode(d))?
}

// Read the draft with the given id back from disk.
export fn loadDraft(id: string): Draft! {
  let content = readFile(draftPath(id))?
  return decode(content)?
}
```

`Draft!` means "a `Draft`, or an error." You cannot get a `Draft` out of a
`Draft!` just by using it as one - you have to say what happens on
failure, either with `?` (`loadDraft`, `decode`) or `catch`, below. `()!`
is the fallible version of "nothing": `saveDraft` has no value to return on
success, only a possible failure.

## Propagating with `?`

`loadDraft` calls two fallible functions, `readFile` and `decode`, and has
nothing useful to do itself if either fails - it just needs to pass the
failure up. Postfix `?` does exactly that: on success it unwraps the
value, on failure it returns the error immediately from the enclosing
function, which must itself return a `T!`. `saveDraft` does the same thing
twice in a row: each `?` stops the function right there if that call
failed, so `writeFile` never runs against a directory that
`ensureDraftsDir` failed to create.

## Handling with `catch`

A function that actually knows what to do about a failure uses `catch`
instead:

```bit
fn main() {
  let d = loadDraft("does-not-exist") catch e {
    println("could not load that draft: ${e.message()}")
    return
  }
  println(d.title)
}
```

`catch e { ... }` binds the error to `e` if the call fails, so you can look
at it - `e.message()` reads the human-readable string every Bit error
carries. The other form, `expr catch default`, swaps in a fallback value
on failure instead and discards the error entirely - `listDrafts() catch
[]Draft(0)` would treat a failure to read `~/.ink/drafts` as "no drafts,"
which `cmdList` does not do, because that failure is worth seeing, not
hiding.

## The real use case

`main.bit`'s own `main` is fallible, `fn main(): ()!`, and never handles
anything itself - every command function it calls, it calls with `?`. That
is the normal shape for a command-line tool: let failures bubble all the
way to the top, where `bit run`/`bit test` prints the error and the
process exits non-zero, instead of writing a `catch` at every call site
that has nothing better to do than re-report the same failure.

## What you built

`readFile`, `writeFile`, `saveDraft` and `loadDraft` all return a `T!`
instead of pretending failure cannot happen. `?` sends a failure straight
up to the caller; `catch` is for the one function that actually knows what
to do about it.

Next: [chapter 5, searching drafts](05-searching-drafts.md), where Inkwell
learns to find a draft again instead of only listing every one.
