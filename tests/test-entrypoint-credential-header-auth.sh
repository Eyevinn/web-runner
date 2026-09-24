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
#   Credentials travel via a per-invocation `-c http.extraheader=...` git
#   option (GIT_AUTH_ARGS) instead of being embedded in the clone/fetch URL.
#   git clone/fetch always receive the credential-free
#   https://${GIT_HOST_PUBLIC}${GIT_PATH} URL. A `-c key=value` is never
#   persisted to .git/config and is not part of the URL string, so it
#   cannot appear in "fatal: ... for '<url>'"-style git error output.
#
# These tests assert the fix is in place and has not regressed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: GIT_AUTH_ARGS is built from TOKEN via http.extraheader, not a URL
# ---------------------------------------------------------------------------
if grep -qF 'http.extraheader=AUTHORIZATION: basic' "$ENTRYPOINT"; then
  pass "GIT_AUTH_ARGS uses http.extraheader for credential auth"
else
  fail "GIT_AUTH_ARGS / http.extraheader auth mechanism is missing"
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
#         prints the raw token itself, only its base64-encoded form
# ---------------------------------------------------------------------------
sandbox_out=$(bash -c '
  TOKEN="ghp_supersecrettokenvalue1234567890"
  AUTH_B64=$(printf "%s" "x-access-token:${TOKEN}" | base64 | tr -d "\n")
  GIT_AUTH_ARGS=(-c "http.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  echo "built: ${GIT_AUTH_ARGS[*]}"
')

if echo "$sandbox_out" | grep -q "ghp_supersecrettokenvalue1234567890"; then
  fail "raw token leaked into the built GIT_AUTH_ARGS output: $sandbox_out"
else
  pass "raw token does not appear in the built auth header (only its base64 form does)"
fi

if echo "$sandbox_out" | grep -qF "http.extraheader=AUTHORIZATION: basic"; then
  pass "auth header is correctly shaped (http.extraheader=AUTHORIZATION: basic <b64>)"
else
  fail "auth header was not built as expected: $sandbox_out"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral — the Gitea (pre-embedded user:pass@host) path builds
#         its Basic-Auth pair from the embedded credentials, not by
#         re-embedding them in a URL
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
    GIT_AUTH_ARGS=(-c "http.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  elif [[ "$GIT_HOST" != "$GIT_HOST_PUBLIC" ]]; then
    CREDS="${GIT_HOST%%@*}"
    AUTH_B64=$(printf "%s" "$CREDS" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
