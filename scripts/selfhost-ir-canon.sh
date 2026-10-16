#!/usr/bin/env bash
# Shared IR type-ID canonicalizer (#1766): only `$t<N>` numeric IDs change.
# Local ownership proofs use the direct-only bounded JSON mode below.
# Source this file to call canon_ir_ids without starting a proof process.
canon_ir_ids() {
  # LC_ALL=C: a dump can hold bytes that are not valid UTF-8 (a string literal);
  # awk in a UTF-8 locale dies on them with `towc: multibyte conversion failure` (#6716).
  LC_ALL=C awk '
    {
      line = $0
      out = ""
      while (match(line, /\$t[0-9]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        if (!(tok in map)) {
          map[tok] = "$c" n++
        }
        out = out substr(line, 1, RSTART - 1) map[tok]
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  ' <<<"$1"
}

# Proof mode replaces this shell so a bounded caller also owns the Python PID.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -ne 0 ]; then
  [ "$#" -eq 1 ] && [ "$1" = --prove-owned-appends ] || exit 1
  case "${BASH_SOURCE[0]}" in
    scripts/selfhost-ir-canon.sh) ROOT=. ;;
    */scripts/selfhost-ir-canon.sh) ROOT=${BASH_SOURCE[0]%/scripts/selfhost-ir-canon.sh} ;;
    *) exit 1 ;;
  esac
  . "${ROOT}/scripts/selfhost-diffdump-setup.sh" || exit 1
  diffdump_owned_append_library || exit 1
  DIFFDUMP_OWNED_APPEND_ENGINE=
  diffdump_engine_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_OWNED_APPEND_ENGINE <<'DIFFDUMP_OWNED_APPEND_ENGINE' || diffdump_engine_rc=$?
import base64
import binascii
import hashlib
import json
import re
import sys

APPEND = {b"slice_append_fresh": b"slice_append",
          b"slice_append_str_fresh": b"slice_append_str",
          b"slice_append_slice_fresh": b"slice_append_slice"}
APPENDS = set(APPEND) | set(APPEND.values())
TERMS = {b"br", b"jump", b"ret", b"unreachable"}
EFFECTS = TERMS | {b"index_set", b"field_set", b"keep_alive"}
ARITH = {b"add", b"sub", b"mul", b"icmp_eq", b"icmp_ult", b"icmp_slt", b"icmp_sgt"}
TOKEN = re.compile(rb'"(?:\\.|[^"\\])*"|[A-Za-z_$@][A-Za-z0-9_$@.%]*|(?<![A-Za-z0-9_$@.%])%[0-9]+(?![A-Za-z0-9_$@.%])|(?<![A-Za-z0-9_$@.%])-?[0-9]+(?![A-Za-z0-9_$@.%])|.', re.S)
SOURCE_CALL = re.compile(rb"\s*\(")
remaining = 0


def require(ok):
    if not ok:
        raise ValueError("unsupported proof")


def spend(n=1):
    global remaining
    require(type(n) is int and n >= 0)
    remaining -= n
    require(remaining >= 0)


def root(parent, value):
    for unused in range(len(parent)):
        spend()
        if parent[value] == value:
            return value
        value = parent[value]
    raise ValueError("union bound")


def union(parent, a, b):
    a, b = root(parent, a), root(parent, b)
    parent[max(a, b)] = min(a, b)


def classes(f):
    parent = {v: v for v in f["defs"]}
    for b in f["order"]:
        for n in f["blocks"][b]["code"]:
            link_node(f, parent, n)
    result = {}
    for v in parent:
        result.setdefault(root(parent, v), set()).add(v)
    return {v: members for members in result.values() for v in members}


def link_node(f, parent, node):
    if node["op"] == b"rt_call" and node["name"] in APPENDS:
        require(node["out"] and len(node["args"]) == 4)
        union(parent, node["out"], node["args"][0])
    for target, args in node["targets"]:
        for v, pair in zip(args, f["blocks"][target]["params"]):
            union(parent, v, pair[0])


def fresh_class(f, members):
    for v in members:
        spend()
        b, i, unused = f["defs"][v]
        if i < 0:
            if b == f["order"][0] or not f["pred"][b]:
                return False
            continue
        node = f["blocks"][b]["code"][i]
        if node["op"] == b"const_nil":
            continue
        if node["op"] == b"rt_call" and node["name"] in APPENDS | {b"slice_new"}:
            continue
        return False
    return True


