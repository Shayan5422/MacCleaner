#!/bin/zsh
# Builds a signed (and optionally notarized) release of Mac Cleaner.
#
#   scripts/release.sh --team 244735TY4Y --notary-profile MacCleanerNotary
#   scripts/release.sh --team 244735TY4Y --skip-notarization   # signed only
#   scripts/release.sh --team 244735TY4Y --notary-key AuthKey.p8 --notary-key-id <id> --notary-issuer <uuid>
#
# Produces build/release/Mac-Cleaner-<version>.dmg and .zip plus SHA-256 checksums.
# Notarization uses either a keychain profile created once with
#   xcrun notarytool store-credentials <profile> --apple-id <email> --team-id <team>
# or an App Store Connect API key (what the GitHub release workflow uses).
# --keychain <path> signs and notarizes with a specific keychain (CI's temporary one).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

TEAM=""
PROFILE=""
API_KEY=""
API_KEY_ID=""
API_ISSUER=""
KEYCHAIN=""
NOTARIZE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) TEAM="$2"; shift 2 ;;
    --notary-profile) PROFILE="$2"; shift 2 ;;
    --notary-key) API_KEY="$2"; shift 2 ;;
    --notary-key-id) API_KEY_ID="$2"; shift 2 ;;
    --notary-issuer) API_ISSUER="$2"; shift 2 ;;
    --keychain) KEYCHAIN="$2"; shift 2 ;;
    --skip-notarization) NOTARIZE=0; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TEAM" ]] || { echo "Pass --team <Developer Team ID>" >&2; exit 2; }
typeset -a NOTARY_AUTH SIGN_KEYCHAIN
if [[ -n "$API_KEY" ]]; then
  [[ -n "$API_KEY_ID" && -n "$API_ISSUER" ]] || { echo "--notary-key needs --notary-key-id and --notary-issuer" >&2; exit 2; }
  NOTARY_AUTH=(--key "$API_KEY" --key-id "$API_KEY_ID" --issuer "$API_ISSUER")
elif [[ -n "$PROFILE" ]]; then
  NOTARY_AUTH=(--keychain-profile "$PROFILE")
  [[ -n "$KEYCHAIN" ]] && NOTARY_AUTH+=(--keychain "$KEYCHAIN")
elif [[ $NOTARIZE -eq 1 ]]; then
  echo "Pass --notary-profile <name>, --notary-key <AuthKey.p8> … or --skip-notarization" >&2; exit 2
fi
[[ -n "$KEYCHAIN" ]] && SIGN_KEYCHAIN=(--keychain "$KEYCHAIN")

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' project.yml | head -1)"
APP_NAME="Mac Cleaner"
ARTIFACT="Mac-Cleaner-$VERSION"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/MacCleaner.xcarchive"
EXPORT="$BUILD/export"
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Generating Xcode project"
command -v xcodegen >/dev/null && xcodegen generate --quiet

echo "==> Archiving $APP_NAME $VERSION"
typeset -a SIGN_FLAGS
SIGN_FLAGS=(--timestamp)
[[ -n "$KEYCHAIN" ]] && SIGN_FLAGS+=(--keychain "$KEYCHAIN")
xcodebuild -quiet -project MacCleaner.xcodeproj -scheme MacCleaner -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="${SIGN_FLAGS[*]}"
[[ -d "$ARCHIVE" ]] || { echo "Archive failed" >&2; exit 1; }

echo "==> Exporting with Developer ID"
sed "s/__TEAM_ID__/$TEAM/" scripts/ExportOptions.plist > "$BUILD/ExportOptions.plist"
xcodebuild -quiet -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD/ExportOptions.plist" -exportPath "$EXPORT"
APP="$EXPORT/$APP_NAME.app"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier|flags=.*runtime" || {
  echo "The app isn't signed with Developer ID and the hardened runtime" >&2; exit 1; }

echo "==> Creating disk image"
STAGING="$BUILD/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# hdiutil occasionally fails with "Resource busy" on CI machines; retry a few times.
for attempt in 1 2 3; do
  if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO -imagekey zlib-level=9 "$BUILD/$ARTIFACT.dmg" >/dev/null; then
    break
  fi
  [[ $attempt -eq 3 ]] && { echo "Creating the disk image failed" >&2; exit 1; }
  echo "hdiutil failed (attempt $attempt), retrying…" >&2
  sleep 5
done
codesign --sign "Developer ID Application" --timestamp "${SIGN_KEYCHAIN[@]}" "$BUILD/$ARTIFACT.dmg"

if [[ $NOTARIZE -eq 1 ]]; then
  echo "==> Notarizing (this usually takes a few minutes)"
  xcrun notarytool submit "$BUILD/$ARTIFACT.dmg" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$BUILD/$ARTIFACT.dmg"
  xcrun stapler staple "$APP"
  echo "==> Gatekeeper assessment"
  spctl --assess --type open --context context:primary-signature --verbose "$BUILD/$ARTIFACT.dmg"
  spctl --assess --type execute --verbose "$APP"
fi

echo "==> Creating zip"
ditto -c -k --keepParent "$APP" "$BUILD/$ARTIFACT.zip"

(cd "$BUILD" && shasum -a 256 "$ARTIFACT.dmg" "$ARTIFACT.zip" > "$ARTIFACT.sha256")
echo "==> Done"
ls -lh "$BUILD"/*.dmg "$BUILD"/*.zip
cat "$BUILD/$ARTIFACT.sha256"
