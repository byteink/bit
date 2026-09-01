#!/usr/bin/env bash
# Cut a release from THIS machine. Bit does not use GitHub Actions.
#
#   dist/release.sh <version>            # build, verify, upload as a draft
#   dist/release.sh <version> --dry-run  # build and verify, publish nothing
#
# <version> is semver without the leading v, e.g. 0.1.0.
#
# This replaces the deleted .github/workflows/release.yml. It is not a
# translation of it — a workflow can assume a clean runner per job, and this
# cannot, so every step that mattered there is done here explicitly:
#
#   1. bootstrap a native host `bit1` off the PINNED STAGE0 — compiler/ built by
#      stage0, linking a stage0-built runtime archive. That is stage0's only
#      role below (#3034)
#   2. bit1 builds the SHIPPED runtime archive and the SHIPPED `bit`, for every
#      target (the packaged compiler carries all three runtime archives so one
#      install can cross-compile) — this tree's own codegen, not stage0's; for
#      the host triple, the shipped `bit` must reproducibly build itself before
#      anything is packaged
#   3. dist/package.sh per target
#   4. smoke-test each UNPACKED artifact by compiling and running a program, on
#      hardware that matches it. Not the staging tree: the bytes that ship are
#      the only thing worth testing, and this is what caught macOS serialising
#      xattrs into every member.
#   5. generate a CycloneDX SBOM (dist/sbom.py) in a throwaway venv
#   6. SHA256SUMS over every artifact, including the SBOM
#   7. release notes from conventional commits
#   8. `gh release create --draft` and upload
#
# Nothing here needs a token beyond the `gh` login already on this machine.
set -euo pipefail

VERSION="${1:?usage: dist/release.sh <version> [--dry-run]}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || {
	echo "release.sh: '${VERSION}' is not a semver version" >&2
	exit 2
}

ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${ROOT}/dist/out"
cd "${ROOT}"

command -v gh >/dev/null || { echo "release.sh: gh not found" >&2; exit 1; }

# A release must come from a clean tree at a tagged commit, or the artifacts
# cannot be traced back to source. Checked first, before any minutes are spent.
git diff --quiet || { echo "release.sh: working tree is dirty" >&2; exit 1; }
git diff --cached --quiet || { echo "release.sh: staged changes present" >&2; exit 1; }

# THE COMMIT THE ARTIFACTS ARE BUILT FROM, resolved here and nowhere else (#1856).
# The two checks above have just established that the tree equals HEAD, so HEAD
# names the exact source of everything built below. `gh release create` defaults a
# new tag to the DEFAULT BRANCH'S REMOTE HEAD, not to the local tree, so without
# passing this explicitly a release cut while origin/main is ahead — or from any
# branch at all — tags a commit whose source was never compiled. v0.1.3 shipped
# that way. Captured before the build rather than after so a commit landing mid-run
# cannot move it.
BUILT_COMMIT="$(git rev-parse HEAD)"

# --- preflight: confirm both smoke-test images exist BEFORE cross-building ---
# (#2930). "the artifact is broken" and "the verifier is not provisioned" are
# opposite conclusions. Without this, a missing image is discovered ~11 minutes
# in, at the smoke step (:424, :455 below) — and the remote docker daemon's own
# "Unable to find image ... locally" / "pull access denied" lines land in the
# same log stream three lines above THIS script's failure message, reading as a
# local defect in the release rather than an unprovisioned verifier. For an
# x86-64 target that misreading is this repo's signature for an ABI-boundary
# bug, the most expensive thing it could be mistaken for. So check now, while
# nothing has been built yet, and name the host, the tag and the fix.
GATE_IMAGE_LOCAL="bit-linux-gate:latest"
GATE_IMAGE_REMOTE="bit-linux-gate-amd64:latest"

command -v docker >/dev/null || { echo "release.sh: docker not found" >&2; exit 1; }

docker image inspect "${GATE_IMAGE_LOCAL}" >/dev/null 2>&1 || {
	echo "release.sh: image '${GATE_IMAGE_LOCAL}' not found locally (needed to smoke-test aarch64-linux)" >&2
	echo "  build it:" >&2
	echo "    docker build -t ${GATE_IMAGE_LOCAL} -f docker/linux-gate.Dockerfile ." >&2
	exit 1
}

# Resolved once, here, deliberately BEFORE the "no x86-64 host reachable" check
# further down (:434-465), which can be reached only after ~11 minutes of
# building — that refusal is correct but too late to save the time.
X64_HOST="$(sh scripts/x64host.sh 2>/dev/null | head -1 || true)"
if [ -z "${X64_HOST}" ]; then
	echo "release.sh: no x86-64 host reachable — cannot verify x86_64-linux" >&2
	echo "release.sh: refusing to publish an unverified release" >&2
	exit 1
fi
ssh "${X64_HOST}" "docker image inspect ${GATE_IMAGE_REMOTE}" >/dev/null 2>&1 || {
	echo "release.sh: image '${GATE_IMAGE_REMOTE}' not found on ${X64_HOST} (needed to smoke-test x86_64-linux)" >&2
	echo "  provision it:" >&2
	echo "    ssh ${X64_HOST} 'mkdir -p /tmp/bitgate && cd /tmp/bitgate && \\" >&2
	echo "      docker build -t ${GATE_IMAGE_REMOTE} -f - .' < docker/linux-gate.Dockerfile" >&2
	exit 1
}
echo "release.sh: gate images present (${GATE_IMAGE_LOCAL} local, ${GATE_IMAGE_REMOTE} on ${X64_HOST})"

