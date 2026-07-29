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
#   docker build -f docker/zig-linux.Dockerfile -t bit-zig-0.16.0:latest .
#   # on the x86-64 box:
#   docker build -f docker/zig-linux.Dockerfile -t bit-zig-0.16.0-amd64:latest .
#
# THE FILENAME AND THE IMAGE TAGS ARE NOW MISNOMERS, DELIBERATELY. #1871 deleted
# build.zig, so the gates run `./make` and this image installs no Zig at all.
# The names are kept because the images ALREADY BUILT under them are what the
# two gate hosts have on disk, and renaming would break both gates until someone
# rebuilt and redistributed — a change that has to be made on the hosts, not
# here. An image built from this file today simply has no Zig in it; the older
# images still carry it, harmlessly. Renaming is tracked separately.
#
# This file exists because the images were originally built ad hoc, with no
# recorded recipe — so when the suite grew a dependency the images lacked (git,
# #1818), nobody could rebuild them identically to add it.
FROM debian:bookworm

# git: the package manager (#1731-#1738) fetches dependencies by shelling out to
# it, and two test surfaces exercise that — tests/imports/pmadd_e2e and
# compiler/pmclicheck.bit. Without it the suite fails with `git: not found` and
# a bare assertion panic. macOS has git from the host, which is why this went
# unnoticed until the Linux gates ran.
# curl, ca-certificates, xz-utils: scripts/stage0.sh downloads the pinned
# previous release over https and unpacks the .tar.xz. That is the ONLY
# toolchain this image needs — the bootstrap compiler is a published bit binary,
# not a second language.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
