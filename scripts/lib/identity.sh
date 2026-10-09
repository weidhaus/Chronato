#!/usr/bin/env bash
#
# Which Developer ID build-app.sh and release.sh sign with. Both source this
# file, so they cannot drift apart.
#
#   developer_id < <(security find-identity -v -p codesigning)
#
# reads find-identity's output and prints "<SHA-1> <name>" of the valid
# "Developer ID Application: … (5SB3S8ESR3)" identity to sign with, or nothing
# when there is none. The same certificate in two keychains counts once (the
# caller signs by SHA-1, which a duplicate name cannot make ambiguous). Several
# distinct ones (a renewal, a new name) are all this team's, so the NEWEST
# certificate (latest notBefore) wins and the choice is printed on stderr;
# DEVELOPER_ID_SHA1 overrides. If their dates cannot be told apart, it stops
# with the list rather than guess.
#
#   scripts/lib/identity.sh --selftest   checks the rule against sample output

TEAM_ID="5SB3S8ESR3"

# notBefore of the keychain certificate with this SHA-1, in epoch seconds
# (0 when it cannot be read). A function so the selftest can stand in for it.
cert_start() {
    local pem start
    pem="$(security find-certificate -a -Z -p 2>/dev/null | awk -v want="$1" '
        /^SHA-1 hash:/ { take = ($3 == want); next }
        take && /-----BEGIN CERTIFICATE-----/ { out = 1 }
        take && out { print }
        take && /-----END CERTIFICATE-----/ { exit }')"
    start="$(openssl x509 -noout -startdate <<<"$pem" 2>/dev/null | sed 's/^notBefore=//')"
    [[ -n "$start" ]] && LC_ALL=C date -j -u -f "%b %d %T %Y %Z" "$start" +%s 2>/dev/null || echo 0
}

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
        local sha rest start best="" best_start=0 tie=0 unknown=0
        while read -r sha rest; do
            start="$(cert_start "$sha")"
            (( start > 0 )) || unknown=1   # an unreadable date might be the newest
            # Only a tie on the NEWEST date is ambiguous; a newer one clears it.
            if (( start > best_start )); then best="$sha $rest"; best_start=$start; tie=0
            elif (( start == best_start )); then tie=1; fi
        done <<<"$candidates"
        if [[ -z "$best" || $tie == 1 || $unknown == 1 ]]; then
            printf '\033[31m✗ several Developer ID Application identities of team %s and their dates do not tell them apart; set DEVELOPER_ID_SHA1:\033[0m\n%s\n' \
                "$TEAM_ID" "$(sed 's/^/    /' <<<"$candidates")" >&2
            return 1
        fi
        printf '  using the newest of %s Developer ID identities: %s (set DEVELOPER_ID_SHA1 to choose another)\n' \
            "$(wc -l <<<"$candidates" | tr -d ' ')" "${best#* }" >&2
        echo "$best"
        return 0
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
    D="7777777777777777777777777777777777777777"
    E="8888888888888888888888888888888888888888"
    cert_start() { case "$1" in "$A") echo 1789912963 ;; "$B") echo 1791533783 ;; "$D"|"$E") echo 1700000000 ;; *) echo 0 ;; esac; }
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
    expect "two distinct: the newest wins" "$B Developer ID Application: New Name (5SB3S8ESR3)" 0 "$LINE_A
$LINE_A2
$LINE_B
$OTHERS"
    expect "order does not matter" "$B Developer ID Application: New Name (5SB3S8ESR3)" 0 "$LINE_B
$LINE_A
$OTHERS"
    expect "a tie below the newest does not matter" "$B Developer ID Application: New Name (5SB3S8ESR3)" 0 "  8) $D \"Developer ID Application: Twin One (5SB3S8ESR3)\"
  9) $E \"Developer ID Application: Twin Two (5SB3S8ESR3)\"
$LINE_B
$OTHERS"
    expect "a tie on the newest stops" "" 1 "  8) $D \"Developer ID Application: Twin One (5SB3S8ESR3)\"
  9) $E \"Developer ID Application: Twin Two (5SB3S8ESR3)\"
$OTHERS"
    C="6666666666666666666666666666666666666666"
    expect "dates that do not tell them apart stop" "" 1 "$LINE_A
  8) $C \"Developer ID Application: Unknown Date (5SB3S8ESR3)\"
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