# --- preflight: SBOM venv reachability + hash integrity (#2802) -------------
# dist/sbom.py needs cyclonedx-python-lib, which this Mac does not carry
# system-wide (#2748). `pip install --require-hashes` against
# dist/sbom-requirements.txt is the ONLY step in this whole release that
# needs PyPI, and it used to run after the three cross-builds and their
# on-hardware smoke tests — about 10 minutes in — so an unreachable PyPI or a
# stale mirror cost the operator the whole run, discovered far too late to be
# useful. Resolve it now, before anything is built. ${SBOM_VENV} stays alive
# across the whole build; the actual `dist/sbom.py` invocation still happens
# at its original site near the checksums, since its output path depends on
# ${OUT} — this only moves WHEN reachability and hash integrity are checked,
# never weakens --require-hashes, and never installs anything outside this
# throwaway venv.
echo "release.sh: preflighting the SBOM venv (dist/sbom-requirements.txt)"
SBOM_VENV="$(mktemp -d)"
python3 -m venv "${SBOM_VENV}"
"${SBOM_VENV}/bin/pip" install --quiet --require-hashes -r dist/sbom-requirements.txt || {
	echo "release.sh: could not install dist/sbom-requirements.txt into a throwaway venv" >&2
	echo "  either PyPI is unreachable (check network / PIP_INDEX_URL) or a hash in" >&2
	echo "  that file no longer matches the package it pins. Diagnose with:" >&2
	echo "    python3 -m venv /tmp/sbomcheck && /tmp/sbomcheck/bin/pip install --require-hashes -r dist/sbom-requirements.txt -v; rm -rf /tmp/sbomcheck" >&2
	echo "  then fix the network path or repin dist/sbom-requirements.txt and retry." >&2
	rm -rf "${SBOM_VENV}"
	exit 1
}
echo "release.sh: SBOM dependencies resolved"

TARGETS=(x86_64-linux aarch64-linux aarch64-macos)

echo "release.sh: building the bootstrap runtime archives (L0, stage0-built)"
./make libbitrt

echo "release.sh: resolving the pinned stage0"
# Downloads + digest-verifies against dist/stage0/SHA256SUMS; refuses on failure.
STAGE0="$(sh scripts/stage0.sh)"
echo "release.sh: stage0 = ${STAGE0}"
# The SBOM's metadata.tools entry names stage0 by VERSION, not by path. Asking
# the resolved binary itself (rather than re-parsing dist/stage0/SHA256SUMS'
# header comment) means there is one source of truth for which release stage0
# is — the same one scripts/stage0.sh already verified the digest of.
STAGE0_VERSION="$("${STAGE0}" version | awk '{print $2}')"
echo "release.sh: stage0 version = ${STAGE0_VERSION}"

# C1 (#3034): stage0 builds compiler/ AS IT SITS ON DISK (unstamped — the
# version stamp below is for the STAGED copy the shipped binaries come from),
# for the HOST triple only, linking the L0 archive `./make libbitrt` just
# built. This is stage0's entire job in this script: bit1 is a native host
# binary exactly like stage0 itself, so it can cross-produce every shipped
# target below the same way stage0 always has. `./make` is `install`, which
# depends on `selfhost` which depends on `libbitrt` — both already satisfied
# or cheaply re-verified by the call above.
echo "release.sh: bootstrapping the host self-hosted compiler with stage0 (bit1)"
./make
BIT1="${ROOT}/bit-out/bin/bit"
[ -x "${BIT1}" ] || { echo "release.sh: ./make did not produce ${BIT1}" >&2; exit 1; }
# `stepSelfhost` (tools/build/artifactsteps.bit) writes this on every `./make`
# call, unconditionally, before its own up-to-date check — so it is reliably
# fresh here without release.sh reimplementing the uname table.
HOST_TRIPLE="$(cat "${ROOT}/bit-out/make/host.triple" 2>/dev/null || true)"
[ -n "${HOST_TRIPLE}" ] || {
	echo "release.sh: could not read bit-out/make/host.triple after ./make" >&2
	exit 1
}
echo "release.sh: bit1 = ${BIT1} (host triple ${HOST_TRIPLE})"

rm -rf "${OUT}"
mkdir -p "${OUT}"

# Stamp the version into a STAGED COPY of compiler/, never into the source tree.
#
# `compiler/version.bit` holds the checked-in development version, and the
# self-hosted compiler compiles that constant directly — so building compiler/ as
# it sits on disk ships a binary that reports `0.1.0-dev` no matter what version we
# are releasing. v0.1.0 shipped exactly that bug: `bit --version` said 0.1.0-dev.
#
# This IS the version-stamping mechanism — there is no build-driver option for
# it, and there should not be: a release needs three CROSS-built targets, and a
# driver flag would only ever stamp the one native compiler.
#
# EXCLUDE the real version.bit rather than overwriting it afterwards: two files
# declaring `bitVersion` is a duplicate-symbol error, and a copy-then-overwrite
# that silently loses the race leaves the dev version in place.
# Basename stays `selfhost`: the directory name is the module name, so a staged
# copy called anything else is not a drop-in substitute for the real thing.
STAGE_SRC="${OUT}/stagesrc/compiler"
mkdir -p "${STAGE_SRC}"
find compiler -maxdepth 1 -name '*.bit' ! -name 'version.bit' -exec cp {} "${STAGE_SRC}/" \;
printf '// Generated by dist/release.sh. Source of truth: compiler/version.bit.\nconst bitVersion: string = "%s"\n' \
	"${VERSION}" > "${STAGE_SRC}/version.bit"
