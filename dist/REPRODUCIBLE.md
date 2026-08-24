# Reproducing a release — for anyone, not just the maintainer

This is written for a party who has **none of this repository's tacit
knowledge**: no worktree, no `bit-out` cache, no idea what `./make` resolves
internally. All you start with is a published release tag, a published
`SHA256SUMS`, and this document.

What it proves: the `bit` binary a release ships is exactly what its published
source, built with its own pinned stage0, produces. It is option 3 of
`docs/release/bootstrap.md` §5's decision table — diverse double-compiling —
and this file is what makes that option something an outside party can
actually run, not just something the maintainer can claim.

What it does **not** prove: that the pinned stage0 itself has no backdoor with
no source-level trace (`docs/release/bootstrap.md` §5(a) states that limit
plainly). Rebuilding from a tag you don't trust the stage0 lineage of proves
only that the rebuild is faithful to that lineage, whatever it is.

## What you need

Exactly what building `bit` from source already needs (see the repo's own
`README.md` → "Build from source"): `git`, `sh`, `curl`, `tar`, and either
`sha256sum` or `shasum` to compare digests. No C compiler, no Zig, nothing
target-specific. `bit` builds itself; nothing here adds a second toolchain
requirement on top of that.

## The sequence

```sh
git clone https://github.com/byteink/bit.git
cd bit
git checkout v<version>                 # the exact tag you are verifying

mkdir -p /tmp/published && cd /tmp/published
curl -fsSLO "https://github.com/byteink/bit/releases/download/v<version>/bit-<version>-linux-x86_64.tar.xz"
curl -fsSLO "https://github.com/byteink/bit/releases/download/v<version>/bit-<version>-linux-aarch64.tar.xz"
curl -fsSLO "https://github.com/byteink/bit/releases/download/v<version>/bit-<version>-macos-aarch64.tar.xz"
curl -fsSLO "https://github.com/byteink/bit/releases/download/v<version>/SHA256SUMS"
cd -

scripts/verify-reproducible-release.sh "v<version>" /tmp/published
```

`scripts/verify-reproducible-release.sh` is not internal-only tooling — it is
committed in this repo, so it travels with the clone above. It rebuilds all
three shipping targets (`x86_64-linux`, `aarch64-linux`, `aarch64-macos`) from
the tag's own source using the tag's own pinned stage0
(`dist/stage0/SHA256SUMS`, also committed, also in your clone — no digest is
trusted from anywhere else), packages them exactly as `dist/release.sh` does,
and diffs the unpacked contents plus a per-file `sha256` against what you
downloaded. `all 3 shipping artifacts rebuild bit-identical to <tag>` on stdout
and exit 0 is the pass; any `CONTENT differs` or `FILE TREE differs` names the
offending file and exits 1.

The script cross-builds all three targets regardless of which platform you run
it from — it is a genuine cross-compile, not three native builds — so this
works the same on Linux or macOS, and even inside a Linux container on a
machine with no macOS in sight, verified below.

## The one gotcha if you rebuild by hand instead of via the script

`bit` on macOS embeds the **output filename** into the Mach-O code signature.
Two byte-identical compilers built to different `-o` paths will differ for a
reason that has nothing to do with reproducibility. If you skip the script and
follow `docs/release/bootstrap.md` §1's L0/C1/L1/C2 chain yourself, build to
`bin/bit` — the exact relative path `dist/package.sh` ships inside every
archive — not an arbitrary name. The script already does this correctly; this
note is for anyone re-deriving the steps manually.

## Demonstrated end-to-end, on a machine that did not produce the release

Run 2026-08-24, tag `v0.1.25`, inside a throwaway `debian:bookworm-slim`
container (`docker run --rm --platform linux/arm64`, no bind mount of any host
state — a genuine fresh `git clone` and fresh downloads inside the container),
on the same machine that maintains this repo but an environment that built
none of the published bytes: no host `bit-out`, no host git objects, no shared
filesystem with the release-cutting checkout. Full sequence above, run
verbatim, output trimmed to the verdict lines:

```
L1: building runtime archive for x86_64-linux with bit1...
g2archive: OK — x86_64-linux, 25 objects, .../lib1/x86_64-linux/libbitrt.a (785764 bytes)
L1: building runtime archive for aarch64-linux with bit1...
g2archive: OK — aarch64-linux, 25 objects, .../lib1/aarch64-linux/libbitrt.a (636676 bytes)
L1: building runtime archive for aarch64-macos with bit1...
g2archive: OK — aarch64-macos, 25 objects, .../lib1/aarch64-macos/libbitrt.a (524460 bytes)
C2: rebuilding x86_64-linux with bit1...
x86_64-linux: OK — bit-identical to published bit-0.1.25-linux-x86_64.tar.xz
C2: rebuilding aarch64-linux with bit1...
aarch64-linux: OK — bit-identical to published bit-0.1.25-linux-aarch64.tar.xz
C2: rebuilding aarch64-macos with bit1...
aarch64-macos: OK — bit-identical to published bit-0.1.25-macos-aarch64.tar.xz
all 3 shipping artifacts rebuild bit-identical to v0.1.25
```

`$?` of the script, captured directly (not through a pipe): `0`.

Independent digest check on top of the script's own tree-diff, extracted
`bin/bit` for `aarch64-linux`, published vs rebuilt:

```
published: e06b170100b8d0c18c7a01e958015ea38bfc9358f189a73ead9daee3102cf248
rebuilt:   e06b170100b8d0c18c7a01e958015ea38bfc9358f189a73ead9daee3102cf248
```

Exact match. Note the **compressed tarball's own** sha256 does *not* match
between published and rebuilt (`ff135151...` vs `f3c44740...`) — expected and
already documented in the script's header: this container's `xz` reduced its
thread count to fit a memory limit, which changes the compressed container's
bytes without changing what unpacks. The public contract
(`dist/README.md` → "Checksums") is over the unpacked content, which this
check confirms byte-for-byte; `dist/package.sh` does not attempt to pin `xz`'s
internal thread count or version.

`aarch64-macos` is the interesting one here: it was cross-built and compared
bit-identical from inside a Linux container with **no macOS present at all**,
which is the strongest available evidence that the Mach-O codesign/filename
gotcha above is handled correctly by the script rather than by something
specific to building on the same OS the release was cut on.
