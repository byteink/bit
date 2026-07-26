# website/

Static content for **bit-lang.byteink.com**, per the planned layout in the
repo root `CLAUDE.md` (`website/   static site → k3s byteink namespace`).

```
website/
  support.sh          generator for the Support/Security page
  deploy.sh           regenerate + push to the byteink k3s cluster
  deploy/
    bit-lang.yaml     Deployment + Service + Traefik IngressRoute
  public/             served as-is; no build step, no npm, no framework
    support.html      generated — do not hand-edit
    support.css
```

`support.sh` reads `../docs/release/SUPPORT.md` by relative path, so it assumes
this directory sits beside `docs/` in the same checkout. That one line is what
would need changing if the site is ever split into its own repo.

## Support/Security page

`public/support.html` carries two things:

- The **support matrix** — every row of the table under `## Support matrix` in
  `docs/release/SUPPORT.md` (version, released, full-support-end, EOL, status),
  copied verbatim. The section opens at that heading and closes at the next
  heading of any level, so neither a subheading's table nor a later section's
  table bleeds into the matrix. Column count comes from the header row: a row
  that disagrees with it fails the build rather than losing a cell, and a matrix
  with no release rows yet renders an empty state rather than failing.
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

A draft or embargoed advisory must never reach this page. Four guards:

- The API is queried with `state=published`, so a draft is never sent.
- jq filters `select(.state == "published")` again on what came back, so an API
  change cannot turn a draft into a published-looking row.
- Every API-derived field is HTML-escaped (`@html`) before it lands in the page.
- `BIT_REPO` is validated as `owner/name` before use. It is spliced into both the
  request path and `href` attributes, so a value carrying `?` or extra segments
  could otherwise reshape the request and get past the server-side filter,
  leaving the jq filter as the only thing standing between a draft and the page.

### Never a false all-clear

"No published security advisories." is a definitive claim, so the generator only
makes it when it actually reached the right repo's advisories endpoint:

- Fetch succeeded, feed empty → renders "No published security advisories."
- **404, and `/repos/<owner>/<name>` itself resolves** → same. The endpoint 404s
  while a repo has no advisory surface, and having confirmed access to the repo,
  there is no published advisory being hidden from us. This is the current state
  of `byteink/bit`.
- 404 with the repo *not* resolving → "unavailable" + a link to GitHub. GitHub
  answers 404, not 403, for a repo the token cannot see, so a mistyped
  `BIT_REPO`, a rename, or an under-scoped `gh` lands here instead of publishing
  a false all-clear.
- Any other failure, including a `--paginate` run that died partway with pages
  already in hand → "unavailable". A partial feed is never shown as the whole one.

`--self-check` covers the parsing and escaping paths against fixtures with no
network: a draft advisory is dropped, a `<script>` in a summary is escaped, an
alignment delimiter row is not mistaken for data, tables under a sibling h2 or a
child h3 stay out of the matrix, a ragged row fails the build, a header-only
matrix renders, and every malformed `BIT_REPO` is rejected.

## Deployment

`website/deploy.sh` regenerates the page, pushes `public/` as the
`bit-lang-site` ConfigMap, applies `deploy/bit-lang.yaml` (nginx Deployment +
Service + Traefik IngressRoute for `bit-lang.byteink.com`, `websecure`
entrypoint, `letsencrypt` cert resolver, namespace `byteink`), and restarts the
Deployment so the new bytes are actually served.

```sh
sh website/deploy.sh    # needs kubectl and the `byteink` context
```

Two things are outside this repo and both are needed before the page is live:

1. **A DNS record** for `bit-lang.byteink.com` pointing at the cluster. None
   exists as of 2026-07-26.
2. **The decision to publish.** Nothing about Bit is public yet, so this has not
   been run.

`byteink/bit` is also still private, which is why the advisory feed renders
empty — there are no published advisories to list.
