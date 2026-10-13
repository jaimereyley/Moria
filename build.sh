#!/bin/zsh
# Builds Moria.app next to this script. Signing with your Apple Development identity (when present) keeps the
# signature stable across rebuilds, so the keychain entry behind Touch ID keeps trusting new builds.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
# Assembled aside and moved in finished, so Finder never sees (and caches the generic icon of) a half-built app.
scratch=$(mktemp -d)
app="$scratch/Moria.app"
mkdir -p "$app"/Contents/{MacOS,Resources}
cp .build/release/Moria "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
cp Door.png "$app/Contents/Resources/"
swift Assets.swift Door.png "$scratch"
xcrun actool "$scratch/AppIcon.icon" "$scratch/Assets.xcassets" --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor --output-partial-info-plist "$scratch/Info.plist" >/dev/null
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${identity:--}" "$app"
rm -rf Moria.app
mv "$app" Moria.app
echo "Built ${PWD}/Moria.app"
