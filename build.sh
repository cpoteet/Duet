#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD_DIR="$ROOT/.build"
DIST_DIR="$ROOT/dist"
APP_NAME="Duet"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ICON_SOURCE="$ROOT/Resources/DuetIcon.png"
ICONSET="$BUILD_DIR/Duet.iconset"

if pgrep -x "$APP_NAME" >/dev/null; then
  echo "Closing running $APP_NAME…"
  pkill -x "$APP_NAME" || true

  for _ in {1..50}; do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.1
  done

  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Could not close $APP_NAME; rebuild aborted." >&2
    exit 1
  fi
fi

rm -rf "$BUILD_DIR" "$APP_BUNDLE" "$DIST_DIR/Prompt Pair.app"
mkdir -p "$BUILD_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

xcrun swiftc \
  -target arm64-apple-macos15.0 \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -parse-as-library \
  -framework SwiftUI \
  -framework WebKit \
  -framework AppKit \
  -framework Combine \
  "$ROOT"/Sources/*.swift \
  -o "$EXECUTABLE"

for resource in "$ROOT"/Resources/*; do
  [[ "${resource:t}" == "Info.plist" ]] && continue
  cp -R "$resource" "$APP_BUNDLE/Contents/Resources/"
done
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [[ -f "$ICON_SOURCE" ]]; then
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/Duet.icns"
fi

codesign --force --sign - "$APP_BUNDLE" >/dev/null

open "$APP_BUNDLE"
echo "Built and launched: $APP_BUNDLE"
