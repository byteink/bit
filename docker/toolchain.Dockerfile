# The Bit toolchain as a container image: ghcr.io/byteink/bit.
#
#   docker run --rm -v "$PWD:/work" ghcr.io/byteink/bit build hello.bit
#
# Built from a RELEASE ARTIFACT, not from source. The tarball the release job
# already produced is the thing users install, so the image ships exactly those
# bytes — an image built separately from source could differ from the release it
# is named after, and nobody would notice.
#
# Multi-arch from prebuilt binaries: both linux tarballs go into the context and
# TARGETARCH picks one, so `buildx --platform linux/amd64,linux/arm64` produces a
# real manifest list without emulating a compile.

FROM alpine:3.24

LABEL org.opencontainers.image.title="Bit" \
      org.opencontainers.image.description="The Bit compiler toolchain: a systems language with TypeScript-flavored syntax and Go-like semantics." \
      org.opencontainers.image.source="https://github.com/byteink/bit" \
      org.opencontainers.image.url="https://bitlang.org" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="byteink"

# git, because the package manager shells out to it: `bit add <gitURL>` clones
# into the content-addressed cache. A toolchain image without git can compile but
# cannot resolve a dependency — this was learned the hard way when the test
# images lacked it and three unrelated harnesses went red.
#
# ca-certificates for https git remotes. Nothing else: the compiler is a static
# binary with no libc dependency, so there is no runtime to install.
RUN apk add --no-cache git ca-certificates

# Both linux artifacts; the RUN below keeps the one matching this platform.
ARG BIT_VERSION
COPY dist/out/*.tar.xz /tmp/

# TARGETARCH is set by buildx per platform (amd64 | arm64) and maps to the
# artifact naming contract in dist/README.md (x86_64 | aarch64).
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH '${TARGETARCH}'" >&2; exit 1 ;; \
    esac; \
    tar -C /opt -xf "/tmp/bit-${BIT_VERSION}-linux-${arch}.tar.xz"; \
    mv "/opt/bit-${BIT_VERSION}-linux-${arch}" /opt/bit; \
    rm -f /tmp/*.tar.xz; \
    # bin/bit resolves stdlib and libbitrt from its OWN location, so a symlink on
    # PATH is all that is needed — no wrapper, no env vars (dist/README.md's
    # "Path resolution"). Verified below rather than assumed.
    ln -s /opt/bit/bin/bit /usr/local/bin/bit; \
    cd /tmp && printf 'function main() {\n  print("toolchain ok\\n")\n}\n' > t.bit; \
    bit run t.bit; \
    rm -f /tmp/t.bit

# Unprivileged by default. The compiler reads sources and writes outputs, so root
# buys nothing, and 65532 is the conventional nonroot id.
#
# THE BIND-MOUNT CONSEQUENCE, measured rather than assumed: a bind mount keeps the
# HOST's ownership, so this uid can read a world-readable project (`bit run` works)
# but cannot create files in one owned by someone else — `bit build -o out` fails
# with "cannot create file". A project directory at mode 0700 is not even readable
# ("not a module", confusingly).
#
# The fix is the standard one, and it is in the README:
#
#     docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" ghcr.io/byteink/bit build x.bit
#
# Verified on real x86-64: the output is then owned by the invoking user, mode
# 0755, and executes on the host. The alternative — dropping USER so the container
# runs as root — writes root-owned binaries into a user's source tree, which is a
# worse default than a documented flag.
WORKDIR /work
USER 65532:65532

# `bit` as the entrypoint so the image behaves like the tool: arguments after the
# image name are the compiler's own (`build`, `run`, `test`, `add`, `fmt`, `lsp`).
ENTRYPOINT ["bit"]
CMD ["--version"]
