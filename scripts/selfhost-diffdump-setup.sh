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


def byte(value):
    require(type(value) is str and len(value) <= 1048576)
    return value.encode("latin1")


def atoms(value):
    result = [byte(v) for v in sequence(value)]
    require(all(v and not v.isspace() for v in result))
    return result


def ident(value):
    return re.fullmatch(rb"%[0-9]+", value) is not None


def value_id(value):
    value = byte(value)
    require(ident(value))
    return value


def label(value):
    value = byte(value)
    require(re.fullmatch(rb"bb[0-9]+", value))
    return value


def compact(row):
    spend(len(row))
    result = TOKEN.findall(row)
    require(b'"' not in result)
    require(all(t.startswith(b'"') or (b"\n" not in t and b"\r" not in t) for t in result))
    return [t for t in result if not t.isspace()]


def pairs(value):
    result = []
    for pair in sequence(value):
        require(type(pair) is list and len(pair) == 2)
        v, ty = value_id(pair[0]), tuple(atoms(pair[1]))
        require(ty and not any(ident(t) for t in ty))
        result.append((v, ty))
    return result


def comma(parts):
    result = []
    for part in parts:
        if result:
            result.append(b",")
        result.extend(part)
    return result


def parameter_tokens(params):
    return comma([[v, b":", *ty] for v, ty in params])


def load_targets(value):
    result = []
    for pair in sequence(value, high=2):
        require(type(pair) is list and len(pair) == 2)
        result.append((label(pair[0]), [value_id(v) for v in sequence(pair[1])]))
    return result


def semantic_uses(op, ts):
    if op == b"gc_alloc":
        return []
    return [t for t in ts if ident(t)]


def load_node(obj):
    keys(obj, "row ts out op ty name args targets")
    row, ts, op = byte(obj["row"]), atoms(obj["ts"]), byte(obj["op"])
    require(ts and ts[0] == op)
    out = None if obj["out"] is None else value_id(obj["out"])
    ty = tuple(atoms(obj["ty"]))
    require(not any(ident(t) for t in ty))
    name = None if obj["name"] is None else byte(obj["name"])
    args = [value_id(v) for v in sequence(obj["args"])]
    targets = load_targets(obj["targets"])
    prefix = [] if out is None else [out, b"="]
    require(compact(row) == prefix + ts and (out is None) == (op in EFFECTS))
    return {"row": row, "ts": ts, "out": out, "op": op, "ty": ty,
            "name": name, "args": args, "targets": targets,
            "uses": semantic_uses(op, ts)}


def load_block(obj, b):
    keys(obj, "row params code")
    row, params = byte(obj["row"]), pairs(obj["params"])
    require(compact(row) == [b, b"(", *parameter_tokens(params), b")", b":"])
    code = [load_node(n) for n in sequence(obj["code"], 1, 4096)]
    return {"row": row, "params": params, "code": code}


def check_view(header, order, blocks, raw):
    ht = compact(header)
    require(len(ht) >= 5 and ht[0] == b"func" and ht[2] == b"(" and ht[-1] == b"{")
    close = ht.index(b")", 3)
    require(ht[3:close] == parameter_tokens(blocks[order[0]]["params"]))
    rows = [header]
    for b in order:
        rows += [blocks[b]["row"]] + [n["row"] for n in blocks[b]["code"]]
    require(raw == b"\n".join(rows + [b"}"]))


def load_graph(obj, raw):
    keys(obj, "header order blocks")
    order = [label(b) for b in sequence(obj["order"], 1, 256)]
    require(len(set(order)) == len(order) and type(obj["blocks"]) is dict)
    require(set(obj["blocks"]) == {b.decode("ascii") for b in order})
    blocks = {b: load_block(obj["blocks"][b.decode("ascii")], b) for b in order}
    require(sum(len(b["code"]) for b in blocks.values()) <= 4096)
    header = byte(obj["header"])
    check_view(header, order, blocks, raw)
    f = {"header": header, "blocks": blocks, "order": order}
    validate(f)
    return f


def definitions(f):
    result = {}
    for b in f["order"]:
        blk = f["blocks"][b]
        items = [(v, -1, ty) for v, ty in blk["params"]]
        items += [(n["out"], i, n["ty"]) for i, n in enumerate(blk["code"]) if n["out"]]
        for v, i, ty in items:
            spend()
            require(v not in result)
            result[v] = (b, i, ty)
    require(len(result) <= 8192)
    return result


