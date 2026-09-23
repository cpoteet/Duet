#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_BUNDLE="$ROOT/dist/Duet.app"
SIGNING_IDENTITY="${DUET_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${DUET_NOTARY_PROFILE:-duet-notary}"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/duet-notary.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT

if [[ -z "$SIGNING_IDENTITY" && -f "$ROOT/.duet-signing-identity" ]]; then
  SIGNING_IDENTITY=$(< "$ROOT/.duet-signing-identity")
fi
if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
  echo "Set DUET_SIGNING_IDENTITY or .duet-signing-identity to your Developer ID Application certificate name." >&2
  exit 1
fi
AVAILABLE_IDENTITIES=$(security find-identity -p codesigning -v)
if ! grep -Fq "\"$SIGNING_IDENTITY\"" <<< "$AVAILABLE_IDENTITIES"; then
  echo "Developer ID Application certificate is not available in this Mac's keychain: $SIGNING_IDENTITY" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null; then
  echo "Save notarization credentials with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID" >&2
  exit 1
fi

rm -f "$ROOT/Duet.zip"
DUET_BUILD_ONLY=1 DUET_RELEASE=1 DUET_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$ROOT/build.sh"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ditto -c -k --keepParent "$APP_BUNDLE" "$STAGING_DIR/Duet-notary.zip"
RESPONSE="$STAGING_DIR/notary-response.plist"
if ! xcrun notarytool submit "$STAGING_DIR/Duet-notary.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$RESPONSE"; then
  cat "$RESPONSE" >&2
  exit 1
fi
STATUS=$(plutil -extract status raw "$RESPONSE")
if [[ "$STATUS" != "Accepted" ]]; then
  SUBMISSION_ID=$(plutil -extract id raw "$RESPONSE")
  echo "Notarization status: $STATUS. Submission: $SUBMISSION_ID" >&2
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  exit 1
fi

xcrun stapler staple "$APP_BUNDLE"
"$ROOT/package.sh"