def liveness(f):
    live = {b: set() for b in f["order"]}
    for unused in range(len(f["defs"]) * len(f["order"]) + 1):
        changed = False
        for b in reversed(f["order"]):
            spend(len(f["defs"]) * (len(f["succ"][b]) + 1))
            values = set().union(*(live[s] for s in f["succ"][b]))
            for n in reversed(f["blocks"][b]["code"]):
                spend(1 + len(n["uses"]))
                values.discard(n["out"])
                values.update(n["uses"])
            values.difference_update(v for v, ty in f["blocks"][b]["params"])
            changed |= values != live[b]
            live[b] = values
        if not changed:
            return live
    raise ValueError("liveness bound")


def live_after(f, live):
    result = {}
    for b in f["order"]:
        values = set().union(*(live[s] for s in f["succ"][b]))
        for i in reversed(range(len(f["blocks"][b]["code"]))):
            n = f["blocks"][b]["code"][i]
            spend(len(f["defs"]) + len(n["uses"]))
            result[(b, i)] = set(values)
            values.discard(n["out"])
            values.update(n["uses"])
    return result


def reachable(f, start):
    reached, work = set(), list(f["succ"][start])
    for unused in range(len(f["order"]) + 1):
        if not work:
            return reached
        b = work.pop()
        if b in reached:
            continue
        spend(len(f["order"]))
        reached.add(b)
        work.extend(s for s in f["succ"][b] if s not in reached and s not in work)
    raise ValueError("reach bound")


def read_only(node, members):
    used = set(node["uses"]) & members
    if not used:
        return True
    if node["op"] in {b"slice_len", b"keep_alive", b"jump"}:
        return True
    if node["op"] == b"br":
        return node["ts"][1] not in members
    if node["op"] == b"field_get":
        return node["ts"][3] in {b"0", b"8", b"16", b"24"} and node["ty"] == (b"i64",)
    if node["op"] == b"rt_call" and node["name"] in APPENDS:
        return node["args"][0] in members and not (set(node["args"][1:]) & members)
    return False


def regenerated_pair(f, b, i, node, members):
    h = node["args"][0]
    if members != {h, node["out"]}:
        return False
    db, di, unused = f["defs"][h]
    if db != b or di < 0 or di >= i:
        return False
    seed = f["blocks"][db]["code"][di]
    return seed["op"] == b"rt_call" and seed["name"] == b"slice_new"


def prior_escape(b, i, eb, ei, reach, regenerated):
    if eb == b and ei <= i:
        return True
    # Re-entering this block executes the exclusive allocation again.
    return not regenerated and b in reach[eb]


def owned(f, b, i, groups, after, reach):
    node = f["blocks"][b]["code"][i]
    members = groups[node["args"][0]]
    if not fresh_class(f, members) or (after[(b, i)] & members) - {node["out"]}:
        return False
    if set(node["args"][1:]) & members:
        return False
    regenerated = regenerated_pair(f, b, i, node, members)
    for eb in f["order"]:
        for ei, use in enumerate(f["blocks"][eb]["code"]):
            spend(len(members) + len(use["uses"]))
            if read_only(use, members):
                continue
            if prior_escape(b, i, eb, ei, reach, regenerated):
                return False
    return True


def zero_offset(f, members):
    if not fresh_class(f, members):
        return False
    for b in f["order"]:
        for node in f["blocks"][b]["code"]:
            spend(len(members) + len(node["uses"]))
            if node["op"] != b"ret" and not read_only(node, members):
                return False
    return True


def constant(f, v, number):
    if v not in f["defs"]:
        return False
    b, i, unused = f["defs"][v]
    return i >= 0 and f["blocks"][b]["code"][i]["ts"] == [b"const_int", b"i64", str(number).encode()]


def supported_call(f, node):
    if node["name"] == b"slice_append_slice_fresh":
        return bulk_call(f, node)
    if node["name"] not in {b"slice_append_fresh", b"slice_append_slice_fresh"}:
        return False
    if node["ty"] != (b"[", b"]", b"i64") or len(node["args"]) != 4:
        return False
    h, value, refs, stride = node["args"]
    if f["defs"][h][2] != node["ty"]:
        return False
    if not constant(f, refs, 0) or not constant(f, stride, 8):
        return False
    ty = (b"i64",) if node["name"] == b"slice_append_fresh" else node["ty"]
    return f["defs"][value][2] == ty


def slice_operand(f, v, ty):
    b, i, actual = f["defs"][v]
    nil = i >= 0 and f["blocks"][b]["code"][i]["op"] == b"const_nil"
    return actual == ty or nil


