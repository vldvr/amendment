#!/usr/bin/env python3
"""Reference for spec/reprint.md: runs spec/reprint-cases.tsv. Standard library only.

    python3 spec/tools/check-reprint.py      # exit 0 if all pass
"""
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
_spec = importlib.util.spec_from_file_location("issue", os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-issue-code.py"))
issue = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(issue)

SPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MAX_PURPOSE = 60
PREFIX = re.compile(r"^для(?![^\W_])\s*:?\s*", re.IGNORECASE)


def purpose(raw):
    """Normalised purpose or None when it cannot be issued."""
    s = raw.replace("№", "")
    s = "".join(" " if c.isspace() else c for c in s if c.isspace() or ord(c) >= 32 and ord(c) != 127)
    s = re.sub(r" +", " ", s).strip()
    s = PREFIX.sub("", s)
    s = re.sub(r"[,.;: ]+$", "", s)
    if not s or len(s) > MAX_PURPOSE:
        return None
    return s


def code_ok(code, journal):
    if len(code) != 4 or not set(code) <= issue.ALPHABET:
        return False
    return all(sum(a != b for a, b in zip(code, c)) >= 2 for c in journal)


def file_name(code, ext, taken):
    base = f"Копия {code}"
    name, n = f"{base}.{ext}", 2
    while name in taken:
        name, n = f"{base} {n}.{ext}", n + 1
    return name


def spoiled(issued, now):
    return (now - issued).total_seconds() >= 86400


def fold(s):
    return s.lower().replace("ё", "е")


def code_like(q):
    w = q.strip().upper().translate(issue.LOOKALIKES).translate(issue.TWINS)
    return len(w) == 4 and set(w) <= issue.ALPHABET | issue.UNREAD


def search(query, entries):
    """entries: [(code, for, title)] in journal order. Returns codes."""
    q = query.strip()
    if not q:
        return []
    if code_like(q):
        code, how = issue.find(["№ " + q], {e[0] for e in entries})
        hits = {code} if code and code != "?" else set(how) if code == "?" else set()
        if hits:
            return [e[0] for e in entries if e[0] in hits]
    f = fold(q)
    return [e[0] for e in entries if f in fold(e[1]) or f in fold(e[2])]


def run(r):
    kind, inp, journal = r["kind"], r["input"], r["journal"]
    if kind == "purpose":
        return purpose(inp.replace("\\n", "\n").replace("\\t", "\t")) or "—"
    if kind == "code":
        return "ok" if code_ok(inp, [c for c in journal.split(",") if c]) else "—"
    if kind == "name":
        code, ext = inp.split(" ")
        return file_name(code, ext, set(journal.split(" | ")) if journal else set())
    if kind == "spoil":
        a, b = (datetime.datetime.fromisoformat(x.replace("Z", "+00:00")) for x in inp.split(" "))
        return "expired" if spoiled(a, b) else "fresh"
    if kind == "search":
        entries = [tuple(e.split(":", 2)) for e in journal.split(" | ")]
        return ",".join(search(inp, entries)) or "—"
    raise ValueError(kind)


def main():
    with open(os.path.join(SPEC, "reprint-cases.tsv"), encoding="utf-8") as f:
        lines = [l.rstrip("\n").split("\t") for l in f if l.strip()]
    head, rows = lines[0], lines[1:]
    failed, ids = 0, set()
    for row in rows:
        r = dict(zip(head, row + [""] * (len(head) - len(row))))
        got = run(r)
        if got != r["expect"] or r["id"] in ids:
            failed += 1
            print(f"FAIL {r['id']}: got {got!r}, want {r['expect']!r}")
        ids.add(r["id"])
    print(f"{len(rows) - failed}/{len(rows)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
