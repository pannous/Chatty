#!/bin/zsh
# Builds Chatty with OPENAI_API_KEY from .env embedded (via the gitignored Secrets/), installs and launches it on the watch.
# usage: tools/build.sh [watch udid]
set -eu -o pipefail # a failed build must not be installed
DEFAULT_DEVICE="00008301-F8849C893C50C02E" # Pannous Watch (Series 7)
BUNDLE_ID="com.pannous.chatty"

APP_DIR="${0:A:h:h}"
DEVICE="${1:-$DEFAULT_DEVICE}"
source "$APP_DIR/.env"
[[ -n "${OPENAI_API_KEY:-}" ]] || { echo "OPENAI_API_KEY missing in $APP_DIR/.env" >&2; exit 1; }
mkdir -p "$APP_DIR/Secrets"
print -r -- "OPENAI_API_KEY = $OPENAI_API_KEY" > "$APP_DIR/Secrets/Secrets.xcconfig"

cd "$APP_DIR"
xcodegen -q
xcodebuild -project Chatty.xcodeproj -scheme Chatty -sdk watchos -destination "id=$DEVICE" \
  -derivedDataPath "$APP_DIR/build/dd" -allowProvisioningUpdates build 2>&1 | grep -E 'error:|warning: .*Sources|BUILD'
xcrun devicectl device install app --device "$DEVICE" "$APP_DIR/build/dd/Build/Products/Debug-watchos/Chatty.app"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
