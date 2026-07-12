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
  "$ROOT/Sources/ProviderAdapter.swift" \
  "$ROOT/Sources/WebBrowser.swift" \
  "$ROOT/Sources/AppState.swift" \
  "$ROOT/Tests/HostLifecycleTests.swift" \
  -o "$BUILD_DIR/HostLifecycleTests"

"$BUILD_DIR/HostLifecycleTests"
