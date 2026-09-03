#!/usr/bin/env bash
# dist/release-smoke.sh — smoke-test helpers, extracted out of dist/release.sh
# (#4132) as a pure move to bring release.sh back under the 800-line ceiling:
# cpuCentis() and smoke() are unchanged below, only relocated. Sourced by
# dist/release.sh, which still owns every invocation (native macOS call,
# aarch64-linux via docker, x86_64-linux and x86_64-windows over SSH) and
# their order; not a new entry point. Refuses if invoked directly rather than
# silently doing nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "release-smoke.sh: sourced-only, not a standalone script — it only" >&2
	echo "  defines cpuCentis()/smoke() for dist/release.sh. Run:" >&2
	echo "  dist/release.sh <version> [--dry-run]" >&2
	exit 2
fi

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