def bulk_call(f, node):
    ty = node["ty"]
    if len(ty) < 3 or ty[:2] != (b"[", b"]") or len(node["args"]) != 4:
        return False
    h, value, refs, stride = node["args"]
    shape = constant(f, stride, 8) or (constant(f, refs, 0) and constant(f, stride, 1))
    flags = constant(f, refs, 0) or constant(f, refs, 1)
    return shape and flags and slice_operand(f, h, ty) and slice_operand(f, value, ty)


def align_modules(modules):
    old, new = modules["oracle"], modules["candidate"]
    require(len(old) == len(new))
    changed = set()
    for i, (a, b) in enumerate(zip(old, new)):
        spend()
        require(a["kind"] == b["kind"])
        require((a["graph"] is None) == (b["graph"] is None))
        if a["graph"] is None:
            require(a["raw"] == b["raw"])
        elif a["raw"] != b["raw"]:
            changed.add(i)
    require(changed)
    return changed


def class_shape(facts, cls):
    ts, ds = facts
    chosen = [d for d in ds if d["kind"] == "class" and byte(d["name"]) == cls]
    require(len(chosen) == 1 and chosen[0]["parent"] is None)
    shape = decl_tokens(ts, chosen[0])
    require(len(shape) in {9, 10} and shape[:3] == [b"class", cls, b"{"])
    require(re.fullmatch(rb"[A-Za-z_][A-Za-z0-9_]*", shape[3]))
    require(shape[4:] in ([b":", b"[", b"]", b"int", b"}"],
                          [b":", b"[", b"]", b"int", b",", b"}"]))
    return chosen[0]


def source_class(facts, cls, relevant, parsed):
    ts, ds = facts
    chosen = class_shape(facts, cls)
    mains = [d for d in ds if d["kind"] == "function" and d["name"] == "main"]
    require(len(mains) == 1 and mains[0]["parent"] is None)
    require(decl_tokens(ts, mains[0], True) == [b"fn", b"main", b"(", b")", b"{"])
    private = {byte(d["name"]) for d in ds if d["kind"] == "function" and d["parent"] is None}
    require(relevant <= private)
    source_scopes(facts, cls, relevant, parsed, chosen)


def source_scopes(facts, cls, relevant, parsed, chosen):
    ts, ds = facts
    for d in ds:
        if d is chosen:
            continue
        raw = b" ".join(decl_tokens(ts, d))
        spend(len(raw))
        refs = set(re.findall(rb"[A-Za-z_][A-Za-z0-9_]*", raw)) & (relevant | {cls})
        direct_source_refs(raw, relevant)
        if refs:
            require(d["kind"] == "function" and d["parent"] is None and byte(d["name"]) in parsed)
            require(decl_tokens(ts, d, True)[:3] == [b"fn", byte(d["name"]), b"("])


def direct_source_refs(raw, relevant):
    for match in re.finditer(rb"[A-Za-z_][A-Za-z0-9_]*", raw):
        if match[0] in relevant:
            require(SOURCE_CALL.match(raw, match.end()) is not None)


def function_inventory(module, cls):
    funcs, words = {}, {}
    for chunk in module:
        lexed = [t for t in TOKEN.findall(chunk["raw"]) if not t.isspace()]
        spend(len(chunk["raw"]))
        if chunk["kind"] == "function":
            name = lexed[1]
            require(name not in funcs)
            funcs[name], words[name] = chunk["graph"], lexed
            require(cls not in lexed or chunk["graph"] is not None)
    return funcs, words


def direct_calls(ts):
    return {t[1:] for i, t in enumerate(ts) if i and ts[i - 1] == b"call" and t.startswith(b"@")}


def field_program(module, facts, cls):
    funcs, words = function_inventory(module, cls)
    calls = {name: direct_calls(ts) for name, ts in words.items()}
    relevant = {name for name, ts in words.items() if cls in ts}
    relevant = call_closure(calls, relevant, True)
    reached = call_closure(calls, {b"main"}, False)
    require(relevant and relevant <= reached and b"main" in relevant)
    direct_references(funcs, words, relevant)
    parsed = {name for name, f in funcs.items() if f is not None}
    source_class(facts, cls, relevant, parsed)
    return {name: f for name, f in funcs.items() if f is not None}


