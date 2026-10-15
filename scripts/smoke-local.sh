#!/bin/bash
# End-to-end check of "This Mac only" mode against a throwaway app instance.
# Builds ./build/Relay.app, runs it on port 47911 with a temp config and data dir,
# drives it with bin/relay (on the system Python 3.9) and curl, then cleans up.
# A notification may appear for the test ask; ignore it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PY="${PYTHON:-/usr/bin/python3}"
PORT=47911
TMP="$(mktemp -d)"
APP_PID=""

cleanup() {
  if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
mode_of() { stat -f '%Lp' "$1"; }

BUILD_ONLY=1 ./scripts/build.sh >/dev/null

# Both folders start 0755. The app tightens the data folder to 0700 at start,
# but leaves the folder of a custom $RELAY_CONFIG as it is.
mkdir -p "$TMP/config" "$TMP/data"
chmod 755 "$TMP/config" "$TMP/data"
printf '{"source":"local","port":%d,"hotkey":""}\n' "$PORT" > "$TMP/config/config.json"
chmod 600 "$TMP/config/config.json"

RELAY_CONFIG="$TMP/config/config.json" RELAY_DATA_DIR="$TMP/data" \
  "$ROOT/build/Relay.app/Contents/MacOS/Relay" >"$TMP/app.log" 2>&1 &
APP_PID=$!

for _ in $(seq 1 40); do
  if curl -q --noproxy '*' -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"app":"relay"'; then break; fi
  sleep 0.25
done
HEALTH="$(curl -q --noproxy '*' -fsS "http://127.0.0.1:$PORT/health" || true)"
printf '%s' "$HEALTH" | grep -q '"source":"local"' || fail "health does not report source local: $HEALTH"
printf '%s' "$HEALTH" | grep -q '"proof"' && fail "health sent a proof without a nonce"
[ "$(mode_of "$TMP/config")" = "755" ] || fail "custom config folder was changed to $(mode_of "$TMP/config")"
[ "$(mode_of "$TMP/data")" = "700" ] || fail "data folder is $(mode_of "$TMP/data"), not 700"

export RELAY_CONFIG="$TMP/config/config.json"
# Test-only: if the temp instance dies, the CLI must never start the installed app.
export RELAY_NO_AUTOLAUNCH=1

# relay post: "posted <id>", then "open <openUrl>".
POST_OUT="$("$PY" bin/relay post Acme --json - <<'EOF'
{"v": 1, "title": "Smoke test ask", "why": "Checks the local queue end to end.",
 "urgency": "today",
 "steps": [{"do": "Run the check", "where": "Terminal", "code": "echo relay-ok", "expect": "relay-ok"}],
 "reply": {"prompt": "Did it work?", "choices": ["Yes", "No"]}}
EOF
)" || fail "relay post exited non-zero"
ID="$(printf '%s\n' "$POST_OUT" | awk '/^posted /{print $2}')"
[ -n "$ID" ] || fail "relay post did not print 'posted <id>': $POST_OUT"
[ "$(printf '%s\n' "$POST_OUT" | sed -n 2p)" = "open http://127.0.0.1:$PORT/i/$ID" ] || fail "missing open link: $POST_OUT"

# Same project and title within 24 h: "deduped <id>", then the same open link.
AGAIN="$("$PY" bin/relay post Acme --json - <<'EOF'
{"v": 1, "title": "Smoke test ask", "steps": [{"do": "Run the check"}]}
EOF
)" || fail "second relay post exited non-zero"
[ "$(printf '%s\n' "$AGAIN" | sed -n 1p)" = "deduped $ID" ] || fail "second post was not deduped: $AGAIN"

# relay list: "<id> <urgency> <project> · <title>".
LIST_OUT="$("$PY" bin/relay list)" || fail "relay list exited non-zero"
printf '%s\n' "$LIST_OUT" | grep -qx "$ID today Acme · Smoke test ask" || fail "relay list line: $LIST_OUT"

