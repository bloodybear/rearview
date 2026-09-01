#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

usage() {
  print -u2 -- "usage: $0 [dev] [zip] [dmg]"
  exit 2
}

show_signing_identity_help() {
  print -u2 -- "Find available code-signing identities with:"
  print -u2 -- "  /usr/bin/security find-identity -v -p codesigning"
  print -u2 -- "Then set one before rerunning this script:"
  print -u2 -- '  export REARVIEW_SIGNING_IDENTITY="Your Signing Identity"'
}

PACKAGE_MODE="default"
BUILD_ZIP=0
BUILD_DMG=0
for argument in "$@"; do
  case "$argument" in
    dev) PACKAGE_MODE="dev" ;;
    zip) BUILD_ZIP=1 ;;
    dmg) BUILD_DMG=1 ;;
    *)
      print -u2 -- "error: unknown argument: $argument"
      usage
      ;;
  esac
done

BUILD_CONFIGURATION="release"
typeset -a FEATURE_BUILD_ARGUMENTS
FEATURE_BUILD_ARGUMENTS=()

SIGNING_IDENTITY="${REARVIEW_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  print -u2 -- "error: REARVIEW_SIGNING_IDENTITY is not set"
  print -u2 -- "Set it to the code-signing identity available in the macOS keychain; refusing to use ad-hoc signing."
  show_signing_identity_help
  exit 1
fi

if [[ "$PACKAGE_MODE" == "dev" ]]; then
  APP="$ROOT/dist/Rearview-dev.app"
  ZIP="$ROOT/dist/Rearview-dev.zip"
  DMG="$ROOT/dist/Rearview-dev.dmg"
  DMG_VOLUME_NAME="Rearview Dev"
  DEBUG_FEATURE_STATUS="included"
else
  APP="$ROOT/dist/Rearview.app"
  ZIP="$ROOT/dist/Rearview.zip"
  DMG="$ROOT/dist/Rearview.dmg"
  DMG_VOLUME_NAME="Rearview"
  DEBUG_FEATURE_STATUS="excluded"
  FEATURE_BUILD_ARGUMENTS=(
    --product Rearview
    -Xswiftc -DLST_EXCLUDE_DEBUG_FEATURES
  )
fi

HELPER="$APP/Contents/Helpers/BenchmarkFixture.app"
ICON_FILE="$ROOT/Resources/Icons/Rearview.icns"
STATUS_ICON_FILE="$ROOT/Resources/Icons/Rearview.svg"

for required_icon in "$ICON_FILE" "$STATUS_ICON_FILE"; do
  if [[ ! -f "$required_icon" ]]; then
    print -u2 -- "error: icon not found: $required_icon"
    exit 1
  fi
done

if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -Fq "\"$SIGNING_IDENTITY\""; then
  print -u2 -- "error: required code-signing identity not found: $SIGNING_IDENTITY"
  print -u2 -- "Create or install this identity before packaging; refusing to use ad-hoc signing."
  show_signing_identity_help
  exit 1
fi

VERSION_PLIST="$ROOT/Resources/Info.plist"
APP_VERSION="${REARVIEW_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERSION_PLIST")}"
APP_BUILD="${REARVIEW_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$VERSION_PLIST")}"
if [[ -n "${REARVIEW_VERSION:-}" ]] && [[ "$APP_VERSION" != <->.<->.<-> ]]; then
  print -u2 -- "error: REARVIEW_VERSION must use YY.M.Patch numeric format: $APP_VERSION"
  exit 1
fi
if [[ -n "${REARVIEW_BUILD:-}" ]] && [[ "$APP_BUILD" != <->.<-> ]]; then
  print -u2 -- "error: REARVIEW_BUILD must use YYYYMMDD.N numeric format: $APP_BUILD"
  exit 1
fi

if [[ -z "${SDKROOT:-}" ]]; then
  SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path) || {
    print -u2 -- "error: unable to locate the macOS SDK with xcrun"
    exit 1
  }
fi
if [[ ! -d "$SDKROOT" ]]; then
  print -u2 -- "error: SDKROOT does not point to a directory: $SDKROOT"
  exit 1
fi
export SDKROOT
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
swift build -c "$BUILD_CONFIGURATION" --disable-sandbox \
  --cache-path "$ROOT/.swiftpm-cache" \
  --config-path "$ROOT/.swiftpm-config" \
  --security-path "$ROOT/.swiftpm-security" \
  "${FEATURE_BUILD_ARGUMENTS[@]}"

/bin/rm -rf "$APP"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$ROOT/.build/$BUILD_CONFIGURATION/Rearview" \
  "$APP/Contents/MacOS/Rearview"
/bin/cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
  "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" \
  "$APP/Contents/Info.plist"
SPARKLE_FRAMEWORK="$(find "$ROOT/.build" -type d -path "*/$BUILD_CONFIGURATION/Sparkle.framework" -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" || ! -d "$SPARKLE_FRAMEWORK" ]]; then
  print -u2 -- "error: Sparkle.framework was not produced by the build"
  exit 1
fi
/bin/mkdir -p "$APP/Contents/Frameworks"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
/usr/bin/install_name_tool -add_rpath '@loader_path/../Frameworks' \
  "$APP/Contents/MacOS/Rearview"
if [[ "$PACKAGE_MODE" == "dev" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.bloodybear.rearview.dev' \
    "$APP/Contents/Info.plist"
fi
for localization in "$ROOT"/Resources/*.lproj; do
  /bin/cp -R "$localization" "$APP/Contents/Resources/"
done
/bin/cp "$ICON_FILE" "$APP/Contents/Resources/Rearview.icns"
/bin/cp "$STATUS_ICON_FILE" "$APP/Contents/Resources/Rearview.svg"

if [[ "$PACKAGE_MODE" == "dev" ]]; then
  /bin/mkdir -p "$HELPER/Contents/MacOS"
  /bin/cp "$ROOT/.build/$BUILD_CONFIGURATION/BenchmarkFixture" \
    "$HELPER/Contents/MacOS/BenchmarkFixture"
  /bin/cp "$ROOT/Resources/BenchmarkFixture-Info.plist" "$HELPER/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" \
    "$HELPER/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" \
    "$HELPER/Contents/Info.plist"
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$HELPER"
fi

/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
if (( BUILD_ZIP )); then
  /bin/rm -f "$ZIP"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

if (( BUILD_DMG )); then
  DMG_STAGING_DIR="$(/usr/bin/mktemp -d "$ROOT/dist/.dmg-staging.XXXXXX")"
  cleanup_dmg_staging() {
    /bin/rm -rf "$DMG_STAGING_DIR"
  }
  trap cleanup_dmg_staging EXIT

  /usr/bin/ditto "$APP" "$DMG_STAGING_DIR/${APP:t}"
  /bin/ln -s /Applications "$DMG_STAGING_DIR/Applications"
  /bin/rm -f "$DMG"
  /usr/bin/hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG"
fi

print -- "Development feature: $DEBUG_FEATURE_STATUS"
print -- "Version: $APP_VERSION ($APP_BUILD)"
print -- "Signed with identity: $SIGNING_IDENTITY"
print -- "Created app: $APP"
if (( BUILD_ZIP )); then
  print -- "Created zip: $ZIP"
fi
if (( BUILD_DMG )); then
  print -- "Created dmg: $DMG"
fi
