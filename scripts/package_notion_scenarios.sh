#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
IDENTITY="${NOTION_SCENARIOS_SIGNING_IDENTITY:-${REARVIEW_SIGNING_IDENTITY:-Rearview Development}}"
/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$IDENTITY\"" || {
  print -u2 "Signing identity not found: $IDENTITY. Set NOTION_SCENARIOS_SIGNING_IDENTITY."; exit 1
}
swift build --product NotionScenarios
APP="$ROOT/dist/NotionScenarios.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/debug/NotionScenarios" "$APP/Contents/MacOS/.NotionScenarios.new"
mv -f "$APP/Contents/MacOS/.NotionScenarios.new" "$APP/Contents/MacOS/NotionScenarios"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.rearview.NotionScenarios</string>
<key>CFBundleName</key><string>Notion Scenarios</string>
<key>CFBundleExecutable</key><string>NotionScenarios</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
# Persist the resolved installation, not the build shell's whole environment.
# A GUI launched by Finder has no nvm/asdf shell initialization.
NTN_EXECUTABLE="$(command -v ntn || true)"
if [[ -n "$NTN_EXECUTABLE" ]]; then
  /usr/libexec/PlistBuddy -c "Add :NotionCLIPath string $NTN_EXECUTABLE" "$APP/Contents/Info.plist"
fi
codesign --force --sign "$IDENTITY" "$APP"
print "Built $APP"
