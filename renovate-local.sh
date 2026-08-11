#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  aem-cm-renovate  ·  GENERATE
#  Create real Renovate branches locally through a throwaway Gitea server —
#  nothing is pushed to the repo's real origin.
# ══════════════════════════════════════════════════════════════════════════════
#
# Flow:
#   1. ensure a local Gitea server (docker) on localhost:3000
#   2. mirror the repo into Gitea (adds a renovate.json if the repo lacks one)
#   3. run real Renovate against Gitea  -> creates renovate/* branches
#   4. fetch those branches back into your checkout, then write Markdown reports
#   5. tear down the Gitea container (unless KEEP_GITEA=1)
#
# Usage:
#   ./renovate-local.sh <repo-path>
#     repo-path   full path to the target CM checkout (required; no default).
#
# Environment:
#   LIMIT=N               cap the run at ~N update branches (default: 0 = unlimited)
#   KEEP_GITEA=1          do NOT tear down the Gitea container at the end
#   GITHUB_COM_TOKEN      read-only GitHub PAT for richer release notes / no rate limits
#
# After it runs:
#   cd <repo-path> && git branch --list 'renovate/*'
#   git show renovate/<branch>          # each branch = one Renovate commit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The target repo must be given explicitly as a path. No default, no guessing.
if [ -z "${1:-}" ]; then
  echo "error: no repo path given." >&2
  echo "usage: $(basename "$0") <full-path-to-cm-checkout>" >&2
  exit 1
fi
REPO_DIR="$1"
[ -d "$REPO_DIR/.git" ] || { echo "error: '$REPO_DIR' is not a git checkout" >&2; exit 1; }
REPO_DIR="$(cd "$REPO_DIR" && pwd)"    # normalize to an absolute path
REPO_NAME="$(basename "$REPO_DIR")"

CONTAINER=renovate-gitea
GITEA_USER=renovate-admin
GITEA_PASS='RenovatePass123!'
GITEA_URL=http://localhost:3000
TMP="$SCRIPT_DIR/.renovate-tmp"
mkdir -p "$TMP"

RENOVATE_BIN="$SCRIPT_DIR/node_modules/.bin/renovate"
[ -x "$RENOVATE_BIN" ] || { echo "renovate not installed; run 'npm install' in $SCRIPT_DIR" >&2; exit 1; }
[ -d "$REPO_DIR/.git" ] || { echo "'$REPO_DIR' is not a git checkout" >&2; exit 1; }

echo ">> [1/4] starting a fresh Gitea..."
docker info >/dev/null 2>&1 || { echo "starting Docker..."; open -a Docker; until docker info >/dev/null 2>&1; do sleep 2; done; }
# Always start clean: a leftover container from an interrupted run can hold a stale
# repo and make Renovate see it as "empty". Recreating each run avoids that race.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  -e GITEA__security__INSTALL_LOCK=true \
  -e GITEA__server__ROOT_URL="$GITEA_URL/" \
  -e GITEA__server__OFFLINE_MODE=true \
  -p 3000:3000 -p 2222:22 gitea/gitea:1.22 >/dev/null
until [ "$(curl -s -o /dev/null -w '%{http_code}' "$GITEA_URL/")" = "200" ]; do sleep 2; done
docker exec -u git "$CONTAINER" gitea admin user create \
  --username "$GITEA_USER" --password "$GITEA_PASS" \
  --email renovate@localhost --admin --must-change-password=false >/dev/null

# fresh API token each run (idempotent-ish: name must be unique, so include epoch)
TOKEN=$(curl -s -X POST "$GITEA_URL/api/v1/users/$GITEA_USER/tokens" \
  -u "$GITEA_USER:$GITEA_PASS" -H 'Content-Type: application/json' \
  -d "{\"name\":\"renovate-$(date +%s)\",\"scopes\":[\"write:repository\",\"write:user\",\"write:issue\"]}" \
  | node "$SCRIPT_DIR/lib/json-get.js" - 'j.sha1')
echo "$TOKEN" > "$TMP/gitea-token.txt"

echo ">> [2/4] mirroring $REPO_NAME into Gitea..."
# recreate repo in gitea (delete if exists)
curl -s -X DELETE -H "Authorization: token $TOKEN" "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME" >/dev/null 2>&1 || true
curl -s -X POST "$GITEA_URL/api/v1/user/repos" -H "Authorization: token $TOKEN" \
  -H 'Content-Type: application/json' -d "{\"name\":\"$REPO_NAME\",\"private\":false}" >/dev/null

PUSH="$TMP/push-$REPO_NAME"
rm -rf "$PUSH"; git clone -q "$REPO_DIR" "$PUSH"
( cd "$PUSH"
  if [ ! -f renovate.json ]; then
    cp "$SCRIPT_DIR/default-renovate.json" renovate.json
    git add renovate.json
    git -c user.email=renovate@localhost -c user.name=renovate commit -q -m "chore: add renovate.json (local test)"
  fi
  BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  git remote add gitea "http://$GITEA_USER:$TOKEN@localhost:3000/$GITEA_USER/$REPO_NAME.git"
  git push -q gitea "$BASE_BRANCH"
)

