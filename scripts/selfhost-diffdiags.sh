#!/usr/bin/env bash
# Thin wrapper (#2743): the diagnostic differential is now one row of the
# table-driven driver. See scripts/selfhost-diffdump.sh for behavior, the
# timeout guard and this differential's header, carried over there verbatim.
# Oracle: the pinned stage0 -- see selfhost-diffdump.sh's own header for detail.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffdiags.sh
exec bash "$(dirname -- "$0")/selfhost-diffdump.sh" diags "$@"
