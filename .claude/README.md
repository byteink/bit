# .claude/

Project-local Claude Code configuration.

- `worktrees/` — **put agent worktrees here**, not as `../bit-<name>` siblings of
  the repo. A fan-out creates one per agent; siblings clutter the parent projects
  directory and are easy to leave behind.

      git worktree add -q -b <topic>-work .claude/worktrees/<topic> HEAD

Subagent definitions (`bit-engineer`, `bit-gates`, `bit-pm`, `bit-scout`,
`bit-skeptic`, `bit-triage`) used to live here as `agents/` (#1518). They now sit
one level up, in the `bitlang-ws` workspace that contains this repo, so they are
shared with the sibling projects rather than owned by this one.
