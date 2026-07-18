#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD_DIR="$ROOT/.build/tests"
mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -target arm64-apple-macos15.0 \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "$ROOT/Sources/Domain.swift" \
  "$ROOT/Sources/UpdateChecker.swift" \
  "$ROOT/Sources/ProviderAdapter.swift" \
  "$ROOT/Tests/CoreTests.swift" \
  -o "$BUILD_DIR/DuetTests"

cd "$ROOT"
"$BUILD_DIR/DuetTests"

xcrun swiftc \
  -target arm64-apple-macos15.0 \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -parse-as-library \
  -framework SwiftUI \
  -framework WebKit \
  -framework AppKit \
  -framework Combine \
  "$ROOT/Sources/Domain.swift" \
  "$ROOT/Sources/UpdateChecker.swift" \
  "$ROOT/Sources/ProviderAdapter.swift" \
  "$ROOT/Sources/WebBrowser.swift" \
  "$ROOT/Sources/AppState.swift" \
  "$ROOT/Sources/WindowIdentity.swift" \
  "$ROOT/Tests/HostLifecycleTests.swift" \
  -o "$BUILD_DIR/HostLifecycleTests"

"$BUILD_DIR/HostLifecycleTests"

MICROPHONE_USAGE_DESCRIPTION=$(
  plutil -extract NSMicrophoneUsageDescription raw "$ROOT/Resources/Info.plist"
)
if [[ -z "$MICROPHONE_USAGE_DESCRIPTION" ]]; then
  echo "Missing NSMicrophoneUsageDescription in Resources/Info.plist" >&2
  exit 1
fi

MARKETING_VERSION=$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")
BUILD_VERSION=$(plutil -extract CFBundleVersion raw "$ROOT/Resources/Info.plist")
if [[ "$BUILD_VERSION" != "$MARKETING_VERSION" ]]; then
  echo "CFBundleVersion must match CFBundleShortVersionString for release builds." >&2
  exit 1
fi

echo "Bundle metadata tests passed."
