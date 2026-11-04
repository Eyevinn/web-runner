#!/bin/bash
# Verifies write_commit_info in scripts/docker-entrypoint.sh hides
# .commit-info.json from `git status` via info/exclude even when called from a
# cwd that is not the repo (the real entrypoint runs from /runner).
# See Eyevinn/web-runner#73.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${ENTRYPOINT_OVERRIDE:-$SCRIPT_DIR/../scripts/docker-entrypoint.sh}"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
OTHER="$TMP/other"
mkdir -p "$REPO" "$OTHER"

git -C "$REPO" init -q
echo hello > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q -m "init"
printf 'custom-rule\n' >> "$REPO/.git/info/exclude"
BEFORE_COUNT=$(git -C "$REPO" rev-list --count HEAD)

eval "$(sed -n '/^write_commit_info() {/,/^}/p' "$ENTRYPOINT")"

cd "$OTHER" || exit 1
write_commit_info "$REPO" >/dev/null
write_commit_info "$REPO" >/dev/null

if [ -f "$REPO/.commit-info.json" ] && grep -q '"sha"' "$REPO/.commit-info.json"; then
  pass ".commit-info.json written with sha"
else
  fail ".commit-info.json missing or without sha"
fi

if [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  pass "git status --porcelain is clean"
else
  fail "git status not clean: $(git -C "$REPO" status --porcelain)"
fi

if [ "$(grep -cxF '.commit-info.json' "$REPO/.git/info/exclude")" = "1" ]; then
  pass "exclude entry is idempotent"
else
  fail "exclude entry count != 1"
fi

if grep -qxF 'custom-rule' "$REPO/.git/info/exclude"; then
  pass "existing exclude rules survive"
else
  fail "existing exclude rule lost"
fi

if [ "$(git -C "$REPO" rev-list --count HEAD)" = "$BEFORE_COUNT" ] \
  && [ ! -e "$REPO/.gitignore" ] \
  && git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet; then
  pass "no commit, no .gitignore, no tracked changes"
else
  fail "tracked tree or history modified"
fi

if [ -z "$(ls -A "$OTHER")" ]; then
  pass "caller cwd stays clean (no stray .git)"
else
  fail "stray files in caller cwd: $(ls -A "$OTHER")"
fi

if [ "$FAILURES" -gt 0 ]; then echo "$FAILURES failure(s)"; exit 1; fi
echo "All tests passed"
