#!/usr/bin/env bash
#
# Builds dist/Chronato.app: Apple-silicon-only (arm64) release binary, Info.plist stamped with
# the git version, the app icon (Icon Composer + .icns fallback), and a Developer ID signature.
#
#   scripts/build-app.sh              build and sign
#   scripts/build-app.sh --notarize   … then notarize, staple, and write
#                                     dist/Chronato-<version>.zip and .dmg
#   scripts/build-app.sh --install    … then replace /Applications/Chronato.app
#
# CHRONATO_VERSION=1.2.0 sets the version instead of the nearest git tag
# (scripts/release.sh does this). Sparkle.framework is embedded and re-signed.
# DEVELOPER_ID_SHA1=<SHA-1> picks the identity when the keychain holds several
# Developer IDs (security find-identity -v -p codesigning lists them).
#
# Notarization reads Apple credentials from a notarytool keychain profile,
# NOTARY_PROFILE (default "weidhaus"). Create one once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NAME="Chronato"
APP="dist/$NAME.app"

NOTARIZE=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --notarize) NOTARIZE=1 ;;
        --install) INSTALL=1 ;;
        -h | --help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Version: CHRONATO_VERSION, else the nearest tag ("v0.2.0" → "0.2.0"), else
# 0.1.0. Build number: commit count, so every commit gets a higher
# CFBundleVersion than the last; Sparkle compares that number, not the version.
if [[ -n "${CHRONATO_VERSION:-}" ]]; then
    VERSION="$CHRONATO_VERSION"
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "CHRONATO_VERSION must look like 1.2.3, not \"$VERSION\""
else
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || VERSION="0.1.0"
fi
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"

# 1. Build -------------------------------------------------------------------

bold "→ building $NAME $VERSION ($BUILD, $DESCRIBE)"
# Apple silicon only: no Intel slice anywhere, so macOS never offers Rosetta.
ARM64=(-c release --arch arm64)
swift build "${ARM64[@]}"
BIN="$(swift build "${ARM64[@]}" --show-bin-path)/$NAME"
[[ -x "$BIN" ]] || die "no binary at $BIN"
ok "binary: $(lipo -archs "$BIN")"

# 2. Bundle ------------------------------------------------------------------

[[ -f Branding/AppIcon.icns ]] || swift scripts/make-icon.swift Branding
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist" || die "Info.plist is invalid"
cp Branding/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The macOS 26 icon: the Icon Composer document compiled into Assets.car
# (CFBundleIconName). actool also writes a Chronato.icns of its own; the bundle
# keeps AppIcon.icns (CFBundleIconFile), drawn from the same master.
ICONS="$(mktemp -d)"
# Absolute input path: actool hands the job to a shared ibtoold daemon that
# resolves relative paths against ITS working directory, not this script's.
ACTOOL="$(xcrun actool "$PWD/Branding/Chronato.icon" --compile "$ICONS" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon Chronato --output-partial-info-plist "$ICONS/partial.plist" --output-format human-readable-text 2>&1)" \
    || die "actool could not compile Branding/Chronato.icon: $ACTOOL"
[[ -f "$ICONS/Assets.car" ]] || die "actool wrote no Assets.car: $ACTOOL"
cp "$ICONS/Assets.car" "$APP/Contents/Resources/Assets.car"
rm -rf "$ICONS"

# Sparkle is a dynamic framework the binary loads through @rpath. SwiftPM
# leaves it beside the binary; the bundle carries it in Contents/Frameworks,
# and the rpath points there. ditto keeps the framework's symlinks.
# Sparkle ships universal, so its Intel slices are stripped here; the
# signing below replaces the signatures this invalidates.
FRAMEWORK="$(dirname "$BIN")/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || die "no Sparkle.framework beside $BIN"
mkdir -p "$APP/Contents/Frameworks"
ditto --arch arm64 "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$NAME"
ok "assembled $APP"

# 3. Sign --------------------------------------------------------------------

# The team's one Developer ID (scripts/lib/identity.sh, shared with
# release.sh), signed by its SHA-1, not its name: the same certificate in two
# keychains makes a name ambiguous to codesign. Several distinct ones stop the
# build here (set -e) unless DEVELOPER_ID_SHA1 picks one.
source scripts/lib/identity.sh
IDENTITY="$(developer_id < <(security find-identity -v -p codesigning 2>/dev/null))"
if [[ -n "$IDENTITY" ]]; then
    IDENTITY_HASH="${IDENTITY%% *}"
    bold "→ signing as ${IDENTITY#* } ($IDENTITY_HASH)"
    # Hardened runtime and a secure timestamp are what notarization requires.
    # No entitlements: Chronato is not sandboxed and needs no exceptions.
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY_HASH")
else
    warn ""
    warn "!!! No \"Developer ID Application\" identity of team $TEAM_ID in the keychain: signing AD-HOC."
    warn "!!! Fine on this Mac. Other Macs will refuse to open it, it cannot be"
    warn "!!! notarized, and the Keychain may ask again after every rebuild."
    warn ""
    SIGN=(codesign --force --sign -)
