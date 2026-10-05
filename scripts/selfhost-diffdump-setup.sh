#!/usr/bin/env bash
# Sourced-only setup for scripts/selfhost-diffdump.sh (#6196, split out to
# hold that file under the 800-line E0200 ceiling; behaviour unchanged,
# proven by `sh scripts/selfhost-diffall.sh` GREEN with this split in place).
#
# diffdump_setup resolves NAME (ast|tokens|diags|types|ir|iropt) into the
# FLAG/LABEL/SKIPLABEL/VERB/KIND/TIMEOUT/PREFIX row and the ORACLE/BIT2
# compilers, then exports the pinned-flag agreements every row body in
# selfhost-diffdump.sh needs before it walks the corpus. See that file's own
# header for the differential driver this feeds and
# docs/development/dump-differential.md for the full per-form design record.
#
# Usage (sourced, never executed standalone, ROOT already set by the caller):
#   . "${ROOT}/scripts/selfhost-diffdump-setup.sh"
#   diffdump_setup "$NAME"
#
# Sources diffexit.sh itself (harmless if the caller already did) since this
# file calls diffrequire directly -- _tests_/bit/shellsize.bit's #4724 check
# requires the source line in the SAME file that calls it, not merely
# somewhere in the call chain.
# shellcheck source=scripts/diffexit.sh
. "${ROOT}/scripts/diffexit.sh"

diffdump_setup() {
  local name=$1
  # name    | flag           | verdict label   | skip label        | verb (ir only) | kind  | timeout (env, default)
  case "$name" in
    ast)    FLAG=--dump-ast;    LABEL="AST";           SKIPLABEL="parse-err";       VERB="";         KIND=basic; TIMEOUT="${DIFFAST_TIMEOUT:-20}" ;;
    tokens) FLAG=--dump-tokens; LABEL="token";         SKIPLABEL="lex-err";         VERB="";         KIND=basic; TIMEOUT="${DIFFTOKENS_TIMEOUT:-20}" ;;
    diags)  FLAG=--dump-diags;  LABEL="diag";          SKIPLABEL="";                VERB="";         KIND=basic; TIMEOUT="${DIFFDIAGS_TIMEOUT:-20}" ;;
    types)  FLAG=--dump-types;  LABEL="type";          SKIPLABEL="check-err";       VERB="";         KIND=types; TIMEOUT="${DIFFTYPES_TIMEOUT:-20}" ;;
    ir)     FLAG=--dump-ir-pre; LABEL="IR (pre-opt)";  SKIPLABEL="lower/check-err"; VERB="pre-opt";  KIND=ir;    TIMEOUT="${DIFFIR_TIMEOUT:-300}" ;;
    iropt)  FLAG=--dump-ir;     LABEL="IR (post-opt)"; SKIPLABEL="lower/check-err"; VERB="post-opt"; KIND=ir;    TIMEOUT="${DIFFIROPT_TIMEOUT:-300}" ;;
    *) echo "selfhost-diffdump: unknown differential '${name}' (want ast|tokens|diags|types|ir|iropt)" >&2; exit 2 ;;
  esac
  PREFIX="diff${name}"

  # Oracle: the pinned stage0 -- the same compiler one release back, an EARLIER
  # VERSION OF THIS SAME COMPILER, which is exactly what limits the claim below.
  # scripts/stage0.sh downloads and DIGEST-VERIFIES it, and refuses rather
  # than skipping, so a failure here is loud. A green run proves no behaviour
  # change versus the last release; it cannot catch a bug present in both —
  # docs/release/bootstrap.md §4/§5.
  ORACLE="$(sh "${ROOT}/scripts/stage0.sh")" || exit 2
  BIT2="${ROOT}/bit-out/bin/bit"

  # A missing compiler must ABORT, never score a vacuous green (#1514): both sides
  # of the differential would produce empty output, and equal-empty compares as
  # agreement. Exit 2 to keep this distinct from a real divergence (exit 1).
  # [diags' version of the same point:] This gate is the worst of the family
  # without it: both sides render empty, and since it skips nothing every file
  # scores MATCH — a full green board from no compiler.
  diffrequire "$PREFIX" "$ORACLE" "$BIT2"

  # BOTH SIDES must reach the working tree's stdlib THROUGH THE SAME PATH STRING,
  # the #1920 pin selfhost-diffcheck.sh already carries -- read its copy for the
  # full account. It was a check-row-only concern until #5177 routed
  # `--dump-types`/`--dump-ir`/`--dump-ir-pre` through `loadProject` for prelude
  # injection (compiler/main.bit's `checkedSourceFile`, replacing a scratch module
  # with `prelude: -1` that never touched stdRoot), and the pin was not carried
  # over here with it.
  #
  # Unpinned, stage0.sh's wrapper hands the ORACLE an absolute BIT_STDLIB while
  # BIT2 runs bare and `stdRootPath` (compiler/mainpaths.bit) falls through
  # `resolveNearExe` -- there is no `bit-out/stdlib` -- to the cwd-relative
  # literal `"stdlib"`. `loadModuleAt` (compiler/project.bit) memoises on
  # `pathResolve(dir)`, which is LEXICAL and never absolutises, so for a corpus
  # file under `stdlib/core/` the relative spelling makes the prelude's key and
  # the root's key the SAME STRING: the root load hits the prelude's cached
  # module and its `rootOnly` filter is dropped, dumping the whole two-file
  # module against its concatenated source. That is one compiler disagreeing with
  # ITSELF about an environment, scored as a divergence between two compilers
  # (#5356: stdlib/core/core.bit and stdlib/core/option.bit, MISMATCH=2 from a
  # bare shell while `./make test-differentials` -- which exports BIT_STDLIB per
  # tools/build/gatestable2.bit -- read green).
  #
  # `$(pwd)` not `${ROOT}`: it must name the tree the CORPUS below is found in,
  # since `find $CORPUS` is cwd-relative. The wrapper's `${BIT_STDLIB:-...}` takes
  # this value instead of substituting its own.
  BIT_STDLIB="$(pwd)/stdlib"
  export BIT_STDLIB

  # #6000: IFACE_SIG, BCE_JOIN, JSON_APPEND, and (since #6192) the #5990
  # static-const closure-cell lowering are all gone as flags -- the pinned
  # ORACLE (>= 0.31.0, which carries #6000) already emits every one of them
  # unconditionally, same as this tree. So are MAPLIT, STATIC_METHODS,
  # GENERIC_EXPLODE, DCE_PARAMS and DCE_METHODS since the 0.33.0 repin (#6245).
  # So are CONST_STRING_FOLD, MAP_PRESENCE and STRBOX_JOIN since the 0.35.0
  # repin (#6527).
}
