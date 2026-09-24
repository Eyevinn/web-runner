#!/usr/bin/env bash
# tests/test-entrypoint-credential-header-auth.sh
#
# Shell regression tests for the header-based git auth fix in
# scripts/docker-entrypoint.sh (issue #55).
#
# Background:
#   git clone/git fetch received the credentialed URL as an argument
#   (https://${TOKEN}@${GIT_HOST_PUBLIC}${GIT_PATH}, or the pre-embedded
#   Gitea user:pass@host form). When either command failed, git's own
#   diagnostic output echoed that URL verbatim to stderr — captured by
#   promtail into Loki — independent of anything this script itself logged.
#   A crash-looping pod with an existing /usercontent/.git took the
#   "existing repo found" branch on every restart, which re-injected the
#   token into origin before every fetch, making this the dominant leak
#   source.
#
# Fix (this PR):
#   Credentials travel via a per-invocation `-c http.<url>.extraheader=...`
#   git option (GIT_AUTH_ARGS) instead of being embedded in the clone/fetch
#   URL. git clone/fetch always receive the credential-free
#   https://${GIT_HOST_PUBLIC}${GIT_PATH} URL. A `-c key=value` is never
#   persisted to .git/config and is not part of the URL string, so it
#   cannot appear in "fatal: ... for '<url>'"-style git error output.
#
# Follow-up fix (PR #56 review):
#   1. The extraheader config key is scoped to the exact host being
#      cloned/fetched from (http.https://${GIT_HOST_PUBLIC}/.extraheader)
#      instead of a bare, unscoped http.extraheader. An unscoped extraheader
#      is attached to every request git makes for the invocation, including
#      a redirect to a different host.
#   2. The Gitea pre-embedded-credentials path splits on the LAST "@" in
#      GIT_HOST (CREDS="${GIT_HOST%@*}", single %, shortest suffix match) to
#      match the GIT_HOST_PUBLIC="${GIT_HOST##*@}" convention already used
#      two lines above. The prior CREDS="${GIT_HOST%%@*}" (double %%, longest
#      suffix match) split on the FIRST "@", silently truncating any
#      password containing a literal "@" character.
#
# These tests assert the fix is in place and has not regressed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: GIT_AUTH_ARGS is built from TOKEN via a HOST-SCOPED
#         http.https://<host>/.extraheader key, not a bare/unscoped
#         http.extraheader
# ---------------------------------------------------------------------------
scoped_header_count=$(grep -cF 'http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic' "$ENTRYPOINT")
if [ "$scoped_header_count" -ge 2 ]; then
  pass "GIT_AUTH_ARGS uses a host-scoped http.https://\${GIT_HOST_PUBLIC}/.extraheader key ($scoped_header_count call sites)"
else
  fail "expected at least 2 host-scoped http.https://\${GIT_HOST_PUBLIC}/.extraheader call sites, found $scoped_header_count"
fi

# Guard against regressing back to a bare/unscoped key. A bare key looks like
# `"http.extraheader=` (the config key starts directly with "extraheader",
# no "http.<scheme>://<host>/." prefix in front of it).
unscoped_header=$(grep -nE '"http\.extraheader=' "$ENTRYPOINT" || true)
if [ -z "$unscoped_header" ]; then
  pass "no bare/unscoped http.extraheader key remains in the script"
else
  fail "a bare/unscoped http.extraheader key was found (should be host-scoped): $unscoped_header"
fi

# ---------------------------------------------------------------------------
# Test 2: no git clone/fetch/remote-set-url line interpolates \$TOKEN
#         directly into a URL argument
# ---------------------------------------------------------------------------
token_in_url=$(grep -nE '(clone|fetch|remote set-url)[^#]*\$\{?TOKEN\}?@' "$ENTRYPOINT" || true)
if [ -z "$token_in_url" ]; then
  pass "no clone/fetch/remote-set-url line embeds \$TOKEN in a URL"
else
  fail "a git URL still embeds \$TOKEN: $token_in_url"
fi

# ---------------------------------------------------------------------------
# Test 3: no git clone/fetch line interpolates the unscrubbed \$GIT_HOST
#         (which may itself carry embedded user:pass@ credentials for the
#         Gitea case) into a URL argument. Only \$GIT_HOST_PUBLIC may appear
#         in a clone/fetch URL.
# ---------------------------------------------------------------------------
git_host_in_clone=$(grep -nE '(clone|fetch)[^#]*\$\{GIT_HOST\}' "$ENTRYPOINT" || true)
if [ -z "$git_host_in_clone" ]; then
  pass "no clone/fetch line embeds the unscrubbed \$GIT_HOST in a URL"
else
  fail "a git clone/fetch line still embeds unscrubbed \$GIT_HOST: $git_host_in_clone"
fi

