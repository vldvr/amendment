#!/bin/bash
# Builds build/Redakciya.app and signs it ad hoc (no paid certificate), as Zamazka does.
#   scripts/build-app.sh             this Mac's architecture, for local runs
#   scripts/build-app.sh --universal Apple silicon and Intel
#   scripts/build-app.sh --dmg       universal, plus dist/Redakciya-<version>-macOS.dmg and its SHA-256
#   scripts/build-app.sh --install   plus a copy in /Applications
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS="$(uname -m)"; DMG=0; INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) ARCHS="arm64 x86_64" ;;
        --dmg) ARCHS="arm64 x86_64"; DMG=1 ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

APP=build/Redakciya.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINARIES=()
for arch in $ARCHS; do
    swift build -c release --product Redakciya --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch" >/dev/null
    BINARIES+=(".build/$arch/release/Redakciya")
done
lipo -create -output "$APP/Contents/MacOS/Redakciya" "${BINARIES[@]}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The ASN base for «Источники»: scripts/fetch-asn.sh builds it, not kept in git. Without it companies are unknown.
if [[ -f Resources/asn.bin ]]; then
    cp Resources/asn.bin "$APP/Contents/Resources/asn.bin"
elif [[ $DMG == 1 ]]; then
    echo "error: Resources/asn.bin is missing, run scripts/fetch-asn.sh" >&2; exit 1
else
    echo "warning: Resources/asn.bin is missing, run scripts/fetch-asn.sh"
fi
# Spectral (SIL OFL 1.1) for the paper; the licence travels with the fonts.
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# The icon is drawn in code (UI/AppIcon.swift): render every size, pack into .icns. Not kept in git.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    "$APP/Contents/MacOS/Redakciya" --icon-png "$ICONSET/icon_${s}x${s}.png" $s >/dev/null
    "$APP/Contents/MacOS/Redakciya" --icon-png "$ICONSET/icon_${s}x${s}@2x.png" $((s * 2)) >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/Redakciya"))"

if [[ $DMG == 1 ]]; then
    mkdir -p dist
    IMAGE="dist/Redakciya-$VERSION-macOS.dmg"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Программы"
    rm -f "$IMAGE"
    hdiutil create -volname "Редакция" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$IMAGE" >/dev/null
    (cd dist && shasum -a 256 "$(basename "$IMAGE")" > "$(basename "$IMAGE").sha256")
    echo "Built $IMAGE"
    cat "$IMAGE.sha256"
fi

if [[ $INSTALL == 1 ]]; then
    osascript -e 'quit app id "com.vldvr.redakciya"' 2>/dev/null || true
    pkill -x Redakciya 2>/dev/null || true
    rm -rf /Applications/Redakciya.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Redakciya.app"
fi