def call_closure(calls, reached, reverse):
    for unused in range(len(calls)):
        spend(len(calls) * len(calls))
        if reverse:
            reached |= {name for name in calls if calls[name] & reached}
        else:
            reached |= set().union(*(calls[n] for n in reached if n in calls))
    return reached


def direct_references(funcs, words, relevant):
    for name, ts in words.items():
        for i, t in enumerate(ts):
            if t.startswith(b"@") and t[1:] in relevant:
                require(i > 0 and ts[i - 1] == b"call" and funcs[name] is not None)


def nodes(f):
    return [(b, i, n) for b in f["order"] for i, n in enumerate(f["blocks"][b]["code"])]


def object_inputs(funcs, name, b, v):
    f = funcs[name]
    spend(len(funcs) * 8192)
    pos = [p[0] for p in f["blocks"][b]["params"]].index(v)
    if b == f["order"][0]:
        return {(caller, n["args"][pos]) for caller, g in funcs.items() for eb, ei, n in nodes(g)
                if n["op"] == b"call" and n["name"] == b"@" + name}
    return {(name, args[pos]) for eb, ei, n in nodes(f) for target, args in n["targets"] if target == b}


def object_constraints(funcs, cls):
    deps, seeds = {}, set()
    for name, f in funcs.items():
        for v, (b, i, ty) in f["defs"].items():
            if ty != (cls,):
                continue
            key = (name, v)
            if i < 0:
                deps[key] = object_inputs(funcs, name, b, v)
                continue
            n = f["blocks"][b]["code"][i]
            require(n["op"] == b"gc_alloc")
            require(n["ts"] == [b"gc_alloc", b"size", b"=", b"8", b"ptrs", b"=", b"[", b"%0", b"]", cls])
            seeds.add(key)
            deps[key] = set()
    require(deps and seeds)
    require(all(inputs <= deps.keys() for inputs in deps.values()))
    return deps, seeds


def object_origins(deps, seeds):
    origins = {v: ({v} if v in seeds else set()) for v in deps}
    for unused in range(len(deps) + 1):
        changed = False
        for v, inputs in deps.items():
            spend(len(deps) * (len(inputs) + 1))
            value = origins[v] | set().union(*(origins[s] for s in inputs))
            changed |= value != origins[v]
            origins[v] = value
        if not changed:
            require(all(origins.values()))
            return
    raise ValueError("object origins bound")


def object_use(funcs, f, n, used, cls):
    if n["op"] in {b"field_get", b"field_set"}:
        return used == {n["ts"][1]} and n["ts"][3] == b"0"
    if n["op"] == b"keep_alive":
        return True
    if n["op"] in {b"jump", b"br"}:
        return used <= set().union(*(set(args) for target, args in n["targets"]))
    if n["op"] != b"call" or n["name"] is None:
        return False
    return object_call(funcs, n, used, cls)


def object_call(funcs, n, used, cls):
    target = n["name"][1:]
    if target not in funcs:
        return False
    params = funcs[target]["blocks"][funcs[target]["order"][0]]["params"]
    return all(params[i][1] == (cls,) for i, v in enumerate(n["args"]) if v in used)


def object_uses(funcs, deps, cls):
    for name, f in funcs.items():
        values = {v for owner, v in deps if owner == name}
        for b, i, n in nodes(f):
            spend(len(values) + len(n["uses"]))
            used = set(n["uses"]) & values
            require(not used or object_use(funcs, f, n, used, cls))


def seed_initializers(funcs, seeds):
    stores = set()
    for name, v in seeds:
        f = funcs[name]
        spend(8192)
        b, at, ty = f["defs"][v]
        uses = [(i, n) for i, n in enumerate(f["blocks"][b]["code"]) if v in n["uses"]]
        require(uses and uses[0][0] > at)
        i, store = uses[0]
        require(store["ts"][:6] == [b"field_set", v, b"[", b"0", b"]", b"="])
        h = store["ts"][6]
        hb, hi, ht = f["defs"][h]
        require(hi >= 0)
        n = f["blocks"][hb]["code"][hi]
        require(n["op"] == b"const_nil" or (n["name"] == b"slice_new" and ht == (b"[", b"]", b"i64")))
        require(n["op"] == b"const_nil" or sum(h in x["uses"] for eb, ei, x in nodes(f)) == 1)
        stores.add((id(f), b, i))
    return stores


