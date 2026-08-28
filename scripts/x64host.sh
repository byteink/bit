#!/usr/bin/env bash
# Resolve the ssh alias of a real x86-64 Linux box, for the gates that must run
# on hardware rather than under qemu.
#
# NO HOSTNAME IS HARDCODED IN THIS REPO. The candidate list is machine-local
# configuration, because it names one developer's machines and has no business
# in a tracked file. Resolution order, first hit wins:
#
#   1. $BIT_X64_HOST            a single alias; used as-is, no probing
#   2. $BIT_X64_HOSTS           space/colon-separated candidates, in preference order
#   3. $BIT_X64_HOSTS_FILE      path to a file of candidates (one per line, # comments ok)
#   4. ./.x64hosts              repo-local, GITIGNORED
#   5. ~/.config/bit/x64hosts   the usual place
#
# For 2-5 the first candidate that ANSWERS is chosen, so a preferred box that is
# asleep falls through to the next instead of failing the gate.
#
# Prints the alias on stdout and exits 0, or explains how to configure and
# exits 1. Callers must check the exit code: a gate that runs against the wrong
# box, or reports "no host" as a result, is worse than one that does not run.
#
# `x64host.sh --all` opts OUT of first-answer-wins: it probes every candidate
# and prints all reachable ones (one per line), for callers checking
# hardware-timing-sensitive code, where "first box that happens to be awake"
# can silently pick the machine that hides a real regression (#1690). Exits 0
# if at least one candidate answered, 1 otherwise.
set -u

ALL=0
if [ "${1:-}" = "--all" ]; then
  ALL=1
fi

_probe() {                       # $1 = alias; answers ssh within 8s?
  # </dev/null: without it ssh inherits the caller's stdin and drains a
  # non-deterministic prefix of it before "true" runs — #3899, proved by #3833
  # with a piped `git archive HEAD` losing bytes to this exact probe.
  ssh -o ConnectTimeout=8 -o BatchMode=yes "$1" true </dev/null >/dev/null 2>&1
}

# 1. explicit single host — trusted, not probed, so a deliberate choice always wins
if [ -n "${BIT_X64_HOST:-}" ]; then
  printf '%s\n' "${BIT_X64_HOST}"
  exit 0
fi

_candidates=""
# 2. explicit list
if [ -n "${BIT_X64_HOSTS:-}" ]; then
  _candidates=$(printf '%s' "${BIT_X64_HOSTS}" | tr ':' ' ')
fi
# 3-5. first config file that exists
if [ -z "${_candidates}" ]; then
  _repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  for _f in "${BIT_X64_HOSTS_FILE:-}" "${_repo_root}/.x64hosts" "${HOME}/.config/bit/x64hosts"; do
    [ -n "${_f}" ] && [ -f "${_f}" ] || continue
    _candidates=$(sed -e 's/#.*//' "${_f}" | tr '\n' ' ')
    break
  done
fi

_found=0
for _h in ${_candidates}; do
  [ -n "${_h}" ] || continue
  if _probe "${_h}"; then
    printf '%s\n' "${_h}"
    _found=1
    [ "${ALL}" -eq 1 ] || exit 0
  fi
done
[ "${ALL}" -eq 1 ] && [ "${_found}" -eq 1 ] && exit 0

{
  if [ -n "${_candidates}" ]; then
    echo "x64host: no candidate answered ssh:${_candidates:+ }${_candidates}"
    echo "         (a box may be asleep — wake it, or set BIT_X64_HOST=<alias> to force one)"
  else
    echo "x64host: no x86-64 host configured."
  fi
  echo
  echo "Configure ONE of:"
  echo "  export BIT_X64_HOST=<ssh-alias>          # force a single box"
  echo "  export BIT_X64_HOSTS='<alias> <alias>'   # ordered candidates"
  echo "  echo '<alias>' >> ~/.config/bit/x64hosts # persistent, one alias per line"
  echo
  echo "The box must be real x86-64 Linux with docker; verify with:"
  echo "  ssh <alias> 'uname -m; uname -s; command -v docker'"
} >&2
exit 1
