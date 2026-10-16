#!/usr/bin/env bash
# Shared structural identities for the IR comparisons (#3125, #3132).
# Unknown differences fail closed; filenames never authorize a difference.
# Rationale and history: docs/development/dump-differential.md.

# explainMismatch <oracle_text> <bit2_text> <kind> [file]
explainMismatch() {
  [ "$3" = iropt ] || return 1
  local LC_ALL=C
  [ "$((${#1} + ${#2} + 1))" -le 8388608 ] || return 1
  local proof_source="${BASH_SOURCE[0]%/*}/selfhost-ir-canon.sh"
  { printf '%s\0%s' "$1" "$2"; } | python3 /dev/fd/3 "$proof_source" "${4:-}" 3<<'PYTHON'
import base64
import bisect
import hashlib
import json
import os
import re
import stat
import subprocess
import sys

TOKEN = re.compile(rb'"(?:\\.|[^"\\])*"|[A-Za-z_$@][A-Za-z0-9_$@.%]*|(?<![A-Za-z0-9_$@.%])%[0-9]+(?![A-Za-z0-9_$@.%])|(?<![A-Za-z0-9_$@.%])-?[0-9]+(?![A-Za-z0-9_$@.%])|.', re.S)
RECORD = re.compile(rb'"(?:\\.|[^"\\])*"|[^"\n]+|\n|"', re.S)
APPEND = {b"slice_append_fresh": b"slice_append",
          b"slice_append_str_fresh": b"slice_append_str",
          b"slice_append_slice_fresh": b"slice_append_slice"}
TERMS = {b"br", b"jump", b"ret", b"unreachable"}
ARITH = {b"add", b"sub", b"mul", b"srem", b"icmp_eq", b"icmp_ult", b"icmp_ule", b"icmp_slt", b"icmp_sgt"}
remaining = 1000000


def require(ok):
    if not ok:
        raise ValueError("unsupported identity")


def spend(n=1):
    global remaining
    remaining -= n
    require(remaining >= 0)


def records(data):
    result, row = [], []
    for match in RECORD.finditer(data):
        token = match[0]
        require(token != b'"')
        if token == b"\n":
            result.append(b"".join(row))
            row = []
        else:
            row.append(token)
    result.append(b"".join(row))
    return result


def tokens(row):
    spend(len(row))
    result = TOKEN.findall(row)
    require(b'"' not in result)
    return result


def compact(row):
    ts = tokens(row)
    require(all(t.startswith(b'"') or b"\r" not in t for t in ts))
    return [t for t in ts if not t.isspace()]


def ident(t):
    return re.fullmatch(rb"%[0-9]+", t) is not None


def blockid(t):
    return re.fullmatch(rb"bb[0-9]+", t) is not None


def comma_groups(ts):
    require(not ts or ts[-1] != b",")
    result, current = [], []
    for t in ts:
        if t == b",":
            require(current)
            result.append(current)
            current = []
        else:
            current.append(t)
    if current:
        result.append(current)
    return result


def params(ts):
    result = []
    for group in comma_groups(ts):
        require(len(group) >= 3 and ident(group[0]) and group[1] == b":")
        require(not any(ident(t) for t in group[2:]))
        result.append((group[0], tuple(group[2:])))
    return result


def arguments(ts):
    groups = comma_groups(ts)
    require(all(len(g) == 1 and ident(g[0]) for g in groups))
    return [g[0] for g in groups]


def call_parts(ts):
    require(len(ts) >= 5 and ts[2] == b"(")
    require(re.fullmatch(rb"[A-Za-z_$@][A-Za-z0-9_$@.%]*", ts[1]))
    close = ts.index(b")", 3)
    return ts[1], arguments(ts[3:close]), tuple(ts[close + 1:])


def branch_targets(ts):
    result, at = [], 1 if ts[0] == b"jump" else 3
    if ts[0] == b"br":
        require(len(ts) > 3 and ident(ts[1]) and ts[2] == b",")
    count = 1 if ts[0] == b"jump" else 2
    for index in range(count):
        require(blockid(ts[at]) and ts[at + 1] == b"(")
        close = ts.index(b")", at + 2)
        result.append((ts[at], arguments(ts[at + 2:close])))
        at = close + 1
        if index + 1 < count:
            require(ts[at] == b",")
            at += 1
    require(at == len(ts))
    return result


def allocation_type(ts):
    require(len(ts) >= 9 and ts[:3] == [b"gc_alloc", b"size", b"="])
    require(ts[3].isdigit() and 0 < int(ts[3]) <= 8388608)
    require(ts[4:7] == [b"ptrs", b"=", b"["])
    close = ts.index(b"]", 7)
    slots = comma_groups(ts[7:close])
    require(len(slots) <= 256)
    require(all(len(s) == 1 and ident(s[0]) and int(s[0][1:]) < int(ts[3]) for s in slots))
    require(len(ts[close + 1:]) == 1 and re.fullmatch(rb"[A-Za-z_][A-Za-z_0-9]*", ts[-1]))
    return (ts[-1],)


def simple_type(ts):
    if ts[0] == b"slice_len":
        require(len(ts) == 2 and ident(ts[1]))
        return (b"i64",)
    require(len(ts) == 3 and ts[1] == b"u8" and ident(ts[2]))
    return (b"u8",)


def result_type(ts):
    op = ts[0]
    if op in ARITH or op == b"const_int":
        require(len(ts) >= 3)
        return (ts[1],)
    if op == b"const_string":
        require(len(ts) == 2 and ts[1].startswith(b'"'))
        return (b"string",)
    if op == b"const_nil":
        require(len(ts) == 1)
        return ()
    if op in {b"slice_len", b"convert"}:
        return simple_type(ts)
    if op == b"gc_alloc":
        return allocation_type(ts)
    require(op in {b"field_get", b"index_get"})
    require(len(ts) >= 6 and ts[2] == b"[" and ts[4] == b"]")
    return tuple(ts[5:])


def instruction(row):
    ts = compact(row)
    require(ts)
    out = None
    if ident(ts[0]):
        require(len(ts) > 2 and ts[1] == b"=")
        out, ts = ts[0], ts[2:]
    op, ty, name, args = ts[0], (), None, []
    if op in {b"rt_call", b"call"}:
        name, args, ty = call_parts(ts)
    elif op not in TERMS | {b"index_set", b"field_set", b"keep_alive"}:
        ty = result_type(ts)
    targets = branch_targets(ts) if op in {b"br", b"jump"} else []
    require(not any(ident(t) for t in ty))
    require((out is None) == (op in TERMS | {b"index_set", b"field_set", b"keep_alive"}))
    return {"row": row, "ts": ts, "out": out, "op": op, "ty": ty,
            "name": name, "args": args, "targets": targets,
            "uses": [] if op == b"gc_alloc" else [t for t in ts if ident(t)]}


def parse(rows):
    header = compact(rows[0])
    require(header[0] == b"func" and header[2] == b"(" and header[-1] == b"{")
    close = header.index(b")", 3)
    formals = params(header[3:close])
    blocks, order, current = {}, [], None
    for row in rows[1:-1]:
        spend()
        ts = compact(row)
        require(ts)
        if blockid(ts[0]):
            require(ts[1] == b"(" and ts[-2:] == [b")", b":"])
            current = ts[0]
            require(current not in blocks)
            blocks[current] = {"row": row, "params": params(ts[2:-2]), "code": []}
            order.append(current)
        else:
            require(current is not None)
            blocks[current]["code"].append(instruction(row))
    require(0 < len(order) <= 256 and blocks[order[0]]["params"] == formals)
    require(sum(len(b["code"]) for b in blocks.values()) <= 4096)
    f = {"header": rows[0], "blocks": blocks, "order": order}
    validate(f)
    return f


def definitions(f):
    result = {}
    for b in f["order"]:
        blk = f["blocks"][b]
        pairs = [(v, -1, ty) for v, ty in blk["params"]]
        pairs += [(n["out"], i, n["ty"]) for i, n in enumerate(blk["code"]) if n["out"]]
        for v, i, ty in pairs:
            require(v not in result)
            result[v] = (b, i, ty)
    return result


def edges(f):
    pred = {b: set() for b in f["order"]}
    succ = {b: set() for b in f["order"]}
    for b in f["order"]:
        code = f["blocks"][b]["code"]
        require(code and code[-1]["op"] in TERMS)
        require(all(n["op"] not in TERMS for n in code[:-1]))
        for target, args in code[-1]["targets"]:
            require(target in pred)
            require(len(args) == len(f["blocks"][target]["params"]))
            pred[target].add(b)
            succ[b].add(target)
    return pred, succ


def dominators(order, pred):
    entry, allb = order[0], set(order)
    require(not pred[entry])
    require(entry_reaches(order, pred))
    dom = {b: ({b} if b == entry else set(allb)) for b in order}
    for unused in range(len(order) * len(order) + 1):
        changed = False
        for b in order[1:]:
            spend(len(order) * len(pred[b]))
            require(pred[b])
            value = {b} | set.intersection(*(dom[p] for p in pred[b]))
            changed |= value != dom[b]
            dom[b] = value
        if not changed:
            require(all(entry in dom[b] for b in order))
            return dom
    raise ValueError("dominance bound")


def entry_reaches(order, pred):
    seen = {order[0]}
    for unused in range(len(order)):
        spend(len(order) * len(order))
        before = len(seen)
        seen.update(b for b in order if pred[b] & seen)
        if len(seen) == before:
            return len(seen) == len(order)
    return len(seen) == len(order)


def validate(f):
    defs = definitions(f)
    require(len(defs) <= 8192)
    pred, succ = edges(f)
    dom = dominators(f["order"], pred)
    for b in f["order"]:
        for i, node in enumerate(f["blocks"][b]["code"]):
            for v in node["uses"]:
                spend()
                require(v in defs)
                db, di, unused = defs[v]
                require((db == b and di < i) or (db != b and db in dom[b]))
            for target, args in node["targets"]:
                for v, pair in zip(args, f["blocks"][target]["params"]):
                    require(not defs[v][2] or defs[v][2] == pair[1])
    f.update({"defs": defs, "pred": pred, "succ": succ})

def body(node, expected):
    return node["ts"] == expected


def constant(f, v, number):
    if v not in f["defs"]:
        return False
    b, i, unused = f["defs"][v]
    return i >= 0 and body(f["blocks"][b]["code"][i],
                           [b"const_int", b"i64", str(number).encode()])


def scalar_fast(f, code, h, length, value, join):
    require(len(code) in {5, 6, 7, 8})
    data = code[0]["out"]
    require(body(code[0], [b"field_get", h, b"[", b"0", b"]", b"i64"]))
    at, slot, zero = 1, length, True
    if code[1]["op"] == b"field_get":
        off = code[1]["out"]
        require(body(code[1], [b"field_get", h, b"[", b"16", b"]", b"i64"]))
        require(body(code[2], [b"add", b"i64", off, b",", length]))
        at, slot, zero = 3, code[2]["out"], False
    require(body(code[at], [b"index_set", data, b"[", slot, b"]", b"=", value]))
    at += 1
    if code[at]["op"] == b"const_int":
        require(body(code[at], [b"const_int", b"i64", b"1"]))
        at += 1
    bump = code[at]
    require(len(bump["ts"]) == 5 and bump["ts"][:4] == [b"add", b"i64", length, b","])
    require(constant(f, bump["ts"][4], 1))
    require(body(code[at + 1], [b"field_set", h, b"[", b"8", b"]", b"=", bump["out"]]))
    require(code[at + 2]["targets"] == [(join, [h])] and at + 3 == len(code))
    return zero


def uses_outside(f, removed, allowed):
    for b in f["order"]:
        for i, node in enumerate(f["blocks"][b]["code"]):
            spend(len(node["uses"]))
            if (b, i) not in allowed:
                require(not (set(node["uses"]) & removed))


def island_header(f, b):
    blk = f["blocks"][b]
    if len(blk["code"]) < 4:
        return None
    length, cap, cmp, branch = blk["code"][-4:]
    if length["op"] != b"slice_len" or branch["op"] != b"br":
        return None
    h = length["ts"][1]
    if not capacity_header(h, length, cap, cmp, branch) or f["defs"][h][2] != (b"[", b"]", b"i64"):
        return None
    (fast, fa), (grow, ga) = branch["targets"]
    require(not fa and not ga and fast != grow)
    require(f["pred"][fast] == {b} and f["pred"][grow] == {b})
    require(not f["blocks"][fast]["params"] and not f["blocks"][grow]["params"])
    return h, length, fast, grow


def capacity_header(h, length, cap, cmp, branch):
    if not body(cap, [b"field_get", h, b"[", b"24", b"]", b"i64"]):
        return False
    if not body(cmp, [b"icmp_slt", b"bool", length["out"], b",", cap["out"]]):
        return False
    return branch["ts"][1] == cmp["out"]


def island(f, b):
    header = island_header(f, b)
    if header is None:
        return None
    h, length, fast, grow = header
    fc, gc = f["blocks"][fast]["code"], f["blocks"][grow]["code"]
    require(len(gc) == 2 and gc[0]["op"] == b"rt_call")
    require(gc[0]["name"] == b"slice_append")
    call = gc[0]
    require(len(call["args"]) == 4 and call["args"][0] == h)
    require(constant(f, call["args"][2], 0) and constant(f, call["args"][3], 8))
    require(f["defs"][call["args"][1]][2] == (b"i64",))
    require(len(gc[1]["targets"]) == 1)
    join, ja = gc[1]["targets"][0]
    require(len({b, fast, grow, join}) == 4)
    require(ja == [call["out"]] and f["pred"][join] == {fast, grow})
    require(len(f["blocks"][join]["params"]) == 1)
    result, ty = f["blocks"][join]["params"][0]
    require(ty == call["ty"] == (b"[", b"]", b"i64"))
    zero = scalar_fast(f, fc, h, length["out"], call["args"][1], join)
    return fast, grow, join, result, call, zero


def collapse(f, b, shape):
    fast, grow, join, result, call, zero = shape
    head = f["blocks"][b]["code"]
    allowed = {(b, i) for i in range(len(head) - 4, len(head))}
    allowed |= {(x, i) for x in (fast, grow) for i in range(len(f["blocks"][x]["code"]))}
    removed = {n["out"] for x, i in allowed for n in [f["blocks"][x]["code"][i]] if n["out"]}
    uses_outside(f, removed, allowed)
    row = b"  " + result + b" = rt_call slice_append(" + b", ".join(call["args"]) + b") []i64"
    f["blocks"][b]["code"] = head[:-4] + [instruction(row)] + f["blocks"][join]["code"]
    for x in (fast, grow, join):
        require(x != f["order"][0] and x != b)
        del f["blocks"][x]
        f["order"].remove(x)
    validate(f)
    return call["args"][0] if zero else None


def inverse(f):
    zero = []
    for unused in range(4096):
        changed = False
        for b in list(f["order"]):
            spend()
            shape = island(f, b)
            if shape is None:
                continue
            value = collapse(f, b, shape)
            if value is not None:
                zero.append(value)
            changed = True
            break
        if not changed:
            return zero
    raise ValueError("island bound")


def roles(row, positions):
    ts = [row[i] for i in positions]
    if ts[0] == b"func":
        return set(), True
    if blockid(ts[0]):
        return {positions[0]}, True
    op = ts[2] if ident(ts[0]) else ts[0]
    if op == b"gc_alloc":
        return set(), {positions[0]}
    if op not in {b"br", b"jump"}:
        return set(), False
    return {i for i in positions if blockid(row[i])}, False


def mapped_token(a, b, maps, is_block):
    require(blockid(b) if is_block else ident(b))
    forward, backward = maps[1 if is_block else 0]
    if forward.get(a, b) != b or backward.get(b, a) != a:
        return False
    forward[a], backward[b] = b, a
    return True


def mapped_kind(token, next_token, blocks, parameters, index):
    if ident(token):
        if isinstance(parameters, set):
            return 0 if index in parameters else -1
        return 0 if not parameters or next_token == b":" else -1
    if index in blocks:
        return 1
    return -1


def mapped_row(old, new, maps):
    left, right = tokens(old), tokens(new)
    if len(left) != len(right):
        return False
    meaningful = [i for i, t in enumerate(left) if not t.isspace()]
    blocks, parameters = roles(left, meaningful)
    next_token = {i: left[j] for i, j in zip(meaningful, meaningful[1:])}
    for i, (a, b) in enumerate(zip(left, right)):
        spend()
        kind = mapped_kind(a, next_token.get(i), blocks, parameters, i)
        if kind >= 0:
            if not mapped_token(a, b, maps, kind == 1):
                return False
        elif a != b:
            return False
    return True


def compared_node(f, old, new, maps):
    if old["name"] == new["name"]:
        return mapped_row(old["row"], new["row"], maps), False
    if APPEND.get(old["name"]) != new["name"] or old["op"] != b"rt_call":
        return False, False
    row = new["row"].replace(b"rt_call " + new["name"] + b"(",
                              b"rt_call " + old["name"] + b"(", 1)
    return mapped_row(old["row"], row, maps), True


def compare_function(old_rows, new_rows):
    old, new = parse(old_rows), parse(new_rows)
    oldzero, newzero = inverse(old), inverse(new)
    maps = [[{}, {}], [{}, {}]]
    require(mapped_row(old["header"], new["header"], maps))
    require(len(old["order"]) == len(new["order"]))
    queries = [query("zero", "oracle", value=v) for v in oldzero]
    queries += [query("zero", "candidate", value=v) for v in newzero]
    changed = 0
    for ob, nb in zip(old["order"], new["order"]):
        left, right = old["blocks"][ob], new["blocks"][nb]
        require(mapped_row(left["row"], right["row"], maps))
        require(len(left["code"]) == len(right["code"]))
        for i, (a, b) in enumerate(zip(left["code"], right["code"])):
            same, delta = compared_node(old, a, b, maps)
            require(same)
            if delta:
                queries.append(query("owned", "oracle", ob, i))
                changed += 1
    require(changed)
    return old, new, queries


def query(kind, side, block=None, index=None, value=None):
    return {"kind": kind, "side": side, "block": block, "index": index, "value": value}


def chunks(rows):
    result, current = [], []
    for row in rows:
        if row.startswith(b"func "):
            require(not current)
            current = [row]
        elif current:
            current.append(row)
            if row == b"}":
                result.append(current)
                current = []
        else:
            result.append(row)
    require(not current and len(result) <= 8192)
    return result


def encoded(value, depth=0):
    require(depth <= 16)
    if isinstance(value, bytes):
        return value.decode("latin1")
    if value is None or isinstance(value, (str, int)):
        return value
    if isinstance(value, (list, tuple)):
        return [encoded(v, depth + 1) for v in value]
    require(isinstance(value, dict))
    return {encoded(k, depth + 1): encoded(v, depth + 1) for k, v in value.items()}


def graph(f):
    result = {"header": f["header"], "order": f["order"], "blocks": {}}
    fields = ("row", "ts", "out", "op", "ty", "name", "args", "targets")
    for b in f["order"]:
        block = f["blocks"][b]
        result["blocks"][b] = {"row": block["row"], "params": block["params"],
                               "code": [{k: n[k] for k in fields} for n in block["code"]]}
    return result


def inventory(chunks, original):
    result, raw = [], []
    for chunk in chunks:
        data = b"\n".join(chunk) if isinstance(chunk, list) else chunk
        raw.append(data)
        result.append({"kind": "function" if isinstance(chunk, list) else "raw",
                       "raw_b64": base64.b64encode(data).decode("ascii"), "graph": None})
    require(b"\n".join(raw) == original)
    return {"sha256": hashlib.sha256(original).hexdigest(), "chunks": result}


def proof_view(f):
    rows = [f["header"]]
    for b in f["order"]:
        block = f["blocks"][b]
        rows.append(block["row"])
        rows.extend(n["row"] for n in block["code"])
    return b"\n".join(rows + [b"}"])


def bind_graph(record, f):
    record["graph"] = graph(f)
    record["raw_b64"] = base64.b64encode(proof_view(f)).decode("ascii")


def seal_module(module):
    raw = b"\n".join(base64.b64decode(c["raw_b64"]) for c in module["chunks"])
    module["sha256"] = hashlib.sha256(raw).hexdigest()


SOURCE = re.compile(rb'(?P<whitespace>\s+)|(?P<comment>//[^\n]*|/\*(?:[^*]|\*(?!/))*\*/)|(?P<string>"(?:\\.|[^"\\])*")|(?P<word>[A-Za-z_][A-Za-z_0-9]*)|(?P<punct>[^\s])', re.S)


def source_tokens(raw):
    parts, texts, offset = [], [], 0
    spend(len(raw))
    for m in SOURCE.finditer(raw):
        require(m.start() == offset)
        kind, token = m.lastgroup, m[0]
        if kind == "punct":
            require(token[0] < 128 and token not in {b'"', b"'", bytes([96])})
            require(raw[m.start():m.start() + 2] != b"/*")
        if kind == "string":
            expressions = re.findall(rb'\$\{[^{}"\\]*\}', token)
            require(token.count(bytes([36, 123])) == len(expressions))
            require(not any(re.search(rb'\b(fn|class|interface|let|export|extern)\b|[;=@]', e) for e in expressions))
        parts.append([m.start(), m.end(), kind])
        texts.append(token)
        offset = m.end()
    require(offset == len(raw) and len(parts) <= 65536)
    return parts, texts


def source_braces(parts, texts):
    significant = [i for i, p in enumerate(parts) if p[2] not in {"whitespace", "comment"}]
    pair, depth, stack = {}, {}, []
    for i in significant:
        depth[i] = len(stack)
        if texts[i] == b"{":
            stack.append(i)
        elif texts[i] == b"}":
            require(stack)
            pair[stack.pop()] = i
        elif texts[i] in {b"fn", b"class", b"interface"}:
            require(not stack)
    require(not stack)
    return significant, pair, depth


def method_starts(inside, texts, depth):
    return [i for a, i in enumerate(inside[:-1])
            if depth[i] == 1 and re.fullmatch(rb'[A-Za-z_][A-Za-z_0-9]*', texts[i])
            and texts[inside[a + 1]] == b"("]


def method_body(inside, start, end, texts, depth):
    spend(len(inside))
    return next((i for i in inside if start < i < end and depth[i] == 1 and texts[i] == b"{"), None)


def source_methods(decls, parent, sig, texts, pair, depth):
    spend(len(sig))
    owner = decls[parent]
    inside = [i for i in sig if owner["body"] < i < owner["end"] - 1]
    starts = method_starts(inside, texts, depth)
    for at, start in enumerate(starts):
        end = starts[at + 1] if at + 1 < len(starts) else owner["end"] - 1
        body = method_body(inside, start, end, texts, depth)
        decls.append({"kind": "method", "name": texts[start].decode("ascii"), "start": start,
                      "body": body, "end": pair[body] + 1 if body is not None else end, "parent": parent})


def source_inventory(raw, path):
    parts, texts = source_tokens(raw)
    sig, pair, depth = source_braces(parts, texts)
    decls, at = [], 0
    kinds = {b"fn": "function", b"class": "class", b"interface": "interface"}
    for unused in range(len(sig)):
        if at == len(sig):
            break
        start, word = sig[at], texts[sig[at]]
        require(depth[start] == 0)
        if word == b"import":
            stop = next((j for j in range(at + 1, len(sig)) if parts[sig[j]][2] == "string"), None)
            require(stop is not None)
            decls.append({"kind": "import", "name": "", "start": start,
                          "body": None, "end": sig[stop] + 1, "parent": None})
            at = stop + 1
            continue
        require(word in kinds and at + 2 < len(sig))
        name = texts[sig[at + 1]]
        require(re.fullmatch(rb'[A-Za-z_][A-Za-z_0-9]*', name))
        spend(len(sig) - at)
        body = next((sig[j] for j in range(at + 2, len(sig)) if texts[sig[j]] == b"{"), None)
        require(body in pair)
        decls.append({"kind": kinds[word], "name": name.decode("ascii"), "start": start,
                      "body": body, "end": pair[body] + 1, "parent": None})
        if word != b"fn":
            source_methods(decls, len(decls) - 1, sig, texts, pair, depth)
        at = bisect.bisect_right(sig, pair[body])
    require(at == len(sig))
    return {"version": 1, "path": path, "raw_b64": base64.b64encode(raw).decode("ascii"),
            "sha256": hashlib.sha256(raw).hexdigest(), "tokens": parts, "decls": decls}


def source_snapshot():
    require(0 < len(sys.argv[2]) <= 4096)
    path = os.path.abspath(sys.argv[2])
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_size <= 1048576)
        raw = stream.read(1048577)
        after, current = os.fstat(stream.fileno()), os.stat(path, follow_symlinks=False)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns))
        require((current.st_dev, current.st_ino) == (before.st_dev, before.st_ino))
        require(len(raw) == before.st_size)
    return source_inventory(raw, path)


