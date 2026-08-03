# Package Manager

Bit resolves third-party dependencies through `bit add`/`bit up`/`bit remove`,
a `bit.json` manifest, and a machine-generated `bit.lock`. (Spec: §17.7.)

**v1 is git-URL only.** There is no hosted registry, no package name
namespace, and no server. `bit add github.com/owner/repo@v1.2.3` clones that
repo directly; the repo's own host (`github.com/owner/repo`) is the identity,
so there is nothing separate to squat or reserve. A hosted registry is future
scope layered on top of the same manifest and lock shape, not a prerequisite
for using packages today.

## `bit.json`: the `dependencies` field

```
dependency_map   = '"dependencies"' ':' '{' [ dependency_entry { ',' dependency_entry } ] '}' .
dependency_entry = STRING_LIT ':' STRING_LIT .   (* name : "gitHost/owner/repo@ref" *)
```

```json
{
  "dependencies": {
    "quicwire": "github.com/byteink/quicwire@v1.4.2",
    "http2util": "github.com/byteink/http2util@main",
    "scratch": "github.com/byteink/scratch@a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  }
}
```

Each value is `gitHost/owner/repo@ref`, and `ref` is exactly one of:

- an exact tag `vMAJOR.MINOR.PATCH` (e.g. `v1.4.2`) - the only form Minimal
  Version Selection (below) treats as an ordered version;
- a branch name (e.g. `main`), resolved to that branch's current tip; or
- a bare 40-character commit SHA, resolved to exactly that commit.

**No range operators.** `^`, `~`, `>=`, `<`, `x`, and every other range or
wildcard spelling are rejected at parse time - a dependency names one exact
ref, never a range for a resolver to pick from.

`bit.json` is JSONC (comments and trailing commas allowed); `bit add`/`bit
up`/`bit remove` rewrite only the one entry that changed, through a
comment-preserving edit layer, never a blind parse-and-reserialize. They add
*to* an existing project - a bare `{}` is enough to start from - they do not
scaffold a new `bit.json`.

## `bit add`

```
bit add <gitHost/owner/repo>[@ref] [--dir <path>]
```

Adds or updates one dependency. With no `@ref`, resolves the remote's default
branch HEAD and records that commit's exact SHA (never the word `HEAD`) as
the ref in `bit.json`. `--dir` runs against a project rooted somewhere other
than the current directory.

```console
$ bit add github.com/byteink/quicwire@v1.4.2
bit add: quicwire -> github.com/byteink/quicwire@v1.4.2 (9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c)
```

The dependency's own `bit.json` is fetched and its transitive requirements
are checked with Minimal Version Selection before anything is written: adding
a version that undercuts what another already-locked dependency transitively
requires fails loudly rather than locking an inconsistent graph.

## `bit up` / `bit update`

```
bit up [name] [--dir <path>]
bit update [name] [--dir <path>]
```

`update` is an exact alias. With no `name`, re-resolves every dependency
`bit.json` names against its *current* ref - picking up a moved branch tip or
re-verifying a tag - and rewrites `bit.lock` with the refreshed commits and
transitive requirements. With a `name`, restricts the refresh to that one
dependency. Either way, `bit.json` itself is never touched: the ref an entry
names only changes if you edit it by hand.

```console
$ bit up quicwire
bit up: quicwire -> v1.4.2 (a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2)
```

## `bit remove`

```
bit remove <name> [--dir <path>]
```

Deletes one dependency's entry from `bit.json`'s `dependencies` object and
its entry from `bit.lock`. Accepts either the bare name or a full
`gitHost/owner/repo[@ref]` spec - only the trailing path segment is used, so
`bit remove quicwire` and `bit remove github.com/byteink/quicwire@v1.4.2` name
the same entry. Fails if the name is not present, rather than a silent no-op.
Removal does not prune the on-disk `~/.bit/pkg` cache.

```console
$ bit remove quicwire
bit remove: quicwire
```

## `bit.lock`

```json
{
  "quicwire": {
    "url": "https://github.com/byteink/quicwire.git",
    "commit": "9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c",
    "requires": {
      "streambuf": "github.com/byteink/streambuf@v0.9.0"
    }
  }
}
```

