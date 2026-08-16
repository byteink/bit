# Smash epic rollup audit

## The bug this guards against

An epic flips `pending -> in_progress` automatically (tagged `[system]` in its
provenance) the moment a child starts. Nothing flips it back. Two wrong
end-states result, and smash's own source is not part of this checkout, so
neither is fixable from here — this document is the acceptance's escape
hatch: a recurring manual procedure, not a code change. See smash task #3145
for the original report and #2513 for the sibling bug this shares a root
cause with (`smash_complete` can report success on a branch that was never
merged — a ledger state asserting something the tree does not support).

1. **All children completed, epic still `in_progress`.** Completed work
   stays invisible inside the "what's being worked on" view forever.
2. **Some children completed, none active, epic still `in_progress`.** The
   epic reads as live when nobody is touching it.

The forward transition works (an epic with a genuinely active child is
correctly `in_progress` — do not "fix" that case). Only the return path is
missing, and only a human (or an agent instructed to do this) supplies it.

## When to run this

- Whenever `smash whois`'s **In Progress** count looks larger than the
  number of agents you know are actually running. That mismatch is the
  trigger — epics are consistently the majority of the excess.
- Before trusting the board to answer "what is actually being worked on
  right now" for planning purposes.
- As a periodic sweep (e.g. at the start of a planning session) independent
  of any specific trigger, since drift accumulates silently.

## Step 1 — find the candidate epics

```sh
smash whois
```

```
Project: bit
Tasks:
  Pending:     320
  In Progress: 8
  ...
```

Cross-check against reality — is a build actually running for each?

```sh
pgrep -fl make-driver
git worktree list
```

Then narrow the in-progress set to epics, since epics are the class with the
stuck-rollup bug (a stale non-epic ticket is a different problem, out of
scope here):

```sh
smash list | grep "\[in progress\]" | grep -E "\] epic"
```

Verified 2026-08-16, `smash whois` reported 8 in progress; this narrowed it
to exactly 2 candidate epics:

```
#1851 [in progress] epic/s2/L {codegen,perf,backend,gc} ... Bit backend optimiser: ...
#3147 [in progress] epic/s2 {gc,runtime,perf,memory} ... GC address->object index costs 24 bytes per slot ...
```

## Step 2 — read each candidate's rollup

`smash show <id>` prints the children and a `Rollup:` line summarizing their
statuses — this is the one command that answers "is this epic's status still
true":

```sh
smash show <epic-id>
```

Read the tail of the output for `Children (N):` and the `Rollup:` line.
Two real examples, both captured 2026-08-16 against `main`:

**#1851** (currently correctly `in_progress`):

```
Children (13):
  #1852 [completed] ...
  #1853 [completed] ...
  #3101 [pending] ...
  #3104 [completed] ...
  #3105 [completed] ...
  #3112 [completed] ...
  #3142 [completed] ...
  #3163 [completed] ...
  #3164 [completed] ...
  #3169 [completed] ...
  #3171 [pending] ...
  #3181 [completed] ...
  #3182 [in_progress] ...
Rollup: pending: 2, in_progress: 1, completed: 10
```

**#3147** (currently *stale* `in_progress` — a live instance of case 2 found
while writing this doc, left uncorrected; see "Worked example" below):

```
Children (5):
  #3175 [completed] ...
  #3176 [completed] ...
  #3177 [pending] ...
  #3178 [pending] ...
  #3179 [pending] ...
Rollup: pending: 3, completed: 2
```

## Step 3 — classify against the Rollup line

| Rollup shows | correct epic status | if the epic disagrees |
|---|---|---|
| `in_progress: >=1` | `in_progress` | this is the forward transition; it should already be correct. If not, something else is wrong — investigate before touching status. |
| `in_progress: 0`, at least one non-completed (`pending`/`blocked`) child | `pending` | roll back with `smash set-status <id> pending`, evidence comment first (Step 5). |
| `in_progress: 0`, every child `completed` | `completed` — **but only after Step 4** | do not complete the epic until every completed child's work is verified on `main`. |

`#1851` above: `in_progress: 1` matches its current `In Progress` status —
correct, leave it alone. `#3147` above: `in_progress: 0` with 3 pending
children — its status should be `pending`, not `In Progress`.

## Step 4 — for an "all completed" epic, verify the children actually landed

A child's `completed` status is a ledger claim, not proof the code reached
`main` (#2513). Before rolling the epic to `completed`, check every completed
child's commit is really an ancestor of `main`.

**Find the landing commit.** This repo's commit convention is `#<id>: <summary>`
for a direct commit and `Merge #<id>: <summary>` for a squash-merge — but an
**unanchored** grep false-positives on any *other* ticket's commit whose body
merely *mentions* the id in prose. Verified 2026-08-16: `#3175`'s commit body
discusses `#3178` and `#3176` by number (corrections filed against sibling
tickets), so `git log --grep="#3178"` wrongly returns `#3175`'s commit even
though nothing has landed for `#3178` at all. Anchor to the subject line:

```sh
git log --oneline --grep="^#<id>:" --grep="^Merge #<id>:" main
```

Verified both directions on 2026-08-16:

```sh
$ git log --oneline --grep="^#3178:" --grep="^Merge #3178:" main
# (empty — correct: #3178 is still pending, nothing has landed)

$ git log --oneline --grep="^#3176:" --grep="^Merge #3176:" main
fb825cca #3176: add the per-span occupied-slot bitmap, write-only
```

If nothing prints, the child produced no commit under that convention —
fall back to reading the child's own comments for a recorded sha (engineers
write "branch `task-N-slug`, commit `<sha>`" when they land work; grep for
it):

