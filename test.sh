#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD_DIR="$ROOT/.build/tests"
INFO_PLIST="$ROOT/Resources/Info.plist"
mkdir -p "$BUILD_DIR"

# Keep in step with build.sh. Swift autolinks the frameworks each file imports.
SWIFT_FLAGS=(
  -target arm64-apple-macos15.0
  -swift-version 6
  -strict-concurrency=complete
  -warnings-as-errors
)

xcrun swiftc "${SWIFT_FLAGS[@]}" \
  "$ROOT/Sources/Domain.swift" \
  "$ROOT/Sources/JavaScriptLiteral.swift" \
  "$ROOT/Sources/UpdateChecker.swift" \
  "$ROOT/Sources/ProviderAdapter.swift" \
  "$ROOT/Sources/NotificationScript.swift" \
  "$ROOT/Tests/CoreTests.swift" \
  -o "$BUILD_DIR/DuetTests"

cd "$ROOT"
"$BUILD_DIR/DuetTests"

xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
  "$ROOT/Sources/Domain.swift" \
  "$ROOT/Sources/JavaScriptLiteral.swift" \
  "$ROOT/Sources/UpdateChecker.swift" \
  "$ROOT/Sources/ProviderAdapter.swift" \
  "$ROOT/Sources/NotificationScript.swift" \
  "$ROOT/Sources/NotificationBridge.swift" \
  "$ROOT/Sources/LocationBridge.swift" \
  "$ROOT/Sources/PrintingBridge.swift" \
  "$ROOT/Sources/WebBrowser.swift" \
  "$ROOT/Sources/AppState.swift" \
  "$ROOT/Sources/WindowIdentity.swift" \
  "$ROOT/Sources/ContentView.swift" \
  "$ROOT/Tests/HostLifecycleTests.swift" \
  -o "$BUILD_DIR/HostLifecycleTests"

"$BUILD_DIR/HostLifecycleTests"

# A full compile, not -typecheck: some concurrency diagnostics only run
# after type checking.
xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library "$ROOT"/Sources/*.swift -o "$BUILD_DIR/DuetCompileCheck"

# plutil fails on a missing key, which set -e would turn into a bare exit.
require_plist_text() {
  local value
  if ! value=$(plutil -extract "$1" raw "$INFO_PLIST" 2>/dev/null) || [[ -z "$value" ]]; then
    echo "Missing $1 in Resources/Info.plist" >&2
    exit 1
  fi
  print -r -- "$value"
}

require_plist_text NSMicrophoneUsageDescription >/dev/null
require_plist_text NSLocationUsageDescription >/dev/null

MARKETING_VERSION=$(require_plist_text CFBundleShortVersionString)
BUILD_VERSION=$(require_plist_text CFBundleVersion)
if [[ "$BUILD_VERSION" != "$MARKETING_VERSION" ]]; then
  echo "CFBundleVersion must match CFBundleShortVersionString for release builds." >&2
  exit 1
fi

"$ROOT/site-version.sh" --check

echo "Bundle metadata tests passed."