# ---------------------------------------------------------------------------
# Test 4: GIT_AUTH_ARGS is actually passed to both the clone call and the
#         fetch origin call(s)
# ---------------------------------------------------------------------------
clone_uses_auth_args=$(grep -cE 'git "\$\{GIT_AUTH_ARGS\[@\]\}" clone' "$ENTRYPOINT")
if [ "$clone_uses_auth_args" -ge 1 ]; then
  pass "git clone is invoked with \${GIT_AUTH_ARGS[@]}"
else
  fail "git clone is not invoked with \${GIT_AUTH_ARGS[@]}"
fi

fetch_uses_auth_args=$(grep -cE 'git -C /usercontent/ "\$\{GIT_AUTH_ARGS\[@\]\}" fetch origin' "$ENTRYPOINT")
if [ "$fetch_uses_auth_args" -ge 2 ]; then
  pass "git fetch origin (default-branch and by-commit-sha paths) is invoked with \${GIT_AUTH_ARGS[@]}"
else
  fail "expected at least 2 'git fetch origin' invocations using \${GIT_AUTH_ARGS[@]}, found $fetch_uses_auth_args"
fi

# ---------------------------------------------------------------------------
# Test 5: stderr of the clone/fetch network calls is wrapped for defense in
#         depth (git_scrub_stderr helper)
# ---------------------------------------------------------------------------
if grep -qF 'git_scrub_stderr()' "$ENTRYPOINT"; then
  pass "git_scrub_stderr helper is defined"
else
  fail "git_scrub_stderr helper is missing"
fi

scrub_call_count=$(grep -cE 'git_scrub_stderr git ' "$ENTRYPOINT")
if [ "$scrub_call_count" -ge 3 ]; then
  pass "git_scrub_stderr wraps clone and fetch network calls ($scrub_call_count call sites)"
else
  fail "expected at least 3 git_scrub_stderr-wrapped git invocations, found $scrub_call_count"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral — building the auth header from a fake token never
