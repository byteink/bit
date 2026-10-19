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

# A successful IR dump can hide failed lowering; only this source's E0092
# object refusal is coverage missing from the immutable oracle (#7931).
oracle_lowering_declined() {
  awk -v source="$2" '
    NR == 1 { if ($0 != "bit: " source ": refusing to emit an object") bad = 1; next }
    /^error\[E0092\]: / { if (pending) bad = 1; errors++; pending = 1; next }
    /^note: while emitting .*\047, instantiated here$/ { if (pending || !errors) bad = 1; pending = 1; next }
    /^[[:space:]]*--> / {
      location = $0; sub(/^[[:space:]]*--> /, "", location)
      if (location !~ /:[0-9]+:[0-9]+$/) bad = 1
      sub(/:[0-9]+:[0-9]+$/, "", location)
      if (!pending || location != source) bad = 1
      pending = 0; next
    }
    /^[[:space:]]*([0-9]+[[:space:]]*)?\|/ { next }
    /^[[:space:]]*$/ { next }
    { bad = 1 }
    END { exit (bad || pending || !errors) }
  ' "$1"
}

# Prints decline, ok, or undecided; failed execution never means coverage.
oracle_check_coverage() {
  local rc cap=$2
  alarmrun_retry_cap ORACLECHECK "" "$cap" "$ORACLE" check "$1"
  rc=$?
  case "$rc" in
    0) if grep -q '^panic: ' "$cap"; then echo undecided; else echo ok; fi ;;
    1) if grep -q '^panic: ' "$cap"; then echo undecided; else echo decline; fi ;;
    *) echo undecided ;;
  esac
}

oracle_object_coverage() {
  local source=$1 dir=$2 rc cap object
  cap="${dir:?}/oracle-object.cap"
  object="${dir:?}/oracle-object.o"
  alarmrun_retry_cap ORACLEOBJECT "$object" "$cap" "$ORACLE" build "$source" \
    --emit-obj --no-optimize -o "$object"
  rc=$?
  case "$rc" in
    0) [ -s "$object" ] && ! grep -q '^panic: ' "$cap" && echo ok || echo undecided ;;
    1) if [ ! -e "$object" ] && oracle_lowering_declined "$cap" "$source"; then echo decline; else echo undecided; fi ;;
    *) echo undecided ;;
  esac
}

oracle_ir_coverage() {
  local source=$1 dir=$2 status
  [ -x "$ORACLE" ] || { echo undecided; return; }
  status=$(oracle_check_coverage "$source" "${dir:?}/oracle-check.cap")
  [ "$status" = ok ] || { echo "$status"; return; }
  oracle_object_coverage "$source" "$dir"
}


# A candidate object is a framing witness, never a second oracle retry.
ir_mismatch_signature() {
  local source=$1 dir=$2 old=$3 new=$4 object cap rc
  case "$NAME" in ir|iropt) ;; *) return 1 ;; esac
  object="${dir:?}/bit2-object.o"
  cap="${dir:?}/bit2-object.cap"
  [ ! -L "$object" ] && [ ! -L "$cap" ] || return 2
  rm -f "$object" || return 2
  alarmrun_cap "$cap" "$BIT2" build "$source" --emit-obj --no-optimize -o "$object"
  rc=$?
  [ "$rc" -eq 0 ] && [ -f "$object" ] && [ ! -L "$object" ] && [ -s "$object" ] || {
    printf 'IR framing object command_rc=%s input=%s\n' "$rc" "$source" >&2
    return 2
  }
  if grep -q '^panic: ' "$cap"; then
    printf 'IR framing object command_rc=%s panic_output input=%s\n' "$rc" "$source" >&2
    return 2
  fi
  explainMismatch "$old" "$new" "$NAME" "$source" "${dir:?}/oracle-object.o" "$object" "${dir:?}/oracle.cap" "${dir:?}/bit2.cap"
}

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

  # #6416: the `if` branch-chain lowering (#5926, `ifBranchChainEnabled` in
  # compiler/lowercondchain.bit) defaults ON in this tree since the 0.41.0
  # repin; that ORACLE carries the code but still defaults it off. Both sides
  # inherit this environment, so force "1" to compare ON against ON. Delete
  # with the flag, one release after the flip.
  export BIT_IF_BRANCHCHAIN=1
}

# Fixed proof-library definitions; ordinary setup never calls this loader.
diffdump_owned_append_library() {
  DIFFDUMP_OWNED_APPEND_PYTHON=
  local diffdump_library_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_OWNED_APPEND_PYTHON <<'DIFFDUMP_OWNED_APPEND_LIBRARY' || diffdump_library_rc=$?
def keys(value, expected):
    require(type(value) is dict and set(value) == set(expected.split()))

def integer(value, low, high):
    require(type(value) is int and low <= value <= high)
    return value

def sequence(value, low=0, high=8192):
    require(type(value) is list and low <= len(value) <= high)
    return value

def unique_object(pairs):
    result = dict(pairs)
    require(len(result) == len(pairs))
    return result

DIFFDUMP_OWNED_APPEND_LIBRARY
  [ "$diffdump_library_rc" -eq 1 ]
}

# Fixed byte-parser utilities shared with the isolated parent process.
diffdump_parent_library() {
  DIFFDUMP_PARENT_PYTHON=
  local diffdump_parent_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_PARENT_PYTHON <<'DIFFDUMP_PARENT_LIBRARY' || diffdump_parent_rc=$?
def file_snapshot(path):
    require(0 < len(path) <= 4096)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= 8 * 1024 * 1024)
        raw = stream.read(8 * 1024 * 1024 + 1)
        after, current = os.fstat(stream.fileno()), os.stat(path, follow_symlinks=False)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns))
        require((current.st_dev, current.st_ino) == (before.st_dev, before.st_ino))
        require(len(raw) == before.st_size)
    return raw
DIFFDUMP_PARENT_LIBRARY
  [ "$diffdump_parent_rc" -eq 1 ]
}

# Only the fixed sibling framing source enters either proof process.
diffdump_frame_libraries() {
  . "$1/selfhost-diffiropt.sh" || return 1
  diffdump_parent_library && diffiropt_literal_library && diffdump_owned_append_library
}
