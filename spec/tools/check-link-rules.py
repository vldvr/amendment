#!/usr/bin/env python3
"""Reference implementation of link-tail rules (spec/link-rules.md). Standard library only.

    python3 check-link-rules.py                          # spec/link-rules.json + spec/link-cases.tsv, exit 0 if all pass
    python3 check-link-rules.py RULES.json CASES.tsv

Mac and Windows implementations must give the same answers on the same cases.
Besides the cases it checks the rules file (structure, unique hosts), that cleaning
is idempotent, and that every rule fires in at least one case.
"""
import json
import os
import re
import sys
from urllib.parse import unquote

CLASSES = ("needed", "tracks", "gives_away")
DROP = ("tracks", "gives_away")
SHOW = {"gives_away": "card", "tracks": "silent", "none": "none"}


# ---------- rules file ----------

def validate(rules):
    problems = []
    if rules.get("format") != 1:
        problems.append("format must be 1")
    if not isinstance(rules.get("version"), int) or rules["version"] < 1:
        problems.append("version must be an integer >= 1")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(rules.get("updated", ""))):
        problems.append("updated must be YYYY-MM-DD")

    def entries(where, params):
        for e in params:
            if ("name" in e) == ("prefix" in e):
                problems.append(f"{where}: exactly one of name/prefix: {e}")
            if e.get("class") not in CLASSES:
                problems.append(f"{where}: bad class: {e}")
            if "values" in e and not (isinstance(e["values"], list) and e["values"]):
                problems.append(f"{where}: values must be a non-empty list: {e}")
            if e.get("confidence") not in ("high", "medium", "low"):
                problems.append(f"{where}: confidence: {e}")
    entries("global", rules.get("global", {}).get("params", []))
    for e in rules.get("global", {}).get("params", []):
        if e.get("class") == "needed":
            problems.append(f"global: needed makes no sense: {e}")

    seen = {}
    for d in rules.get("domains", []):
        if d.get("mode") not in ("allow", "deny"):
            problems.append(f"{d.get('id')}: mode")
        if d.get("mode") == "allow" and d.get("unknown_class") not in DROP:
            problems.append(f"{d.get('id')}: allow needs unknown_class tracks|gives_away")
        entries(d.get("id", "?"), d.get("params", []))
        for h in d.get("hosts", []):
            if h != h.lower() or h in seen:
                problems.append(f"host {h}: not lowercase or repeated ({seen.get(h)})")
            seen[h] = d.get("id")
    for s in rules.get("short_links", []):
        if s.get("host") != s.get("host", "").lower() or ("path_prefix" in s and not s["path_prefix"].startswith("/")):
            problems.append(f"short_links: {s}")
    for a in rules.get("sharing_apps", []):
        if not a.get("id") or not (a.get("mac") or a.get("win")):
            problems.append(f"sharing_apps: {a}")
    return problems


# ---------- algorithm ----------

def host_matches(host, rule_host):
    return host == rule_host or host.endswith("." + rule_host)


def split_url(url):
    """(scheme, authority, base_rest, query|None, fragment|None) or None if not a single http(s) URL."""
    if re.search(r"\s", url):
        return None
    # (?a): ASCII only, otherwise IGNORECASE folds "ſ" (U+017F) into "s" and takes httpſ://
    m = re.match(r"(?ai)(https?)://", url)
    if not m:
        return None
    s = url[m.end():]
    frag = query = None
    if "#" in s:
        s, frag = s.split("#", 1)
    if "?" in s:
        s, query = s.split("?", 1)
    i = s.find("/")
    authority, path = (s, "") if i < 0 else (s[:i], s[i:])
    return m.group(0), authority, path, query, frag


def host_of(authority):
    h = authority.rsplit("@", 1)[-1]
    if not h.startswith("["):
        h = h.split(":", 1)[0]
    return h.lower().rstrip(".")


def entry_matches(e, name, value):
    if "name" in e and e["name"].lower() != name:
        return False
    if "prefix" in e and not name.startswith(e["prefix"].lower()):
        return False
    return "values" not in e or value in e["values"]


def entry_key(owner, e):
    k = f"{owner}:{e.get('name') or e['prefix'] + '*'}"
    return k + (f"={','.join(e['values'])}" if "values" in e else "")


