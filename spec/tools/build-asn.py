#!/usr/bin/env python3
"""Builds asn.bin (spec/sources.md, «База ASN») from the iptoasn.com table ip2asn-v4.tsv[.gz].
   python3 spec/tools/build-asn.py ip2asn-v4.tsv.gz asn.bin
   python3 spec/tools/build-asn.py --lookup asn.bin 149.154.167.50 8.8.8.8"""
import gzip, ipaddress, re, struct, sys

# Clouds and CDNs: the address says who rents out the servers, not who is behind them.
CLOUDS = {16509, 14618, 8987, 13335, 209242, 20940, 16625, 21342, 12222, 54113, 396982, 19527, 8075, 14061, 24940,
          16276, 63949, 20473, 31898, 45102, 37963, 200350, 60068, 202422, 9009, 136907, 13414}
# Networks that are the service itself, under the name people know.
OWN = {15169: "Google", 212772: "AdGuard", 714: "Apple", 6185: "Apple", 62041: "Telegram", 59930: "Telegram",
       44907: "Telegram", 211157: "Telegram", 62014: "Telegram", 32934: "Meta", 13238: "Яндекс", 208722: "Яндекс",
       47764: "VK", 47541: "VK", 36459: "GitHub", 8068: "Microsoft", 8075: "Microsoft", 399358: "Anthropic",
       46489: "Twitch", 2906: "Netflix", 8403: "Spotify", 16509: "Amazon", 14618: "Amazon", 13335: "Cloudflare",
       396982: "Google", 20940: "Akamai", 16625: "Akamai", 54113: "Fastly", 14061: "DigitalOcean", 24940: "Hetzner",
       16276: "OVH", 19679: "Dropbox", 13414: "X", 32590: "Valve", 2635: "Automattic", 714: "Apple"}
TAILS = [", Inc.", " Inc.", ", Inc", " Inc", ", LLC", " LLC", " L.L.C.", " Ltd.", " Ltd", " Limited", " Corporation", " Corp.",
         " GmbH", " B.V.", " International", " Software", " Messenger", " Networks", " Technologies", " AB", " S.A.",
         " LLP", ", PBC", " PBC", " Co.", " JSC", " OOO", " PJSC", " AG", " S.r.l.", " SAS", " Pty", " Company"]
HANDLE = re.compile(r"[A-Z0-9_-]+")


def company(asn, raw):
    if asn in OWN:
        return OWN[asn]
    s = raw
    if " - " in s:
        s = s.split(" - ", 1)[1]
    else:
        first, _, rest = s.partition(" ")
        if rest and HANDLE.fullmatch(first):
            s = rest
    changed = True
    while changed:
        changed = False
        s = s.strip(" ,.")
        for tail in TAILS:
            if s.endswith(tail) and len(s) > len(tail):
                s, changed = s[: -len(tail)], True
    words = s.split(" ")
    if len(words) >= 2 and words[0] == words[1]:
        s = " ".join(words[1:])
    if "," in s and len(s) - s.rindex(",") <= 4:
        s = s[: s.rindex(",")]
    return s.strip(" ,.") or raw


def build(src, dst):
    opener = gzip.open if src.endswith(".gz") else open
    names, index, ranges = [], {}, []
    with opener(src, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            c = line.rstrip("\n").split("\t")
            if len(c) < 5 or c[2] == "0":
                continue
            asn = int(c[2])
            key = (company(asn, c[4]), asn in CLOUDS)
            if key not in index:
                index[key] = len(names)
                names.append(key)
            start, end, name = int(ipaddress.IPv4Address(c[0])), int(ipaddress.IPv4Address(c[1])), index[key]
            if ranges and ranges[-1][2] == name and ranges[-1][1] + 1 == start:
                ranges[-1][1] = end
            else:
                ranges.append([start, end, name])
    ranges.sort()
    blob, offsets = b"", []
    for name, cloud in names:
        offsets.append(len(blob))
        blob += bytes([1 if cloud else 0]) + name.encode("utf-8")
    offsets.append(len(blob))
    n = len(ranges)
    with open(dst, "wb") as f:
        f.write(b"RASN" + struct.pack("<III", 1, n, len(names)))
        for col in range(3):
            f.write(struct.pack(f"<{n}I", *(r[col] for r in ranges)))
        f.write(struct.pack(f"<{len(offsets)}I", *offsets))
        f.write(blob)
    print(f"wrote {dst}: {n} ranges, {len(names)} names")


def lookup(path, ips):
    data = open(path, "rb").read()
    magic, version, n, m = struct.unpack_from("<4sIII", data)
    assert magic == b"RASN" and version == 1
    base = 16 + 12 * n
    for ip in ips:
        x = int(ipaddress.IPv4Address(ip))
        lo, hi, found = 0, n - 1, -1
        while lo <= hi:
            mid = (lo + hi) // 2
            if struct.unpack_from("<I", data, 16 + 4 * mid)[0] <= x:
                found, lo = mid, mid + 1
            else:
                hi = mid - 1
        if found < 0 or struct.unpack_from("<I", data, 16 + 4 * n + 4 * found)[0] < x:
            print(f"{ip}\t—")
            continue
        name = struct.unpack_from("<I", data, 16 + 8 * n + 4 * found)[0]
        a, b = struct.unpack_from("<II", data, base + 4 * name)
        raw = data[base + 4 * (m + 1) + a: base + 4 * (m + 1) + b]
        print(f"{ip}\t{raw[1:].decode()}\t{'cloud' if raw[0] & 1 else ''}")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--lookup":
        lookup(sys.argv[2], sys.argv[3:])
    elif len(sys.argv) == 3:
        build(sys.argv[1], sys.argv[2])
    else:
        sys.exit(__doc__)
