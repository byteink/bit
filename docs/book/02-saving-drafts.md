# Saving drafts

A notes tool that forgets everything when it exits is not a notes tool. You
want `ink new "title" "body"` to write a note to disk, and `ink list` to
show you what is there.

## What a draft needs

Every note Inkwell keeps is a `Draft`. This is the real, complete
[`docs/book/ink/draft.bit`](ink/draft.bit) - the next chapter explains it
in depth; for now, treat it as a small bundle of fields, the same as any
other [class](/language/classes):

```bit
// Where a draft is in its life.
export enum Status {
  Draft,
  Published,
  Archived,
}

// One note: what it says, what it is tagged with, and where it stands.
export class Draft {
  export id: string
  export title: string
  export body: string
  export tags: []string
  export status: Status
  export created: i64
  export updated: i64

  // A short word for `status`, for `ink list` to print.
  export statusLabel(): string {
    return match (this.status) {
      Draft => "draft"
      Published => "published"
      Archived => "archived"
    }
  }
}
```

`id`, `title` and `body` are `string` variables, the same type you would
use to hold a single line of text. `tags` is `[]string`, a slice: an
ordered, growable list. Every `Draft` has all seven fields, because a
`class` declares a fixed shape - [chapter 3](03-what-is-a-draft.md) is
where this stops being background and becomes the point.

## Writing a draft to disk

A draft has to live somewhere between two runs of `ink`. Inkwell keeps one
file per draft under `~/.ink/drafts/`, named `<id>.md`. This is the real
[`docs/book/ink/store.bit`](ink/store.bit):

```bit
import { exists, mkdir, readDir, readFile, writeFile } from "std/fs"
import { envOr } from "std/os"
import { splitN, split, parseInt, join } from "std/strings"
import { format, uuidV7 } from "std/uuid"
import path from "std/path"

// A fresh, time-ordered id for a new draft.
export fn newId(): string {
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

// Every draft on disk. Empty, never a failure, if ~/.ink/drafts does not
// exist yet.
export fn listDrafts(): []Draft! {
  if (!exists(draftsDir())) {
    return []Draft(0)
  }
  let out = []Draft(0)
  for name of readDir(draftsDir())? {
    let content = readFile(path.join(draftsDir(), name))?
    out = append(out, decode(content)?)
  }
  return out
}
```

`envOr("HOME", ".")` reads your home directory, falling back to `.` if it
is somehow unset. `path.join` builds a path the right way for your
operating system instead of gluing strings with `/` by hand. `writeFile`
and `readFile` (`std/fs`) do exactly what they say: write a whole string to
a file, or read one back. A draft file looks like this on disk:

```text
id: 01912e9a-58cc-4372-a567-0e02b2c3d479
title: First note
status: draft
tags:
created: 1735300000
updated: 1735300000
---
hello inkwell
```

`encode` builds that text from a `Draft`; `decode` is its exact inverse,
splitting the header from the body at the `---` line and reading each
`key: value` pair with `splitN`. You do not need to memorize file
formats to follow this: the point is that reading and writing a file is
one function call each, and a plain-text `string` gets you the rest of the
way with `+`, `split` and `splitN`.

## Wiring up the commands

`main.bit` reads what you typed and calls the right function. This is the
real [`docs/book/ink/main.bit`](ink/main.bit)'s `new` and `list` handling:

```bit
import { args } from "std/os"
import { now } from "std/time"

fn usage() {
  println("usage: ink <new|list|search> ...")
}

fn cmdNew(title: string, body: string): ()! {
  let n = now().ns / 1_000_000_000
  let d = Draft{
    id = newId(),
    title = title,
    body = body,
    tags = []string(0),
    status = Status.Draft,
    created = n,
    updated = n,
  }
  saveDraft(d)?
  println("saved ${d.id}: ${d.title}")
}

fn cmdList(): ()! {
  let drafts = listDrafts()?
  for d of drafts {
    println("${d.id}  ${d.statusLabel()}  ${d.title}")
  }
}

fn main(): ()! {
  let a = args()
  if (len(a) < 2) {
    usage()
    return
  }
  switch (a[1]) {
    case "new":
      if (len(a) < 3) {
        usage()
        return
      }
      let body = len(a) > 3 ? join(a[3:], " ") : ""
      cmdNew(a[2], body)?
    case "list":
      cmdList()?
    default:
      usage()
  }
}
```

`args()` (`std/os`) gives you every word on the command line, `args()[0]`
being `ink` itself. `now().ns / 1_000_000_000` turns the current time,
which `std/time` gives you in nanoseconds, into whole seconds - what
`created` and `updated` store. `a[3:]` is a slice: everything from index 3
onward, so `ink new "First note" hello inkwell` joins `hello` and `inkwell`
back into one body with a space between them.

## Try it

```text
$ bit run main.bit -- new "First note" hello inkwell
saved 01912e9a-58cc-4372-a567-0e02b2c3d479: First note
$ bit run main.bit -- list
01912e9a-58cc-4372-a567-0e02b2c3d479  draft  First note
```

## What you built

`ink new` writes a draft to `~/.ink/drafts/`; `ink list` reads every one
back. You used `string`, `[]string`, `map<string, string>`, functions with
return values, and three `std/fs` calls to get there.

Next: [chapter 3, what is a draft](03-what-is-a-draft.md), which comes back
to the `Draft` class and the `Status` enum you used here and explains what
they actually are.
