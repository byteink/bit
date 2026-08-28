# pkg/redis

A RESP2 client for Redis (and RESP2-protocol-compatible servers) written in
Bit, over `std/net`. The first first-party Bit package
(`bitlang-ws/CLAUDE.md`'s "First-party packages" design, #3466) — read the
"Package layout precedent" section below before adding a second one.

## Install

```json
{
  "dependencies": {
    "redis": "bitlang.org/pkg/redis@redis/v0.1.0"
  }
}
```

See "Versioning and release tags" below for why this pins a literal ref
rather than a `^0.1.0` range. `bit add` derives the dependency key ("redis")
from the vanity name's trailing path segment (`compiler/pmcli.bit`'s
`pmLastSegment`) — that key is also the import path a consuming module uses,
below.

## Usage

```
import { connect } from "redis"

fn main(): ()! {
  let c = connect("127.0.0.1", 6379)?
  c.set("greeting", "hello")?
  let v = c.get("greeting")?        // Option<string> -- None on a cache miss
  println(v)
  c.close()
  return
}
```

- `connect(host, port): Client!`
- `get(key): Option<string>!` -- `Option.None` on a miss, never `Option.Some("")`
- `set(key, value): ()!`
- `del(keys): i64!` -- the number of keys actually removed
- `exists(keys): i64!` -- the number of the given keys that exist
- `expire(key, seconds): bool!`
- `ping(): string!`
- `command(args): Reply!` -- the generic escape hatch: sends any command,
  returns its raw decoded `Reply`, so a command this package has not named
  yet never blocks a caller. A `-ERR ...` reply from the server surfaces as
  a `fail` from `command()` (and from every named method built on it), the
  same as any other failure.

## Package layout precedent

Everything here is what a second package author copies without asking
(#3466). Read this section before adding `pkg/<name>/`.

- **Where it lives.** `pkg/<name>/` is a subdirectory of the `bit` compiler
  repository -- never a separate repo (`bitlang-ws/CLAUDE.md`: "one repo, one
  gate"). It is one Bit *module*: every `.bit` file directly inside
  `pkg/<name>/` shares one declaration namespace (SPEC §17.1); there are no
  subdirectories under it.
- **`bit.json`.** This package has none. SPEC §17.7's dependency manifest is
  only needed when a package has its own third-party dependencies -- a
  directory with neither `bit.json` nor `bit.lock` "has nothing to
  reconcile and must never be flagged"
  (`compiler/projectcheck.bit`'s `checkManifestLockProblemNoFiles`). A
  package's own version is never written into its own `bit.json` either --
  SPEC §17.7 resolves a version constraint against the *consuming*
  repository's git tags, never against anything a package declares about
  itself. Add `pkg/<name>/bit.json` only once that package genuinely
  depends on another package or a third-party module; the shape is
  identical to any consuming project's.
- **Tests live in the package's own directory, not under `_tests_/`.**
  `./make test-package-<name>` (`tools/build/gates.bit`'s `packageGates()`,
  filesystem-driven from whatever `pkg/<name>/` directories exist -- nothing
  to register by hand) runs `bit test pkg/<name>` (SPEC §19), which
  discovers every top-level `fn test_*()` in the module. `resp.test.bit` and
  `client.test.bit` here are ordinary siblings of `resp.bit`/`client.bit` --
  same module, so a test calls an unexported helper directly with no
  import. This is a deliberate split from how the `bit` compiler tests
  itself (`_tests_/bit/`, `_tests_/imports/`): a first-party package is tested
  the way SPEC §19 documents testing an ordinary Bit project, because that
  is what it is.
- **No test may reach a real network service.** `resp.test.bit` drives the
  RESP codec directly against captured byte strings through the
  `byteSource` interface (`resp.bit`), which both `Client` (over a live
  `std/net.Conn`) and a test fixture (a fixed buffer, replayed once then
  EOF) satisfy structurally -- no socket involved at all.
  `client.test.bit` stands up a real TCP listener on `127.0.0.1:0`
  (kernel-chosen port) and `spawn`s exactly one accept-and-reply -- the same
  listen/spawn/accept/dial shape `_tests_/imports/nettcp/main.bit` already
  uses -- never a connection to a host the test did not itself start.
- **Versioning and release tags.** A release is a git tag on the `bit`
  repository itself, spelled `<name>/vMAJOR.MINOR.PATCH` -- for this
  package, `redis/v0.1.0`, never a bare `v0.1.0` (that namespace is the
  compiler's own release tags, matched by `dist/changelog.sh --match
  'v*'`; a bare tag here would collide with it). `bit add`/`bit up` resolve
  an arbitrary ref name via `git ls-remote <url> <ref> <ref>^{}`
  (`compiler/pmfetchresolve.bit`'s `resolveDependencyRef`), which works for
  any literal tag name, slash and all -- that is what #3287's
  `hasExplicitRef` fix made reachable in the first place.

  **A namespaced tag is NOT matched by SPEC §17.7's `^`/`~` version-constraint
  machinery** -- `listVersions` (`compiler/pmfetchresolve.bit`) only
  recognizes an unprefixed `MAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH` tag.
  A consumer of this package -- or any later one sharing this repo's tag
  namespace -- pins the *exact* ref, `"redis": "bitlang.org/pkg/redis@redis/v0.1.0"`,
  never a caret/tilde range. Cutting a release is the integrator's job, not
  an engineering ticket's (a tag is a release action); this package
  documents the spelling and creates no tag itself.
- **Vanity resolution.** Once hosted, `https://bitlang.org/pkg/redis` must
  serve exactly one line (SPEC §17.7):

  ```
  bit-import: bitlang.org/pkg/redis git https://github.com/byteink/bit.git dir pkg/redis
  ```

  The `dir pkg/redis` field (#3270) is what lets `bit add` resolve a
  package living in a subfolder of a larger repository rather than at its
  root. Serving that document is `bit-website`'s job, not this package's --
  recorded here so whoever wires it up does not have to reverse-engineer
  the line.
- **Constraints that shaped this package**, worth restating for the next
  one: no dependency on `std/sql` (a package couples to the interfaces its
  own domain needs, not to an unrelated one); no new file under
  `scripts/` -- `./make test-package-<name>` needed no registration at all,
  by design (#3271); no separate git repo, ever.

## RESP notes

- `Reply` (`resp.bit`) is a 5-variant sum type: `Simple`, `Err`, `Int`,
  `Bulk(Option<string>)`, `Array(Option<[]Reply>)`. `Bulk`/`Array` carry
  `Option` specifically so a null reply (`$-1\r\n` / `*-1\r\n`) is
  distinguishable from an empty one (`$0\r\n\r\n` / `*0\r\n`) -- conflating
  the two is the classic RESP client defect this package exists not to
  repeat.
- Only RESP2 is implemented -- no RESP3 (Redis 6+'s `HELLO 3`) push types,
  maps, doubles, or big numbers. A server that requires RESP3 is out of
  scope for v0.1 of this package.