# relay status: "open · <project> · <title>" while open.
STATUS_OUT="$("$PY" bin/relay status "$ID")" || fail "relay status exited non-zero"
[ "$(printf '%s\n' "$STATUS_OUT" | head -1)" = "open · Acme · Smoke test ask" ] || fail "status while open: $STATUS_OUT"

# relay done, then status "(by session)", then a second done says who finished it.
[ "$("$PY" bin/relay done "$ID" "smoke")" = "done $ID" ] || fail "relay done output"
STATUS_OUT="$("$PY" bin/relay status "$ID")" || fail "relay status exited non-zero"
[ "$(printf '%s\n' "$STATUS_OUT" | head -1)" = "done (by session) · Acme · Smoke test ask" ] \
  || fail "status after done: $STATUS_OUT"
[ "$("$PY" bin/relay done "$ID")" = "already done (by session) $ID" ] || fail "second done is not 'already done (by session)'"

# relay wait: owner events only come from the app, so this ask has none and a session's
# done doesn't count. It exits 3 after about 2 s with nothing on stdout.
WAIT_RC=0
WAIT_OUT="$("$PY" bin/relay wait "$ID" --timeout 2 --interval 1 2>"$TMP/wait.err")" || WAIT_RC=$?
[ "$WAIT_RC" = "3" ] || fail "relay wait exited $WAIT_RC, not 3: $(cat "$TMP/wait.err")"
[ -z "$WAIT_OUT" ] || fail "relay wait printed on stdout: $WAIT_OUT"
grep -qx "no owner answer on $ID within 2 s" "$TMP/wait.err" || fail "relay wait timeout line: $(cat "$TMP/wait.err")"

# The hook: a key's first run is silent, exits 0 and writes the cursor next to config.json.
HOOK_OUT="$(printf '{"session_id":"smoke-1","prompt":"hello"}' | "$PY" bin/relay replies --new --hook)" \
  || fail "hook exited non-zero"
[ -z "$HOOK_OUT" ] || fail "hook first run printed output: $HOOK_OUT"
[ -f "$TMP/config/replies-cursor.json" ] || fail "replies cursor not written next to config.json"
grep -q '"session:smoke-1"' "$TMP/config/replies-cursor.json" || fail "replies cursor has no session:smoke-1 key"
[ "$(mode_of "$TMP/config/replies-cursor.json")" = "600" ] || fail "replies-cursor.json is not 0600"

# The local API, by hand. The token is this temp instance's; it is never printed.
TOKEN="$(cat "$TMP/config/local-token")"
code() { curl -q --noproxy '*' -s -o /dev/null -w '%{http_code}' "$@"; }
[ "$(code -H "Authorization: Bearer $TOKEN" -H 'Origin: http://example.com' "http://127.0.0.1:$PORT/asks")" = "403" ] || fail "Origin not refused"
[ "$(code -H "Authorization: Bearer $TOKEN" -H "Host: evil.example:$PORT" "http://127.0.0.1:$PORT/asks")" = "403" ] || fail "bad Host not refused"
[ "$(code "http://127.0.0.1:$PORT/asks")" = "401" ] || fail "missing token not refused"
[ "$(code -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/asks")" = "200" ] || fail "the right token is not accepted"
[ "$(code -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"text":"forged"}' "http://127.0.0.1:$PORT/asks/$ID/reply")" = "404" ] || fail "reply route exists"
[ "$(code -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"verdict":"done","actor":"owner"}' "http://127.0.0.1:$PORT/asks/$ID/resolve")" = "403" ] || fail "owner actor not refused"
curl -q --noproxy '*' -fsS -H 'X-Relay-Nonce: 00112233445566778899aabbccddeeff' "http://127.0.0.1:$PORT/health" | grep -q '"proof":"' \
  || fail "health proof missing"
[ "$(mode_of "$TMP/config/local-token")" = "600" ] || fail "local-token is not 0600"
[ "$(mode_of "$TMP/data/queue.json")" = "600" ] || fail "queue.json is not 0600"

echo "SMOKE OK"
