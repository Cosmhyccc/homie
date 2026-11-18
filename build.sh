#!/bin/bash
# Builds homie.app. First run fetches the engines (scripts/fetch-engines.sh).
# Signing: ad-hoc by default; set HOMIE_SIGNING_IDENTITY to your own certificate to keep macOS permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"
identity="${HOMIE_SIGNING_IDENTITY:--}"
bash scripts/fetch-engines.sh
app=build/homie.app
staging=$(mktemp -d); trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/homie.app/Contents/MacOS" "$staging/homie.app/Contents/Resources"
xcrun swiftc -O Sources/*.swift -o "$staging/homie.app/Contents/MacOS/homie" -framework AppKit -framework AVFoundation
cp Info.plist "$staging/homie.app/Contents/Info.plist"
cp Resources/AppIcon.icns "$staging/homie.app/Contents/Resources/"
bash scripts/bundle-homie.sh "$staging/homie.app" "$identity"
codesign --force --sign "$identity" "$staging/homie.app"
mkdir -p build && rm -rf "$app" && ditto "$staging/homie.app" "$app"
echo "Built $app — open it, press Fn, talk."
