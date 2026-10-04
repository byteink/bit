# What is a draft

[chapter 2](02-saving-drafts.md) used `Draft` and `Status` without really
looking at them. This chapter does.

## A class is a shape with a name

`ink list` printed `01912e9a...  draft  First note`: an id, a status, a
title, always in that order, always all three present. That is what a
[class](/language/classes) buys you - a fixed shape, so code that handles
one `Draft` can rely on every field being there. This is the real
[`docs/book/ink/draft.bit`](ink/draft.bit):

```text
export class Draft {
  export id: string
  export title: string
  export body: string
  export tags: []string
  export status: Status
  export created: i64
  export updated: i64
}
```

That is the whole shape, from the real
[`docs/book/ink/draft.bit`](ink/draft.bit) - the full file, with its
method, is below. `export` on a field means code outside this file can
read and write it -
`main.bit`'s `cmdList` reads `d.title` and `d.status`, in a different file
in the same project. Leave `export` off a field and only `draft.bit` itself
could touch it.

## A draft's status is one of a fixed set

A draft is never "sort of published." It is exactly one of three things,
and Bit has a type for exactly that: an [enum](/language/enums).

```bit
// Where a draft is in its life. A brand new one starts at `Status.Draft`
// (the status, not the type) and moves forward one step at a time.
export enum Status {
  Draft,
  Published,
  Archived,
}
```

`Status.Draft`, `Status.Published` and `Status.Archived` are the only
values a `Status` can ever hold - not a string that could also be
`"pulished"` by a typo, not an int that could also be `4`. `cmdNew`
(chapter 2) wrote `status = Status.Draft`, qualified with the enum's name;
inside `match`, below, the bare variant name is enough, because the value
being matched already tells Bit which enum it belongs to.

## Turning a status into text

`ink list` needs to print `draft`, not `Status.Draft`. `Draft.statusLabel()`
does that with `match`:

```bit
export class Draft {
  export id: string
  export title: string
  export body: string
  export tags: []string
  export status: Status
  export created: i64
  export updated: i64

  // A short word for `status`, for `ink list` and store.bit's file format
  // to print. The inverse of store.bit's `parseStatus`.
  export statusLabel(): string {
    return match (this.status) {
      Draft => "draft"
      Published => "published"
      Archived => "archived"
    }
  }
}
```

`statusLabel` is a **method**: a function that always acts on a `Draft`,
written inside the class body with the reserved receiver `this`. `match`
picks the arm whose variant equals `this.status` and runs it - here, each
arm is just an expression, so `match` itself is the return value.

`match` is exhaustive: every arm names a `Status` variant, and if you added
a fourth variant - `Deleted`, say - without adding an arm for it here, `bit
check` would stop you with a compile error rather than let `statusLabel`
silently return the wrong thing for it. That is the guarantee an `if`
chain on a plain string could never give you.

## What you built

`Draft` gives every note the same seven fields; `Status` limits a draft's
status to exactly three possibilities; `match` on `Status` is checked for
every case at compile time. `store.bit`'s `parseStatus` (chapter 2) is the
same idea in the other direction: a `switch` over a `string`, since Bit has
no way to turn a string into an enum value for you - which is
exactly why `Status` and not a bare `string` is what `Draft.status` holds.

Next: [chapter 4, when things go wrong](04-when-things-go-wrong.md): what
happens when `loadDraft` is asked for an id that does not exist.
