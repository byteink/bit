# Package Manager

Bit resolves third-party dependencies through `bit add`/`bit up`/`bit remove`,
a `bit.json` manifest, and a machine-generated `bit.lock`. `bit list` and
`bit why` read that graph back without opening either file by hand. (Spec:
§17.7.)

**v1 is git-URL only.** There is no hosted registry, no package name
namespace, and no server. `bit add github.com/owner/repo@v1.2.3` clones that
repo directly; the repo's own host (`github.com/owner/repo`) is the identity,
so there is nothing separate to squat or reserve. A hosted registry is future
scope layered on top of the same manifest and lock shape, not a prerequisite
for using packages today.

## `bit init`

```
bit init [name]
```

Writes a minimal `bit.json` in the current directory - `{"dependencies": {}}`,
or, with `[name]`, `{"name": "<name>", "dependencies": {}}` - and exits 0.
Fails, leaving the directory untouched, if a `bit.json` already exists there.

```console
$ bit init
bit init: wrote bit.json
$ bit init
bit init: bit.json already exists — refusing to overwrite
```

**Bit's fs ABI has no `getcwd`** (`compiler/buildout.bit`'s own comment on
`manifestProjectName`), so `bit init` has no way to read the directory it is
running in and default `[name]` to it, the way `npm init -y` derives one from
`path.basename(process.cwd())`. Omit `[name]` and the manifest simply carries
no `"name"` key - see below for the one thing that key actually does.

## `bit.json`

`bit.json` is JSONC (comments and trailing commas allowed when read by `bit
add`/`bit up`/`bit remove`; see the caveat below). Every key besides
`dependencies` is optional, and an unrecognized key is accepted and ignored
silently - nothing rejects a typo.

### `name`

A plain string, read in exactly one place: `bit build <dir>` (a
project-directory build, not a single-file one) names its default output
after it (`compiler/buildout.bit:81`, `manifestProjectName`). With no `name`
key, that default falls back to the directory argument's own last path
component instead. `bit init [name]` is the only way to set it from the CLI;
`bit add`/`bit up`/`bit remove` never touch it.

This is also the one field where the two JSON readers in this codebase
disagree: `bit build`'s lookup goes through `readManifest`
(`compiler/pmfetchresolve.bit:687`), which parses **strict** JSON, not JSONC -
a `bit.json` with a `name` key that reads fine for `bit add`/`bit up` (JSONC,
via `jsoncParse`) can still silently lose its `name` for `bit build`'s
purposes if the file also carries a comment or a trailing comma, degrading to
"no name" rather than failing loudly. `bit init` never writes either, so a
manifest it created is immune to this; a hand-edited one carrying comments is
not.

There is no `version` field. Nothing in the compiler reads a `"version"` key
anywhere in `bit.json` - it is not wired to anything, including the ref a
dependency resolves to (that comes from the dependency *spec string* itself,
`gitHost/owner/repo@ref`, not from any field named `version`). A `"version"`
key some other tool's manifest convention might expect is accepted like any
other unrecognized key: parsed, kept, never read.

### `dependencies`

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

- a **version constraint** - `MAJOR.MINOR.PATCH` (exact), `^MAJOR.MINOR.PATCH`
  (caret), or `~MAJOR.MINOR.PATCH` (tilde), resolved against the target
  repository's git tags (§17.7's "Version constraints"/"Git tag matching");
- a branch name (e.g. `main`), resolved to that branch's current tip; or
- a bare 40-character commit SHA, resolved to exactly that commit.

**No `v` prefix, and no other operator.** A version constraint is always
plain semver - `^1.2.0`, never `^v1.2.0` - `bit add` accepts either spelling
on the command line and writes the `v`-less form; a `bit.json` containing a
`v`-prefixed version is rejected at parse time. `>=`, `<`, `x`, `*`, `||`,
hyphen ranges, and every other range/wildcard spelling beyond `^`/`~` are
rejected too - a dependency names exactly one of the three forms above, never
a broader range grammar to pick from.

