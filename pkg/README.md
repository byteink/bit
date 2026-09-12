# First-party packages

Every directory under `pkg/` is a first-party Bit package: one Bit module,
consumed by its vanity name `bitlang.org/pkg/<name>`, released as a git tag on
this repository. This file is the authority on how packages are laid out,
gated, versioned and released. A package's own `README.md` documents the
package; it does not restate this.

## Layout

- `pkg/<name>/` is one module (SPEC §17.1): every `.bit` file directly inside
  it shares one namespace, and there are no subdirectories.
- Tests are `<file>.test.bit` beside the file they test, run by
  `bit test pkg/<name>` (SPEC §19).
- No `bit.json` unless the package has third-party dependencies of its own.
- A `README.md` with install, usage and the exported surface.
- No separate repository. One repo, one gate, one atomic change when a
  package and the compiler move together.

## Gate

`tools/build/` discovers packages from the filesystem: one `test-package-<name>`
step per directory, plus `test-packages` for all of them. Nothing to register.

| the diff touches | what runs |
|---|---|
| `pkg/<name>/**` only | `./make test-package-<name>` |
| `compiler/`, `runtime/`, `stdlib/`, `tools/build/` | the full pre-push gate, then `./make test-packages` |

Neither step is part of `./make test`, on purpose: a package is a leaf, so a
`pkg/`-only diff cannot break the language and owes none of the language's
gates. The language can break a package, so a compiler change owes
`test-packages` on top of its own gate.

## Consuming a package

```json
{
  "dependencies": {
    "web": "bitlang.org/pkg/web@v0.1.0"
  }
}
```

`bit add bitlang.org/pkg/web@v0.1.0` writes that. The version a consumer
writes is a plain `vX.Y.Z`; the package manager maps it to the repository tag
`web/v0.1.0` (see Releasing, below) because the vanity document carries a
`dir` field. Ranges (`^0.1.0`) work the same way and only ever match that
package's own tags - a bare `vX.Y.Z` on this repository is a compiler
release and is never a candidate. `bit.lock` records the tag that was
matched, `"tag": "web/v0.1.0"`, beside `"version": "0.1.0"`, so the mapping
is visible without re-querying the remote.

The vanity name resolves through `https://bitlang.org/pkg/<name>`, one line
served by the website:

```
bit-import: bitlang.org/pkg/web git https://github.com/byteink/bit.git dir pkg/web
```

`dir` (SPEC §17.7) is what makes a subfolder of this repository addressable.
The website generates that document from `content/packages.txt` in the
`bit-website` repository; one line per package:

```
web https://github.com/byteink/bit.git dir pkg/web
```

## Versioning

- A package version is independent of the compiler version. `web/v0.1.0` says
  nothing about which `v0.x.y` compiler cut it.
- Semantic versioning, same rule as the compiler (`docs/release/VERSIONING.md`):
  anything added or anything breaking is MINOR, fixes only is PATCH, MAJOR
  stays `0` until the owner lifts it.
- The surface that decides the bump is the package's exported API.
- A package works with the compiler release it was cut against and newer ones,
  until a compiler release states otherwise in its notes.

## Releasing a package

A release is a git tag and nothing else. `bit add` clones the repository at
the ref, so the tag is the artifact: no tarball, no GitHub release object, no
Homebrew, no container image, no `dist/release.sh`.

Tags are `<name>/vMAJOR.MINOR.PATCH`, never a bare `vX.Y.Z`. The bare
namespace is the compiler's own (`v0.1.0` is already a compiler release) and
`dist/changelog.sh` matches it with `v*`, so a package tag can never be
mistaken for a compiler release and two packages never collide on a version.
The consumer never sees the prefix: `@v0.1.0` in `bit.json` resolves
`web/v0.1.0` on the repository.

1. The commit is on pushed `main`. `main` is only pushed after the full gate,
   so the language is already proven at that commit.
2. `./make test-package-<name>` exits 0 on that commit.
3. `bitlang.org/pkg/<name>` serves the vanity document, with the `dir` field.
   If not, add the line to `content/packages.txt` in `bit-website`, regenerate
   and deploy first.
4. Classify the bump against the previous `<name>/v*` tag, per the rule above.
5. Tag and push the tag only:

   ```sh
   git tag -a web/v0.1.0 <sha> -m "web v0.1.0"
   git push origin web/v0.1.0
   ```

6. Prove it from outside: in a scratch project in `$TMPDIR`, run
   `bit add bitlang.org/pkg/<name>@vX.Y.Z`, then build a program that
   imports it. Resolution through the vanity name and the `dir` field is the
   part nothing else checks.

This repository has no CI workflows, so pushing a tag runs nothing and bills
nothing. Keep it that way.

## Adding a package

Copy `pkg/redis/`'s shape: module directory, `.test.bit` beside each file,
`README.md`. The gate picks it up on the next `./make`. Add its line to
`content/packages.txt` in `bit-website` when it is ready to be consumed, not
before.
