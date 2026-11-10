#!/bin/bash
# Copies spec/link-rules.json into a checkout of the public vldvr/redakciya-rules and commits it there.
# Pushing is left to the person: the script prints the command.
#   spec/tools/publish-rules.sh [path-to-redakciya-rules-checkout]   (default: ../redakciya-rules)
set -euo pipefail
cd "$(dirname "$0")/../.."
DEST="${1:-../redakciya-rules}"
[[ -d "$DEST/.git" ]] || { echo "No checkout at $DEST: gh repo clone vldvr/redakciya-rules $DEST"; exit 1; }

python3 spec/tools/check-link-rules.py >/dev/null || { echo "spec/tools/check-link-rules.py failed: not publishing"; exit 1; }

version() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1"; }
NEW="$(version spec/link-rules.json)"
if [[ -f "$DEST/link-rules.json" ]]; then
    OLD="$(version "$DEST/link-rules.json")"
    if (( NEW <= OLD )); then
        echo "version $NEW is not greater than published $OLD: clients would ignore it. Raise version in spec/link-rules.json."
        exit 1
    fi
fi

cp spec/link-rules.json "$DEST/link-rules.json"
git -C "$DEST" add link-rules.json
git -C "$DEST" commit -q -m "Правила v$NEW"
echo "Committed v$NEW in $DEST. To publish: git -C $DEST push"
