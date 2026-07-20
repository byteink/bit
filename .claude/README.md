# .claude/

Project-local Claude Code configuration.

- `agents/` — subagent definitions (#1518). Six roles, derived from this repo's
  actual incident history rather than from what sounds sensible.
- `worktrees/` — **put agent worktrees here**, not as `../bit-<name>` siblings of
  the repo. A fan-out creates one per agent; siblings clutter the parent projects
  directory and are easy to leave behind.

      git worktree add -q -b <topic>-work .claude/worktrees/<topic> HEAD
