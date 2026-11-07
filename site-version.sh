#!/bin/zsh
# Keeps the version shown on the public site in step with Resources/Info.plist.
#   ./site-version.sh          rewrite site/index.html to the app's marketing version
#   ./site-version.sh --check  fail if the site shows a different version
set -euo pipefail

ROOT="${0:A:h}"
SITE_PAGE="$ROOT/site/index.html"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Expected an X.Y.Z marketing version in Info.plist, found: $VERSION" >&2
  exit 1
fi
SHORT_VERSION="${VERSION%.*}"

# Markers in site/index.html:
#   <span data-version="full">X.Y.Z</span>
#   <span data-version="short">X.Y</span>
#   <a data-release-notes href="https://github.com/cpoteet/Duet/releases/tag/vX.Y.Z">
FULL_PATTERN='<span data-version="full">[^<]*</span>'
SHORT_PATTERN='<span data-version="short">[^<]*</span>'
LINK_PATTERN='data-release-notes href="https://github.com/cpoteet/Duet/releases/tag/v[^"]*"'

for pattern in "$FULL_PATTERN" "$SHORT_PATTERN" "$LINK_PATTERN"; do
  if ! grep -Eq "$pattern" "$SITE_PAGE"; then
    echo "site/index.html is missing a version marker matching: $pattern" >&2
    exit 1
  fi
done

if [[ "${1:-}" == "--check" ]]; then
  STALE=$(
    grep -Eo "$FULL_PATTERN" "$SITE_PAGE" | grep -Fvx "<span data-version=\"full\">$VERSION</span>" || true
    grep -Eo "$SHORT_PATTERN" "$SITE_PAGE" | grep -Fvx "<span data-version=\"short\">$SHORT_VERSION</span>" || true
    grep -Eo "$LINK_PATTERN" "$SITE_PAGE" | grep -Fvx "data-release-notes href=\"https://github.com/cpoteet/Duet/releases/tag/v$VERSION\"" || true
  )
  if [[ -n "$STALE" ]]; then
    echo "site/index.html does not match version $VERSION. Run ./site-version.sh to update it:" >&2
    echo "$STALE" >&2
    exit 1
  fi
  exit 0
fi

DUET_VERSION="$VERSION" DUET_SHORT_VERSION="$SHORT_VERSION" perl -0pi -e '
  s{(<span data-version="full">)[^<]*(</span>)}{$1$ENV{DUET_VERSION}$2}g;
  s{(<span data-version="short">)[^<]*(</span>)}{$1$ENV{DUET_SHORT_VERSION}$2}g;
  s{(data-release-notes href="https://github\.com/cpoteet/Duet/releases/tag/v)[^"]*(")}{$1$ENV{DUET_VERSION}$2}g;
' "$SITE_PAGE"

echo "Site version set to $VERSION."
