#!/bin/bash
# Packs a signed, notarised D-Jay Noodles.app into a download file (DMG):
# the app plus an Applications shortcut to drag it onto. The DMG itself is
# then signed, sent to Apple for approval, and stapled.
#   tool/make_dmg.sh "path/to/D-Jay Noodles.app" [out_dir]
# Needs the "noodles-notary" keychain profile (xcrun notarytool store-credentials).
set -euo pipefail
APP="$1"
OUT="${2:-$(dirname "$APP")}"
ID="Developer ID Application: Dean Kapoor (R45H3FV584)"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$OUT/D-Jay Noodles $VER.dmg"
xcrun stapler validate "$APP" >/dev/null || { echo "Notarise the app first"; exit 1; }

# Window artwork (1x + 2x in one file, so it is sharp on Retina screens).
TOOLS="$HOME/NoodlesBuild/dmgtools/bin/dmgbuild"
[ -x "$TOOLS" ] || { echo "Install dmgbuild: python3 -m venv ~/NoodlesBuild/dmgtools && ~/NoodlesBuild/dmgtools/bin/pip install dmgbuild"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Customers must see the app under its real name, whatever the source folder is called.
ditto "$APP" "$TMP/D-Jay Noodles.app"; APP="$TMP/D-Jay Noodles.app"
python3 "$HERE/dmg/make_background.py" >/dev/null
tiffutil -cathidpicheck "$HERE/dmg/background.png" "$HERE/dmg/background@2x.png" -out "$TMP/background.tiff" 2>/dev/null
rm -f "$DMG"
"$TOOLS" -s "$HERE/dmg/settings.py" -D app="$APP" -D bg="$TMP/background.tiff" "D-Jay Noodles" "$DMG" >/dev/null

codesign --sign "$ID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile noodles-notary --wait | tail -2
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
ls -lh "$DMG"