echo ">> [3/5] running Renovate (creates branches; PRs land only in disposable Gitea)..."
# Optional: export GITHUB_COM_TOKEN before running for richer release notes /
# changelogs in the reports (a read-only public-scope GitHub PAT is enough).
# Preflight the token so an expired/invalid one doesn't silently yield empty
# release notes — Renovate fetches changelog content from github.com.
if [ -n "${GITHUB_COM_TOKEN:-}" ]; then
  gh_status="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $GITHUB_COM_TOKEN" https://api.github.com/rate_limit || echo 000)"
  if [ "$gh_status" = "200" ]; then
    export GITHUB_COM_TOKEN
    echo "   GITHUB_COM_TOKEN OK (github.com auth 200) — release notes will be fetched."
  else
    echo "   WARNING: GITHUB_COM_TOKEN is set but github.com returned $gh_status (expected 200)." >&2
    echo "            The token is likely expired/invalid — release notes will be EMPTY." >&2
    echo "            Fix: export a valid read-only PAT, or 'unset GITHUB_COM_TOKEN'. Continuing..." >&2
    unset GITHUB_COM_TOKEN   # don't pass a broken token to Renovate
  fi
else
  echo "   note: GITHUB_COM_TOKEN not set — release notes may be empty/rate-limited."
  echo "         Export a read-only GitHub PAT for full changelogs."
fi
# Cap on how many update branches+PRs Renovate may create in this run.
#   LIMIT unset / 0  -> UNLIMITED: a branch/PR for EVERY available update (default).
#   LIMIT=N          -> at most ~N branches+PRs.
# We apply this via Renovate's `force` config (RENOVATE_FORCE) because a repo's own
# renovate.json OVERRIDES plain env vars — `force` wins over everything, so the
# limit is honored even when the target repo sets its own prConcurrentLimit.
LIMIT="${LIMIT:-0}"
export RENOVATE_FORCE="{\"prConcurrentLimit\":$LIMIT,\"branchConcurrentLimit\":$LIMIT,\"prHourlyLimit\":0}"
LOG_LEVEL=info \
RENOVATE_PLATFORM=gitea \
RENOVATE_ENDPOINT="$GITEA_URL/api/v1" \
RENOVATE_TOKEN="$TOKEN" \
RENOVATE_GIT_URL=endpoint \
RENOVATE_REPOSITORIES="$GITEA_USER/$REPO_NAME" \
RENOVATE_DEPENDENCY_DASHBOARD=false \
RENOVATE_ONBOARDING=false \
RENOVATE_REQUIRE_CONFIG=optional \
RENOVATE_GIT_AUTHOR='Renovate Bot <renovate@localhost>' \
RENOVATE_BASE_DIR="$TMP/base" \
RENOVATE_REPORT_TYPE=file \
RENOVATE_REPORT_PATH="$TMP/renovate-report.json" \
  "$RENOVATE_BIN" > "$TMP/gitea-run.log" 2>&1 || { echo "renovate failed; see $TMP/gitea-run.log"; exit 1; }

echo ">> [4/5] fetching renovate/* branches into $REPO_NAME (nothing pushed to real origin)..."
( cd "$REPO_DIR"
  git remote remove renovate-local 2>/dev/null || true
  git remote add renovate-local "http://$GITEA_USER:$TOKEN@localhost:3000/$GITEA_USER/$REPO_NAME.git"
  git fetch -q renovate-local '+refs/heads/renovate/*:refs/heads/renovate/*'
  git remote remove renovate-local
  echo "   $(git branch --list 'renovate/*' | wc -l | tr -d ' ') local renovate/* branches ready"
)

echo ">> [5/5] writing Markdown reports (PR body + release-notes/change history)..."
REPORTS_DIR="$SCRIPT_DIR/renovate-reports/$REPO_NAME"
rm -rf "$REPORTS_DIR"; mkdir -p "$REPORTS_DIR"

# branches whose lockfile/artifact update failed (from the run log).
# `|| true` keeps a no-match grep from aborting the script under `set -e`.
PROBLEM="$(grep -oE 'artifactErrors \(repository=[^,]+, branch=renovate/[^)]+\)' "$TMP/gitea-run.log" 2>/dev/null | grep -oE 'renovate/[^)]+' | sort -u | paste -sd, - || true)"

# paginate PRs from Gitea (API caps each page at 50) into $TMP/pulls-page-*.json
rm -f "$TMP"/pulls-page-*.json
page=1
while : ; do
  f="$TMP/pulls-page-$page.json"
  curl -sf -H "Authorization: token $TOKEN" \
    "$GITEA_URL/api/v1/repos/$GITEA_USER/$REPO_NAME/pulls?state=all&limit=50&page=$page" -o "$f" || break
  n="$(node "$SCRIPT_DIR/lib/json-get.js" "$f" 'j.length' 2>/dev/null || echo 0)"
  [ "$n" -eq 0 ] && { rm -f "$f"; break; }
  [ "$n" -lt 50 ] && break
  page=$((page+1))
done

# turn each PR into <sanitized-branch>.md (body includes Release Notes) + index.md
REPORTS_DIR="$REPORTS_DIR" REPO_DIR="$REPO_DIR" PAGES_DIR="$TMP" REPO_NAME="$REPO_NAME" \
REPORT_JSON="$TMP/renovate-report.json" \
RENOVATE_PROBLEM_BRANCHES="$PROBLEM" node "$SCRIPT_DIR/lib/build-report.js"
rm -f "$TMP"/pulls-page-*.json

# Auto-teardown: branches are in your checkout and reports are on disk, so the
# Gitea container is no longer needed. Keep it with KEEP_GITEA=1.
if [ "${KEEP_GITEA:-}" = "1" ]; then
  echo ">> KEEP_GITEA=1 set — leaving Gitea running (teardown: docker rm -f $CONTAINER)"
else
  echo ">> tearing down Gitea container ($CONTAINER)..."
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi

echo ">> done."
echo ">> reports:            $REPORTS_DIR/  (open index.md)"
echo ">> inspect branches:   cd $REPO_DIR && git branch --list 'renovate/*'"
echo ">> delete local branches:  ./cleanup-renovate-branches.sh $REPO_DIR"