def edges(f):
    pred = {b: set() for b in f["order"]}
    succ = {b: set() for b in f["order"]}
    for b in f["order"]:
        code = f["blocks"][b]["code"]
        require(code and code[-1]["op"] in TERMS)
        require(all(n["op"] not in TERMS for n in code[:-1]))
        for target, args in code[-1]["targets"]:
            require(target in pred and len(args) == len(f["blocks"][target]["params"]))
            pred[target].add(b)
            succ[b].add(target)
    return pred, succ


def validate(f):
    defs = definitions(f)
    pred, succ = edges(f)
    for b in f["order"]:
        for i, node in enumerate(f["blocks"][b]["code"]):
            for v in node["uses"]:
                spend()
                require(v in defs)
            for target, args in node["targets"]:
                for v, pair in zip(args, f["blocks"][target]["params"]):
                    require(not defs[v][2] or defs[v][2] == pair[1])
    f.update({"defs": defs, "pred": pred, "succ": succ})


def load_module(obj):
    keys(obj, "sha256 chunks")
    require(type(obj["sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", obj["sha256"]))
    result, raws = [], []
    for chunk in sequence(obj["chunks"], 1, 8192):
        keys(chunk, "kind raw_b64 graph")
        require(chunk["kind"] in {"raw", "function"} and type(chunk["raw_b64"]) is str)
        raw = base64.b64decode(chunk["raw_b64"], validate=True)
        require(len(raw) <= 8 * 1024 * 1024)
        f = None
        if chunk["graph"] is not None:
            require(chunk["kind"] == "function")
            f = load_graph(chunk["graph"], raw)
        result.append({"kind": chunk["kind"], "raw": raw, "graph": f})
        raws.append(raw)
    require(hashlib.sha256(b"\n".join(raws)).hexdigest() == obj["sha256"])
    return result


def source_facts(obj):
    keys(obj, "version path raw_b64 sha256 tokens decls")
    require(type(obj["version"]) is int and obj["version"] == 1)
    require(type(obj["path"]) is str and 0 < len(obj["path"]) <= 4096)
    require(type(obj["raw_b64"]) is str and type(obj["sha256"]) is str)
    raw = base64.b64decode(obj["raw_b64"], validate=True)
    require(len(raw) <= 1048576 and hashlib.sha256(raw).hexdigest() == obj["sha256"])
    require(not any(word in raw for word in (b"export", b"extern", b"@")))
    result = source_tokens(obj["tokens"], raw)
    decls = sequence(obj["decls"], 1, 4096)
    for index, d in enumerate(decls):
        check_decl(d, index, decls, len(result))
    source_coverage(result, decls)
    return result, decls


def source_coverage(tokens, decls):
    covered = {i for d in decls if d["parent"] is None for i in range(d["start"], d["end"])}
    require(all(i in covered or kind in {"whitespace", "comment"} for i, (t, kind) in enumerate(tokens)))


def source_tokens(items, raw):
    result, at = [], 0
    kinds = {"whitespace", "comment", "string", "word", "punct"}
    for item in sequence(items, 1, 65536):
        require(type(item) is list and len(item) == 3 and item[2] in kinds)
        start = integer(item[0], at, at)
        end = integer(item[1], start + 1, len(raw))
        result.append((raw[start:end], item[2]))
        at = end
    require(at == len(raw))
    return result


def check_decl(d, index, decls, count):
    keys(d, "kind name start body end parent")
    require(d["kind"] in {"import", "class", "interface", "function", "method"})
    require(type(d["name"]) is str)
    start = integer(d["start"], 0, count - 1)
    end = integer(d["end"], start + 1, count)
    if d["body"] is not None:
        integer(d["body"], start, end - 1)
    if d["parent"] is not None:
        parent = decls[integer(d["parent"], 0, index - 1)]
        require(parent["kind"] in {"class", "interface"})
        require(parent["start"] < start < end <= parent["end"])


def decl_tokens(tokens, d, header=False):
    end = d["body"] + 1 if header else d["end"]
    return [t for t, kind in tokens[d["start"]:end] if kind not in {"whitespace", "comment"}]


def unique_object(pairs):
    result = dict(pairs)
    require(len(result) == len(pairs))
    return result
DIFFDUMP_OWNED_APPEND_LIBRARY
  [ "$diffdump_library_rc" -eq 1 ]
}
