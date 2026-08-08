#!/usr/bin/env bash
# Thin wrapper (#2743): the pre-opt IR differential is now one row of the
# table-driven driver. See scripts/selfhost-diffdump.sh for behavior, the
# timeout guard and this differential's header, carried over there verbatim.
#
# Usage: ./make selfhost && bash scripts/selfhost-diffir.sh
exec bash "$(dirname -- "$0")/selfhost-diffdump.sh" ir "$@"
