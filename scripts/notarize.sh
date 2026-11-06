#!/bin/sh
# Builds DeadAir.app signed with a Developer ID and the hardened runtime, notarizes
# it with Apple, staples the ticket, and checks that Gatekeeper accepts it.
# Prints the app's path.
#
#   scripts/notarize.sh
#   SIGN_ID="Developer ID Application: You (TEAMID)" NOTARY_PROFILE=mine scripts/notarize.sh
#
# NOTARY_PROFILE is a notarytool keychain profile (default maxpane-notary). To make one:
#   xcrun notarytool store-credentials <name> --apple-id <email> --team-id <team> --password <app-specific password>
set -eu
cd "$(dirname "$0")/.."

profile="${NOTARY_PROFILE:-maxpane-notary}"
id="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$id" ] || { echo "notarize: no Developer ID Application identity in the keychain" >&2; exit 1; }
app="build/DeadAir.app"
zip="build/DeadAir.zip"

make app >&2
codesign --force --options runtime --timestamp -s "$id" "$app" >&2
codesign --verify --strict --verbose=2 "$app" >&2

# notarytool takes a zip, not a bare .app; ditto keeps the bundle intact.
ditto -c -k --keepParent "$app" "$zip"
echo "==> submitting to Apple with profile $profile (takes a few minutes)" >&2
out="$(xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait 2>&1)" || true
echo "$out" >&2
sub="$(echo "$out" | awk '/^  id:/ {print $2; exit}')"
if ! echo "$out" | grep -q 'status: Accepted'; then
  [ -n "$sub" ] && xcrun notarytool log "$sub" --keychain-profile "$profile" >&2
  exit 1
fi
rm -f "$zip"

xcrun stapler staple "$app" >&2
spctl --assess --type execute --verbose=2 "$app" >&2
echo "$app"
