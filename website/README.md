# website/

Static content for **bit-lang.byteink.com**, per the planned layout in the
repo root `CLAUDE.md` (`website/   static site → k3s byteink namespace`).

```
website/
  support.sh          generator for the Support/Security page
  public/             served as-is; no build step, no npm, no framework
    support.html      generated — do not hand-edit
    support.css
```

## Support/Security page

`public/support.html` carries two things:

- The **support matrix** — every row of the table under `## Support matrix` in
  `docs/release/SUPPORT.md` (version, released, full-support-end, EOL, status),
  copied verbatim. The generator anchors to that heading and stops at the next
  one, so other tables in the doc cannot bleed into the matrix.
- The **security advisory feed** — published advisories from
  `GET /repos/byteink/bit/security-advisories`, newest first.

### Sync mechanism

**Build-time pull, then static.** `website/support.sh` reads
`docs/release/SUPPORT.md` and calls the advisories API once, writes
`public/support.html`, and that file is committed. The page ships zero
client-side JavaScript and makes no requests to GitHub at view time, so it
cannot leak a token, cannot break when GitHub is down, and renders the same
for every visitor.

```sh
sh website/support.sh              # regenerate public/support.html
sh website/support.sh --self-check # verify the generator (no network needed)
```

Environment overrides: `BIT_REPO`, `BIT_SUPPORT_MD`, `BIT_SUPPORT_OUT`,
`BIT_ADVISORIES_JSON` (read a local JSON file instead of calling the API).

### Refresh cadence

Re-run the generator and commit the result:

1. **On every change to `docs/release/SUPPORT.md`** — same commit as the edit.
2. **On every advisory publication** — publishing an advisory is a manual,
   deliberate act, so regenerating in the same sitting is part of it.
3. **Monthly**, otherwise. `status` cells go stale on a date boundary, not on
   an edit: a line silently moves full support → security-only → EOL when its
   `full-support-end`/`EOL` date passes. A monthly regen bounds how long the
   page can disagree with the policy to ~31 days.

Cadence is manual-but-scripted on purpose: the repo does not build the website
in CI, and GitHub Actions minutes are not spent on this. Point a scheduled job
at `sh website/support.sh` if the monthly step starts getting missed.

### Advisory safety

A draft or embargoed advisory must never reach this page. Three guards:

- The API is queried with `state=published`, so a draft is never sent.
- jq filters `select(.state == "published")` again on what came back, so an API
  change cannot turn a draft into a published-looking row.
- Every API-derived field is HTML-escaped (`@html`) before it lands in the page.

A fetch failure renders "Advisory feed unavailable at build time" plus a link
to GitHub — never "no advisories", which would read as an all-clear the page
has not earned. An HTTP 404 is the one exception and is treated as an empty
feed: the endpoint 404s while the repo has no advisory surface, and a
*published* advisory is public by definition, so nothing is being hidden.
`--self-check` asserts all of this against fixtures, including that a draft
advisory in the feed is dropped and that a `<script>` in a summary is escaped.

## Deployment

Not yet deployed: `bit-lang.byteink.com` has no DNS record and no k3s
IngressRoute as of 2026-07-26, and `byteink/bit` is still private (hence the
empty advisory feed — there are no published advisories to list). Serving
`public/` behind an IngressRoute in the `byteink` namespace is the remaining
step and belongs to whoever owns that cluster config; nothing in this
directory needs to change for it.
