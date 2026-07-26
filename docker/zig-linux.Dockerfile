# The image the Linux hardware gates run in — scripts/arm64gate.sh (aarch64) and
# scripts/x64gate.sh (x86-64, on the box scripts/x64host.sh resolves).
#
# Built per-architecture NATIVELY, never with --platform emulation: the whole
# point of these gates is real hardware execution, so an emulated image would
# make every result arguable (see memory of the x86-64 red-zone bug, which only
# a real box settled). `zig build test` inside resolves host_target from the
# container's own arch.
#
#   # on the aarch64 host (this Mac):
#   docker build -f docker/zig-linux.Dockerfile -t bit-zig-0.16.0:latest .
#   # on the x86-64 box:
#   docker build -f docker/zig-linux.Dockerfile -t bit-zig-0.16.0-amd64:latest .
#
# This file exists because the images were originally built ad hoc, with no
# recorded recipe — so when the suite grew a dependency the images lacked (git,
# #1818), nobody could rebuild them identically to add it.
ARG ZIG_VERSION=0.16.0
FROM debian:bookworm

# git: the package manager (#1731-#1738) fetches dependencies by shelling out to
# it, and three test surfaces exercise that — tests/imports/pmadd_e2e,
# tests/pmimports.zig, and selfhost/pmclicheck.bit. Without it the suite fails
# three harnesses with `git: not found`, an empty failure, and a bare assertion
# panic. macOS has git from the host, which is why this went unnoticed until the
# Linux gates ran.
# ca-certificates: git over https for any fixture that needs it.
# xz-utils/curl: unpacking the zig tarball below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION
# Native arch only: dpkg's arch maps to zig's own naming. No cross-download, so
# a build on the wrong host fails loudly instead of producing an emulated image.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      arm64) ZARCH=aarch64 ;; \
      amd64) ZARCH=x86_64 ;; \
      *) echo "unsupported arch: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    /opt/zig/zig version

ENV PATH="/opt/zig:${PATH}"
WORKDIR /work