def field_root(f, members):
    roots = []
    for v in members:
        b, i, ty = f["defs"][v]
        require(i >= 0)
        n = f["blocks"][b]["code"][i]
        if n["op"] == b"rt_call" and n["name"] in APPENDS:
            continue
        require(n["op"] == b"field_get" and ty == (b"[", b"]", b"i64") and n["ts"][3] == b"0")
        roots.append((n["ts"][1], f["defs"][n["ts"][1]][2]))
    require(len(roots) == 1 and len(roots[0][1]) == 1)
    return roots[0][0], roots[0][1][0]


def append_call(f, n):
    name = next((old for old, new in APPEND.items() if n["name"] == new), n["name"])
    return n["op"] == b"rt_call" and supported_call(f, dict(n, name=name))


def next_effect(f, b, i):
    code = f["blocks"][b]["code"]
    for at in range(i + 1, len(code)):
        spend()
        if code[at]["op"] not in {b"const_int", b"const_nil", b"const_string"}:
            return at
    raise ValueError("missing writeback")


def field_chain(f, members, receiver, after, all_headers):
    stores, appends = set(), set()
    for b, i, n in nodes(f):
        if n["op"] != b"rt_call" or n["name"] not in APPENDS:
            continue
        if n["args"][0] not in members:
            continue
        spend(len(members) + len(all_headers))
        require(append_call(f, n) and not (set(n["args"][1:]) & all_headers))
        require(not ((after[(b, i)] & members) - {n["out"]}))
        at = next_effect(f, b, i)
        expected = [b"field_set", receiver, b"[", b"0", b"]", b"=", n["out"]]
        require(f["blocks"][b]["code"][at]["ts"] == expected)
        stores.add((id(f), b, at))
        appends.add((id(f), b, i))
    require(len(appends) <= 2)
    return stores, appends


def data_pointer(f, n):
    if n["op"] != b"field_get" or n["ts"][3] != b"0":
        return
    for b, i, use in nodes(f):
        spend(len(use["uses"]))
        if n["out"] in use["uses"]:
            require(use["op"] == b"index_get" and use["ts"][1] == n["out"])
            require(use["uses"].count(n["out"]) == 1)


def header_barrier(n, location, objects, stores, appends):
    if n["op"] == b"call":
        return True
    if n["op"] == b"rt_call":
        return location not in appends
    return n["op"] == b"field_set" and n["ts"][1] in objects and location not in stores


def field_uses(f, members, objects, stores, appends, after):
    for b, i, n in nodes(f):
        spend(len(members) + len(n["uses"]))
        location = (id(f), b, i)
        used = set(n["uses"]) & members
        if used:
            require(location in stores or read_only(n, members))
            if n["op"] == b"field_get":
                data_pointer(f, n)
        if after[(b, i)] & members:
            require(not header_barrier(n, location, objects, stores, appends))


def field_analysis(f, cache):
    if id(f) not in cache:
        cache[id(f)] = classes(f), live_after(f, liveness(f)), {b: reachable(f, b) for b in f["order"]}
    return cache[id(f)]


def field_reads(f, cls):
    objects = {v for v, definition in f["defs"].items() if definition[2] == (cls,)}
    reads = [n["out"] for b, i, n in nodes(f) if n["op"] == b"field_get" and n["ts"][1] in objects]
    return objects, reads


def field_function(f, cls, initial, cache):
    objects, reads = field_reads(f, cls)
    if not objects:
        return set(), set()
    groups, after, reach = field_analysis(f, cache)
    all_headers = set().union(*(groups[v] for v in reads))
    stores, appends = set(initial), set()
    seen = set()
    for v in reads:
        if v in seen:
            continue
        members = groups[v]
        receiver, actual = field_root(f, members)
        require(actual == cls)
        own_stores, own_appends = field_chain(f, members, receiver, after, all_headers)
        field_uses(f, members, objects, own_stores, own_appends, after)
        seen |= members
        stores |= own_stores
        appends |= own_appends
    field_stores(f, objects, stores)
    return appends, {(id(f), v) for v in seen}


def field_stores(f, objects, allowed):
    for b, i, n in nodes(f):
        spend()
        if n["op"] == b"field_set" and n["ts"][1] in objects:
            require((id(f), b, i) in allowed)


def prove_field(f, at, node, groups, side, modules, facts, cache):
    v = at if node is None else node["args"][0]
    receiver, cls = field_root(f, groups[v])
    key = (side, cls)
    if key not in cache:
        require(facts is not None)
        funcs = field_program(modules[side], facts, cls)
        deps, seeds = object_constraints(funcs, cls)
        object_origins(deps, seeds)
        object_uses(funcs, deps, cls)
        initial = seed_initializers(funcs, seeds)
        appends, zero = set(), set()
        for g in funcs.values():
            a, z = field_function(g, cls, initial, cache)
            appends |= a
            zero |= z
        cache[key] = appends, zero
    appends, zero = cache[key]
    return (id(f), v) in zero if node is None else (id(f), *at) in appends


