#!/usr/bin/env python3
"""Generate a CycloneDX 1.7 SBOM for a release.

    dist/sbom.py <version> <stage0-version> [<pass1-base-commit>]

<version> is the tag without its leading `v`. <stage0-version> is the pinned
bootstrap compiler's version, the one named by dist/stage0/SHA256SUMS.
1.7 (Oct 2025, ratified as ECMA-424 2nd edition) is the current spec version
per cyclonedx.org/specification/overview as of this writing; 1.6 remains
readable by every validator 1.7 is, so there is no compatibility cost to
using the newer one.

<pass1-base-commit> (#4197): present only when a runtime ABI transition
forced dist/release.sh's two-pass BIT_STAGE0_BIN bootstrap
(docs/development.md, "Landing a runtime ABI change") instead of the
ordinary single-pass `./make libbitrt && ./make`. The pinned stage0 above is
still the root either way -- pass 1 is built BY it -- this just names the
extra link the chain gained, so the claim stays re-derivable from the tag
alone rather than resting on an unre-derivable BIT_STAGE0_BIN override.

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
It is listed under metadata.tools, the schema's slot for build tooling, not as a
shipped dependency — because it is not one. Nothing else occupies that slot:
the build needs no compiler other than a previous Bit release.
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


def build_bom(version: str, stage0_version: str, pass1_base: str = "") -> Bom:
    bom = Bom()
    bom.metadata.component = Component(
        name="bit",
        type=ComponentType.APPLICATION,
        version=version,
        description="Bit compiler release artifact.",
    )
    stage0_desc = (
        "Pinned stage0: the previous bit release, digest-verified "
        "against dist/stage0/SHA256SUMS. Compiles this tree's "
        "compiler and every runtime archive linked into a bit binary."
    )
    if pass1_base:
        stage0_desc += (
            f" Reached via the two-pass BIT_STAGE0_BIN bootstrap "
            f"(#4197): pass 1 links this stage0 against runtime/** at "
            f"commit {pass1_base}, pass 2 rebuilds from pass 1."
        )
    bom.metadata.tools.components.add(
        Component(
            name="bit",
            type=ComponentType.APPLICATION,
            version=stage0_version,
            description=stage0_desc,
        )
    )
    bom.metadata.properties.add(
        Property(name="bit:vendored-dependencies", value=NO_VENDORED_DEPS)
    )
    if pass1_base:
        bom.metadata.properties.add(
            Property(name="bit:pass1-base-commit", value=pass1_base)
        )
    return bom


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("usage: sbom.py <version> <stage0-version> [<pass1-base-commit>]", file=sys.stderr)
        return 2
    version, stage0_version = sys.argv[1], sys.argv[2]
    pass1_base = sys.argv[3] if len(sys.argv) == 4 else ""
    bom = build_bom(version, stage0_version, pass1_base)
    print(JsonV1Dot7(bom).output_as_string(indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
