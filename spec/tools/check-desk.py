#!/usr/bin/env python3
"""Reference for spec/desk.md: computes stage and action for every row of spec/desk-cases.tsv.
   python3 spec/tools/check-desk.py"""
import csv, datetime, pathlib, sys

SPEC = pathlib.Path(__file__).resolve().parent.parent
TERMS = {"plain": 30, "screenshot": 14, "personal": 3}
SKIP_NAMES = {"desktop.ini", "thumbs.db", "icon\r"}
PARTIAL = {"crdownload", "download", "part", "partial", "opdownload", "tmp"}
FLAGS = {"dir", "link", "excluded", "screenshot", "personal", "kept"}


def evaluate(name, flags, added, enabled, modified, today):
    term = TERMS["screenshot"] if "screenshot" in flags else TERMS["plain"]
    if "personal" in flags and "kept" not in flags:
        term = TERMS["personal"]
    ext = name.rsplit(".", 1)[1].lower() if "." in name[1:] else ""
    if (name.startswith(".") or name.lower() in SKIP_NAMES or ext in PARTIAL
            or flags & {"dir", "link", "excluded"}):
        return term, "skip", "none"
    age = (today - max(added, enabled)).days
    if age * 3 < term * 2:
        return term, "fresh", "none"
    if age < term:
        return term, "aging", "none"
    hold = modified >= today - datetime.timedelta(days=1)
    return term, "expired", "hold" if hold else "move"


def main():
    day = datetime.date.fromisoformat
    failed, ids = 0, set()
    with open(SPEC / "desk-cases.tsv", encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE))
    stages = set()
    for r in rows:
        flags = set(filter(None, r["flags"].split(",")))
        problems = []
        if r["id"] in ids:
            problems.append("duplicate id")
        ids.add(r["id"])
        if flags - FLAGS:
            problems.append(f"unknown flags {sorted(flags - FLAGS)}")
        term, stage, action = evaluate(r["name"], flags, day(r["added"]), day(r["enabled"]),
                                       day(r["modified"]), day(r["today"]))
        stages.add((stage, action))
        want = (int(r["term"]), r["stage"], r["action"])
        if (term, stage, action) != want:
            problems.append(f"got {term} {stage} {action}, want {' '.join(map(str, want))}")
        if problems:
            failed += 1
            print(f"FAIL {r['id']}: " + "; ".join(problems))
    for need in [("skip", "none"), ("fresh", "none"), ("aging", "none"), ("expired", "move"), ("expired", "hold")]:
        if need not in stages:
            failed += 1
            print(f"FAIL coverage: no case for {need}")
    print(f"desk: {len(rows)} cases: " + ("all passed" if failed == 0 else f"{failed} problems"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
