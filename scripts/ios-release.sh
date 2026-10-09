#!/bin/bash
# Archives the iPhone app (Release) and uploads it to App Store Connect for TestFlight.
#
#   scripts/ios-release.sh            # archive, check, export and upload
#   scripts/ios-release.sh --dry-run  # unsigned archive and the same checks; no Apple account needed
#
# The upload signs in with an App Store Connect API key, taken from the
# environment so it never lands in the repository:
#   ASC_KEY_PATH   path to the AuthKey_<id>.p8 file
#   ASC_KEY_ID     the key's ID
#   ASC_ISSUER_ID  the issuer ID (App Store Connect → Users and Access → Integrations)
# BUILD_NUMBER overrides the build number. The default is a UTC timestamp, so
# every upload gets a new, increasing one without editing the project.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

OUT=dist/ios
ARCHIVE="$OUT/Chronato.xcarchive"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
rm -rf "$ARCHIVE" "$OUT/export"
mkdir -p "$OUT"

# A command-line build setting reaches both targets, so app and widget share the build number.
ARCHIVE_CMD=(xcodebuild -project iOS/Chronato.xcodeproj -scheme Chronato -configuration Release
             -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -quiet
             CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

# What App Store Connect would reject after a long upload: an extension whose
# version differs from the app's, a missing export-compliance key, icon or
# privacy manifest, an icon with alpha, a simulator build.
# The icon is Branding/Chronato.icon, compiled by actool into Assets.car: the
# layered stack iOS 26+ draws with Liquid Glass, and flattened 1024 px images
# for iOS 18-25 and the App Store, which must be opaque.
check_archive() {
    local app="$ARCHIVE/Products/Applications/Chronato.app"
    local ext="$app/PlugIns/ChronatoWidgets.appex"
    local fail=0
    # An unsigned build has no AppIdentifierPrefix (the team prefix) to expand.
    local prefix=5SB3S8ESR3.
    [[ $DRY_RUN == 0 ]] || prefix=""
    key() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist" 2>/dev/null || true; }
    expect() { [[ "$1" == "$2" ]] || { echo "✗ $3 is '$1', expected '$2'" >&2; fail=1; }; }
    expect "$(key "$app" CFBundleIdentifier)" com.weidhaus.chronato "app bundle id"
    expect "$(key "$ext" CFBundleIdentifier)" com.weidhaus.chronato.widgets "widget bundle id"
    expect "$(key "$app" CFBundleDisplayName)" Chronato "display name"
    expect "$(key "$app" DTPlatformName)" iphoneos "platform"
    expect "$(key "$app" CFBundleVersion)" "$BUILD_NUMBER" "app build number"
    expect "$(key "$ext" CFBundleVersion)" "$BUILD_NUMBER" "widget build number"
    expect "$(key "$ext" CFBundleShortVersionString)" "$(key "$app" CFBundleShortVersionString)" "widget version"
    expect "$(key "$app" ITSAppUsesNonExemptEncryption)" false "ITSAppUsesNonExemptEncryption"
    expect "$(key "$app" NSSupportsLiveActivities)" true "NSSupportsLiveActivities"
    expect "$(key "$app" CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName)" Chronato "app icon name"
    expect "$(key "$app" ChronatoKeychainGroup)" "${prefix}com.weidhaus.chronato.shared" "keychain group"
    local car
    car="$(xcrun assetutil --info "$app/Assets.car" 2>/dev/null || echo '[]')"
    expect "$(jq '[.[] | select(.Name == "Chronato" and .AssetType == "IconImageStack")] | length > 0' <<<"$car")" true "layered app icon in Assets.car"
    expect "$(jq '[.[] | select(.Name == "Chronato" and .AssetType == "Icon Image" and .PixelWidth == 1024)] | length > 0 and all(.Opaque == true)' <<<"$car")" true "opaque 1024 px app icon in Assets.car"
    for bundle in "$app" "$ext"; do
        [[ -f "$bundle/PrivacyInfo.xcprivacy" ]] || { echo "✗ no PrivacyInfo.xcprivacy in ${bundle##*/}" >&2; fail=1; }
    done
    [[ $fail == 0 ]] || return 1
    echo "✓ archive checks passed: $(key "$app" CFBundleShortVersionString) ($BUILD_NUMBER)"
}

if [[ $DRY_RUN == 1 ]]; then
    "${ARCHIVE_CMD[@]}" CODE_SIGNING_ALLOWED=NO archive
    check_archive
    echo "Dry run: nothing signed or uploaded. Archive in $ARCHIVE"
    exit 0
fi

: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the App Store Connect API key file (.p8)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID to the API key ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the API key issuer ID}"
# Lets automatic signing register the App IDs, App Group and profiles, and sign for distribution.
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

"${ARCHIVE_CMD[@]}" "${AUTH[@]}" archive
check_archive
# destination=upload in ExportOptions.plist: the export goes straight to App Store Connect.
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist iOS/ExportOptions.plist \
    -exportPath "$OUT/export" "${AUTH[@]}"
echo "✓ Uploaded build $BUILD_NUMBER. It appears in TestFlight once App Store Connect has processed it."
