#!/usr/bin/env bash
# tests/test-entrypoint-curl-argv.sh
#
# The runner-token refresh call must not pass OSC_ACCESS_TOKEN in curl's argv.
# The real refresh block is extracted from the entrypoint and run with a stub
# `curl` that records its argv and the body file content.
#
# Usage: bash tests/test-entrypoint-curl-argv.sh

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

start=$(grep -n '^if \[\[ ! -z "\$OSC_ACCESS_TOKEN" \]\] && \[\[ ! -z "\$CONFIG_SVC" \]\]; then' "$ENTRYPOINT" | head -1 | cut -d: -f1)
end=$(grep -n '^LOADED_CONFIG_EXPORTS=""' "$ENTRYPOINT" | head -1 | cut -d: -f1)
hstart=$(grep -n '^# BEGIN signal-handling' "$ENTRYPOINT" | head -1 | cut -d: -f1)
hend=$(grep -n '^# END signal-handling' "$ENTRYPOINT" | head -1 | cut -d: -f1)
if [ -z "$start" ] || [ -z "$end" ] || [ -z "$hstart" ] || [ -z "$hend" ]; then
  echo "FAIL: could not locate refresh block or helpers in $ENTRYPOINT"
  exit 1
fi
{ sed -n "${hstart},${hend}p" "$ENTRYPOINT"; sed -n "${start},$((end - 1))p" "$ENTRYPOINT"; } > "$TMP/block.sh"

cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$STUB_DIR/curl_argv"
while [ $# -gt 0 ]; do
  case "$1" in
    --data) f="${2#@}"; cat "$f" > "$STUB_DIR/curl_body"; stat -c %a "$f" > "$STUB_DIR/curl_mode" 2>/dev/null; echo "$f" > "$STUB_DIR/curl_bodyfile"; shift ;;
  esac
  shift
done
printf '{"token":"fresh-pat"}\n200'
STUB
cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP"/bin/*

OUT=$(STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" OSC_ACCESS_TOKEN="sekret-token-123" CONFIG_SVC=mystore \
  bash -c 'LOADING_PID=999999; . "'"$TMP"'/block.sh"; echo "TOKEN=$OSC_ACCESS_TOKEN"' 2>&1)

grep -q "sekret-token-123" "$TMP/curl_argv" && fail "token present in curl argv" || pass "token absent from curl argv"
[ "$(cat "$TMP/curl_body" 2>/dev/null)" = '{"token":"sekret-token-123"}' ] && pass "request body file holds the token JSON" || fail "body file content wrong"
[ "$(cat "$TMP/curl_mode" 2>/dev/null)" = "600" ] && pass "body file is mode 0600" || fail "body file mode ($(cat "$TMP/curl_mode" 2>/dev/null))"
[ -e "$(cat "$TMP/curl_bodyfile" 2>/dev/null)" ] && fail "body file not removed" || pass "body file removed after call"
echo "$OUT" | grep -q "TOKEN=fresh-pat" && pass "passing path: refreshed token is exported" || fail "refreshed token not exported (out='$OUT')"

echo "Passed: $PASS, Failed: $FAIL"
[ "$FAIL" -eq 0 ]
