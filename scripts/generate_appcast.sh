#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

usage() {
  print -u2 -- "usage: $0 [archives-directory] [appcast-path]"
  print -u2 -- "  archives-directory: directory containing versioned Rearview update archives"
  print -u2 -- "  appcast-path:      output appcast path (default: $ROOT/appcast.xml)"
  exit 2
}

(( $# <= 2 )) || usage

ARCHIVE_DIRECTORY="${1:-$ROOT/.local/update-archives}"
APPCAST_PATH="${2:-$ROOT/appcast.xml}"
[[ "$ARCHIVE_DIRECTORY" == /* ]] || ARCHIVE_DIRECTORY="$ROOT/$ARCHIVE_DIRECTORY"
[[ "$APPCAST_PATH" == /* ]] || APPCAST_PATH="$ROOT/$APPCAST_PATH"

VERSION_PLIST="$ROOT/Resources/Info.plist"
APP_VERSION="${REARVIEW_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERSION_PLIST")}"
if [[ "$APP_VERSION" != <->.<->.<-> ]]; then
  print -u2 -- "error: REARVIEW_VERSION must use YY.M.Patch numeric format: $APP_VERSION"
  exit 1
fi

SPARKLE_KEY_ACCOUNT="${REARVIEW_SPARKLE_KEY_ACCOUNT:-ed25519}"
DOWNLOAD_URL_PREFIX="${REARVIEW_DOWNLOAD_URL_PREFIX:-https://github.com/bloodybear/rearview/releases/download/v${APP_VERSION}/}"
RELEASE_LINK="${REARVIEW_RELEASE_LINK:-https://github.com/bloodybear/rearview}"
[[ "$DOWNLOAD_URL_PREFIX" == */ ]] || DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX/"

SPARKLE_BIN_DIRECTORY="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN_DIRECTORY/generate_appcast"
GENERATE_KEYS="$SPARKLE_BIN_DIRECTORY/generate_keys"
if [[ ! -x "$GENERATE_APPCAST" || ! -x "$GENERATE_KEYS" ]]; then
  print -u2 -- "error: Sparkle publishing tools are not available"
  print -u2 -- "Run this first to resolve Sparkle and produce the tools:"
  print -u2 -- "  $ROOT/scripts/local/package_app.sh zip"
  exit 1
fi

if [[ ! -d "$ARCHIVE_DIRECTORY" ]]; then
  print -u2 -- "error: update archive directory not found: $ARCHIVE_DIRECTORY"
  print -u2 -- "Create it and place a versioned Rearview.zip archive there before generating the appcast."
  exit 1
fi
if ! find "$ARCHIVE_DIRECTORY" -maxdepth 1 -type f \
    \( -name 'Rearview-*.zip' -o -name 'Rearview-*.dmg' \) -print -quit \
    | /usr/bin/grep -q .; then
  print -u2 -- "error: no versioned Rearview update archive found in: $ARCHIVE_DIRECTORY"
  print -u2 -- "Expected a file such as: $ARCHIVE_DIRECTORY/Rearview-$APP_VERSION.zip"
  exit 1
fi

if ! "$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p >/dev/null; then
  print -u2 -- "error: Sparkle EdDSA key was not found in the macOS keychain"
  print -u2 -- "Generate it once with:"
  print -u2 -- "  $GENERATE_KEYS --account \"$SPARKLE_KEY_ACCOUNT\""
  exit 1
fi

/bin/mkdir -p "${APPCAST_PATH:h}"
SOURCE_APPCAST="$ARCHIVE_DIRECTORY/appcast.xml"
if [[ -f "$APPCAST_PATH" && "$APPCAST_PATH" != "$SOURCE_APPCAST" ]]; then
  /bin/cp "$APPCAST_PATH" "$SOURCE_APPCAST"
fi

"$GENERATE_APPCAST" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$RELEASE_LINK" \
  -o "$APPCAST_PATH" \
  "$ARCHIVE_DIRECTORY"

if [[ ! -s "$APPCAST_PATH" ]]; then
  print -u2 -- "error: Sparkle did not create an appcast: $APPCAST_PATH"
  exit 1
fi
if ! /usr/bin/grep -Fq 'sparkle:edSignature=' "$APPCAST_PATH"; then
  print -u2 -- "error: generated appcast has no EdDSA update signature: $APPCAST_PATH"
  exit 1
fi

print -- "Generated appcast: $APPCAST_PATH"
print -- "Download URL prefix: $DOWNLOAD_URL_PREFIX"
print -- "Sparkle key account: $SPARKLE_KEY_ACCOUNT"
