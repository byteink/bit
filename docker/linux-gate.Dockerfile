# The image the Linux hardware gates run in — scripts/arm64gate.sh (aarch64) and
# scripts/x64gate.sh (x86-64, on the box scripts/x64host.sh resolves).
#
# Built per-architecture NATIVELY, never with --platform emulation: the whole
# point of these gates is real hardware execution, so an emulated image would
# make every result arguable (see the x86-64 red-zone bug, which only a real box
# settled). `./make test` inside resolves the host triple from the container's
# own arch.
#
#   # on the aarch64 host (this Mac):
#   docker build -f docker/linux-gate.Dockerfile -t bit-linux-gate:latest .
#   # on the x86-64 box:
#   docker build -f docker/linux-gate.Dockerfile -t bit-linux-gate-amd64:latest .
#
# The tags carry no version, on purpose: the image installs five Debian packages
# and nothing that pins a compiler, so there is no version for it to be OF. The
# thing under test arrives with the tree (`git archive HEAD`) and the bootstrap
# compiler is downloaded and digest-verified per run by scripts/stage0.sh.
#
# This file exists because the images were originally built ad hoc, with no
# recorded recipe — so when the suite grew a dependency the images lacked (git,
# #1818), nobody could rebuild them identically to add it.
FROM debian:bookworm

# git: the package manager (#1731-#1738) fetches dependencies by shelling out to
# it, and two test surfaces exercise that — _tests_/imports/pmadd_e2e and
# compiler/pmclicheck.bit. Without it the suite fails with `git: not found` and
# a bare assertion panic. macOS has git from the host, which is why this went
# unnoticed until the Linux gates ran.
# curl, ca-certificates, xz-utils: scripts/stage0.sh downloads the pinned
# previous release over https and unpacks the .tar.xz. That is the ONLY
# toolchain this image needs — the bootstrap compiler is a published bit binary,
# not a second language.
# procps: tools/build/gatesexec.bit's killTreeFnDef() call walks a killed gate's
# descendants with `pgrep -P`. Without it, `pgrep` is missing, the walk
# silently sees zero descendants (its stderr is redirected to /dev/null), and
# only the direct child gets killed on timeout (#3230, a regression of #3066).
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl xz-utils procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
