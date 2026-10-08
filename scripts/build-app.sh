#!/usr/bin/env bash
#
# Builds dist/Chronato.app: universal release binary, Info.plist stamped with
# the git version, the app icon, and a Developer ID signature.
#
#   scripts/build-app.sh              build and sign
#   scripts/build-app.sh --notarize   … then notarize, staple, and write
#                                     dist/Chronato-<version>.zip and .dmg
#   scripts/build-app.sh --install    … then replace /Applications/Chronato.app
#
# CHRONATO_VERSION=1.2.0 sets the version instead of the nearest git tag
# (scripts/release.sh does this). Sparkle.framework is embedded and re-signed.
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
        -h | --help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
UNIVERSAL=(-c release --arch arm64 --arch x86_64)
if swift build "${UNIVERSAL[@]}"; then
    BIN="$(swift build "${UNIVERSAL[@]}" --show-bin-path)/$NAME"
else
    warn "! universal build failed; building for $(uname -m) only. The app will run on $(uname -m) Macs only."
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/$NAME"
fi
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

# Sparkle is a dynamic framework the binary loads through @rpath. SwiftPM
# leaves it beside the binary (universal and native builds alike); the bundle
# carries it in Contents/Frameworks, and the rpath points there. ditto keeps
# the framework's symlinks.
FRAMEWORK="$(dirname "$BIN")/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || die "no Sparkle.framework beside $BIN"
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$NAME"
ok "assembled $APP"

# 3. Sign --------------------------------------------------------------------

# First valid Developer ID. Signed by its SHA-1, not its name: the same
# certificate in two keychains makes a name ambiguous to codesign.
# `|| true`: no match must not end the script under `set -e -o pipefail`.
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application' || true)"
if [[ -n "$IDENTITY_LINE" ]]; then
    IDENTITY_HASH="$(awk '{print $2}' <<<"$IDENTITY_LINE")"
    IDENTITY_NAME="$(sed 's/.*"\(.*\)"/\1/' <<<"$IDENTITY_LINE")"
    bold "→ signing as $IDENTITY_NAME"
    # Hardened runtime and a secure timestamp are what notarization requires.
    # No entitlements: Chronato is not sandboxed and needs no exceptions.
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY_HASH")
else
    warn ""
    warn "!!! No \"Developer ID Application\" identity in the keychain: signing AD-HOC."
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

# The shape a launch depends on (the loop above already proved the framework
# is there). A bundle without the rpath dies in dyld before main(), yet
# codesign and notarization pass it. grep without -q reads all of otool's
# output, so pipefail cannot trip over a SIGPIPE.
otool -l "$APP/Contents/MacOS/$NAME" | grep "path @executable_path/../Frameworks " >/dev/null \
    || die "$APP has no @executable_path/../Frameworks rpath; it cannot find Sparkle"
# A valid signature does not prove the binary starts. `--version` loads it
# under the hardened runtime, so dyld must accept the re-signed Sparkle, and
# reads the stamped Info.plist, all without a GUI. stderr stays visible: when
# this fails, dyld's reason ("different Team IDs", "Library not loaded") is there.
[[ "$("$APP/Contents/MacOS/$NAME" --version)" == "$VERSION" ]] || die "$APP does not start or reports the wrong version"
ok "starts and reports $VERSION"

# 4. Notarize, staple, package ----------------------------------------------

if (( NOTARIZE )); then
    [[ -n "$IDENTITY_LINE" ]] || die "notarization needs a Developer ID signature"
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
