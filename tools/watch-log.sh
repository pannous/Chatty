#!/bin/zsh
# usage: tools/watch-log.sh [lines]  — prints the end of Chatty's own log from the watch (log collect needs root and fails)
set -eu -o pipefail
DEVICE="00008301-F8849C893C50C02E"; BUNDLE_ID="com.pannous.chatty"
APP_DIR="${0:A:h:h}"; DESTINATION="$APP_DIR/build/watch-logs"
mkdir -p "$DESTINATION"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Documents/chatty.log --destination "$DESTINATION/chatty.log" >/dev/null
tail -n "${1:-60}" "$DESTINATION/chatty.log"
