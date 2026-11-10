#!/bin/bash
# Downloads the iptoasn.com table (PDDL, public domain) and builds Resources/asn.bin for «Источники»
# (spec/sources.md, «База ASN»). Not kept in git: the table changes every hour.
#   scripts/fetch-asn.sh            only when Resources/asn.bin is missing
#   scripts/fetch-asn.sh --force    rebuild anyway
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Resources/asn.bin
[[ "${1:-}" == "--force" || ! -f "$OUT" ]] || { echo "$OUT is already there (--force to rebuild)"; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 --max-time 300 -A "redakciya-build" -o "$TMP/ip2asn-v4.tsv.gz" https://iptoasn.com/data/ip2asn-v4.tsv.gz
SIZE=$(stat -f %z "$TMP/ip2asn-v4.tsv.gz")
(( SIZE > 2000000 )) || { echo "error: the table is only $SIZE bytes" >&2; exit 1; }
gzip -t "$TMP/ip2asn-v4.tsv.gz"
python3 ../spec/tools/build-asn.py "$TMP/ip2asn-v4.tsv.gz" "$OUT"
python3 ../spec/tools/build-asn.py --lookup "$OUT" 8.8.8.8 149.154.167.50
