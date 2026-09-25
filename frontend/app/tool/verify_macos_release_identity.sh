#!/bin/sh
set -eu

# Guard the identity that macOS uses for the sandbox container and Keychain.
# Changing it turns an update into a different application and makes the old
# encrypted client state inaccessible.

cd "$(dirname "$0")/.."

expected_bundle_id="com.messenger.messengerApp"
config="macos/Runner/Configs/AppInfo.xcconfig"
entitlements="macos/Runner/Release.entitlements"
product_name="$(sed -n 's/^PRODUCT_NAME = //p' "$config")"
app="build/macos/Build/Products/Release/$product_name.app"

configured_bundle_id="$(sed -n 's/^PRODUCT_BUNDLE_IDENTIFIER = //p' "$config")"
if [ "$configured_bundle_id" != "$expected_bundle_id" ]; then
  echo "FAIL: PRODUCT_BUNDLE_IDENTIFIER=$configured_bundle_id (expected $expected_bundle_id)" >&2
  exit 1
fi

for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.network.client \
  com.apple.security.device.audio-input
do
  if ! /usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements" 2>/dev/null | grep -qx true; then
    echo "FAIL: required release entitlement is absent or false: $entitlement" >&2
    exit 1
  fi
done

if [ ! -d "$app" ]; then
  echo "FAIL: release app is absent; run 'flutter build macos --release' first" >&2
  exit 1
fi

built_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
if [ "$built_bundle_id" != "$expected_bundle_id" ]; then
  echo "FAIL: built CFBundleIdentifier=$built_bundle_id (expected $expected_bundle_id)" >&2
  exit 1
fi

signed_entitlements="$(mktemp -t ouo-entitlements.XXXXXX)"
trap 'rm -f "$signed_entitlements"' EXIT
codesign -d --entitlements :- "$app" >"$signed_entitlements" 2>/dev/null

for entitlement in \
  com.apple.security.app-sandbox \
  com.apple.security.network.client \
  com.apple.security.device.audio-input
do
  if ! /usr/libexec/PlistBuddy -c "Print :$entitlement" "$signed_entitlements" 2>/dev/null | grep -qx true; then
    echo "FAIL: signed app is missing entitlement: $entitlement" >&2
    exit 1
  fi
done

echo "PASS: bundle identity and required signed entitlements are stable"
echo "bundle_id=$built_bundle_id"
echo "app=$app"
echo "NOTE: this guard does not replace Developer ID/notarization verification in the release pipeline"
