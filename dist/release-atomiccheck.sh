#!/usr/bin/env bash
# dist/release-atomiccheck.sh — packaged-runtime atomic-width probe, extracted
# out of dist/release.sh (#4132) as a pure move to bring release.sh back under
# the 800-line ceiling: checkAtomicWidth() and checkAtomicWidthTriple() are
# unchanged below, only relocated. Sourced by dist/release.sh; not a new entry
# point. Refuses if invoked directly rather than silently doing nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	echo "release-atomiccheck.sh: sourced-only, not a standalone script — it only" >&2
	echo "  defines checkAtomicWidth()/checkAtomicWidthTriple() for dist/release.sh." >&2
	echo "  Run: dist/release.sh <version> [--dry-run]" >&2
	exit 2
fi

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
