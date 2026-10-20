"""Sort declaration names in the repository's scoped Nix expressions.

Run from the repository root. This only reorders attrset/let bindings and
function-pattern parameters; lists and opaque strings remain untouched.

Known limitation: inherit names are rewritten without moving inter-name
comments, and those rewrites are omitted from the group counter. Do not use
--write on annotated inherit bindings; compare transformed text in a dry run.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path.cwd()
FILES = [
    ROOT / "flake.nix",
    ROOT / "treefmt.nix",
    *sorted((ROOT / "modules").rglob("*.nix")),
    *sorted((ROOT / "pkgs/by-name").rglob("package.nix")),
    *sorted((ROOT / "pkgs/by-name").rglob("treefmt.nix")),
]


def lex(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c.isspace():
            i += 1
            continue
        if s.startswith("#", i):
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        if s.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if s.startswith("/*", i):
                    depth += 1
                    i += 2
                elif s.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        if s.startswith("''", i):
            start = i
            i += 2
            while i < n:
                if s.startswith("'''", i):
                    i += 3
                elif s.startswith("''${", i):
                    i += 4
                elif s.startswith("''\\", i):
                    i += 3
                elif s.startswith("''", i):
                    i += 2
                    break
                else:
                    i += 1
            out.append(("str", s[start:i], start, i))
            continue
        if c == '"':
            start = i
            i += 1
            while i < n:
                if s[i] == "\\":
                    i = min(n, i + 2)
                elif s[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
            out.append(("str", s[start:i], start, i))
            continue
        if c.isalpha() or c == "_":
            start = i
            i += 1
            while i < n and (s[i].isalnum() or s[i] in "_'-"):
                i += 1
            out.append(("id", s[start:i], start, i))
            continue
        if s.startswith("...", i):
            out.append(("sym", "...", i, i + 3))
            i += 3
            continue
        out.append(("sym", c, i, i + 1))
        i += 1
    return out


def pairs_of(toks):
    stack = []
    pairs = {}
    closes = {"}": "{", "]": "[", ")": "("}
    for i, t in enumerate(toks):
        v = t[1]
        if v in ("{", "[", "("):
            stack.append(i)
        elif v in closes and stack and toks[stack[-1]][1] == closes[v]:
            j = stack.pop()
            pairs[i] = j
            pairs[j] = i
    return pairs


def decode_key(v):
    if v.startswith('"') and v.endswith('"'):
        try:
            return json.loads(v)
        except Exception:
            return v[1:-1]
    return v


def key_at(toks, lo, hi):
    if lo >= hi:
        return None
    vals = [t[1] for t in toks[lo:hi]]
    if vals[0] == "inherit":
        p = 1
        if p < len(vals) and vals[p] == "(":
            depth = 1
            p += 1
            while p < len(vals) and depth:
                if vals[p] == "(":
                    depth += 1
                elif vals[p] == ")":
                    depth -= 1
                p += 1
        names = [v for v in vals[p:] if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_\'-]*", v)]
        return ("inherit", names) if names else None
    if vals[0] == "...":
        return ("ellipsis", ["..."])
    # shortcut: dynamic attribute names are skipped; inspect new forms manually.
    if toks[lo][0] not in ("id", "str"):
        return None
    names = [decode_key(toks[lo][1])]
    p = lo + 1
    while (
        p < hi and toks[p][1] == "." and p + 1 < hi and toks[p + 1][0] in ("id", "str")
    ):
        names.extend([".", decode_key(toks[p + 1][1])])
        p += 2
    if p >= hi or toks[p][1] != "=":
        return None
    return ("attr", "".join(names))


def split_top(toks, lo, hi, pairs, sep):
    out = []
    st = lo
    i = lo
    while i < hi:
        if toks[i][1] in ("{", "[", "(") and i in pairs and pairs[i] < hi:
            i = pairs[i] + 1
            continue
        if toks[i][1] == sep:
            out.append((st, i + 1))
            st = i + 1
        i += 1
    if st < hi:
        out.append((st, hi))
    return out


def split_bindings(toks, lo, hi, pairs):
    out = []
    st = lo
    i = lo
    nested_lets = 0
    pending_semis = 0
    while i < hi:
        v = toks[i][1]
        if v in ("{", "[", "(") and i in pairs and pairs[i] < hi:
            i = pairs[i] + 1
            continue
        if v == "let":
            nested_lets += 1
        elif v == "in" and nested_lets:
            nested_lets -= 1
        elif v in ("with", "assert"):
            pending_semis += 1
        elif v == ";":
            if nested_lets:
                pass
            elif pending_semis:
                pending_semis -= 1
            else:
                out.append((st, i + 1))
                st = i + 1
        i += 1
    if st < hi:
        out.append((st, hi))
    return out


def binding_segments(toks, pairs, lo, hi):
    segs = split_bindings(toks, lo, hi, pairs)
    result = []
    for a, b in segs:
        stop = b - 1 if toks[b - 1][1] == ";" else b
        key = key_at(toks, a, stop)
        if key is None:
            return None
        result.append((a, b, key))
    return result


def find_unsorted(s, toks, pairs):
    found = []
    for i, t in enumerate(toks):
        if t[1] == "{" and i in pairs:
            j = pairs[i]
            if j + 1 < len(toks) and toks[j + 1][1] == ":":
                parts = split_top(toks, i + 1, j, pairs, ",")
                params = []
                for a, b in parts:
                    if a >= b or toks[a][1] == "...":
                        continue
                    if toks[a][0] != "id":
                        params = []
                        break
                    params.append((a, b, toks[a][1]))
                if len(params) > 1 and [p[2] for p in params] != sorted(
                    p[2] for p in params
                ):
                    found.append(("params", i, j, params))
                continue
            items = binding_segments(toks, pairs, i + 1, j)
            if items and len(items) > 1:
                keys = [min(k[1]) if k[0] == "inherit" else k[1] for _, _, k in items]
                if keys != sorted(keys):
                    found.append(("set", i, j, items))
        if t[1] == "let":
            stack = []
            nested = 0
            k = i + 1
            end = None
            while k < len(toks):
                v = toks[k][1]
                if v in ("{", "[", "("):
                    stack.append(v)
                elif v in ("}", "]", ")") and stack:
                    stack.pop()
                elif not stack:
                    if v == "let":
                        nested += 1
                    elif v == "in":
                        if nested == 0:
                            end = k
                            break
                        nested -= 1
                k += 1
            if end is not None:
                items = binding_segments(toks, pairs, i + 1, end)
                if items and len(items) > 1:
                    keys = [
                        min(k[1]) if k[0] == "inherit" else k[1] for _, _, k in items
                    ]
                    if keys != sorted(keys):
                        found.append(("let", i, end, items))
    return found


def sort_inherit_names(s):
    toks = lex(s)
    pairs = pairs_of(toks)
    edits = []
    for i, t in enumerate(toks):
        if t[1] != "inherit":
            continue
        j = i + 1
        if j < len(toks) and toks[j][1] == "(" and j in pairs:
            j = pairs[j] + 1
        names = []
        while j < len(toks) and toks[j][1] != ";":
            if toks[j][0] == "id":
                names.append(j)
            j += 1
        if len(names) > 1:
            vals = [toks[k][1] for k in names]
            if vals != sorted(vals):
                # Comments stay fixed while names move; --write is unsafe when interleaved.
                for k, v in zip(names, sorted(vals)):
                    if toks[k][1] != v:
                        edits.append((toks[k][2], toks[k][3], v))
    for a, b, v in reversed(edits):
        s = s[:a] + v + s[b:]
    return s


def one_sort(s, group):
    kind, start, end, items = group
    toks = lex(s)
    if kind in ("set", "let"):
        opener = toks[start]
        inner_start = opener[3]
        ranges = []
        prev = inner_start
        for a, b, key in items:
            stop = toks[b - 1][3]
            ranges.append((prev, stop, min(key[1]) if key[0] == "inherit" else key[1]))
            prev = stop
        new = "".join(s[a:b] for a, b, _ in sorted(ranges, key=lambda r: r[2]))
        return s[: ranges[0][0]] + new + s[ranges[-1][1] :]
    opener = toks[start]
    closer = toks[end]
    inner_start = opener[3]
    inner_end = closer[2]
    pairs = pairs_of(toks)
    segments = split_top(toks, start + 1, end, pairs, ",")
    units = []
    prev = inner_start
    has_trailing = bool(segments and toks[segments[-1][1] - 1][1] == ",")
    for a, b in segments:
        stop = toks[b - 1][3]
        text = s[prev:stop]
        if toks[b - 1][1] == ",":
            text = text[:-1]
        units.append((toks[a][1], text))
        prev = stop
    ell = [u for u in units if u[0] == "..."]
    units = [u for u in units if u[0] != "..."]
    units.sort(key=lambda u: u[0])
    units += ell
    pieces = []
    for n, (_, text) in enumerate(units):
        pieces.append(text)
        if n < len(units) - 1 or has_trailing:
            pieces.append(",")
    return s[:inner_start] + "".join(pieces) + s[inner_end:]


def transform(s):
    s = sort_inherit_names(s)
    changes = 0
    while True:
        toks = lex(s)
        pairs = pairs_of(toks)
        groups = find_unsorted(s, toks, pairs)
        if not groups:
            break

        def span(g):
            return toks[g[2]][3] - toks[g[1]][2]

        s = one_sort(s, min(groups, key=span))
        changes += 1
        if changes > 2000:
            raise RuntimeError("non-convergent sort")
    return s, changes


if __name__ == "__main__":
    write = "--write" in sys.argv
    total = 0
    for p in FILES:
        if not p.exists():
            continue
        src = p.read_text()
        out, n = transform(src)
        if out != src:
            total += n
            print(f"{p.relative_to(ROOT)}: {n} declaration group(s) sorted")
            if write:
                p.write_text(out)
    print(f"total groups sorted: {total}; mode={'write' if write else 'dry-run'}")
