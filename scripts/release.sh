#!/bin/bash
# Packages LabelIt for a GitHub release: dist/LabelIt.zip and dist/LabelIt.zip.sha256, the two files install.sh
# downloads. Run from the repository: make release
#
# Signing:
#   - A "Developer ID Application" certificate (found in the keychain, or named in DEVELOPER_ID="Developer ID
#     Application: Your Name (TEAMID)"): signed for distribution, and with
#     NOTARY_PROFILE=<a notarytool keychain profile> also notarized and stapled, so it opens cleanly however it's
#     downloaded. (Make the profile once: xcrun notarytool store-credentials <name>.)
#   - Neither: signed ad hoc. It installs and runs through install.sh (curl downloads aren't quarantined), but a zip
#     downloaded in a browser gets Gatekeeper's "unidentified developer" warning, and macOS asks for permissions
#     again after each update.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)
[[ -n "$VERSION" ]] || { echo "release.sh: no MARKETING_VERSION in project.yml" >&2; exit 1; }
OUT=build/release
DIST=dist

scripts/build-llama.sh
xcodegen generate --quiet

# A Developer ID certificate in the keychain is used without being named (when there's exactly one).
if [[ -z "${DEVELOPER_ID:-}" ]]; then
  FOUND=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | sort -u)
  [[ $(printf '%s' "$FOUND" | grep -c .) == 1 ]] && DEVELOPER_ID="$FOUND"
fi
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  TEAM="${DEVELOPER_ID##*(}"; TEAM="${TEAM%)}"   # the certificate's team, e.g. "… (ABCDE12345)"
  SIGNING=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS="--timestamp")
  echo "Signing with $DEVELOPER_ID"
else
  SIGNING=(CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
  echo "No DEVELOPER_ID: signing ad hoc (see the top of this script)"
fi

rm -rf "$OUT" "$DIST"
xcodebuild -project LabelIt.xcodeproj -scheme LabelIt -configuration Release -derivedDataPath build/DerivedData \
  CONFIGURATION_BUILD_DIR="$PWD/$OUT" "${SIGNING[@]}" build -quiet
codesign --verify --deep --strict "$OUT/LabelIt.app"

mkdir -p "$DIST"
if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$OUT/LabelIt.app" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT/LabelIt.app"
  rm "$DIST/notarize.zip"
fi
ditto -c -k --keepParent "$OUT/LabelIt.app" "$DIST/LabelIt.zip"
(cd "$DIST" && shasum -a 256 LabelIt.zip > LabelIt.zip.sha256)

echo
echo "Built LabelIt $VERSION: $DIST/LabelIt.zip ($(du -h "$DIST/LabelIt.zip" | cut -f1)), sha256 $(cut -d' ' -f1 "$DIST/LabelIt.zip.sha256")"
echo "Publish it (install.sh always fetches the latest release):"
echo "  gh release create v$VERSION $DIST/LabelIt.zip $DIST/LabelIt.zip.sha256 --title \"LabelIt $VERSION\" --generate-notes"
