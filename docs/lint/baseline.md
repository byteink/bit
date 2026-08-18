# Lint baseline: compiler/ and stdlib/

Epic #2354. A one-time snapshot of what `bit lint` currently reports over the
project's own source, taken so #2453 (the count-ratchet gate, blocked on this
ticket) has a starting number to compare against. It is not itself read by any
gate — see "What this is for" below.

## Measured at

- Commit: `6813e4844be17b0969764ee1c294ed809f066b3e` (`main`)
- Date: 2026-08-18
- Binary: `./bit-out/bin/bit` (dev build, freshly rebuilt with `./make selfhost`
  in a worktree cloned from the shared checkout at this commit — not the
  brew-installed `bit`, which is release 0.1.21)

## How this was produced

```sh
./bit-out/bin/bit lint compiler > /tmp/lint-compiler.txt 2>&1; echo "exit=$?"
./bit-out/bin/bit lint stdlib   > /tmp/lint-stdlib.txt   2>&1; echo "exit=$?"
```

`bit lint` writes every finding to **stderr**, so `2>&1` is required or the
capture is silently empty. Both runs are recorded, not inferred:

| scope | exit code |
|---|--:|
| `compiler` | 1 |
| `stdlib` | 1 |

## Regenerating this file

Re-run the two commands above against a rebuilt `./bit-out/bin/bit` (`./make
selfhost` first, so the binary reflects the tree it is about to lint), then
regenerate the tables below from the fresh output:

```sh
grep -oE 'warning\[E[0-9]+\]' /tmp/lint-compiler.txt | sort | uniq -c
grep -oE 'warning\[E[0-9]+\]' /tmp/lint-stdlib.txt   | sort | uniq -c
tail -1 /tmp/lint-compiler.txt   # lint: N findings, M overrides active
tail -1 /tmp/lint-stdlib.txt
grep -A1 'warning\[E0214\]' /tmp/lint-compiler.txt /tmp/lint-stdlib.txt | grep -- '-->'
```

Do not copy the numbers below into a later document without re-running this —
this repo has had five figures go stale that way. State the commit you
measured on, the way this file states `6813e484`.

## Per-rule finding counts

Each cell is `grep -c 'warning\[E0NNN\]'` against that scope's `2>&1` capture,
at the commit above. `E0212` and `E0214` are included with their current
(post-triage) counts of zero, not omitted, so a reader does not have to
wonder whether the rule was skipped or simply clean.

| rule | name | compiler/ | stdlib/ | total |
|---|---|--:|--:|--:|
| E0201 | max-fn-lines | 79 | 18 | 97 |
| E0202 | max-params | 85 | 21 | 106 |
| E0203 | max-nesting | 24 | 2 | 26 |
| E0204 | max-complexity | 235 | 48 | 283 |
| E0210 | unused-import | 0 | 1 | 1 |
| E0211 | unused-local | 148 | 0 | 148 |
| E0212 | unreachable-code | 0 | 0 | 0 |
| E0213 | shadowed-local | 1 | 1 | 2 |
| E0214 | append-aliasing | 0 | 0 | 0 |
| E0215 | unused-result | 22 | 23 | 45 |
| **Total** | | **594** | **114** | **708** |

The "Total" row is the linter's own printed summary line, not a sum computed
here (the sum agrees, but the summary line is the authority):

```
compiler: lint: 594 findings, 19 overrides active
stdlib:   lint: 114 findings, 41 overrides active
```

19 + 41 = 60 active `// bit:lint allow` overrides across both scopes. An
override suppresses a finding that would otherwise be counted above, so this
number is evidence the 708 is not the whole story — some findings were
already dispositioned before this snapshot (E0214 among them: see below) and
are not sitting in the 708.

`E0212 unreachable-code` reads 0 in both scopes because #3211 fixed the
underlying dead code rather than suppressing the rule — see
`docs/lint/policy.md`'s E0212 section (corrected by #3233 the same day). It is
not a gap in this measurement.

## E0214 append aliasing

0 findings (0 compiler + 0 stdlib), so there is nothing to list. `bit lint`
prints no `warning[E0214]` line in either capture at this commit:

```sh
$ grep -c 'warning\[E0214\]' /tmp/lint-compiler.txt; echo $?
0
1
$ grep -c 'warning\[E0214\]' /tmp/lint-stdlib.txt; echo $?
0
1
```

(`grep -c` on zero matches exits 1 — the `1` above is `grep`'s own exit code,
not a finding count. Recorded so a zero-count reading is never mistaken for a
command that didn't run.)

This is not an absence of scrutiny: #3209 (`compiler/`, merged `844967b9`)
dispositioned all 8 findings the widened rule exposed there, and #3208
(`stdlib/`, merged `92d03397`) dispositioned all 22 in `stdlib/` — one of
which (`stdlib/tls/handshakewire.bit:144`, the TLS transcript aliasing bug)
was FIXED with a defensive copy rather than overridden; the other 29 across
both scopes carry a per-finding `// bit:lint allow E0214 -- <reason>`. Those
30 overrides are part of the 60 counted above.

## What this is for

This file is a **snapshot**, not a live check. Nothing currently reads it.
**#2453** ("Add the lint-self gate to tools/build/gates.bit as a count
ratchet", blocked on this ticket) is expected to add a gate that compares a
future `bit lint` run's totals against the numbers recorded here and fails on
regression. Until #2453 lands, this document has no enforcement behind it —
treat any number above as informational only, and re-run the commands in
"Regenerating this file" before relying on it for anything.