```sh
smash show <child-id> | grep -oE "(commit|sha) \`?[0-9a-f]{7,40}\`?"
```

**Then confirm ancestry — this is the authoritative check, not the grep
above, which only finds a candidate:**

```sh
git merge-base --is-ancestor <sha> main && echo "ON MAIN" || echo "NOT ON MAIN"
```

Verified 2026-08-16, both directions, so the check is proven to discriminate
rather than rubber-stamp:

```sh
# a genuinely landed commit
$ git merge-base --is-ancestor fb825cca8a4ca0948f658b460c623f9a165b83d4 main
$ echo $?
0

# a genuinely unmerged commit (an open worktree's branch HEAD)
$ git merge-base --is-ancestor 901d7f8d main
$ echo $?
1
```

Also verified against the historical case-1 examples this ticket names
(#2238, #2571 — both hand-corrected during the original 2026-08-16 audit,
already `completed`):

```sh
$ for sha in b45acd20 5348da20 807b18e8 bbcdc75b; do
    git merge-base --is-ancestor "$sha" main && echo "$sha: ON MAIN"
  done
b45acd20: ON MAIN
5348da20: ON MAIN
807b18e8: ON MAIN
bbcdc75b: ON MAIN
```

Do this for **every** completed child before rolling the epic up. One
unverified or unmerged child is enough to withhold the rollup.

## Step 5 — apply the correction, with evidence first

Record the evidence as a comment **before** changing status — the ticket
should explain to the next reader why the status moved, not just that it
did. Follow the pattern already used in this repo's own hand-corrections
(#1851, #2238, #2571):

```sh
smash comment <epic-id> "Ledger audit <date>: status said In Progress, but \
Rollup shows in_progress: 0. <N> children checked: <list with per-child \
git merge-base --is-ancestor result>. <decision + reasoning>."

smash set-status <epic-id> pending      # case: some children not yet done, none active
# or
smash set-status <epic-id> completed    # case: every child verified on main
```

`smash complete <epic-id>` also works for the completed case and is
preferable when the epic itself should carry a completion timestamp; omit
`--sha` since an epic has no commit of its own — only its children do.

## When ticket status and repo reality disagree

This is the case worth the most care, because it is exactly #2513's shape
recurring one level down:

- **A completed child's commit is not an ancestor of `main`.** Do not treat
  that child as done for rollup purposes — the epic must not complete. Leave
  the epic `pending` (or `in_progress` if something else is genuinely
  active), and comment on the **child** ticket flagging the discrepancy
  (cite #2513) rather than silently re-opening or completing anything. That
  child needs a human or engineer to actually land the work, or to correct
  its own status if it was force-completed in error.
- **A completed child has no discoverable commit at all** (neither the
  anchored `git log --grep` nor a sha in its comments). Some tickets are
  legitimately code-free (a decision-only or research-only child) and
  `smash complete` explicitly allows omitting `--sha` for exactly that case.
  Do not treat "no sha" alone as a red flag — read the child's own comments
  for its stated evidence and judge on content, the same way `smash_show`'s
  printed evidence is read for any other verification in this repo. If the
  child's own acceptance criteria were about code and no code exists, that
  is a disagreement; if they were never about code, it is not.
- **Never** correct an epic's rollup by editing its children's statuses to
  make the arithmetic match. The children's statuses are the input to this
  procedure, not something this procedure is allowed to adjust to produce a
  tidier result.

## Worked example, live, from this session

While writing and verifying this procedure on 2026-08-16, epic **#3147**
was found in the exact stale state this document guards against: `Status:
In Progress`, `Rollup: pending: 3, completed: 2` (zero in-progress), no
worktree or process for any of its three pending children
(`git worktree list`, `pgrep -fl "task-317"` both empty). Per the
classification table its correct status is `pending`. It was **left
uncorrected** deliberately — fixing it is outside this documentation
ticket's scope (source-file and status changes were both out of bounds for
#3145's dispatch); the point of leaving it in place is that it is a real,
reproducible instance a reader can run Step 1 through Step 3 against right
now and get the same answer this document claims.

## Filing upstream

Smash's own source is not part of this workspace checkout and its
repository location is not recorded anywhere in this project's config
(`smash.json` only names the local project id). This ticket could not file
an upstream report against smash's own tracker as a result — whoever owns
that repository should be handed this document (the reproduction in Step 1
through Step 3, and the two wrong end-states in "The bug this guards
against") as the report once its location is known.
