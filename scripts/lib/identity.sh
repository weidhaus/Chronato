#!/usr/bin/env bash
#
# Which Developer ID build-app.sh and release.sh sign with. Both source this
# file, so they cannot drift apart.
#
#   developer_id < <(security find-identity -v -p codesigning)
#
# reads find-identity's output and prints "<SHA-1> <name>" of the one valid
# "Developer ID Application: … (5SB3S8ESR3)" identity, or nothing when there is
# none. The same certificate in two keychains counts once (the caller signs by
# SHA-1, which a duplicate name cannot make ambiguous). Several distinct ones
# (say, a renewal or a new name) fail with the list, unless DEVELOPER_ID_SHA1
# names one of them.
#
#   scripts/lib/identity.sh --selftest   checks the rule against sample output

TEAM_ID="5SB3S8ESR3"

developer_id() {
    local candidates want
    # `  1) <SHA-1> "Developer ID Application: Name (TEAM)"` → `<SHA-1> Developer ID Application: Name (TEAM)`,
    # first line per SHA-1. Anchored at the closing quote, so other teams and
    # identities flagged invalid (a trailing "(CSSMERR_…)") do not match.
    candidates="$(sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(Developer ID Application: .* ('"$TEAM_ID"')\)"$/\1 \2/p' | awk '!seen[$1]++')"
    if [[ -n "${DEVELOPER_ID_SHA1:-}" ]]; then
        want="$(tr a-f A-F <<<"$DEVELOPER_ID_SHA1")"
        if [[ "$want" =~ ^[0-9A-F]{40}$ ]] && grep "^$want " <<<"$candidates"; then return 0; fi
        printf '\033[31m✗ DEVELOPER_ID_SHA1=%s is not a valid Developer ID Application identity of team %s here. Those are:\033[0m\n%s\n' \
            "$DEVELOPER_ID_SHA1" "$TEAM_ID" "$(sed 's/^/    /' <<<"${candidates:-(none)}")" >&2
        return 1
    fi
    if [[ "$candidates" == *$'\n'* ]]; then
        printf '\033[31m✗ several Developer ID Application identities of team %s; set DEVELOPER_ID_SHA1 to the one to sign with:\033[0m\n%s\n' \
            "$TEAM_ID" "$(sed 's/^/    /' <<<"$candidates")" >&2
        return 1
    fi
    [[ -z "$candidates" ]] || echo "$candidates"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    [[ "${1:-}" == --selftest ]] || { echo "usage: $0 --selftest   (the build scripts source this file)" >&2; exit 2; }
    unset DEVELOPER_ID_SHA1
    A="09D5CCFB52D8C2AB7D3157347479701E767BB7DB"
    B="1111111111111111111111111111111111111111"
    LINE_A="  1) $A \"Developer ID Application: Old Name (5SB3S8ESR3)\""
    LINE_A2="  2) $A \"Developer ID Application: Old Name (5SB3S8ESR3)\""
    LINE_B="  3) $B \"Developer ID Application: New Name (5SB3S8ESR3)\""
    OTHERS="  4) 2222222222222222222222222222222222222222 \"Developer ID Application: Someone Else (ABCDE12345)\"
  5) 3333333333333333333333333333333333333333 \"Apple Development: Created via API (RP4AXPC5H3)\"
  6) 4444444444444444444444444444444444444444 \"Developer ID Application: Revoked (5SB3S8ESR3)\" (CSSMERR_TP_CERT_REVOKED)
  7) 5555555555555555555555555555555555555555 \"Developer ID Application: Evil (5SB3S8ESR3) (ABCDE12345)\"
     7 valid identities found"
    FAILS=0
    expect() { # expect <case> <wanted stdout> <wanted status> <find-identity output>
        local out rc=0
        out="$(developer_id <<<"$4" 2>/dev/null)" || rc=$?
        if [[ "$out" == "$2" && "$rc" == "$3" ]]; then
            echo "ok   $1"
        else
            echo "FAIL $1: status $rc, printed \"$out\""
            FAILS=1
        fi
    }
    expect "duplicate counts once" "$A Developer ID Application: Old Name (5SB3S8ESR3)" 0 "$LINE_A
$LINE_A2
$OTHERS"
    expect "two distinct stop" "" 1 "$LINE_A
$LINE_A2
$LINE_B
$OTHERS"
    DEVELOPER_ID_SHA1="$(tr A-F a-f <<<"$B")" \
        expect "DEVELOPER_ID_SHA1 picks one (any case)" "$B Developer ID Application: New Name (5SB3S8ESR3)" 0 "$LINE_A
$LINE_A2
$LINE_B
$OTHERS"
    DEVELOPER_ID_SHA1="2222222222222222222222222222222222222222" \
        expect "DEVELOPER_ID_SHA1 of another team stops" "" 1 "$LINE_A
$LINE_B
$OTHERS"
    DEVELOPER_ID_SHA1="$A" expect "DEVELOPER_ID_SHA1 not in the keychain stops" "" 1 "$OTHERS"
    expect "other teams, dev and invalid certs only: none" "" 0 "$OTHERS"
    expect "empty keychain: none" "" 0 "     0 valid identities found"
    (( FAILS == 0 )) || { echo "identity selftest FAILED" >&2; exit 1; }
    echo "identity selftest passed"
fi