decls="$(grep -l 'const bitVersion' "${STAGE_SRC}"/*.bit | wc -l | tr -d ' ')"
[ "${decls}" = "1" ] || {
	echo "release.sh: staged tree declares bitVersion ${decls} times, expected 1" >&2
	exit 1
}
staged="$(ls "${STAGE_SRC}"/*.bit | wc -l | tr -d ' ')"
real="$(find compiler -maxdepth 1 -name '*.bit' | wc -l | tr -d ' ')"
[ "${staged}" = "${real}" ] || {
	echo "release.sh: staged ${staged} of ${real} selfhost files — the copy lost some" >&2
	exit 1
}

# L1 (#3034): bit1 — this tree's own codegen, not stage0's — compiles
# runtime/ for every target. This is the half that reaches every user program
# (#2213), so from here on it is built by THIS tree, not stage0.
#
# WRITTEN UNDER ${OUT}, NEVER INTO THE SHARED `bit-out/lib/` — a real defect
# found by measurement, not review, in this ticket's first pass: `bit-out/lib`
# is the same path `./make libbitrt` writes and staleness-checks by a
# fingerprint over runtime/** SOURCE, not over which compiler produced the
# archive on disk. Writing L1 there made a SECOND `release.sh` run in the same
# tree see "up to date" over an archive that was actually the FIRST run's L1
# output — silently turning "rooted at stage0" false on the second run, and
# blind to it. Building here, all three up front (mirroring how `./make
# libbitrt` builds all three before anything reads them, since `package.sh`
# below embeds all three archives in every target's tarball regardless of
# which target it is packaging), keeps `bit-out/` untouched by this script and
# `./make libbitrt` genuinely idempotent.
LIB1="${OUT}/lib1"
for t in "${TARGETS[@]}"; do
	echo "release.sh: L1 ${t}"
	l1scratch="$(mktemp -d)"
	BIT="${BIT1}" bash scripts/g2archive.sh "${t}" "${l1scratch}/libbitrt.a"
	mkdir -p "${LIB1}/${t}"
	cp "${l1scratch}/libbitrt.a" "${LIB1}/${t}/libbitrt.a"
	rm -rf "${l1scratch}"
done

for t in "${TARGETS[@]}"; do
	echo "release.sh: ${t}"
	rm -rf "${OUT}/stage"
	mkdir -p "${OUT}/stage/bin"

	archive="${LIB1}/${t}/libbitrt.a"

	# C2 (#3034): bit1 builds the STAGED, version-stamped compiler/ for ${t},
	# linking L1 — this IS the shipped `bin/bit`. Not stage0: a release is no
	# longer produced by the previous release now that this tree's own
	# compiler is proven, once below, to reliably build itself.
	#
	# BIT_LIBBITRT IS STILL LOAD-BEARING (#2213, unchanged by #3034): bit1
	# resolves `libbitrt.a` relative to itself absent an override, which is
	# `bit-out/lib/${t}/libbitrt.a` (the L0 archive) — never ${archive}, since
	# L1 now lives entirely under ${OUT} and bit1's sibling `lib/` cannot see
	# it. Without this override the build would silently link L0 (stage0's
	# codegen) instead of L1, defeating the whole point of this pass.
	[ -f "${archive}" ] || {
		echo "release.sh: missing ${archive} (the L1 build above should have written it)" >&2
		exit 1
	}
	BIT_LIBBITRT="${archive}" \
		"${BIT1}" build "${STAGE_SRC}" --target "${t}" -o "${OUT}/stage/bin/bit"
	chmod +x "${OUT}/stage/bin/bit"

	if [ "${t}" = "${HOST_TRIPLE}" ]; then
		# C3, HOST TRIPLE ONLY (#3034): the shipped `bit` (bit2) must
		# reproducibly build itself (bit3) from the same staged source and the
		# same L1 archive, before anything is packaged. This is the standard
		# fixed-point mitigation for a compiler that now compiles itself into
		# what ships — reusing scripts/selfhost-fixpoint.sh's rule rather than
		# re-deriving it: the Mach-O codesign identifier derives from the
		# output FILENAME, so bit2 and bit3 are written to the SAME basename
		# ("bit") in DIFFERENT directories, or the hashes differ for a reason
		# that has nothing to do with codegen.
		#
		# HOST-ONLY, DELIBERATELY: a bit2 built for x86_64-linux or
		# aarch64-linux cannot run on this Mac to build a bit3 of its own, so
		# this proves nothing about those two targets' self-reproducibility —
		# only that bit1 cross-produced them, the same guarantee stage0's
		# cross-production always carried.
		echo "release.sh: fixed-point check for ${t} — bit2 must reproducibly build bit3"
		mkdir -p "${OUT}/fixpoint/bin"
		BIT_LIBBITRT="${archive}" \
			"${OUT}/stage/bin/bit" build "${STAGE_SRC}" --target "${t}" -o "${OUT}/fixpoint/bin/bit"
		bit2Sha="$(shasum -a 256 "${OUT}/stage/bin/bit" | cut -d' ' -f1)"
		bit3Sha="$(shasum -a 256 "${OUT}/fixpoint/bin/bit" | cut -d' ' -f1)"
		echo "release.sh: bit2 sha256 = ${bit2Sha}"
		echo "release.sh: bit3 sha256 = ${bit3Sha}"
		rm -rf "${OUT}/fixpoint"
		[ "${bit2Sha}" = "${bit3Sha}" ] || {
			echo "release.sh: FIXED POINT BROKEN for ${t} — bit2 != bit3. This tree's compiler" >&2
			echo "  does not reliably build itself, so shipping it as bin/bit is unsafe. Refusing." >&2
			exit 1
		}
		echo "release.sh: FIXED POINT OK for ${t} — bit2 == bit3"
	fi

	bash dist/package.sh "${VERSION}" "${t}" "${OUT}" "${LIB1}"