`bit.lock` is plain JSON - no comments, no trailing commas, unlike `bit.json`.
It is fully machine-owned: hand edits are not a supported workflow, and every
`bit add`/`bit up`/`bit remove` regenerates it from scratch, sorted by
dependency name so repeated resolutions diff cleanly. Per dependency it
records:

- `url` - the git remote it was fetched from.
- `commit` - the exact resolved commit SHA. A tag or branch ref is always
  dereferenced to a commit before being recorded; `bit.lock` never stores a
  mutable ref.
- `requires` - that dependency's own transitive `dependencies`, verbatim,
  so Minimal Version Selection can re-run from the lockfile alone without
  re-fetching every transitive manifest.

## Resolution: Minimal Version Selection

Bit resolves the dependency graph with Go-style MVS, not a SAT/range solver:
for each module named anywhere in the transitive requirement graph, the
resolver takes the **maximum** of every stated minimum version for it.
Non-version refs (a branch or a bare SHA) are not compared against tagged
versions. One pass over the graph, no backtracking, deterministic by
construction - the resolved version is never lower than the highest of all
requirements and never higher than some entry actually asked for.

## The package cache: `~/.bit/pkg`

A resolved dependency is cached at:

```
~/.bit/pkg/<gitHost>/<owner>/<repo>/<commitSha>/
```

a real `git` checkout (the `.git` directory is kept), content-addressed by
commit SHA. `bit build` resolves a bare import name through `bit.lock` and
this cache only - a warm cache means a fully-locked build never touches the
network. A cache hit is verified, never trusted blind: `git rev-parse HEAD`
inside the cached directory must equal the locked SHA, or the build fails
loudly rather than silently rebuilding over a tampered or corrupted entry.

Set `BIT_PKG_CACHE` to use a different root (e.g. a CI checkout with a
pre-warmed, offline cache) instead of `~/.bit/pkg`.

`BIT_VANITY_ORIGIN` is a **testing-only** variable, not for normal use: when
set, it replaces the `https://<host>` prefix a vanity-name lookup (a
dependency whose leading path segment isn't a known git host, e.g.
`bitlang.org/pkg/http`) dials for its `bit-import:` document, so
`BIT_VANITY_ORIGIN=http://127.0.0.1:8099` turns that lookup into a request to
`http://127.0.0.1:8099/pkg/http` instead of `https://bitlang.org/pkg/http` -
it exists so this path can be exercised against a local fixture server with
no TLS and no network at all. It never weakens TLS verification for a real
lookup, never changes what `bit.lock` records (still the `<gitURL>` the
fetched document names), and never applies to the git fetch of that resolved
URL - only to the vanity document request itself. Unset, resolution is
byte-identical to not having this variable at all.

## Importing a dependency

A bare import name (anything that isn't `std/...` or a relative `./`/`../`
path) is looked up in `bit.lock`:

```bit ignore
import { Frame } from "quicwire"
```

An import naming something absent from `bit.lock` fails with a hint to run
`bit add`, rather than reaching for the network mid-build - `bit build` never
adds an unlocked dependency itself.

## Security posture

- **No install-time code execution, no exceptions.** Fetching a dependency
  reads only its `bit.json` and source tree. There is no build script, no
  postinstall hook, and no field in `bit.json` that names one.
- **Commit-SHA pinning is the integrity story.** `bit.lock` never stores a
  mutable ref; every dependency is locked to the exact commit fetched, and a
  cache hit is re-verified against that SHA on every read. There is no
  separate signature scheme in v1 - the git object's own SHA-1 identity is
  the check. If a tag is later force-moved, the next fetch's SHA won't match
  the lock, and the build fails rather than silently re-resolving.
- **Git-URL-only means no separate namespace to police.** There is no
  hosted registry account system, so there is nothing to squat, and no
  server-side yank to worry about - ownership of `owner/repo` on the git
  host itself is the only identity that matters.
- **Fetched manifests are bounded before they are parsed.** A dependency's
  `bit.json` is capped at 1 MiB and rejected outright above that, on top of
  the JSON parser's existing nesting-depth guard - an oversized or
  maliciously deep manifest from a third-party remote is refused before any
  parsing happens.