fi
# Sparkle first, inside out, then the app. It arrives ad-hoc signed, and under
# the hardened runtime dyld refuses a framework whose Team ID differs from the
# app's. Explicitly rather than --deep: each helper is code that must be signed
# before the bundle around it. The XPC services are discovered, not named:
# missing them got a sibling app's notarization rejected, and whatever Sparkle
# adds later is covered too. Entitlements are not preserved: Autoupdate's
# ad-hoc com.apple.application-identifier would not match a Developer ID.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE/Versions/B/Updater.app" "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE"; do
    [[ -e "$item" ]] || die "missing $item; has Sparkle's layout changed?"
    "${SIGN[@]}" "$item"
done
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/  /'
# The picker trusts the certificate's NAME ending in "(TEAM)"; the signature
# itself says which team it really is. A Developer ID build must be that team's,
# with the Developer ID requirement (leaf marker 6.1.13) installed copies check.
if [[ -n "${IDENTITY:-}" ]]; then
    [[ "$(codesign -dv "$APP" 2>&1)" == *"TeamIdentifier=$TEAM_ID"* ]] || die "$APP is not signed by team $TEAM_ID"
    DR="$(codesign -d -r- "$APP" 2>&1)"
    [[ "$DR" == *"1.2.840.113635.100.6.1.13"* && "$DR" == *"subject.OU] = \"$TEAM_ID\""* ]] \
        || die "$APP's designated requirement does not pin Developer ID and team $TEAM_ID: $DR"
fi

# The shape a launch depends on (the loop above already proved the framework
# is there). A bundle without the rpath dies in dyld before main(), yet
# codesign and notarization pass it. grep without -q reads all of otool's
# output, so pipefail cannot trip over a SIGPIPE.
otool -l "$APP/Contents/MacOS/$NAME" | grep "path @executable_path/../Frameworks " >/dev/null \
    || die "$APP has no @executable_path/../Frameworks rpath; it cannot find Sparkle"

# Every Mach-O in the bundle must be arm64 and nothing else: one Intel slice
# and Finder calls the app Universal and offers "Open using Rosetta".
while IFS= read -r -d '' f; do
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    [[ -z "$archs" || "$archs" == "arm64" ]] || die "$f is $archs, expected arm64 only"
done < <(find "$APP" -type f -print0)
ok "Apple silicon only: every binary is arm64"
# A valid signature does not prove the binary starts. `--version` loads it
# under the hardened runtime, so dyld must accept the re-signed Sparkle, and
# reads the stamped Info.plist, all without a GUI. stderr stays visible: when
# this fails, dyld's reason ("different Team IDs", "Library not loaded") is there.
[[ "$("$APP/Contents/MacOS/$NAME" --version)" == "$VERSION" ]] || die "$APP does not start or reports the wrong version"
ok "starts and reports $VERSION"

# 4. Notarize, staple, package ----------------------------------------------

if (( NOTARIZE )); then
    [[ -n "$IDENTITY" ]] || die "notarization needs a Developer ID signature"
    PROFILE="${NOTARY_PROFILE:-weidhaus}"
    ZIP="dist/$NAME-$VERSION.zip"
    DMG="dist/$NAME-$VERSION.dmg"

    bold "→ notarizing with keychain profile \"$PROFILE\" (takes a few minutes)"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    # notarytool can exit 0 for a rejected submission; the status line decides.
    RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)"
    if ! grep -q "status: Accepted" <<<"$RESULT"; then
        ID="$(awk '/^ *id:/ {print $2; exit}' <<<"$RESULT")"
        die "notarization not accepted. Details: xcrun notarytool log ${ID:-<id>} --keychain-profile $PROFILE"
    fi
    xcrun stapler staple "$APP"
    spctl -a -t exec -vv "$APP"

    # Re-zip: the archive that ships must contain the stapled ticket.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    STAGE="$(mktemp -d)"
    ditto "$APP" "$STAGE/$NAME.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
    rm -rf "$STAGE"
    ok "$ZIP"
    ok "$DMG"
fi

# 5. Install -----------------------------------------------------------------

if (( INSTALL )); then
    TARGET="/Applications/$NAME.app"
    # Match the whole command line so only the menu-bar app quits, not the
    # `Chronato mcp` servers AI agents are talking to (same process name).
    if pgrep -fx ".*/$NAME" >/dev/null; then
        bold "→ quitting the running $NAME"
        pkill -fx ".*/$NAME" || true
        for _ in {1..50}; do
            pgrep -fx ".*/$NAME" >/dev/null || break
            sleep 0.2
        done
        pgrep -fx ".*/$NAME" >/dev/null && die "$NAME is still running; quit it from its menu and run again"
    fi
    bold "→ installing $TARGET"
    if ! { rm -rf "$TARGET" && ditto "$APP" "$TARGET"; }; then
        # An app installed from a disk image is guarded by App Management.
        die "could not replace $TARGET. Drag it to the Trash in Finder (or allow your terminal under Privacy & Security → App Management) and run again."
    fi
    ok "installed $TARGET"
    echo "  open it with: open -a $NAME"
fi

ok "done: $APP ($VERSION, build $BUILD)"
