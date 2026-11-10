#!/usr/bin/env python3
"""Reference reader for issue codes (spec/issue-code.md). Standard library only.

    python3 check-issue-code.py              # runs spec/issue-code-cases.tsv, exit 0 if all pass
    python3 check-issue-code.py CASES.tsv

Mac and Windows readers must give the same answers on the same cases.
"""
import os
import re
import sys

ALPHABET = set("2345679ABCEHJKMPRSTUVWXY")
LOOKALIKES = str.maketrans("АВЕКМНОРСТУХЗБ", "ABEKMHOPCTYX36")
TWINS = str.maketrans("8NZFG", "BM7E6")
UNREAD = set("O0QD")

# [^\W_] is "letter or digit" for str patterns, the same as [\p{L}\p{N}] in the spec.
# Sign as Vision (№, Nº, N°, No) and Windows.Media.Ocr (N2, N!, N', Н:, Н') write it; a bare N only before a space.
SIGNED = re.compile(r"(?<![^\W_])(?:№\s*|N[º°O0Q2!':]\.?\s*|N\.?\s+|H[:']\s*)([0-9A-Z]{4}|[0-9A-Z]{2} [0-9A-Z]{2})(?![^\W_])")
BARE = re.compile(r"(?<![^\W_])[0-9A-Z]{4}(?![^\W_])")


def words(line):
    """(word, after_sign) pairs from one OCR line."""
    s = line.upper().translate(LOOKALIKES)
    out = [(m.group(1).replace(" ", "").translate(TWINS), True) for m in SIGNED.finditer(s)]
    out += [(m.group(0).translate(TWINS), False) for m in BARE.finditer(s)]
    return out


def unread(word):
    return sum(c in UNREAD for c in word)


def matches(word, code):
    """Exact match; one unread position counts as any letter."""
    return unread(word) <= 1 and all(w == c or w in UNREAD for w, c in zip(word, code))


def off_by_one(word, code):
    return unread(word) == 0 and sum(w != c for w, c in zip(word, code)) == 1


def find(lines, journal):
    """Returns (code, "exact" | "fuzzy") or ("?", candidates) or (None, None)."""
    ws = {w for line in lines for w in words(line)}
    signed = {w for w, s in ws if s}

    exact = set()
    for w, s in ws:
        if unread(w) and not s:
            continue  # "2026" from a date must not match 2?26
        exact |= {c for c in journal if matches(w, c)}
    if len(exact) == 1:
        return exact.pop(), "exact"
    if len(exact) > 1:
        pick = {c for c in exact if any(matches(w, c) for w in signed)}
        return (pick.pop(), "exact") if len(pick) == 1 else ("?", sorted(exact))

    near = {c for c in journal for w in signed if off_by_one(w, c)}
    if len(near) == 1:
        return near.pop(), "fuzzy"
    if len(near) > 1:
        return "?", sorted(near)
    return None, None


def check_journal(journal):
    """Every code is from the alphabet and differs from every other one in two places at least."""
    problems = [c for c in journal if len(c) != 4 or not set(c) <= ALPHABET]
    codes = sorted(journal)
    for i, a in enumerate(codes):
        for b in codes[i + 1:]:
            if sum(x != y for x, y in zip(a, b)) < 2:
                problems.append(f"{a}~{b}")
    return problems


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "issue-code-cases.tsv")
    with open(path, encoding="utf-8") as f:
        rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
    header, rows = rows[0], rows[1:]
    col = {name: i for i, name in enumerate(header)}
    failed = 0
    for r in rows:
        journal = set(r[col["journal"]].split(","))
        bad = check_journal(journal)
        code, how = find(r[col["lines"]].split(" | "), journal)
        got = "—" if code is None else code
        got_how = how if how in ("exact", "fuzzy") else "—"
        ok = not bad and got == r[col["expect"]] and got_how == r[col["how"]]
        if not ok:
            failed += 1
            print(f"FAIL {r[col['id']]}: got {got} {got_how}, want {r[col['expect']]} {r[col['how']]}"
                  + (f", bad journal {bad}" if bad else ""))
    print(f"{len(rows) - failed}/{len(rows)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
