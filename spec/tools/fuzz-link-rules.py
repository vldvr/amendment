#!/usr/bin/env python3
"""Differential check: random URLs through the reference and through another implementation.

    python3 spec/tools/fuzz-link-rules.py -- swift run --package-path mac redakciya-checks links-stdin
    python3 spec/tools/fuzz-link-rules.py -n 20000 --seed 7 -- target/debug/redakciya-checks links-stdin

The other program reads one input per line from stdin and prints `output<TAB>class<TAB>removed`.
Exit 0 if every line agrees.
"""
import argparse
import importlib.util
import json
import os
import random
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ref", os.path.join(here, "check-link-rules.py"))
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)

HOSTS = ["www.instagram.com", "instagram.com", "youtu.be", "m.youtube.com", "WWW.YouTube.com", "open.spotify.com",
         "www.tiktok.com", "vm.tiktok.com", "x.com", "twitter.com", "docs.google.com", "drive.google.com",
         "www.figma.com", "www.wildberries.ru", "ozon.ru", "clck.ru", "example.com", "notyoutube.com",
         "youtube.com.example.org", "user@www.instagram.com", "www.youtube.com@example.com", "x.com:443",
         "youtube.com.", "[::1]:8080", "", "яндекс.рф"]
NAMES = ["si", "SI", "s%69", "t", "v", "list", "igsh", "srtk", "vrfl", "utm_source", "UTM_Medium", "utm_", "fbclid",
         "ysclid", "usp", "resourcekey", "node-id", "targetUrl", "s", "web_id", "_t", "dlsi", "nd", "q", "is",
         "%", "%zz", "%C3", "%D0%B8", "и", "é", "", "a+b"]
VALUES = ["", "abc", "19", "20", "46", "sharing", "drive_link", "SN", "sn", "%20", "%E2%82", "x=y", "é", "é"]
PATHS = ["", "/", "/p/DQxyz/", "/watch", "/t/abc", "/track/4uLU", "/a?b", "/и"]
FRAGS = [None, "", "comments", "t=30", "utm_source=x", "a=1&si=2", ":~:text=hi", "si=1:~:text=x", "/route?x=1",
         "gid=123", "a=b/c", "é"]


def rand_url(rnd):
    scheme = rnd.choice(["https://", "http://", "HTTPS://", "Https://", "ftp://", "", "https:/"])
    s = scheme + rnd.choice(HOSTS) + rnd.choice(PATHS)
    if rnd.random() < 0.85:
        segs = []
        for _ in range(rnd.randint(0, 5)):
            n = rnd.choice(NAMES)
            segs.append(n if rnd.random() < 0.1 else n + "=" + rnd.choice(VALUES))
        if rnd.random() < 0.1:
            segs.insert(rnd.randint(0, len(segs)), "")
        s += "?" + "&".join(segs)
    f = rnd.choice(FRAGS)
    if f is not None:
        s += "#" + f
    if rnd.random() < 0.02:
        s += rnd.choice([" ", "\t", " ", "\u001f", " "])
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    with open(os.path.join(here, "..", "link-rules.json"), encoding="utf-8") as f:
        rules = json.load(f)
    rnd = random.Random(a.seed)
    # Line breaks would split an input in two: drop such inputs.
    inputs = [u for u in (rand_url(rnd) for _ in range(a.n)) if "\n" not in u and "\r" not in u and " " not in u]
    proc = subprocess.run(cmd, input="\n".join(inputs) + "\n", capture_output=True, text=True, encoding="utf-8")
    got = proc.stdout.split("\n")
    bad = 0
    for i, u in enumerate(inputs):
        out, cls, removed = ref.clean(u, rules)
        want = f"{out}\t{cls}\t{','.join(removed)}"
        line = got[i] if i < len(got) else "<missing>"
        if line != want:
            bad += 1
            if bad <= 10:
                print(f"DIFF {u!r}\n  want {want!r}\n  got  {line!r}")
    print(f"{len(inputs)} inputs, {bad} differ")
    return 1 if bad or proc.returncode else 0


if __name__ == "__main__":
    sys.exit(main())