def classify(name, value, domain, in_fragment, rules):
    if domain:
        for e in domain.get("params", []):
            if entry_matches(e, name, value):
                return e["class"], entry_key(domain["id"], e)
    for e in rules["global"]["params"]:
        if entry_matches(e, name, value):
            return e["class"], entry_key("global", e)
    if domain and domain["mode"] == "allow" and not in_fragment:
        return domain["unknown_class"], f"{domain['id']}:*"
    return None, None


def filter_params(text, domain, in_fragment, rules, removed, fired):
    """Returns the rebuilt text or None if nothing was removed."""
    kept, dropped = [], False
    for seg in text.split("&"):
        if seg == "":
            continue
        raw_name, _, raw_value = seg.partition("=")
        name = unquote(raw_name).lower()
        cls, key = classify(name, unquote(raw_value), domain, in_fragment, rules)
        if key:
            fired.add(key)
        if cls in DROP:
            dropped = True
            removed.append((name, cls))
        else:
            kept.append(seg)
    return "&".join(kept) if dropped else None


def clean(url, rules, fired=None):
    """Returns (output, class, removed names). class is gives_away | tracks | none."""
    fired = fired if fired is not None else set()
    parts = split_url(url)
    if parts is None:
        return url, "none", []
    scheme, authority, path, query, frag = parts
    host = host_of(authority)
    if not host:
        return url, "none", []

    for s in rules["short_links"]:
        if host_matches(host, s["host"]) and path.startswith(s.get("path_prefix", "")):
            return url, "none", []

    domain, best = None, -1
    for d in rules["domains"]:
        for h in d["hosts"]:
            if host_matches(host, h) and len(h) > best:
                domain, best = d, len(h)

    removed = []
    new_query = filter_params(query, domain, False, rules, removed, fired) if query else None

    new_frag = None
    if frag:
        head, sep, tail = frag.partition(":~:")
        segs = [x for x in head.split("&") if x]
        if segs and all("=" in x for x in segs) and "/" not in head and "?" not in head:
            r = filter_params(head, domain, True, rules, removed, fired)
            if r is not None:
                new_frag = r + sep + tail

    if not removed:
        return url, "none", []
    out = scheme + authority + path
    q = new_query if new_query is not None else query
    if q:
        out += "?" + q
    f = new_frag if new_frag is not None else frag
    if f is not None and f != "":
        out += "#" + f
    elif frag == "" and new_frag is None:
        out += "#"
    cls = "gives_away" if any(c == "gives_away" for _, c in removed) else "tracks"
    return out, cls, [n for n, _ in removed]


# ---------- runner ----------

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rules_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "link-rules.json")
    cases_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "..", "link-cases.tsv")
    with open(rules_path, encoding="utf-8") as f:
        rules = json.load(f)
    with open(cases_path, encoding="utf-8") as f:
        rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    header, rows = rows[0], rows[1:]
    col = {n: i for i, n in enumerate(header)}

    failed = 0
    for p in validate(rules):
        failed += 1
        print(f"FAIL rules: {p}")

    fired = set()
    ids = set()
    for r in rows:
        cid = r[col["id"]]
        want_out, want_cls, want_show = r[col["output"]], r[col["class"]], r[col["show"]]
        want_removed = [x for x in r[col["removed"]].split(",") if x]
        problems = []
        if cid in ids:
            problems.append("duplicate id")
        ids.add(cid)
        if SHOW.get(want_cls) != want_show:
            problems.append(f"class {want_cls} and show {want_show} disagree")
        out, cls, removed = clean(r[col["input"]], rules, fired)
        if out != want_out:
            problems.append(f"output {out!r}, want {want_out!r}")
        if cls != want_cls:
            problems.append(f"class {cls}, want {want_cls}")
        if removed != want_removed:
            problems.append(f"removed {removed}, want {want_removed}")
        again = clean(out, rules)
        if again != (out, "none", []):
            problems.append(f"not idempotent: {again}")
        if problems:
            failed += 1
            print(f"FAIL {cid}: " + "; ".join(problems))

    every = {entry_key("global", e) for e in rules["global"]["params"]}
    for d in rules["domains"]:
        every |= {entry_key(d["id"], e) for e in d["params"]}
        if d["mode"] == "allow":
            every.add(f"{d['id']}:*")
    for key in sorted(every - fired):
        failed += 1
        print(f"FAIL coverage: no case triggers rule {key}")

    print(f"{len(rows)} cases, rules v{rules.get('version')}: "
          + ("all passed" if not failed else f"{failed} problems"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
