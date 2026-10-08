#!/usr/bin/env bash
#
# End-to-end test: the real TrackerStore (`Chronato selftest`) against an
# in-memory Kimai 2.69 lookalike (scripts/mock-kimai.py) on 127.0.0.1.
# Never contacts a real Kimai, never touches the Keychain or the app's
# UserDefaults, shows no windows. Exit code: the selftest's (0 = all passed).
#
#   scripts/e2e.sh
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRATCH="$(mktemp -d /private/tmp/chronato-e2e.XXXXXX)"
TOKEN="e2e-token"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

python3 scripts/mock-kimai.py --port "$PORT" --token "$TOKEN" >"$SCRATCH/mock.log" 2>&1 &
MOCK=$!
trap 'kill "$MOCK" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT
for _ in {1..50}; do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/__state" && break
    sleep 0.1
done

swift build
# A process time zone far from the Kimai user's (Europe/Berlin) makes any date
# handled in the Mac's zone instead of Kimai's show up as hours off.
set +e
TZ="Pacific/Honolulu" CHRONATO_HOME="$SCRATCH/home" \
    swift run --skip-build Chronato selftest --server "http://127.0.0.1:$PORT" --token "$TOKEN"
STATUS=$?
set -e
(( STATUS == 0 )) || { echo "mock log:"; tail -n 40 "$SCRATCH/mock.log"; }
exit "$STATUS"
