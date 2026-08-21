#!/usr/bin/env bash
# Thin wrapper (#2743): the type differential is now one row of the
# table-driven driver. See scripts/selfhost-diffdump.sh for behavior, the
# timeout guard and this differential's header, carried over there verbatim.
# Oracle: the pinned stage0 -- see selfhost-diffdump.sh's own header for detail,
# including what a red run here means and what to do about it (#2382).
# Exit code: decided by selfhost-diffdump.sh, which calls the shared
# scripts/diffexit.sh helper (#3382) -- this file hand-writes no exit logic.
#
# Usage: ./make selfhost && bash scripts/selfhost-difftypes.sh
exec bash "$(dirname -- "$0")/selfhost-diffdump.sh" types "$@"
