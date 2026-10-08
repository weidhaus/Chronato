#!/usr/bin/env bash
#
# Releases Chronato: a signed, notarized, stapled disk image and a signed
# Sparkle appcast, both attached to the GitHub release v<version>.
#
#   scripts/release.sh 1.2.0                   release 1.2.0
#   scripts/release.sh 1.2.0 --notes notes.md  … with these release notes (Markdown),
#                                              on GitHub and in Sparkle's update window
#   scripts/release.sh 1.2.0 --dry-run         preflight, build, disk image; stops
#                                              before notarization, publishes nothing
#
# Installed copies read https://github.com/weidhaus/Chronato/releases/latest/download/appcast.xml:
# every release carries its own appcast.xml, and GitHub's "latest" redirect
# points Sparkle at the newest one.
#
# Needs a Developer ID Application certificate, notarization credentials (an App
# Store Connect API key via ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID, or a notarytool
# keychain profile NOTARY_PROFILE, default "weidhaus"), gh logged in, and Sparkle's EdDSA private
# key in the login keychain (generate_appcast signs with it and may ask first).
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NAME="Chronato"
REPO="weidhaus/Chronato"
PROFILE="${NOTARY_PROFILE:-weidhaus}"
GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

VERSION=""
NOTES=""
DRY_RUN=0
while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        # Checked here: a trailing --notes would make the second shift fail,
        # and set -e would end the script without a word.
        --notes) (( $# >= 2 )) || die "--notes needs a file"; NOTES="$2"; shift ;;
        -h | --help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
        *) [[ -z "$VERSION" ]] || die "one version only"; VERSION="$1" ;;
    esac
    shift
done
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "usage: scripts/release.sh <version, e.g. 1.2.0> [--notes FILE] [--dry-run]"
[[ -z "$NOTES" || -f "$NOTES" ]] || die "no notes file at $NOTES"
TAG="v$VERSION"
APP="dist/$NAME.app"
DMG="dist/$NAME-$VERSION.dmg"

# 1. Preflight ---------------------------------------------------------------
#
# Everything that can stop a release is checked before the minutes spent
# building and waiting on Apple. A dry run reports every failed check and
# carries on, so it also works from a branch with uncommitted changes.

check() { # check <what> <how to fix> <command…>
    local what="$1" fix="$2"
    shift 2
    if "$@" >/dev/null 2>&1; then ok "$what"; return; fi
    (( DRY_RUN )) || die "$what: no. $fix"
    warn "! $what: no. $fix (a real release stops here)"
}
on_main() { [[ "$(git symbolic-ref --short -q HEAD)" == main ]]; }
clean_tree() { [[ -z "$(git status --porcelain)" ]]; }
# GIT_TERMINAL_PROMPT=0: an unreachable origin fails instead of asking for a password.
main_pushed() { [[ "$(GIT_TERMINAL_PROMPT=0 git ls-remote origin refs/heads/main | cut -f1)" == "$(git rev-parse HEAD)" ]]; }
tag_free_here() { ! git rev-parse -q --verify "refs/tags/$TAG"; }
# ls-remote --exit-code exits 2 for "no such ref", other codes for errors.
tag_free_on_origin() {
    local rc=0
    GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code origin "refs/tags/$TAG" || rc=$?
    (( rc == 2 ))
}
# Sparkle fetches the feed and the disk image without logging in.
repo_public() { [[ "$(gh repo view "$REPO" --json visibility -q .visibility)" == PUBLIC ]]; }

bold "→ preflight for $NAME $VERSION"
check "on main" "git switch main" on_main
check "working tree clean" "commit or stash first" clean_tree
check "HEAD is origin/main" "push main first, so the release is built from published source" main_pushed
check "tag $TAG unused here" "a version is released once; pick the next" tag_free_here
check "tag $TAG unused on origin" "a version is released once; pick the next (or origin is unreachable)" tag_free_on_origin
check "gh logged in, $REPO reachable" "gh auth login" gh repo view "$REPO"
check "$REPO is public" "make it public; installed copies cannot read a private feed" repo_public
# Notarization signs in with the App Store Connect API key when one is given
# (the same ASC_* variables scripts/ios-release.sh uses), else with a
# notarytool keychain profile.
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
    NOTARY_DESC="App Store Connect API key $ASC_KEY_ID"
else
    NOTARY_AUTH=(--keychain-profile "$PROFILE")
    NOTARY_DESC="keychain profile \"$PROFILE\""
fi
check "notarytool signs in ($NOTARY_DESC)" "set ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID, or: xcrun notarytool store-credentials $PROFILE" \
    xcrun notarytool history "${NOTARY_AUTH[@]}"
check "generate_appcast present" "swift package resolve" test -x "$GENERATE_APPCAST"

# Same lookup as build-app.sh, which signs the app with this identity. Needed
# even for a dry run: the disk image is signed with it too.
IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application' || true)"
[[ -n "$IDENTITY_LINE" ]] || die "no Developer ID Application identity in the keychain; Apple notarizes nothing else"
IDENTITY_HASH="$(awk '{print $2}' <<<"$IDENTITY_LINE")"
ok "signing identity: $(sed 's/.*"\(.*\)"/\1/' <<<"$IDENTITY_LINE")"

# 2. Build -------------------------------------------------------------------

# build-app.sh embeds and re-signs Sparkle, checks the bundle's shape, and
# launches the binary (`--version`) before anything is packaged.
CHRONATO_VERSION="$VERSION" scripts/build-app.sh
[[ "$(codesign -dv "$APP" 2>&1)" =~ TeamIdentifier=[A-Z0-9]{10} ]] || die "$APP is not signed with a Developer ID"

# 3. Disk image ----------------------------------------------------------------

bold "→ building $(basename "$DMG")"
STAGE="dist/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
# The symlink makes the window a drag-to-install.
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
# Gatekeeper checks the image before anything is copied out of it, and the
# notarization ticket is stapled to it, so it is signed as well.
codesign --force --timestamp --sign "$IDENTITY_HASH" "$DMG"
codesign --verify --strict "$DMG"
ok "$DMG"

if (( DRY_RUN )); then
    ok "dry run: stopping before notarization. Nothing was submitted, signed for Sparkle, tagged or published."
    echo "  a release goes on to: notarize, staple, spctl, generate_appcast, tag $TAG, push it, gh release"
    exit 0
fi

# 4. Notarize, staple, verify --------------------------------------------------

bold "→ notarizing with $NOTARY_DESC (waits on Apple, usually minutes)"
# `submit --wait` exits 0 even when Apple rejects the image: the submission
# worked, the verdict was Invalid. Only the verdict counts, and Apple's log
# says why. `|| true`: if it does exit non-zero, the verdict check below still
# runs and fetches the log instead of set -e ending the script mid-air.
NOTARY_JSON="$(xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --output-format json || true)"
NOTARY_ID="$(plutil -extract id raw -o - - <<<"$NOTARY_JSON" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw -o - - <<<"$NOTARY_JSON" 2>/dev/null || true)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    warn "$NOTARY_JSON"
    if [[ -n "$NOTARY_ID" ]]; then
        xcrun notarytool log "$NOTARY_ID" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    die "notarization: ${NOTARY_STATUS:-no verdict}. Nothing was published."
fi
ok "notarized ($NOTARY_ID)"

# The stapled ticket lets a first launch pass Gatekeeper offline.
bold "→ stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t install -vv "$DMG"
ok "Gatekeeper accepts $(basename "$DMG")"

# 5. Appcast -----------------------------------------------------------------

bold "→ generating the appcast (EdDSA-signed with the key in your login keychain)"
# A folder holding only this release: the feed lists just the newest version,
# which is all Sparkle needs. Notes named like the image are embedded in it.
FEED="dist/feed"
rm -rf "$FEED" dist/appcast.xml
mkdir -p "$FEED"
cp "$DMG" "$FEED/"
[[ -z "$NOTES" ]] || cp "$NOTES" "$FEED/$NAME-$VERSION.md"
"$GENERATE_APPCAST" --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    -o dist/appcast.xml "$FEED"
rm -rf "$FEED"
# Sparkle refuses an unsigned update, and a wrong URL is a 404 for every user.
# Both on the enclosure itself: generate_appcast only warns and leaves the
# signature out when the app's SUPublicEDKey does not match the keychain key.
grep -q "<enclosure url=\"https://github.com/$REPO/releases/download/$TAG/$NAME-$VERSION.dmg\".* sparkle:edSignature=\"" dist/appcast.xml \
    || die "dist/appcast.xml has no EdDSA-signed enclosure for the release asset (does SUPublicEDKey match the keychain key?)"
ok "dist/appcast.xml"

# 6. Publish -----------------------------------------------------------------

bold "→ tagging $TAG and pushing the tag"
git tag -a "$TAG" -m "$NAME $VERSION"
git push origin "refs/tags/$TAG"

if [[ -z "$NOTES" ]]; then
    NOTES="dist/release-notes.md"
    echo "Signed with a Developer ID certificate and notarized by Apple. Open the disk image and drag $NAME to Applications; installed copies update themselves." >"$NOTES"
fi

bold "→ publishing the GitHub release"
# Uploaded as a draft, then published: the moment "latest" moves to this
# release, the appcast and the disk image it names are both there.
gh release create "$TAG" "$DMG" dist/appcast.xml --repo "$REPO" \
    --title "$NAME $VERSION" --notes-file "$NOTES" --verify-tag --draft
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
ok "released $NAME $VERSION: https://github.com/$REPO/releases/tag/$TAG"

# What installed copies will read, from the URL baked into the app. Only a
# warning: the release is out either way, but nobody would be offered it.
# grep without -q reads to the end, so curl never dies of SIGPIPE (pipefail).
FEED_URL="$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist")"
if curl -fsSL "$FEED_URL" | grep "/$TAG/$NAME-$VERSION.dmg" >/dev/null; then
    ok "feed: $FEED_URL offers $VERSION"
else
    warn "! $FEED_URL does not offer $VERSION yet; check that this release is marked Latest"
fi
