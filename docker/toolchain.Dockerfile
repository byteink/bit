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

# Unprivileged. The compiler only reads sources and writes outputs, so root buys
# nothing; 65532 is the conventional nonroot id. Users bind-mount their project
# over /work, so it must be writable by this uid at runtime — a bind mount keeps
# the host's ownership, which is the user's own, so this works for the common
# `-v "$PWD:/work"` case.
WORKDIR /work
USER 65532:65532

# `bit` as the entrypoint so the image behaves like the tool: arguments after the
# image name are the compiler's own (`build`, `run`, `test`, `add`, `fmt`, `lsp`).
ENTRYPOINT ["bit"]
CMD ["--version"]