#         prints the raw token itself, only its base64-encoded form, and the
#         header config key is scoped to GIT_HOST_PUBLIC
# ---------------------------------------------------------------------------
sandbox_out=$(bash -c '
  GIT_HOST_PUBLIC="example.git.host"
  TOKEN="ghp_supersecrettokenvalue1234567890"
  AUTH_B64=$(printf "%s" "x-access-token:${TOKEN}" | base64 | tr -d "\n")
  GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  echo "built: ${GIT_AUTH_ARGS[*]}"
')

if echo "$sandbox_out" | grep -q "ghp_supersecrettokenvalue1234567890"; then
  fail "raw token leaked into the built GIT_AUTH_ARGS output: $sandbox_out"
else
  pass "raw token does not appear in the built auth header (only its base64 form does)"
fi

if echo "$sandbox_out" | grep -qF "http.https://example.git.host/.extraheader=AUTHORIZATION: basic"; then
  pass "auth header is correctly shaped and host-scoped (http.https://<host>/.extraheader=AUTHORIZATION: basic <b64>)"
else
  fail "auth header was not built as expected: $sandbox_out"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral — the Gitea (pre-embedded user:pass@host) path builds
#         its Basic-Auth pair from the embedded credentials, not by
#         re-embedding them in a URL, and scopes the header to the host
# ---------------------------------------------------------------------------
sandbox_gitea=$(bash -c '
  GIT_URL="https://oscadmin:abc123def@example.git.host/owner/repo.git"
  GIT_HOST="${GIT_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  TOKEN=""
  GIT_AUTH_ARGS=()
  if [[ ! -z "$TOKEN" ]]; then
    AUTH_B64=$(printf "%s" "x-access-token:${TOKEN}" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  elif [[ "$GIT_HOST" != "$GIT_HOST_PUBLIC" ]]; then
    CREDS="${GIT_HOST%@*}"
    AUTH_B64=$(printf "%s" "$CREDS" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST_PUBLIC}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  fi
  echo "args: ${GIT_AUTH_ARGS[*]}"
  echo "clone_url: https://${GIT_HOST_PUBLIC}${GIT_PATH}"
')

if echo "$sandbox_gitea" | grep -q "abc123def"; then
  fail "Gitea credentials leaked in plaintext into sandbox output: $sandbox_gitea"
else
  pass "Gitea pre-embedded credentials do not leak in plaintext when building GIT_AUTH_ARGS"
fi

if echo "$sandbox_gitea" | grep -q "^clone_url: https://example.git.host$"; then
  pass "Gitea clone URL is credential-free (oscadmin:abc123def@ stripped)"
else
  fail "Gitea clone URL sandbox output unexpected: $sandbox_gitea"
fi

if echo "$sandbox_gitea" | grep -qF "http.https://example.git.host/.extraheader=AUTHORIZATION: basic"; then
  pass "Gitea auth header is host-scoped (http.https://example.git.host/.extraheader=...)"
else
  fail "Gitea auth header was not host-scoped as expected: $sandbox_gitea"
fi

# ---------------------------------------------------------------------------
# Test 8: behavioral — a Gitea password containing a literal "@" survives
#         the CREDS split in full (splits on the LAST "@", not the first)
# ---------------------------------------------------------------------------
sandbox_gitea_at_password=$(bash -c '
  # oscadmin:pa@ss is the full user:pass pair; @host is the host boundary.
  # The literal "@" inside the password is what a first-"@" split truncates.
  GIT_URL="https://oscadmin:pa@ss@host/owner/repo.git"
  GIT_HOST="${GIT_URL#*://}"
  GIT_HOST="${GIT_HOST%%/*}"
  GIT_HOST_PUBLIC="${GIT_HOST##*@}"
  CREDS="${GIT_HOST%@*}"
  AUTH_B64=$(printf "%s" "$CREDS" | base64 | tr -d "\n")
  echo "creds: $CREDS"
  echo "host_public: $GIT_HOST_PUBLIC"
  echo "decoded: $(printf "%s" "$AUTH_B64" | base64 -d)"
')

if echo "$sandbox_gitea_at_password" | grep -qF "creds: oscadmin:pa@ss"; then
  pass "CREDS splits on the LAST @, preserving the full password (oscadmin:pa@ss)"
else
  fail "CREDS did not preserve the full @-containing password: $sandbox_gitea_at_password"
fi

if echo "$sandbox_gitea_at_password" | grep -qF "host_public: host"; then
  pass "GIT_HOST_PUBLIC still correctly resolves to the host-only suffix (host)"
else
  fail "GIT_HOST_PUBLIC did not resolve as expected: $sandbox_gitea_at_password"
fi

if echo "$sandbox_gitea_at_password" | grep -qF "decoded: oscadmin:pa@ss"; then
  pass "base64-decoded Basic-Auth pair contains the full password, including the embedded @"
else
  fail "base64-decoded Basic-Auth pair dropped part of the @-containing password: $sandbox_gitea_at_password"
fi

# ---------------------------------------------------------------------------
# Test 9: behavioral — a host-scoped extraheader is NOT sent to a different
#         host (regression guard for the unscoped-header leak scenario:
#         redirect / wrong GIT_HOST_PUBLIC). Uses two local HTTP servers to
#         prove the Authorization header only reaches the scoped host.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  HDR_TEST_DIR=$(mktemp -d)
  cat > "$HDR_TEST_DIR/log_server.py" <<'PYEOF'
import http.server
import sys

log_path = sys.argv[1]
port = int(sys.argv[2])


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log_path, "a") as f:
            f.write(f"AUTH={self.headers.get('Authorization')}\n")
        self.send_response(404)
        self.end_headers()

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF

  SCOPED_LOG="$HDR_TEST_DIR/scoped.log"
  OTHER_LOG="$HDR_TEST_DIR/other.log"
  touch "$SCOPED_LOG" "$OTHER_LOG"

  python3 "$HDR_TEST_DIR/log_server.py" "$SCOPED_LOG" 18991 >/dev/null 2>&1 &
  SCOPED_PID=$!
  python3 "$HDR_TEST_DIR/log_server.py" "$OTHER_LOG" 18992 >/dev/null 2>&1 &
  OTHER_PID=$!
  sleep 1

  # Header scoped to 127.0.0.1:18991; request goes to a DIFFERENT host
  # (127.0.0.1:18992) to simulate a redirect/host-mismatch scenario.
  git -c "http.http://127.0.0.1:18991/.extraheader=AUTHORIZATION: basic dGVzdA==" \
    clone "http://127.0.0.1:18992/owner/repo.git" "$HDR_TEST_DIR/clone_other" >/dev/null 2>&1

  # Same scoped header, request goes to the SCOPED host — header must arrive.
  git -c "http.http://127.0.0.1:18991/.extraheader=AUTHORIZATION: basic dGVzdA==" \
    clone "http://127.0.0.1:18991/owner/repo.git" "$HDR_TEST_DIR/clone_scoped" >/dev/null 2>&1

  kill "$SCOPED_PID" "$OTHER_PID" >/dev/null 2>&1
  wait "$SCOPED_PID" "$OTHER_PID" 2>/dev/null

  if grep -q "AUTH=basic dGVzdA==" "$SCOPED_LOG"; then
    pass "host-scoped extraheader IS sent when the request targets the scoped host"
  else
    fail "host-scoped extraheader was not sent to its own scoped host: $(cat "$SCOPED_LOG")"
  fi

  if grep -q "AUTH=None" "$OTHER_LOG" && ! grep -q "basic dGVzdA==" "$OTHER_LOG"; then
    pass "host-scoped extraheader is NOT sent to a different host (no credential leak on host mismatch)"
  else
    fail "host-scoped extraheader leaked to an unrelated host: $(cat "$OTHER_LOG")"
  fi

  rm -rf "$HDR_TEST_DIR"
else
  echo "SKIP: python3 not available, skipping host-scoping network test"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
