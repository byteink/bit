#!/usr/bin/env bash
# Ledger + worktree hygiene. Run as a Stop hook so a turn cannot end with the
# board lying about what is happening.
#
# Three things rot silently in this project, all of them observed:
#   - a ticket left `in_progress` with no agent on it
#   - a ticket parked in a review state nobody returns to
#   - a worktree/branch left open after its work merged
#
# Prints findings to stderr and exits 2 (which surfaces them to the agent) when
# something needs attention; exits 0 when clean. It REPORTS — it never edits the
# ledger, because a hook that silently "fixes" status is how the board starts
# lying in the other direction.
set -u

REPO="${CLAUDE_PROJECT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
cd "${REPO}" 2>/dev/null || exit 0
command -v smash >/dev/null 2>&1 || exit 0

findings=""

# --- review-state tickets: not used in this project ------------------------
bad_states=$(smash stats --json 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
rows = d.get('tasks') or d.get('perTask') or d.get('rows') or []
for t in rows:
    st=(t.get('status') or '')
    if st in ('pending_review','in_review','needs_work','failed'):
        print('  %-14s #%s' % (st, t.get('id')))
" 2>/dev/null)
if [ -n "${bad_states}" ]; then
  findings="${findings}
TICKETS IN A REVIEW/LIMBO STATE — this project uses only pending / in_progress / completed:
${bad_states}
  Resolve each: completed (with evidence) if it landed, pending (with a comment
  saying what is proven and what is next) if it did not."
fi

# --- in_progress: report, never block ---------------------------------------
# in_progress is the NORMAL state while agents are running, so blocking on it
# would jam every turn of a long parallel run. Print the list instead: the point
# is that each id gets eyeballed against the live agents, not that the count is
# zero. A ticket here with nobody on it is the board lying — set it back to
# pending with a comment, or complete it.
inprog=$(smash stats --json 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
rows = d.get('tasks') or d.get('perTask') or d.get('rows') or []
for t in rows:
    if (t.get('status') or '')=='in_progress':
        print('  #%s %s' % (t.get('id'), (t.get('summary') or '')[:60]))
" 2>/dev/null)
if [ -n "${inprog}" ]; then
  printf 'IN PROGRESS — confirm each still has a live agent:\n%s\n' "${inprog}" >&2
fi

# --- worktrees / branches ---------------------------------------------------
# A LOCKED worktree is held by a live agent — git takes that lock for the
# duration. Blocking on it would jam every turn of a parallel run, and acting on
# it (`worktree remove --force`) would destroy work in flight. So locked ones are
# reported, never blocked; only an UNLOCKED leftover is rot.
wt_live=$(git worktree list 2>/dev/null | tail -n +2 | grep ' locked$')
wt=$(git worktree list 2>/dev/null | tail -n +2 | grep -v ' locked$')
if [ -n "${wt_live}" ]; then
  printf 'WORKTREES HELD BY A LIVE AGENT — confirm each agent is still running:\n%s\n' \
    "$(printf '%s' "${wt_live}" | sed 's/^/  /')" >&2
fi
if [ -n "${wt}" ]; then
  findings="${findings}
OPEN WORKTREES (not locked — no agent holds these):
$(printf '%s' "${wt}" | sed 's/^/  /')
  Close each the moment its work is merged:
    git worktree remove --force <path> && git branch -D <branch>"
fi

# A branch checked out in a live worktree is not stray either — exclude it here
# or every locked worktree reports twice, once as itself and once as its branch.
# smash/task-* branches are created, moved and deleted by the live smash daemon;
# they are not stray dev branches and cannot be reconciled by hand without racing
# it (the ref set mutates mid-check), so exclude them — the worktree section above
# already reports any smash worktree that actually needs attention.
br=$(git branch --format='%(refname:short)' 2>/dev/null | grep -v '^main$' | grep -v '^smash/task-')
if [ -n "${br}" ] && [ -n "${wt_live}" ]; then
  live_br=$(printf '%s' "${wt_live}" | sed -n 's/.*\[\(.*\)\].*/\1/p')
  for b in ${live_br}; do
    br=$(printf '%s\n' ${br} | grep -vx "${b}")
  done
fi
if [ -n "${br}" ]; then
  merged=""
  unmerged=""
  for b in ${br}; do
    if git merge-base --is-ancestor "${b}" main 2>/dev/null; then
      merged="${merged} ${b}"
    else
      unmerged="${unmerged} ${b}"
    fi
  done
  [ -n "${merged}" ] && findings="${findings}
BRANCHES ALREADY IN main (delete them):${merged}
    git branch -D${merged}"
  [ -n "${unmerged}" ] && findings="${findings}
BRANCHES NOT IN main (cherry-pick or delete — do not just leave them):${unmerged}"
fi

if [ -n "${findings}" ]; then
  printf 'HYGIENE — resolve before ending the turn:%s\n' "${findings}" >&2
  exit 2
fi
exit 0
