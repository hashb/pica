#!/usr/bin/env bash
# Builds, signs (Developer ID + hardened runtime), notarizes and staples Pica.app,
# then packages it as build/Pica-<version>.zip.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. Saved notarization credentials:
#        xcrun notarytool store-credentials pica-notary --apple-id <you@example.com> --team-id <TEAMID>
#
# Usage: scripts/release.sh            (uses keychain profile "pica-notary")
#        NOTARY_PROFILE=other scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-pica-notary}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="build/Pica.app"
ZIP="build/Pica-$VERSION.zip"

echo "==> Building Pica $VERSION"
scripts/build-app.sh release >/dev/null

echo "==> Signing with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing (this usually takes a few minutes)"
SUBMIT_ZIP="$(mktemp -d)/Pica-submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$SUBMIT_ZIP"

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "Done: $ZIP"
