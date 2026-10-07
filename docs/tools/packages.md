# Packages

Bit resolves third-party dependencies through `bit add`/`bit up`/`bit
remove`, a `bit.json` manifest, and a machine-generated `bit.lock`. `bit
list` and `bit why` read that graph back without opening either file by
hand.

Dependencies are git URLs, not a hosted registry: `bit add
github.com/owner/repo@v1.2.3` clones that repo directly, and the repo's own
host is the identity - there is no separate name to reserve or squat.

## `bit init`

```
bit init [name]
```

Writes a minimal `bit.json` in the current directory. Fails, leaving the
directory untouched, if a `bit.json` already exists there.

```
$ bit init inkwell
bit init: wrote bit.json
$ bit init inkwell
bit init: bit.json already exists - refusing to overwrite
```

`[name]`, when given, is written verbatim. Omitted, it defaults to the
current directory's own name.

## `bit.json`

Comments and trailing commas are allowed. Every key besides `dependencies`
is optional.

```json
{
  "name": "inkwell",
  "dependencies": {
    "web": "bitlang.org/pkg/web@^0.9.0"
  }
}
```

Each dependency value is `gitHost/owner/repo@ref`, where `ref` is one of:

- a version constraint: `1.2.3` (exact), `^1.2.0` (caret) or `~1.2.0`
  (tilde), matched against the target repository's git tags;
- a branch name, resolved to that branch's current tip; or
- a full commit SHA, resolved to exactly that commit.

The map key (`"web"` above) is the name your code imports by - `import {
App } from "web"` - not a label; `bit add` picks it for you from the
repository's own name.

## `bit add`

```
bit add <gitHost/owner/repo>[@ref] [--dir <path>]
```

Adds or updates one dependency.

```
$ bit add bitlang.org/pkg/web
bit add: web -> bitlang.org/pkg/web@^0.9.0 (61f779e0e5adc8034e6ae4852cf5b3beeb4939f8)
$ bit add bitlang.org/pkg/web@0.9.0
bit add: web -> bitlang.org/pkg/web@0.9.0 (61f779e0e5adc8034e6ae4852cf5b3beeb4939f8)
```

Naming no version resolves the newest tag and writes a caret constraint;
naming an exact version writes an exact pin instead, since asking for
`0.8.0` by name means you meant exactly that. Every transitive dependency
reachable from what you just added is fetched and locked too, not only the
one you named directly.

`bit add` checks the new dependency's requirements against everything
already locked before writing anything: a version that conflicts with
another dependency's own transitive requirement fails loudly, naming both
requirers and both versions, and leaves `bit.json`/`bit.lock` untouched.

## `bit up`

```
bit up [name] [--dir <path>] [--latest]
```

With no `name`, re-resolves every dependency `bit.json` names; with a
`name`, refreshes only that one. A branch ref picks up its tip's new head;
a `^`/`~` constraint moves to the highest tag that still satisfies it,
without touching `bit.json`.

```
$ bit up web
bit up: web -> ^0.7.2 (a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2)
```

`--latest` additionally rewrites `bit.json`'s own constraint to the newest
published version, crossing whatever ceiling it had before - this is the
only way to widen a range, and it can break the build, so it's never
implicit.

## `bit outdated`

```
bit outdated [--dir <path>]
```

Read-only, one line per dependency; never rewrites `bit.json` or
`bit.lock`.

```
$ bit outdated
bit outdated: web	0.7.0	0.7.2	0.8.0
```

Tab-separated after the prefix: the version currently locked, the newest
version your `bit.json` constraint already allows, and the newest version
published at all.

## `bit remove`

```
bit remove <name> [--dir <path>]
```

Deletes one dependency from `bit.json` and `bit.lock`. Fails if the name
isn't present, rather than a silent no-op.

```
$ bit remove web
bit remove: web
```

## `bit list` and `bit why`

```
bit list
bit why <name>
```

`bit list` prints your project's direct dependencies, one line each: name,
the spec `bit.json` records, and the commit `bit.lock` resolved it to. `bit
why <name>` prints every path from your `bit.json` to that dependency, so a
diamond - two direct dependencies that both pull in the same transitive one
- shows every route:

```
$ bit why streambuf
root -> web -> streambuf
```

`root` always stands for your own `bit.json`.

## `bit.lock`

Plain JSON, no comments, fully machine-owned - hand edits are not a
supported workflow, and every `bit add`/`bit up`/`bit remove` regenerates
it from scratch.

```json
{
  "web": {
    "vanity": "bitlang.org/pkg/web",
    "dir": "pkg/web",
    "url": "https://github.com/byteink/bit.git",
    "commit": "61f779e0e5adc8034e6ae4852cf5b3beeb4939f8",
    "version": "0.8.0",
    "tag": "web/v0.8.0",
    "requires": {}
  }
}
```

`commit` is the exact resolved SHA - a tag or branch is always dereferenced
to a commit before it is recorded, so `bit.lock` never stores a mutable
reference.

## How conflicts are resolved

When two dependencies require different, incompatible versions of the same
transitive package, Bit's resolver reports the conflict rather than
silently picking one: it names every requirer and every version in
dispute, so you can see which constraint to relax. When several available
versions all satisfy every stated constraint, the highest one is chosen.

## The package cache

A resolved dependency is cached at `~/.bit/pkg/<gitHost>/<owner>/<repo>/<commitSha>/`,
content-addressed by commit. A warm cache means a fully locked build never
touches the network, and every cache hit is re-verified against the locked
commit before use. Set `BIT_PKG_CACHE` to use a different cache root.

## Network failures

A `git ls-remote`, a `git fetch` or the HTTPS fetch of a vanity name's
`bit-import:` document that fails for a transient reason (a timeout,
a refused or reset connection, a DNS failure, an HTTP 5xx or 429) is tried up
to three times, waiting about 0.5 s and then about 1 s, each wait lengthened by
up to half again at random. Every retry prints one line to stderr naming the
operation and the failure's message. An authentication failure, a missing
repository or an HTTP 404
fails on the first attempt, and a failure that survives the third attempt is
reported as the error.

## Importing a dependency

A bare import name - anything that isn't `std/...` or a relative `./`/`../`
path - is looked up in `bit.lock`:

```bit ignore
import { App } from "web"
```

Naming something absent from `bit.lock` fails with a hint to run `bit add`;
`bit build` never fetches an unlocked dependency itself.

## Security posture

- **No install-time code execution.** Fetching a dependency reads only its
  `bit.json` and source tree - there is no build script and no postinstall
  hook.
- **Commit-SHA pinning is the integrity story.** `bit.lock` never stores a
  mutable reference; a cache hit is re-verified against its locked commit
  on every read. If a tag is later force-moved, the next fetch's SHA won't
  match the lock, and the build fails rather than silently re-resolving.
- **No separate namespace to police.** There's no hosted registry account
  system - ownership of the repository on its own git host is the only
  identity that matters.

## Where next

[Build and run](build-and-run.md) is what turns a project with its
dependencies resolved into a binary. [Part 1 of the Book](../book/README.md)
adds `pkg/web` to Inkwell with `bit add` on its first page.
