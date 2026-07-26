#!/usr/bin/env python3
"""Generate a CycloneDX 1.7 SBOM for a release.

    dist/sbom.py <version> <zig-version>

<version> is the tag without its leading `v`. <zig-version> is the pinned
seed toolchain version (.zigversion / build.zig.zon's minimum_zig_version).
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

Bit has no ecosystem-specific CycloneDX generator (build.zig.zon has no
`.dependencies` field today, and the wider Zig tooling has no PURL type yet),
so this is written directly against the model rather than an autodetecting
scanner. The Zig toolchain is the one real "component" in this build: it
compiles the bootstrap seed and every linked runtime archive. It is listed
under metadata.tools, the schema's slot for build tooling, not as a shipped
dependency — because it is not one.
"""
import sys

from cyclonedx.model import Property
from cyclonedx.model.bom import Bom
from cyclonedx.model.component import Component, ComponentType
from cyclonedx.output.json import JsonV1Dot7

NO_VENDORED_DEPS = (
    "bit vendors no third-party source and build.zig.zon declares no "
    "dependencies; the Zig seed toolchain listed under metadata.tools is the "
    "only external component in this build."
)


def build_bom(version: str, zig_version: str) -> Bom:
    bom = Bom()
    bom.metadata.component = Component(
        name="bit",
        type=ComponentType.APPLICATION,
        version=version,
        description="Bit compiler release artifact.",
    )
    bom.metadata.tools.components.add(
        Component(
            name="zig",
            type=ComponentType.APPLICATION,
            version=zig_version,
            description=(
                "Pinned seed toolchain: builds the bootstrap seed compiler "
                "and every runtime archive linked into a bit binary."
            ),
        )
    )
    bom.metadata.properties.add(
        Property(name="bit:vendored-dependencies", value=NO_VENDORED_DEPS)
    )
    return bom


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sbom.py <version> <zig-version>", file=sys.stderr)
        return 2
    _, version, zig_version = sys.argv
    bom = build_bom(version, zig_version)
    print(JsonV1Dot7(bom).output_as_string(indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