def query(obj, modules):
    keys(obj, "id side fn kind block index value")
    require(type(obj["id"]) is str and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", obj["id"]))
    require(type(obj["side"]) is str and obj["side"] in modules)
    fn = integer(obj["fn"], 0, len(modules[obj["side"]]) - 1)
    f = modules[obj["side"]][fn]["graph"]
    require(f is not None)
    if obj["kind"] == "zero":
        require(obj["block"] is None and obj["index"] is None)
        v = value_id(obj["value"])
        require(v in f["defs"])
        return f, v, None
    require(obj["kind"] == "owned" and obj["side"] == "oracle" and obj["value"] is None)
    b = label(obj["block"])
    require(b in f["blocks"])
    i = integer(obj["index"], 0, len(f["blocks"][b]["code"]) - 1)
    n = f["blocks"][b]["code"][i]
    require(n["op"] == b"rt_call" and supported_call(f, n))
    return f, (b, i), n


def prove_queries(queries, modules, changed, facts):
    cache, owned_sites, seen, sites = {}, {}, set(), set()
    for q in sequence(queries, 1, 4096):
        f, at, node = query(q, modules)
        require(q["id"] not in seen)
        seen.add(q["id"])
        key = (q["side"], q["fn"])
        if key not in cache:
            cache[key] = classes(f), live_after(f, liveness(f)), {b: reachable(f, b) for b in f["order"]}
        groups, after, reach = cache[key]
        cache[id(f)] = groups, after, reach
        if node is None:
            require(zero_offset(f, groups[at]) or prove_field(f, at, None, groups, q["side"], modules, facts, cache))
            continue
        require((q["fn"], *at) not in sites)
        sites.add((q["fn"], *at))
        require(owned(f, *at, groups, after, reach) or prove_field(f, at, node, groups, q["side"], modules, facts, cache))
        owned_sites.setdefault(q["fn"], []).append(node)
    require(set(owned_sites) == changed)
    companion(owned_sites, cache)


def companion(owned_sites, cache):
    for fn, nodes in owned_sites.items():
        groups = cache[("oracle", fn)][0]
        bulk = [n["args"][0] for n in nodes if n["name"] == b"slice_append_slice_fresh"]
        require(bulk)
        for n in nodes:
            spend(len(bulk))
            require(any(n["args"][0] in groups[h] for h in bulk))


def main():
    global remaining
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    require(0 < len(data) <= 8 * 1024 * 1024)
    obj = json.loads(data, object_pairs_hook=unique_object)
    keys(obj, "version work_left modules queries source")
    require(type(obj["version"]) is int and obj["version"] == 1)
    remaining = integer(obj["work_left"], 1, 1000000)
    keys(obj["modules"], "oracle candidate")
    modules = {side: load_module(obj["modules"][side]) for side in ("oracle", "candidate")}
    facts = None if obj["source"] is None else source_facts(obj["source"])
    prove_queries(obj["queries"], modules, align_modules(modules), facts)
    response = json.dumps({"version": 1, "query_ids": [q["id"] for q in obj["queries"]],
                           "work_left": remaining}, separators=(",", ":")).encode("ascii") + b"\n"
    require(len(response) <= 65536)
    sys.stdout.buffer.write(response)


try:
    main()
except (ValueError, TypeError, KeyError, IndexError, OverflowError, RecursionError, binascii.Error):
    sys.exit(1)
DIFFDUMP_OWNED_APPEND_ENGINE
  [ "$diffdump_engine_rc" -eq 1 ] || exit 1
  LC_ALL=C
  export LC_ALL
  DIFFDUMP_OWNED_APPEND_CODE="${DIFFDUMP_OWNED_APPEND_PYTHON}"$'\n'"${DIFFDUMP_OWNED_APPEND_ENGINE}"
  [ "${#DIFFDUMP_OWNED_APPEND_CODE}" -le 65536 ] || exit 1
  exec python3 -I /dev/fd/3 3<<<"${DIFFDUMP_OWNED_APPEND_CODE}"
fi

# Keep the ordinary selfcheck in its existing test file, without a child PID.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  exec /bin/bash "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-signatures-selfcheck.sh" --canon-only
fi