done

# --- packaged-runtime atomic-width probe (#2742, #2744) ---------------------
#
# The probe above (#2213) catches a STALE runtime; this one catches WRONG
# CODEGEN in a runtime that is otherwise current. `bit_rt_spin_try_acquire`
# and `bit_rt_spin_release` (runtime/spinlock.bit:61,118) take `p: *i32`
# (spinUnlocked is declared `i32` at :46), so every aarch64 exclusive-access
# instruction inside them must address a 32-bit word — `ldaxr`/`stlxr`/
# `stlr`/`ldar` through a `w` register, never `x`. #2742 shipped the `x` form
# in 0.1.11 unnoticed because nothing here looked for it.
#
# aarch64 ONLY. x86 atomics carry width in the OPERAND SIZE (`lock cmpxchg
# %eax,(%rdi)` vs `%rax,(%rdi)`), not in a distinct register name the way
# aarch64's w/x split does, so there is no equivalent single-mnemonic check
# for x86_64-linux. Skipped on purpose, not an oversight.
#
# A HIT HERE IS NOW A REAL DEFECT (#3034), not a known, tolerated lag. Before
# #3034 the packaged runtime came from `./make libbitrt`'s PINNED STAGE0 build
# (see `stepLibbitrt` in tools/build/artifactsteps.bit) and a codegen fix landing
# in this tree could not reach it until the stage0 pin moved past the release
# carrying the fix — 0.1.11 shipped the #2742 bug unnoticed exactly that way.
# `stepLibbitrt` is unchanged (#3034's constraint: the L0 archive it produces
# is still stage0-built, and still only bootstraps bit1 above), but the
# archive this probe actually reads is packaged from L1 — bit1's own codegen —
# so a failure here means THIS TREE'S compiler still emits the 64-bit form,
# not that the fix is waiting on a pin.

# <archive> <symbol-spelling-as-it-appears-in-the-object> <triple>
# <bit_rt-name-for-messages>. Returns 0 clean, 1 a 64-bit hit, 2 this spelling
# of the symbol is not in the object — Mach-O mangles every C symbol with a
# leading `_`, ELF does not, and the caller tries both.
checkAtomicWidth() {
	local archive="$1" name="$2" triple="$3" sym="$4"
	local dump hits
	dump="$(objdump -d --disassemble-symbols="${name}" "${archive}" 2>/dev/null)" || true
	printf '%s\n' "${dump}" | grep -q "<${name}>:" || return 2
	# The function's own body only: from its label to the next blank line, so
	# the "missing symbol" warning objdump prints for every OTHER .o member of
	# the archive (only one member defines this symbol) can never be mistaken
	# for an instruction belonging to it.
	hits="$(printf '%s\n' "${dump}" |
		awk "/<${name}>:/{p=1} p; /^\$/{if (p) exit}" |
		awk -F'\t' '
			NF < 3 { next }
			{
				mnem = $2; ops = $3
				gsub(/^[ \t]+|[ \t]+$/, "", mnem)
				if (mnem !~ /^(ldaxr|stlxr|stlr|ldar)$/) next
				n = split(ops, parts, ",")
				regn = 0
				for (i = 1; i <= n; i++) {
					tok = parts[i]
					gsub(/^[ \t]+|[ \t]+$/, "", tok)
					if (tok ~ /^[wx][0-9]+$/) { regn++; regs[regn] = tok }
				}
				# stlxr Rs,Rt,[Rn]: Rs (regs[1]) is the exclusive-store status,
				# always w by the ISA regardless of the data width — the WIDTH
				# that matters is Rt (regs[2]). Every other mnemonic here takes
				# one register operand, the value itself, in regs[1].
				target = (mnem == "stlxr") ? regs[2] : regs[1]
				if (substr(target, 1, 1) != "w") print mnem "\t" target "\t" $0
			}')"
	[ -z "${hits}" ] && return 0
	while IFS="$(printf '\t')" read -r mnem target rest; do
		echo "release.sh: ${triple} libbitrt.a: ${sym} does a 64-bit ${mnem} (${target}) through what runtime/spinlock.bit declares *i32: ${rest}" >&2
	done <<<"${hits}"
	return 1
}