def field_types(record):
    if record["graph"] is None:
        return set()
    f = parse(records(base64.b64decode(record["raw_b64"])))
    selected = set()
    for block in f["blocks"].values():
        for n in block["code"]:
            if n["op"] == b"field_get" and n["ty"] == (b"[", b"]", b"i64"):
                selected.update(f["defs"][n["ts"][1]][2])
    return selected


def mentions(ts, names):
    return any(t.lstrip(b"@") in names for t in ts)


def context_indices(facts, selected):
    names = {i: ts[1] for i, ts in facts.items()}
    needed = {i for i, ts in facts.items() if set(ts) & selected or names[i] == b"main"}
    for unused in range(len(names) + 1):
        callees = {names[i] for i in needed}
        spend(sum(map(len, facts.values())))
        grew = {i for i, ts in facts.items() if mentions(ts, callees)}
        if grew <= needed:
            return needed
        needed |= grew
    raise ValueError("caller bound")


def source_context(modules, old, new):
    selected = set().union(*(field_types(c) for c in modules["oracle"]["chunks"]))
    if not selected:
        return None
    facts = {i: compact(b"\n".join(c)) for i, c in enumerate(old) if isinstance(c, list)}
    needed = context_indices(facts, selected)
    for i in needed:
        require(isinstance(old[i], list) and isinstance(new[i], list))
        for side, chunks_ in (("oracle", old), ("candidate", new)):
            if modules[side]["chunks"][i]["graph"] is None:
                bind_graph(modules[side]["chunks"][i], parse(chunks_[i]))
    return source_snapshot()