**The map key is the import name, not a label.** `import { Frame } from
"quicwire"` resolves `"quicwire"` against `bit.lock`'s top-level entries
(`compiler/projectpkg.bit`'s `resolvePackageImport`), and `bit.lock` is keyed
by exactly this map's key - never by the repo name inside the value string,
except that `bit add` always *picks* the key for you as the repo's (or
vanity path's, or local path's) last segment
(`compiler/pmcli.bit:322/117/87`), with no flag to override it. Hand-edit the
key to something else and run `bit up` (which reads every key straight out of
`bit.json`, `compiler/pmcliup.bit:174-202`'s three `upsertLockEntry(entries,
d.name, ...)` call sites) and the new key is what locks and what your
`import` must then name - it is not silently ignored, but `bit add` alone
will never write it for you.

`bit.json` is JSONC (comments and trailing commas allowed when read through
`bit up`'s `jsoncParse` - see the `name` field's caveat above for the one
reader that is stricter); `bit add`/`bit up`/`bit remove` rewrite only the one
entry that changed, through a comment-preserving edit layer, never a blind
parse-and-reserialize. They add *to* an existing project - a bare `{}` is
enough to start from - they do not scaffold a new `bit.json`; `bit init`
(above) does.

## `bit add`

```
bit add <gitHost/owner/repo>[@ref] [--dir <path>]
```

Adds or updates one dependency. `--dir` runs against a project rooted
somewhere other than the current directory. What gets written into
`bit.json` depends on what you name:

- **no `@ref` at all** - resolves the newest available version tag (never a
  branch tip or `HEAD`) and writes a **caret** constraint for it;
- **`@1.2.3`** (or `@v1.2.3`, canonicalised) - naming an exact version means
  you meant it: writes an **exact** pin, `"1.2.3"`, never a caret. This is a
  deliberate departure from npm/cargo, which write a caret even when you name
  a version and need a flag to pin - the explicit form was chosen because the
  npm behaviour surprises people;
- **`@^1.2.0`** / **`@~1.2.0`** - written back exactly as given.

```console
$ bit add github.com/byteink/quicwire
bit add: quicwire -> github.com/byteink/quicwire@^1.4.2 (9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c)
$ bit add github.com/byteink/quicwire@1.4.2
bit add: quicwire -> github.com/byteink/quicwire@1.4.2 (9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c)
```

The dependency's own `bit.json` is fetched and its transitive requirements
are checked against every already-locked dependency's own requirements with
the PubGrub resolver (below) before anything is written: naming a version
that conflicts with what another already-locked dependency transitively
requires fails loudly, naming both requirers and both versions, rather than
locking an inconsistent graph - and `bit.json`/`bit.lock` are left exactly as
they were.

**Transitive dependencies are resolved too.** Every dependency named in the
graph reachable from what was just added or refreshed - not only the direct
ones `bit.json` names - is fetched and given its own top-level `bit.lock`
entry, the same direct-vs-vanity classification and fetch path a root
dependency uses. When two different requirers name the same transitive
dependency, the PubGrub resolver (below) intersects their constraints -
today that always means two exact pinned versions, so two requirers naming
a *different* one fails the whole add or update, naming both, rather than
silently picking one. A name `bit.lock` already has a top-level entry for is
not reconsidered, even by `bit up`, if a newly discovered requirement would
want a higher version - only names with no entry yet are filled in.

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

## `bit list`

```
bit list
```

Prints each of the project's *direct* dependencies - the ones declared in
`bit.json` - one line each: name, the spec `bit.json` records for it, and
the commit `bit.lock` resolved it to (#2271). A transitive dependency (one
reachable only through another dependency's own `requires`) is not listed -
it has no entry of its own in `bit.json`, only inside a direct dependency's
`bit.lock` `requires` map.

```console
$ bit list
quicwire -> github.com/byteink/quicwire@v1.4.2 (9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c)
```

Fails (exit 1) with no `bit.json` here, the same way `bit add`/`bit up` do
outside a project; and fails the same way `bit doc`/`bit check`/`bit build`
already do when `bit.json` and `bit.lock` disagree, rather than printing
`bit.lock`'s possibly-stale answer as though it were still current.

## `bit why`

```
bit why <name>
```

Prints every path from this project's `bit.json` to `<name>`, walking
`bit.lock`'s own recorded `requires` graph - no re-resolution, no network,
just the bytes `bit add`/`bit up` already wrote. If `<name>` is reachable
more than one way, every path is printed, one per line: a diamond (two
direct dependencies that both transitively require the same package) is
exactly the case this command exists for.

```console
$ bit why streambuf
root -> quicwire -> streambuf
$ bit why quicwire
root -> quicwire
```

`root` always stands for this project's own `bit.json`; it is never a real
package name, so a chain always reads as a path *from* the manifest, not a
bare list of names.

Two different failures, each a distinct message and exit 1, worth telling
apart:

```console
$ bit why nosuchpkg
bit why: "nosuchpkg" is not a dependency of this project (no bit.lock entry)
$ bit why orphanedpkg
bit why: "orphanedpkg" is locked but unreachable from any dependency in bit.json — an orphan bit.lock entry; run `bit up` to relock
```

The first is a name `bit.lock` has never heard of. The second is a name
`bit.lock` *does* have an entry for, but no chain from `bit.json` actually
reaches it - an orphan entry, left behind by a hand-edited `bit.lock` or one
gone stale relative to `bit.json`. A single "not found" answer for both
would hide which fix applies: adding the dependency, versus running `bit up`
to relock.

Fails (exit 1) with no `bit.json` here, the same way `bit list` does outside
a project, and the same way when `bit.json` and `bit.lock` disagree.

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
  so the resolver (below) can re-run from the lockfile alone without
  re-fetching every transitive manifest.

## Resolution: PubGrub

Bit resolves the dependency graph with a PubGrub solver
(`compiler/pmresolve.bit`, `compiler/pmresolvesolve.bit`,
`compiler/pmresolveexplain.bit`), not a one-pass "take the maximum" walk -
that was Go-style Minimal Version Selection, retired by the same change that
added this solver. MVS could never fail: every requirement was a bare
minimum, and the max of stated minimums always produced an answer. Once a
package must satisfy the *intersection* of every stated requirement, that
intersection can be empty, so resolution genuinely fails now - and a solver
that can only say "no version works" is not enough to debug that. PubGrub
(Natalie Weizenbaum's writeup; Dart's `pub`, later Cargo's resolver) is unit
propagation plus conflict-driven clause learning over version sets, and its
failures come with a *derivation*: which requirements, stated by which
requirers, cannot all hold at once - not just which package lost.

Every requirement the resolver reasons about is a version set built from a
`^X.Y.Z`, `~X.Y.Z`, or exact constraint (`compiler/pmversionset.bit`); the
resolver keeps the running intersection of every constraint stated against a
package as it works, computed exactly (set intersection, union and
complement over disjoint version ranges), never approximately. A non-version
ref (a branch or a bare commit sha) has no ordering to arbitrate and is
never compared against a tagged version - SPEC §17.7's carve-out, unchanged
by the algorithm swap. When several available versions satisfy the
intersection, the resolved version is the **highest** of them - never the
lowest, and never merely the max of stated minimums. The search can
backtrack - trying a candidate version, finding it conflicts, undoing that
decision and retrying an older one - but it stays deterministic by
construction (decisions are made in a fixed order over the graph's own
package names), so the same graph always resolves to the same versions.

`bit add` writes `^`/`~` and exact constraints per the rules above, so the
solver's constraint model is no longer ahead of what a real `bit add`/`bit up`
run can hand it: a bare `bit add` writes a caret against the newest available
tag, naming a version writes an exact pin, and `@^`/`@~` are written back as
given. A non-version ref (a branch or a bare commit sha) still has no
ordering to arbitrate and is never compared against a tagged version.

When no version satisfies every stated constraint, resolution fails naming
every conflicting requirement rather than a bare "no version works": which
package is disputed, which requirers stated a constraint on it, and what
each constraint was. For example, if an already-locked dependency
transitively requires `streambuf` at one exact version and a fresh `bit add`
or a deeper transitive requirement names a different one, the failure names
both requirers and both versions - not just that `streambuf` could not be
resolved.

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

A `bit-import:` document may additionally name `dir <path>`, appended after
`<gitURL>` on the same line (spec §17.7's vanity document extension point) -
the subdirectory of the fetched repository that is the package's own root,
for a package that lives in a subfolder of a larger repository rather than
at its root (a first-party package under `bit/pkg/<name>/`, for example).
`bit.lock` records it as `dir`, beside `vanity`; a document naming no `dir`
field resolves the package at the repository root and the entry omits the
key entirely, exactly as before this field existed.

## Importing a dependency

A bare import name (anything that isn't `std/...` or a relative `./`/`../`
path) is looked up in `bit.lock`:

```bit ignore
import { Frame } from "quicwire"
```

An import naming something absent from `bit.lock` fails with a hint to run
`bit add`, rather than reaching for the network mid-build - `bit build` never
adds an unlocked dependency itself.

`bit doc <name>` (#2271) resolves the same way, so a dependency's exported
surface is reachable by the name a program imports it by rather than the
on-disk cache path it happens to be fetched to: a name declared in
`bit.lock` first, then a `std/x` name against the standard library, and
only then a literal filesystem path (the one form `bit doc` accepted before
this).

```console
$ bit doc quicwire
function frameLen (Frame) => i64
$ bit doc std/strings
function compare (string, string) => i64
...
```

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

## First-party packages (`pkg/<name>/`)

First-party packages live in `pkg/<name>/` - a subfolder of this repo, not a
separate repo per package. One repo, one gate: each package is consumed by
its vanity name, `bitlang.org/pkg/<name>` (SPEC §17.7, and the `dir <path>`
extension a vanity document can carry, described above), so the git host is
never written into any consumer's `bit.json` and a package could move to its
own repo later with zero consumer churn if it ever needed to.

**Releasing a package is a git tag and nothing else.** `bit add` clones the
dependency's repo at a ref, so the artifact *is* the tag - there is no
tarball, no ghcr image, no brew formula, and `dist/release.sh` (the
compiler's own eight-surface release checklist) is not involved at all.
Per-package tags are `<name>/vX.Y.Z` (e.g. `toml/v0.1.0`), independent of the
compiler's own `v0.1.x` series; `dist/changelog.sh` matches `v*` only, so a
package tag is never mistaken for a compiler release.

And the compiler side of a package release comes free: a package tag names a
commit already on `main`, and `main` is only ever pushed after this repo's
own full gate, so the language is already proven green at that commit. The
package release owes only its own gate, below.

### Why a package release must not run the language's gate

The whole reason packages live in this repo's own `pkg/` rather than in
`~/.bit/pkg`-style external repos is convenience - one clone, one build, one
CI-free workflow. That convenience is worthless if updating one package
means paying the language's own ~62-minute pre-push gate
(`rm -rf bit-out && ./make && ./make test && ./make test-differentials`) for
a change that cannot possibly touch the compiler. So packages get their own
gate, built on one asymmetry:

- **A package cannot break the language.** Nothing in `compiler/**`,
  `runtime/**`, `stdlib/**` or `tools/build/**` imports a package - a
  package is a leaf. For a `pkg/**`-only diff, every one of this repo's
  other gates is provably irrelevant, not merely expensive.
- **The language can break a package.** So the dependency runs one way and
  the gating must too - a compiler, runtime, stdlib, or build-driver change
  must run the package gate too, or a language change could silently break
  every package with nothing catching it.

Concretely:

| what the diff touches | what runs |
|---|---|
| `pkg/<name>/**` only | `./make test-packages` |
| `compiler/`, `runtime/`, `stdlib/`, `tools/build/` | the language's own gate(s) **plus** `./make test-packages` |

`./make test-packages` runs every package's own tests (`bit test pkg/<name>`,
SPEC §19, against every directory `pkg/` currently holds) in one process.
`./make test-package-<name>` runs exactly one, so releasing `toml` does not
also run `yaml`'s compliance corpus. Both are generated from whatever `pkg/`
holds at the moment `./make` runs - adding a package needs no registration
edit anywhere.

`test-packages` is registered as a `Step{}` in `tools/build/defs.bit`'s
`coreSteps()`, deliberately **not** `gateSteps()` - the same place and the
same reason `test-differentials` is: a package's own compliance corpus (a
future `toml-test` or `yaml-test-suite`, hundreds of fixture files) must
never grow the mandatory `./make test` suite, which stays fixed regardless
of how many packages this repo ever holds. `scripts/gate.sh`'s `pkg` bucket
is what a package-only change actually runs day to day; its `selfhost`,
`runtime`, `stdlib`, `stdlibdocs` and `full` buckets each add
`test-packages` to their own steps for the other half of the asymmetry
above.