# One triple's libbitrt.a, both symbols, both possible symbol spellings.
checkAtomicWidthTriple() { # <archive> <triple>
	local archive="$1" triple="$2" bad=0
	local symname resolved rc spelling
	for symname in bit_rt_spin_try_acquire bit_rt_spin_release; do
		resolved=0
		for spelling in "_${symname}" "${symname}"; do
			rc=0
			checkAtomicWidth "${archive}" "${spelling}" "${triple}" "${symname}" || rc=$?
			[ "${rc}" -eq 2 ] && continue
			resolved=1
			[ "${rc}" -eq 0 ] || bad=1
			break
		done
		if [ "${resolved}" -eq 0 ]; then
			echo "release.sh: ${triple} libbitrt.a: symbol ${symname} not found under either Mach-O or ELF spelling — cannot verify atomic width" >&2
			bad=1
		fi
	done
	return "${bad}"
}

echo "release.sh: checking packaged aarch64 libbitrt.a for #2742's 64-bit-through-*i32 defect"
atomicBad=0
# package.sh embeds every RUNTIME_TRIPLE's libbitrt.a in every target's
# tarball, so any produced tarball would do — each triple is still read from
# ITS OWN tarball so a future package.sh that stops doing that does not
# silently make this pass on the wrong bytes.
for pair in "${OUT}/bit-${VERSION}-macos-aarch64.tar.xz aarch64-macos" \
            "${OUT}/bit-${VERSION}-linux-aarch64.tar.xz aarch64-linux"; do
	tarball="${pair%% *}" triple="${pair##* }"
	work="$(mktemp -d)"
	tar -C "${work}" -xf "${tarball}"
	archive="$(ls -d "${work}"/bit-*)/lib/${triple}/libbitrt.a"
	[ -f "${archive}" ] || {
		echo "release.sh: ${tarball} has no lib/${triple}/libbitrt.a" >&2
		rm -rf "${work}"
		exit 1
	}
	rc=0
	checkAtomicWidthTriple "${archive}" "${triple}" || rc=$?
	[ "${rc}" -eq 0 ] || atomicBad=1
	rm -rf "${work}"
done
if [ "${atomicBad}" -eq 1 ]; then
	echo "release.sh: THIS TREE's own compiler (commit ${BUILT_COMMIT}) emits a 64-bit" >&2
	echo "  atomic through what runtime/spinlock.bit declares *i32 — a real codegen" >&2
	echo "  defect, not the pinned-stage0 lag: the packaged libbitrt.a is built by bit1" >&2
	echo "  (#3034), so this is not waiting on a stage0 repin. See #2742." >&2
	exit 1
fi
echo "release.sh: aarch64 libbitrt.a atomic widths OK"

# --- verify the bytes that ship ---------------------------------------------
#
# Each artifact is unpacked somewhere unrelated and asked to COMPILE AND RUN a
# program. A version banner proves nothing about a compiler.

# CPU time consumed by <pid>, in centiseconds. TWO KERNELS, TWO SOURCES: macOS
# offers `ps -o time=`, whose output is `[[HH:]MM:]SS.CC`, so the awk fold
# accumulates base-60; the Linux images carry no `ps` that accepts it, so
# /proc/<pid>/stat's utime+stime (fields 14 and 15, in clock ticks) is read
# instead. `sed 's/.*) //'` drops `pid (comm) ` first, because comm can contain
# spaces and would shift every field after it.
cpuCentis() {
	if [ -r "/proc/$1/stat" ]; then
		sed 's/.*) //' "/proc/$1/stat" |
			awk -v t="$(getconf CLK_TCK 2>/dev/null || echo 100)" \
				'{printf "%d", ($12 + $13) * 100 / t}'
	else
		ps -o time= -p "$1" | tr -d ' ' |
			awk -F: '{s=0; for(i=1;i<=NF;i++) s=s*60+$i; printf "%d", s*100}'
	fi
}

smoke() { # <tarball> <target> <runner...>
	local tar="$1" target="$2"; shift 2
	local work; work="$(mktemp -d)"
	tar -C "${work}" -xf "${tar}"
	local prefix; prefix="$(ls -d "${work}"/bit-*)"
	local lspFifo="${work}/lspfifo"
	mkfifo "${lspFifo}"
	mkdir -p "${work}/proj"
	printf 'fn main() {\n  print("smoke ok\\n")\n}\n' > "${work}/proj/smoke.bit"
	local got
	got="$(cd "${work}/proj" && BIT_STDLIB="${prefix}/stdlib" \
		BIT_LIBBITRT="${prefix}/lib/${target}/libbitrt.a" \
		"$@" "${prefix}/bin/bit" run smoke.bit)"
	# The version the shipped binary REPORTS, not the one we think we built. v0.1.0
	# went out saying `bit 0.1.0-dev` because nothing here ever asked it.
	local ver
	ver="$("$@" "${prefix}/bin/bit" --version)"

	# DOES `bin/bit` CARRY THIS TREE'S RUNTIME? (#2213) Everything above passes
	# with a STALE runtime linked into the compiler: `run` exercises the archive
	# in `lib/`, not the one inside `bin/bit`, and `--version` exercises neither.
	# 0.1.6 and 0.1.7 both shipped that way — the GC fix they were cut for was
	# present in `lib/` and absent from the binary beside it.
	#
	# So probe the compiler's OWN runtime, using the cheapest property that
	# distinguishes them: #2207 made a thread blocked in `fsRead` stop burning
	# CPU. `bit lsp --stdio` deliberately blocks on stdin, so launch it with stdin
	# held open, send nothing, and measure. A stale runtime spins a whole core;
	# a current one is idle. CPU time is read rather than wall-clock %, so a
	# loaded machine cannot fake either verdict.
	local before after used
	"$@" "${prefix}/bin/bit" lsp --stdio < "${lspFifo}" > /dev/null 2>&1 &
	local lsp=$!
	exec 7> "${lspFifo}"
	sleep 1
	before="$(cpuCentis "${lsp}")"
	sleep 6
	after="$(cpuCentis "${lsp}")"
	# `|| true` on BOTH, and it is load-bearing under `set -e`: `wait` reports the
	# job's status, which is 143 for the process we just SIGTERMed, and an
	# unguarded non-zero there terminates this script rather than the probe.
	# `wait` also absorbs the shell's own "Terminated" job notice.
	kill "${lsp}" 2>/dev/null || true
	wait "${lsp}" 2>/dev/null || true
	exec 7>&-
	used=$((after - before))

	rm -rf "${work}"
	[ "${used}" -lt 100 ] || {
		echo "release.sh: ${target} bin/bit burned ${used} centiseconds idle in 6s;" >&2
		echo "  it is linked against a STALE runtime (BIT_LIBBITRT missing? see #2213)" >&2
		return 1
	}
	[ "${got}" = "smoke ok" ] || { echo "release.sh: ${target} smoke test said '${got}'" >&2; return 1; }
	[ "${ver}" = "bit ${VERSION}" ] || {
		echo "release.sh: ${target} reports '${ver}', expected 'bit ${VERSION}'" >&2
		return 1
	}
	echo "release.sh: ${target} smoke ok (${ver})"
}

