# Bit release artifacts — the packaging contract

This file is the contract between the release pipeline
(`.github/workflows/release.yml`, task #358) and everything downstream that
consumes a published release: the Homebrew tap (#359), the `curl | sh`
installer (#360), and the PowerShell/winget path (#361). Change this file first,
then the pipeline, then the consumers.

## Which targets actually ship

The compiler has three build targets — `bit build --target` accepts exactly
`x86_64-linux`, `aarch64-linux`, `aarch64-macos` (`selfhost/main.bit`,
`parseBuildTarget`). Those three, and only those three, are published today.

| target | artifact | status |
|---|---|---|
| `x86_64-linux`  | `bit-<version>-linux-x86_64.tar.xz`  | shipping |
| `aarch64-linux` | `bit-<version>-linux-aarch64.tar.xz` | shipping |
| `aarch64-macos` | `bit-<version>-macos-aarch64.tar.xz` | shipping |
| `x86_64-macos`  | `bit-<version>-macos-x86_64.tar.xz`  | **not built** — the Mach-O linker has no x86-64 relocation support; `zig build libbitrt` emits the archive but no compiler target selects it |
| `x86_64-windows` | `bit-<version>-windows-x86_64.zip`  | **not built** — blocked on #1103 (PE/COFF writer); the runtime also `@compileError`s outside POSIX |
| `aarch64-windows` | `bit-<version>-windows-aarch64.zip` | **not built** — same blockers as above |

The workflow's `dist-*` jobs take the target as a matrix entry, so enabling a
target later is one matrix line plus one `case` arm in `dist/package.sh`. Do not
publish a placeholder for an unbuilt target: a missing artifact is a clear
failure downstream, a broken one is a silent one.

## Naming

```
bit-<version>-<os>-<arch>.tar.xz      # linux, macos
bit-<version>-<os>-<arch>.zip         # windows, when it exists
```

* `<version>` — the git tag with its leading `v` stripped. `v0.1.0-rc1` →
  `0.1.0-rc1`.
* `<os>` — `linux` | `macos` | `windows`.
* `<arch>` — `x86_64` | `aarch64`. These match the compiler's own target
  spelling, not `uname -m`. Installers must map: Linux `uname -m` already
  reports `x86_64`/`aarch64`, but macOS reports `arm64` for `aarch64`.

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

## Required environment — read this before writing an installer

`bin/bit` resolves the standard library and the runtime archive from
**cwd-relative default paths** (`stdlib` and `zig-out/lib/<triple>/libbitrt.a`),
so an installed binary invoked from a user's own directory cannot find either.
Both are overridable, and an installer **must** set them:

```sh
BIT_STDLIB=<prefix>/stdlib
BIT_LIBBITRT=<prefix>/lib/<native-triple>/libbitrt.a
```

Verified working: with both set, a `bit` binary outside the repo compiles and
runs a program from an unrelated directory.

Two consequences installers must handle:

* `BIT_LIBBITRT` names **one** archive, so an install wired this way can only
  build for its own host. Cross-compiling with `--target` needs the variable
  re-pointed at the matching triple. Document it; do not hide it.
* Because the variables are required, ship a wrapper or a profile export rather
  than a bare symlink into `PATH`. Homebrew: `bin.env_script_all_files`.
  `install.sh`: a `bin/bit` wrapper in `~/.bit/bin` that exports both and
  `exec`s the real binary.

Resolving these paths against the binary's own install prefix is the real fix
and belongs in the compiler (both `selfhost/main.bit` and `seed/main.zig` carry
a `ponytail:` note saying so, deferred to this task). Until that lands, the env
contract above is the supported install path.

## Checksums

One `SHA256SUMS` file per release covers **every** published artifact. It is
produced by GNU `sha256sum` on the release job, so it is the standard two-space
format with bare filenames (no directory components):

```
<64 hex>  bit-0.1.0-rc1-linux-x86_64.tar.xz
<64 hex>  bit-0.1.0-rc1-linux-aarch64.tar.xz
<64 hex>  bit-0.1.0-rc1-macos-aarch64.tar.xz
```

Consumers:

* Linux — `sha256sum --check --ignore-missing SHA256SUMS`
* macOS — `shasum -a 256 --check --ignore-missing SHA256SUMS`
* Anywhere — `grep " <filename>$" SHA256SUMS | cut -d' ' -f1`

A checksum mismatch must abort loudly; there is no signature layer behind it
yet, so this file is the only integrity check a downloader gets.

## How the pipeline is verified

The `dist` job smoke-tests the **unpacked artifact**, not the staging tree: it
untars into an unrelated directory, sets only the two variables above, and
requires `bit` to compile and run a program. Testing the shipped bytes rather
than the build tree is what caught macOS `bsdtar` writing an AppleDouble
`._<name>.bit` beside every stdlib source — files the shipped compiler then
globbed as real input, breaking every macOS artifact. A staging-tree test passed
that build happily. Keep the ordering.

Cross-built targets are smoke-tested under `qemu-user-static` on the runner, so
no artifact is published without having executed at least once.

## Version reporting

`bit` prints its version on a bare invocation:

```
$ bit
bit (self-host, seed-built) 0.1.0-stub — selfcheck OK
```

Two known gaps, both needing a compiler change and both tracked against #365:

* There is no real `version` subcommand — `bit version` only prints the same
  banner because unrecognised arguments fall through to the default path.
* The printed string is the hardcoded `selfhostVersion` in
  `selfhost/version.bit`; it is **not** stamped from the release tag. Do not
  parse it to determine the installed release. Installers should record the
  version they downloaded.
