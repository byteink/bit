# Support Policy

Bit follows an Ubuntu/enterprise-style LTS model: most releases are
**interim** (short support window), and periodically one release is
designated **LTS** (long support window). This doc is the source of truth —
given a version string and today's date, it tells you full-support /
security-only / EOL, no other lookup needed.

Pre-1.0 signing/policy scope is tracked under epic #1746.

## Pre-1.0 phasing

**0.x releases are not covered by this policy.** No support guarantee, no
backports, no security-fix commitment — upgrade to the latest 0.x instead of
requesting a backport. The policy activates at the v1.0 line, established by
release #366. Until #366 ships, the matrix below is empty by design.

## Cadence definitions

- **Interim release**: full support for **9 months** from GA (bug fixes +
  security fixes). No security-only period — it goes straight to EOL at the
  9-month mark. Interim releases exist to ship features fast; do not run one
  in production past its EOL.
- **LTS release**: full support for **12 months** from GA (bug fixes +
  security fixes), then **security-only** (security fixes only, no new bug
  fixes) until EOL at **60 months** from GA.

## Generation rule

Given a release's `released` date (GA date) and its designation, compute the
other two dates like this:

```
if designation == interim:
    full-support-end = released + 9 months
    EOL              = full-support-end          # no security-only period
if designation == LTS:
    full-support-end = released + 12 months
    EOL              = released + 60 months
```

`status` as of today (`T`) follows directly:

```
if T < full-support-end:  status = full support
if full-support-end <= T < EOL:
    status = security-only   (LTS only; interim skips this state)
if T >= EOL:               status = EOL
```

Month arithmetic adds calendar months to the GA date (e.g. 2026-07-24 + 12
months = 2027-07-24); no rounding to release boundaries.

## Max parallel supported lines

**At most 1 interim + 2 LTS lines are supported concurrently.** A new LTS
line is not designated until it fits this cap — if 2 LTS lines are already
in their support window (full or security-only), the next LTS designation
waits for one of them to reach EOL. This bounds maintainer support burden to
a fixed, predictable number of branches at any time (Power-of-10: bounded
resource allocation).

## Support matrix

No version is under this policy yet — Bit is pre-1.0. This table starts
populating at the v1.0 line (#366). The row below is illustrative only, to
fix the table's shape; delete the `(example)` marker once real rows land.

| version | released | full-support-end | EOL | status |
|---|---|---|---|---|
| 1.0 (example) | 2026-10-01 | 2027-10-01 | 2031-10-01 | full support |
| 1.1 (example, interim) | 2027-01-01 | 2027-10-01 | 2027-10-01 | full support |

Rows are appended in release order, never edited retroactively except to
advance `status` as dates pass.
