#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Duet"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
LICENSE_FILE="$ROOT/LICENSE.md"
ARCHIVE="$ROOT/$APP_NAME.zip"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/duet-package.XXXXXX")

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing $APP_BUNDLE. Run ./build.sh first." >&2
  exit 1
fi

if [[ ! -f "$LICENSE_FILE" ]]; then
  echo "Missing $LICENSE_FILE." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")
BUILD_VERSION=$(plutil -extract CFBundleVersion raw "$APP_BUNDLE/Contents/Info.plist")
if [[ "$APP_VERSION" != "$BUILD_VERSION" ]]; then
  echo "Built app marketing and build versions do not match." >&2
  exit 1
fi

ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
cp "$LICENSE_FILE" "$STAGING_DIR/LICENSE.md"
rm -f "$ARCHIVE"
(
  cd "$STAGING_DIR"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry --symlinks "$ARCHIVE" "$APP_NAME.app" LICENSE.md
)

ARCHIVE_CONTENTS=$(unzip -Z1 "$ARCHIVE")
if ! grep -qx "$APP_NAME.app/" <<< "$ARCHIVE_CONTENTS"; then
  echo "$ARCHIVE does not contain $APP_NAME.app at its root." >&2
  exit 1
fi
if ! grep -qx "LICENSE.md" <<< "$ARCHIVE_CONTENTS"; then
  echo "$ARCHIVE does not contain LICENSE.md at its root." >&2
  exit 1
fi
if grep -q '^__MACOSX/' <<< "$ARCHIVE_CONTENTS"; then
  echo "$ARCHIVE contains unexpected __MACOSX metadata." >&2
  exit 1
fi

VERIFY_DIR="$STAGING_DIR/verify"
mkdir -p "$VERIFY_DIR"
unzip -q "$ARCHIVE" -d "$VERIFY_DIR"
cmp "$LICENSE_FILE" "$VERIFY_DIR/LICENSE.md"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/$APP_NAME.app"

echo "Packaged $APP_NAME $APP_VERSION: $ARCHIVE"
