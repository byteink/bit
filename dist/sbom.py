#!/usr/bin/env python3
"""Generate a CycloneDX 1.7 SBOM for a release.

    dist/sbom.py <version> <stage0-version>

<version> is the tag without its leading `v`. <stage0-version> is the pinned
bootstrap compiler's version, the one named by dist/stage0/SHA256SUMS.
1.7 (Oct 2025, ratified as ECMA-424 2nd edition) is the current spec version
per cyclonedx.org/specification/overview as of this writing; 1.6 remains
readable by every validator 1.7 is, so there is no compatibility cost to
using the newer one.

Uses the official cyclonedx-python-lib (dist/sbom-requirements.txt pins the
version) to build and serialise the document, so the output is
schema-conformant by construction rather than hand-rolled JSON. This is the
one script in dist/ written in Python rather than bash: CycloneDX has no
Bash-native generator, and hand-writing the schema in bash is exactly what
this must not do. Prints the BOM as JSON to stdout; the caller redirects it
to bit-<version>.cdx.json (dist/README.md naming).

Bit has no ecosystem-specific CycloneDX generator and no package manifest for a
scanner to read, so this is written directly against the model rather than an
autodetecting scanner.

The one real "component" in this build is the PINNED STAGE0 — the previous Bit
release, which compiles this tree's compiler and every linked runtime archive.
Until #1871 that slot held the Zig toolchain; `build.zig` and the Zig pin are
gone, and nothing replaced them, so the build tooling is now a Bit binary. It is
listed under metadata.tools, the schema's slot for build tooling, not as a
shipped dependency — because it is not one.
"""
import sys

from cyclonedx.model import Property
from cyclonedx.model.bom import Bom
from cyclonedx.model.component import Component, ComponentType
from cyclonedx.output.json import JsonV1Dot7

NO_VENDORED_DEPS = (
    "bit vendors no third-party source and declares no package dependencies; "
    "the pinned stage0 compiler listed under metadata.tools is the only "
    "external component in this build, and it is a prior bit release."
)


def build_bom(version: str, stage0_version: str) -> Bom:
    bom = Bom()
    bom.metadata.component = Component(
        name="bit",
        type=ComponentType.APPLICATION,
        version=version,
        description="Bit compiler release artifact.",
    )
    bom.metadata.tools.components.add(
        Component(
            name="bit",
            type=ComponentType.APPLICATION,
            version=stage0_version,
            description=(
                "Pinned stage0: the previous bit release, digest-verified "
                "against dist/stage0/SHA256SUMS. Compiles this tree's "
                "compiler and every runtime archive linked into a bit binary."
            ),
        )
    )
    bom.metadata.properties.add(
        Property(name="bit:vendored-dependencies", value=NO_VENDORED_DEPS)
    )
    return bom


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sbom.py <version> <stage0-version>", file=sys.stderr)
        return 2
    _, version, stage0_version = sys.argv
    bom = build_bom(version, stage0_version)
    print(JsonV1Dot7(bom).output_as_string(indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