# Native host: macOS on ARM64.
smoke "${OUT}/bit-${VERSION}-macos-aarch64.tar.xz" aarch64-macos

# The Linux targets run in containers / on the real x86-64 box, so they are
# verified by scripts, not by this shell. Deliberately NOT qemu for x86-64: an
# emulation artifact is not a pass (see the memory of the red-zone bug).
echo "release.sh: verifying the Linux artifacts"
if command -v docker >/dev/null; then
	work="$(mktemp -d)"
	cp "${OUT}/bit-${VERSION}-linux-aarch64.tar.xz" "${work}/"
	cat > "${work}/go.sh" <<-SH
		set -eu
		tar -C /w -xf /w/bit-${VERSION}-linux-aarch64.tar.xz
		p=\$(ls -d /w/bit-${VERSION}-linux-aarch64)
		mkdir -p /w/proj && cd /w/proj
		printf 'fn main() {\n  print("smoke ok\\\\n")\n}\n' > smoke.bit
		BIT_STDLIB="\$p/stdlib" BIT_LIBBITRT="\$p/lib/aarch64-linux/libbitrt.a" "\$p/bin/bit" run smoke.bit
		# Same version assertion as the native path. \`grep -q\` below only inspects
		# stdout, so a mismatch has to fail the script here via set -eu.
		v=\$("\$p/bin/bit" --version)
		[ "\$v" = "bit ${VERSION}" ] || { echo "reports '\$v', want 'bit ${VERSION}'" >&2; exit 1; }
	SH
	# --user, so the container writes as THIS uid into the bind mount. As root it
	# leaves root-owned files that the next run cannot clean (see the remote path
	# below, where exactly that silently skipped a whole target's verification).
	docker run --rm --user "$(id -u):$(id -g)" -v "${work}:/w" bit-linux-gate:latest sh /w/go.sh \
		| grep -q 'smoke ok' \
		|| { echo "release.sh: aarch64-linux smoke FAILED" >&2; exit 1; }
	echo "release.sh: aarch64-linux smoke ok"
	rm -rf "${work}"
else
	echo "release.sh: docker absent — cannot verify aarch64-linux" >&2
	exit 1
fi

host="$(sh scripts/x64host.sh 2>/dev/null | head -1 || true)"
if [ -n "${host}" ]; then
	# A FRESH remote directory per run. This was hardcoded /tmp/rel, and the
	# container wrote into it as root, so the next run's `rm -rf` hit Permission
	# denied, the tarball never arrived, tar failed — and because the whole thing
	# is `ssh … | grep -q && echo`, the failure was invisible and the release still
	# exited 0. The x86-64 target went unverified with no warning at all. Same
	# fixed-/tmp-path class of bug the linker once had (noted in CLAUDE.md).
	rdir="$(ssh "${host}" 'mktemp -d')"
	scp -q "${OUT}/bit-${VERSION}-linux-x86_64.tar.xz" "${host}:${rdir}/"
	ssh "${host}" "set -eu
		cat > ${rdir}/go.sh <<'SH'