def compare(left, right):
    old, new = chunks(records(left)), chunks(records(right))
    require(len(old) == len(new))
    modules = {"oracle": inventory(old, left), "candidate": inventory(new, right)}
    queries = []
    for index, (a, b) in enumerate(zip(old, new)):
        spend()
        if a == b:
            continue
        require(isinstance(a, list) and isinstance(b, list))
        of, nf, pending = compare_function(a, b)
        bind_graph(modules["oracle"]["chunks"][index], of)
        bind_graph(modules["candidate"]["chunks"][index], nf)
        for q in pending:
            q.update({"id": "q" + str(len(queries)), "fn": index})
            queries.append(q)
    require(0 < len(queries) <= 4096)
    source = source_context(modules, old, new)
    for module in modules.values():
        seal_module(module)
    return encoded({"version": 1, "work_left": remaining, "modules": modules,
                    "queries": queries, "source": source})


def unique_object(pairs):
    result = dict(pairs)
    require(len(result) == len(pairs))
    return result


def prove(packet):
    global remaining
    wire = json.dumps(packet, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    require(len(wire) <= 8 * 1024 * 1024)
    environment = dict(os.environ)
    environment.pop("BASH_ENV", None)
    environment.pop("ENV", None)
    result = subprocess.run(["/bin/bash", sys.argv[1], "--prove-owned-appends"],
                            input=wire, capture_output=True, timeout=5, env=environment)
    require(result.returncode == 0 and result.stderr == b"")
    require(len(result.stdout) <= 65536)
    response = json.loads(result.stdout, object_pairs_hook=unique_object)
    require(type(response) is dict and set(response) == {"version", "query_ids", "work_left"})
    require(type(response["version"]) is int and response["version"] == 1)
    require(response["query_ids"] == [q["id"] for q in packet["queries"]])
    require(type(response["work_left"]) is int)
    require(0 <= response["work_left"] <= packet["work_left"])
    remaining = response["work_left"]


try:
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    require(len(data) <= 8 * 1024 * 1024 and data.count(b"\0") == 1)
    old, new = data.split(b"\0")
    prove(compare(old, new))
except (ValueError, KeyError, IndexError, TypeError, RecursionError, OSError, subprocess.TimeoutExpired):
    sys.exit(1)
print("6175-owned-append-local")
PYTHON
}

# declaredSignatureNames [kind] -- the retirement audit still consults this table.
declaredSignatureNames() {
  if [ "${1:-iropt}" = iropt ]; then
    printf '%s\n' '6175-owned-append-local'
  fi
}

# shellcheck source=scripts/selfhost-ir-canon.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-canon.sh"
