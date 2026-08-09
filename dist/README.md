# Bit release artifacts — the packaging contract

This file is the contract between the release pipeline
(`dist/release.sh`, run by hand from a maintainer machine, never from CI — this
repo has no GitHub Actions and never will, see `CONTRIBUTING.md`'s "No GitHub
Actions") and everything downstream that consumes a published release:
the Homebrew tap (#359), the `curl | sh` installer (#360), and the
PowerShell/winget path (#361). Change this file first, then the pipeline, then
the consumers.

## Which targets actually ship

The compiler has three build targets — `bit build --target` accepts exactly
`x86_64-linux`, `aarch64-linux`, `aarch64-macos` (`compiler/main.bit`,
`parseBuildTarget`). Those three, and only those three, are published today.

| target | artifact | status |
|---|---|---|
| `x86_64-linux`  | `bit-<version>-linux-x86_64.tar.xz`  | shipping |
| `aarch64-linux` | `bit-<version>-linux-aarch64.tar.xz` | shipping |
| `aarch64-macos` | `bit-<version>-macos-aarch64.tar.xz` | shipping |
| `x86_64-macos`  | `bit-<version>-macos-x86_64.tar.xz`  | **not built** — the Mach-O linker has no x86-64 relocation support; `./make libbitrt` emits the archive but no compiler target selects it |
| `x86_64-windows` | `bit-<version>-windows-x86_64.zip`  | **not built** — blocked on #1103 (PE/COFF writer); the runtime also `@compileError`s outside POSIX |
| `aarch64-windows` | `bit-<version>-windows-aarch64.zip` | **not built** — same blockers as above |

`dist/release.sh` is a maintainer-run script with no CI behind it (this repo
has no GitHub Actions and never will; see `CONTRIBUTING.md`'s "No GitHub
Actions"). It loops over a plain `TARGETS` array, so enabling a target later is
one array entry in `dist/release.sh` plus one `case` arm in `dist/package.sh`.
Do not publish a placeholder for an unbuilt target: a missing artifact is a
clear failure downstream, a broken one is a silent one.

## Naming

```
bit-<version>-<os>-<arch>.tar.xz      # linux, macos
bit-<version>-<os>-<arch>.zip         # windows, when it exists
bit-<version>.cdx.json                # CycloneDX SBOM, one per release
```

* `<version>` — the git tag with its leading `v` stripped. `v0.1.0-rc1` →
  `0.1.0-rc1`.
* `<os>` — `linux` | `macos` | `windows`.
* `<arch>` — `x86_64` | `aarch64`. These match the compiler's own target
  spelling, not `uname -m`. Installers must map: Linux `uname -m` already
  reports `x86_64`/`aarch64`, but macOS reports `arm64` for `aarch64`.

## SBOM

`bit-<version>.cdx.json` is a CycloneDX 1.7 SBOM, one per release (not one per
target — the three archives share the same toolchain and dependency set).
Generated automatically, as one of `dist/release.sh`'s own steps (#2748) — no
maintainer ever runs `dist/sbom.py` by hand or decides whether to. The script
builds it via `cyclonedx-python-lib` (version pinned once, in
`dist/sbom-requirements.txt`, read by both the release flow and
`dist/sbom_test.py`) installed into a throwaway venv torn down immediately
after, so cutting a release never leaves a Python package on the host. `bit`
has no third-party source and no package manifest declaring dependencies, so
there is no external toolchain component at all: the compiler is bootstrapped
by the pinned stage0 (`dist/stage0/SHA256SUMS`), which is a prior Bit release
rather than a third-party component. The document states the absence of
vendored dependencies explicitly rather than shipping an empty component list.

## Layout inside the archive

Every archive unpacks into exactly one top-level directory named after the
artifact (no tarbomb):

```
bit-<version>-<os>-<arch>/
  bin/bit                              # the self-hosted compiler
  lib/x86_64-linux/libbitrt.a          # every runtime archive the compiler
  lib/aarch64-linux/libbitrt.a         #   can link, so a single install can
  lib/aarch64-macos/libbitrt.a         #   cross-produce the other targets
  stdlib/...                           # the Bit standard library source tree
  LICENSE
  README.md
  ARTIFACT.md                          # this file
```

## Path resolution — installers need no wrapper

`bin/bit` resolves the standard library and the runtime archive from **its own
location**, not the current working directory. Unpack the artifact anywhere and
symlink `bin/bit` into `PATH`; it works from any directory with no wrapper
script and no environment variables:

```sh
tar xf bit-<version>-linux-x86_64.tar.xz -C /opt
ln -s /opt/bit-<version>-linux-x86_64/bin/bit /usr/local/bin/bit
cd ~/anywhere && bit run hello.bit      # just works
```

The symlink is resolved before the prefix is computed, so the install root is
the real unpacked directory rather than `/usr/local`. Resolution order for each
of the two paths, independently:

1. the explicit override (`BIT_STDLIB`, `BIT_LIBBITRT`) when set,
2. `<prefix>/stdlib` and `<prefix>/lib/<triple>/libbitrt.a`, where `<prefix>` is
   the parent of the directory holding the binary (a flat unpack, everything
   beside the binary, is tried second),
3. the development-tree defaults, relative to the cwd.

Each path is answered on its own evidence — the prefix is probed, not assumed —
so a build tree, a flat unpack and a shipped artifact all work without a special
case.

The two environment variables remain supported as overrides, and are the way to
point a single install at a **cross-target** runtime archive: `BIT_LIBBITRT`
names one archive, so building for a non-host `--target` needs it re-pointed at
the matching triple. They are no longer required for normal use, and installers
should not set them.

Homebrew should use a plain `bin.install_symlink`, not
`bin.env_script_all_files`; `install.sh` should symlink `bin/bit` rather than
generate a wrapper.

## Checksums

One `SHA256SUMS` file per release covers **every** published artifact. It is
produced by `dist/release.sh` running macOS `shasum -a 256`, so it is the
standard two-space format with bare filenames (no directory components):

```
<64 hex>  bit-0.1.0-rc1-linux-x86_64.tar.xz
<64 hex>  bit-0.1.0-rc1-linux-aarch64.tar.xz
<64 hex>  bit-0.1.0-rc1-macos-aarch64.tar.xz
<64 hex>  bit-0.1.0-rc1.cdx.json
```

Consumers:

* Linux — `sha256sum --check --ignore-missing SHA256SUMS`
* macOS — `shasum -a 256 --check --ignore-missing SHA256SUMS`
* Anywhere — `grep " <filename>$" SHA256SUMS | cut -d' ' -f1`

A checksum mismatch must abort loudly; there is no signature layer behind it
yet, so this file is the only integrity check a downloader gets.

## How the pipeline is verified

`dist/release.sh`'s own `smoke()` function smoke-tests the **unpacked
artifact**, not the staging tree: it untars into an unrelated directory, sets
`BIT_STDLIB`/`BIT_LIBBITRT` explicitly, and requires `bit` to compile and run a
program from an unrelated cwd. Testing the shipped bytes rather than the build
tree is what caught macOS `bsdtar` writing an AppleDouble `._<name>.bit` beside
every stdlib source — files the shipped compiler then globbed as real input,
breaking every macOS artifact. A staging-tree test passed that build happily.
Keep the ordering.

The native target (`aarch64-macos`) is smoke-tested directly on the machine
cutting the release. `aarch64-linux` runs in a local Docker container;
`x86_64-linux` runs over ssh on a real x86-64 host, resolved by
`scripts/x64host.sh`. Deliberately **not** emulated for x86_64: an emulation
artifact is not a pass. No artifact is published without having executed at
least once on hardware matching its target.

## Container image

`ghcr.io/byteink/bit` is built from the release artifacts by
`docker/toolchain.Dockerfile` — not from source, so the image ships exactly the
bytes `dist/release.sh` already produced and verified. This is a separate,
manual step, by decision: unlike a draft GitHub release, a pushed container tag
is live on completion with no undraft step, so it stays out of
`dist/release.sh` on purpose. See `docker/toolchain.Dockerfile`'s own header for
the exact `docker buildx` invocation and the anonymous-pull verification.

**Ordering constraint:** push the ghcr image before deploying bitlang.org.
`bit-website/Dockerfile`'s build stage is `FROM ghcr.io/byteink/bit:<version>`
pinned to an exact tag, so a missing tag 404s that deploy.

## Version reporting

`bit version` is the supported way to ask, and installers may parse it. It
prints exactly one line, and `bit --version` / `bit -V` are accepted spellings
of the same thing:

```
$ bit version
bit 1.2.3
```

The pinned stage0 that compiles it prints the same line for its own release,
both reading `compiler/version.bit` as the single source of truth. (`bit-seed`
used to be the other half of this sentence; it was deleted in #1593.)

An unrecognised subcommand is a usage error on stderr with exit status 2; it
does **not** fall through to the banner, so a typo cannot be mistaken for a
successful version query.

### How the version is stamped

`compiler/version.bit` is the single source of truth, compiled directly into
`bit`, so:

* A release build stamps the tag by STAGING: `dist/release.sh` copies
  `compiler/` to `dist/out/stagesrc/compiler` with `version.bit` excluded and a
  generated one written in its place, then cross-builds the three targets from
  that copy. The staging is the **only** difference between a release build and
  a local one — nothing patches a source file, and the working tree stays clean.

* Nothing consults git, a tag, or the network at build time. A release tarball
  with no `.git` in it builds and reports its own version correctly.