set -eu
tar -C /w -xf /w/bit-${VERSION}-linux-x86_64.tar.xz
p=\$(ls -d /w/bit-${VERSION}-linux-x86_64)
mkdir -p /w/proj && cd /w/proj
printf 'fn main() {\n  print(\"smoke ok\\\\n\")\n}\n' > smoke.bit
BIT_STDLIB=\"\$p/stdlib\" BIT_LIBBITRT=\"\$p/lib/x86_64-linux/libbitrt.a\" \"\$p/bin/bit\" run smoke.bit
v=\$(\"\$p/bin/bit\" --version)
[ \"\$v\" = \"bit ${VERSION}\" ] || { echo \"reports '\$v', want 'bit ${VERSION}'\" >&2; exit 1; }
SH
		docker run --rm --user \"\$(id -u):\$(id -g)\" -v ${rdir}:/w bit-linux-gate-amd64:latest sh /w/go.sh" \
		| grep -q 'smoke ok' \
		|| { echo "release.sh: x86_64-linux smoke FAILED on ${host}" >&2; exit 1; }
	echo "release.sh: x86_64-linux smoke ok on real hardware (${host})"
	ssh "${host}" "rm -rf ${rdir}" || true
else
	echo "release.sh: no x86-64 host reachable — cannot verify x86_64-linux" >&2
	echo "release.sh: refusing to publish an unverified release" >&2
	exit 1
fi

# --- SBOM --------------------------------------------------------------------
#
# dist/sbom.py needs cyclonedx-python-lib, which this Mac does not carry
# system-wide (#2748: a fifth release artifact, dist/README.md's "## SBOM",
# was never generated because nothing called the generator). The venv itself
# and its `pip install --require-hashes` were preflighted at the top of this
# script, before the cross-builds (#2802) — reachability and hash integrity
# are already proven by the time we get here, so only the actual generation,
# whose output path depends on ${OUT}, happens at this site.
echo "release.sh: generating SBOM"
"${SBOM_VENV}/bin/python3" dist/sbom.py "${VERSION}" "${STAGE0_VERSION}" \
	> "${OUT}/bit-${VERSION}.cdx.json"
rm -rf "${SBOM_VENV}"
echo "release.sh: wrote ${OUT}/bit-${VERSION}.cdx.json"

# --- checksums and notes ----------------------------------------------------
( cd "${OUT}" && shasum -a 256 ./*.tar.xz ./*.cdx.json | sed 's#\./##' > SHA256SUMS )
echo "release.sh: SHA256SUMS"
cat "${OUT}/SHA256SUMS" | sed 's/^/  /'

bash dist/changelog.sh "${VERSION}" > "${OUT}/NOTES.md" 2>/dev/null || {
	echo "release.sh: changelog.sh failed; writing a minimal note" >&2
	printf '# Bit %s\n' "${VERSION}" > "${OUT}/NOTES.md"
}

# Refuse a bullet naming another language BEFORE the draft is created (#3973).
# Owner ruling 2026-08-30: "in any release notes we don't want to mention Go
# or any other language for that matter". dist/changelog.sh copies commit
# SUBJECTS into NOTES.md verbatim, and a subject is authored weeks earlier by
# someone not thinking about publication — three 0.4.0 bullets named Go and
# were caught by eye and hand-fixed on the PUBLISHED release. "Write it
# carefully" cannot fix text that comes from a different corpus than the one
# anyone reviews; only a mechanical check at cut time can.
#
# Case-sensitive, one word each: proper-noun capitalization is what makes this
# precise instead of noisy — a bare case-insensitive `go` matches ordinary
# English ("does not go", "let it go") constantly, and this repo's own
# CLAUDE.md draft pattern (`[^a-z]c[^a-z+]` for a bare "C") matches almost
# every short word in the corpus. Verified empirically, not assumed: across
# 3140 non-merge commit subjects and 1315 lines of NOTES.md generated for
# v0.1.25 through the range since v0.5.0 (10 ranges), this pattern hit 7
# times and every hit named the language — 0 observed false positives.
# Golang/Rust/Java/JavaScript/Swift/C++ never occurred at all in that corpus.
LANG_NAME_PATTERN='\b(Go|Golang|Rust|Zig|Python|Java|TypeScript|JavaScript|Swift)\b|C\+\+'

checkNotesLanguage() { # <notes-file>
	local notesFile="$1" hits bad=0 lineno text sha
	[ -f "${notesFile}" ] || {
		echo "release.sh: ${notesFile} does not exist — cannot check it for language mentions" >&2
		return 1
	}
	hits="$(grep -nE "${LANG_NAME_PATTERN}" "${notesFile}" || true)"
	[ -z "${hits}" ] && return 0

	# One bullet per line ("- <subject> (<sha>)", dist/changelog.sh), so the
	# trailing "(<sha>)" is the commit to name alongside the line — the way
	# abiarity.bit's refusal names the symbol and both arities, not just "a
	# mismatch exists somewhere".
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		lineno="${line%%:*}"
		text="${line#*:}"
		sha="$(printf '%s' "${text}" | grep -oE '\([0-9a-f]{7,40}\)[[:space:]]*$' | tr -d '()' || true)"
		if [ -n "${sha}" ] && [ -n "${RELEASE_NOTES_LANG_ALLOW:-}" ]; then
			case " ${RELEASE_NOTES_LANG_ALLOW} " in
			*" ${sha} "*) continue ;;
			esac
		fi
		bad=1
		echo "release.sh: ${notesFile}:${lineno}: names another language: ${text}" >&2
		[ -n "${sha}" ] && echo "release.sh:   commit ${sha}" >&2
	done <<<"${hits}"
	[ "${bad}" -eq 0 ] && return 0

	echo "release.sh: refusing — release notes must not name another language (owner ruling 2026-08-30)" >&2
	echo "release.sh: reword the commit subject upstream (preferred) or edit ${notesFile} and re-run" >&2
	echo "release.sh: to approve a specific bullet for this run:" >&2
	echo "release.sh:   RELEASE_NOTES_LANG_ALLOW=\"<sha> ...\" dist/release.sh ${VERSION}" >&2
	return 1
}

# Folds any entries from docs/release/PENDING-NOTES.md into the just-generated
# NOTES.md (#3213, #3392). Entries live PAST the file's `---` separator —
# everything above it is static usage documentation, never release content.
# Appended right after the version heading, not at the end: a security
# disclosure belongs at the top of the notes, not after "Artifacts".
#
# NEVER CLEARS PENDING-NOTES.md ITSELF, on --dry-run or a real run: this
# script only ever creates a DRAFT (see the header comment above), and a
# draft can be abandoned or re-cut. Clearing here would let an abandoned
# draft silently eat the disclosure, with nothing left to fold into the
# release that actually ships it. So this prints an instruction instead —
# the entry is removed by hand, in the commit that records the release notes
# were actually published (see PENDING-NOTES.md's own "How to use this
# file" section).
foldPendingNotes() { # <pending-notes-file> <notes-md-file>
	local pendingFile="$1" notesFile="$2"
	[ -f "${pendingFile}" ] || return 0

	local raw
	raw="$(awk '/^---$/{found=1;next} found{print}' "${pendingFile}")"
	printf '%s\n' "${raw}" | grep -q '[^[:space:]]' || return 0

	# The release skill's own accounting check (grep -cE '^[-*] '
	# dist/out/NOTES.md vs the non-merge commit count, bit-release
	# SKILL.md step 1) would silently miscount a hand-written top-level
	# bullet as a displaced commit bullet — refuse rather than let a
	# pending entry corrupt that assertion into noise.
	local bad
	bad="$(printf '%s\n' "${raw}" | grep -E '^[-*] ' || true)"
	if [ -n "${bad}" ]; then
		echo "release.sh: ${pendingFile} has an entry starting with '- ' or '* ', which the" >&2
		echo "  release skill's bullet-count check would misread as a commit bullet:" >&2
		printf '%s\n' "${bad}" | sed 's/^/  /' >&2
		exit 1
	fi

	# Demote each entry's heading one level (## -> ###) so it nests under
	# the version title the same way "Breaking changes" / "Features" do,
	# instead of competing with it at the same level.
	local demoted title rest count
	demoted="$(printf '%s\n' "${raw}" | sed -E 's/^## /### /')"
	title="$(head -n1 "${notesFile}")"
	rest="$(tail -n +2 "${notesFile}")"
	{
		printf '%s\n\n' "${title}"
		printf '%s\n' "${demoted}"
		printf '\n%s\n' "${rest}"
	} > "${notesFile}"

	count="$(printf '%s\n' "${raw}" | grep -c '^## ' || true)"
	echo "release.sh: folded ${count} pending entry(ies) from ${pendingFile} into ${notesFile}" >&2
	echo "release.sh: ================================================================" >&2
	echo "release.sh: ACTION REQUIRED once this release is PUBLISHED (not on a draft" >&2
	echo "release.sh:   that gets abandoned or re-cut): remove the folded entry(ies) from" >&2
	echo "release.sh:   ${pendingFile} (everything after its '---') and commit that" >&2
	echo "release.sh:   removal. See that file's own \"How to use this file\" section." >&2
	echo "release.sh: ================================================================" >&2
}
foldPendingNotes "${ROOT}/docs/release/PENDING-NOTES.md" "${OUT}/NOTES.md"

checkNotesLanguage "${OUT}/NOTES.md" || exit 1

if [ "${DRY}" -eq 1 ]; then
	echo "release.sh: --dry-run, publishing nothing. Artifacts in ${OUT}"
	echo "release.sh: would tag v${VERSION} at ${BUILT_COMMIT}"
	exit 0
fi

# A DRAFT, always. A human checks the artifacts and presses publish; that is
# also the signal any downstream packaging waits on.
args=(--draft --title "Bit ${VERSION}" --notes-file "${OUT}/NOTES.md")
case "${VERSION}" in *-*) args+=(--prerelease) ;; esac

if gh release view "v${VERSION}" >/dev/null 2>&1; then
	echo "release.sh: v${VERSION} exists; uploading assets with --clobber"
	gh release upload "v${VERSION}" "${OUT}"/*.tar.xz "${OUT}"/*.cdx.json "${OUT}/SHA256SUMS" --clobber
else
	# --target pins the new tag to the tree that was actually built and smoke-tested
	# (#1856). Only meaningful on this branch: for an existing tag gh ignores it,
	# which is correct — the tag is already placed and re-cutting must not move it.
	echo "release.sh: tagging v${VERSION} at ${BUILT_COMMIT}"
	gh release create "v${VERSION}" --target "${BUILT_COMMIT}" "${args[@]}" \
		"${OUT}"/*.tar.xz "${OUT}"/*.cdx.json "${OUT}/SHA256SUMS"
fi

# Report what the release ACTUALLY is now, not what --draft asked for: re-cutting
# an already-published release (an asset fix, as with the 0.1.0-dev version bug)
# leaves it published, and printing "review it, then publish" there is a lie that
# reads as "nothing is live yet".
if [ "$(gh release view "v${VERSION}" --json isDraft --jq .isDraft)" = "true" ]; then
	echo "release.sh: DRAFT v${VERSION} ready — review, then publish:"
	echo "  gh release edit v${VERSION} --draft=false"
else
	echo "release.sh: v${VERSION} is PUBLISHED and its assets are now live:"
	echo "  https://github.com/byteink/bit/releases/tag/v${VERSION}"
fi
