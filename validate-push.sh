#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  aem-cm-renovate  ·  PROMOTE
#  Verify one renovate/* branch with `mvn clean verify`, then push it to the
#  Cloud Manager remote or merge it into the local base branch.
# ══════════════════════════════════════════════════════════════════════════════
#
# The "promote" half of the workflow: renovate-local.sh creates the
# branches locally; this script verifies one and promotes it.
#
# Run with -h/--help for full usage (see the usage() function below).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="$(basename "$0")"

usage() {
  cat <<EOF
$PROG — verify a locally-generated renovate/* branch and promote it.

Builds the chosen branch with 'mvn clean verify' and, on success, either pushes
it to the repo's real origin (the Cloud Manager remote) or merges it into the
local base branch. This is the "promote" half of the workflow;
renovate-local.sh creates the branches first.

With --cloud-manager it additionally triggers a real Adobe Cloud Manager pipeline
run (the same validation the GitHub Actions workflow performs). Default is
Maven-only validation.

USAGE
  $PROG <repo-path> [branch] [action] [--cloud-manager] [--dry-run]
  $PROG -h | --help

ARGUMENTS
  repo-path   Full path to the target CM checkout. Required; no default.
  branch      Renovate branch to promote — exact name (e.g. renovate/babel) or
              just the part after 'renovate/' (e.g. babel). If omitted, the
              script lists the local renovate/* branches and asks you to pick one.
  action      What to do after a successful build:
                push    git push the branch to origin (the CM remote); the CM
                        pipeline then builds/deploys per your branch config.
                merge   merge the branch into the local base branch (main/master);
                        local only — nothing is pushed.
              If omitted, you're asked to choose after the build.

  'branch' and 'action' may be given in either order. When BOTH are supplied the
  script runs fully non-interactively (no prompts).

OPTIONS
  --cloud-manager, --cm   After 'mvn clean verify' passes, run an additional Adobe
                          Cloud Manager pipeline validation via the AIO CLI: point
                          the pipeline at this branch, start an execution, and wait
                          for it to finish. Implies 'push' (the pipeline builds from
                          the CM remote) and is incompatible with 'merge'. Without
                          this flag, validation is Maven-only (the default).
  --dry-run               Validate only: run 'mvn clean verify' (unless SKIP_VERIFY)
                          and then quit WITHOUT pushing, merging, or running any
                          Cloud Manager pipeline — no prompts, no changes. Any
                          'action' argument is ignored.
  -h, --help              Show this help and exit.

ENVIRONMENT
  SKIP_VERIFY=1   Skip 'mvn clean verify' (e.g. to re-promote a verified branch).
  DRY_RUN=1       Same as --dry-run: validate, then quit without changes.

  Cloud Manager validation — only used with --cloud-manager (mirrors the GitHub
  Actions workflow; auth uses OAuth Server-to-Server credentials):
    CM_PROGRAM_ID               Cloud Manager program ID                (required)
    CM_PIPELINE_ID              Cloud Manager pipeline ID to run        (required)
    CM_CLIENT_ID                OAuth client ID                         (required)
    CM_CLIENT_SECRET            OAuth client secret                     (required)
    CM_TECHNICAL_ACCOUNT_ID     Technical account ID                    (required)
    CM_TECHNICAL_ACCOUNT_EMAIL  Technical account email                 (required)
    CM_IMS_ORG_ID               IMS organization ID                     (required)
    CM_SCOPES                   Comma-separated OAuth scopes            (required)
    CM_IMS_ENV                  IMS environment: prod|stage (optional; default prod)
    CM_BASE_URL                 CM API base URL     (optional; default prod endpoint)

BEHAVIOR
  - Refuses to run if the working tree has uncommitted (tracked) changes.
  - A failed 'mvn clean verify' aborts before anything is pushed or merged.
  - 'push' uses 'git push -u origin <branch>'; 'merge' checks out the base
    branch and runs 'git merge --no-edit <branch>'.

EXAMPLES
  # fully interactive: choose the branch, then choose push or merge
  $PROG /full/path/to/aem-cm-project

  # non-interactive: name the branch and the action (either order)
  $PROG /full/path/to/aem-cm-project renovate/aem-core-components push
  $PROG /full/path/to/aem-cm-project merge aemsync-4.x

  # skip the build when re-promoting an already-verified branch
  SKIP_VERIFY=1 $PROG /full/path/to/aem-cm-project renovate/babel merge

  # maven verify + push + a real Cloud Manager pipeline run (CM_* vars must be set)
  $PROG /full/path/to/aem-cm-project renovate/slf4j-monorepo --cloud-manager

  # validate only, then quit without any change (no push/merge, no prompts)
  $PROG /full/path/to/aem-cm-project renovate/babel --dry-run
EOF
}

# ── Cloud Manager pipeline validation (used only with --cloud-manager) ─────────
# Mirrors the GitHub Actions workflow: configure OAuth Server-to-Server auth,
# point the pipeline at the branch, start an execution, and wait for completion.
run_cloud_manager_validation() {
  local branch="$1"
  echo
  echo ">> Cloud Manager validation for '$branch'"

  # Required configuration must be present in the environment.
  local v missing=0
  for v in CM_PROGRAM_ID CM_PIPELINE_ID CM_CLIENT_ID CM_CLIENT_SECRET \
           CM_TECHNICAL_ACCOUNT_ID CM_TECHNICAL_ACCOUNT_EMAIL CM_IMS_ORG_ID CM_SCOPES; do
    if [ -z "${!v:-}" ]; then echo "error: $v is not set" >&2; missing=1; fi
  done
  [ "$missing" = 0 ] || { echo "error: set the CM_* variables above (see --help)." >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: 'jq' is required for Cloud Manager validation." >&2; return 1; }

  # Prefer the AIO CLI installed locally by 'npm install'; fall back to a global one.
  local AIO="aio"
  [ -x "$SCRIPT_DIR/node_modules/.bin/aio" ] && AIO="$SCRIPT_DIR/node_modules/.bin/aio"
  { [ -x "$AIO" ] || command -v "$AIO" >/dev/null 2>&1; } || {
    echo "error: aio CLI not found — run 'npm install' in $SCRIPT_DIR" >&2; return 1; }

  # Ensure the Cloud Manager plugin is present (npm postinstall usually did this).
  "$AIO" cloudmanager --help >/dev/null 2>&1 || "$AIO" plugins:install @adobe/aio-cli-plugin-cloudmanager

  # Configure OAuth Server-to-Server auth into the plugin's default IMS context.
  # Built with jq so secrets are never interpolated unsafely; env defaults to prod.
  local ims_env="${CM_IMS_ENV:-prod}"
  echo ">> IMS environment: $ims_env"
  local cfg; cfg="$(mktemp)"
  jq -n \
    --arg client_id "$CM_CLIENT_ID" \
    --arg client_secret "$CM_CLIENT_SECRET" \
    --arg tech_id "$CM_TECHNICAL_ACCOUNT_ID" \
    --arg tech_email "$CM_TECHNICAL_ACCOUNT_EMAIL" \
    --arg ims_org "$CM_IMS_ORG_ID" \
    --arg scopes "$CM_SCOPES" \
    --arg env "$ims_env" \
    '{
      client_id: $client_id,
      client_secrets: [$client_secret],
      technical_account_id: $tech_id,
      technical_account_email: $tech_email,
      ims_org_id: $ims_org,
      scopes: ($scopes | split(",") | map(gsub("^\\s+|\\s+$";""))),
      env: $env,
      oauth_enabled: true
    }' > "$cfg"
  "$AIO" config:set ims.contexts.aio-cli-plugin-cloudmanager "$cfg" --file --json
  rm -f "$cfg"

  # Point at a non-prod endpoint only when configured; otherwise use the default.
  if [ -n "${CM_BASE_URL:-}" ]; then
    echo ">> Cloud Manager base URL: $CM_BASE_URL"
    "$AIO" config:set cloudmanager.base_url "$CM_BASE_URL"
  else
    echo ">> using default (production) Cloud Manager API endpoint"
  fi

  echo ">> pointing pipeline $CM_PIPELINE_ID at branch '$branch'..."
  "$AIO" cloudmanager:pipeline:update "$CM_PIPELINE_ID" --programId "$CM_PROGRAM_ID" --branch "$branch"

  echo ">> starting pipeline execution..."
  "$AIO" cloudmanager:pipeline:create-execution "$CM_PIPELINE_ID" --programId "$CM_PROGRAM_ID"

  echo ">> waiting for the execution to complete..."
  local i status
  for i in $(seq 1 240); do
    status="$("$AIO" cloudmanager:pipeline:list-executions "$CM_PIPELINE_ID" \
      --programId "$CM_PROGRAM_ID" --limit 1 --json 2>/dev/null \
      | jq -r '.[0].status // .[0].statusName // "UNKNOWN"')"
    echo "   status: $status"
    case "$status" in
      FINISHED)
        echo ">> Cloud Manager pipeline finished successfully."
        return 0 ;;
      ERROR|FAILED|CANCELLED|CANCELLING)
        echo "error: pipeline execution ended in status: $status" >&2
        return 1 ;;
    esac
    sleep 30
  done
  echo "error: timed out waiting for the Cloud Manager pipeline execution." >&2
  return 1
}

# Parse args: <repo-path> [branch] [action] plus optional flags (any order).
CM_VALIDATE=0
DRY_RUN="${DRY_RUN:-0}"   # may be preset via the environment (DRY_RUN=1)
POSITIONAL=()
for a in "$@"; do
  case "$a" in
    -h|--help)             usage; exit 0 ;;
    --cloud-manager|--cm)  CM_VALIDATE=1 ;;
    --dry-run)             DRY_RUN=1 ;;
    -*)                    echo "error: unknown option '$a'" >&2; echo >&2; usage >&2; exit 1 ;;
    *)                     POSITIONAL+=("$a") ;;
  esac
done

# The target repo must be given explicitly as a path. No default, no guessing.
if [ "${#POSITIONAL[@]}" -eq 0 ]; then
  echo "error: no repo path given." >&2
  echo >&2
  usage >&2
  exit 1
fi
REPO_DIR="${POSITIONAL[0]}"
[ -d "$REPO_DIR/.git" ] || { echo "error: '$REPO_DIR' is not a git checkout" >&2; exit 1; }
REPO_DIR="$(cd "$REPO_DIR" && pwd)"    # normalize to an absolute path

# Optional positionals (either order): a branch name and/or an action (push|merge).
BRANCH_ARG=""; ACTION=""
for a in "${POSITIONAL[@]:1}"; do
  [ -z "$a" ] && continue
  case "$a" in
    push|merge) ACTION="$a" ;;
    *)          BRANCH_ARG="$a" ;;
  esac
done

# Cloud Manager validation builds from the CM remote, so it requires a push.
if [ "$CM_VALIDATE" = 1 ]; then
  if [ "$ACTION" = "merge" ]; then
    echo "error: --cloud-manager cannot be combined with 'merge' (the pipeline builds" >&2
    echo "       from the CM remote — use 'push' or omit the action)." >&2
    exit 1
  fi
  ACTION="push"
fi

cd "$REPO_DIR"
echo ">> repo: $REPO_DIR"

# Refuse to run with a dirty working tree (untracked files like .DS_Store are ok).
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree has uncommitted changes — commit/stash them first." >&2
  exit 1
fi

# Determine the base branch (for showing what will be pushed).
BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [ -z "$BASE" ]; then
  for b in main master; do git show-ref --verify --quiet "refs/heads/$b" && BASE="$b" && break; done
fi

# Pick the branch: from the argument if given, otherwise interactively.
if [ -n "$BRANCH_ARG" ]; then
  if git show-ref --verify --quiet "refs/heads/$BRANCH_ARG"; then
    BRANCH="$BRANCH_ARG"
  elif git show-ref --verify --quiet "refs/heads/renovate/$BRANCH_ARG"; then
    BRANCH="renovate/$BRANCH_ARG"
  else
    echo "error: no local branch '$BRANCH_ARG' (or 'renovate/$BRANCH_ARG')" >&2
    exit 1
  fi
else
  mapfile -t BRANCHES < <(git branch --list 'renovate/*' --format '%(refname:short)' | sort)
  if [ "${#BRANCHES[@]}" -eq 0 ]; then
    echo "No renovate/* branches in this repo. Run ./renovate-local.sh first."
    exit 0
  fi
  echo
  echo "Renovate branches in $(basename "$REPO_DIR"):"
  i=1
  for b in "${BRANCHES[@]}"; do printf "  %2d) %s\n" "$i" "$b"; i=$((i+1)); done
  echo
  CHOICE=""
  while :; do
    read -rp "Choose a branch [1-${#BRANCHES[@]}, q to quit]: " CHOICE
    [ "$CHOICE" = "q" ] && { echo "aborted."; exit 0; }
    [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#BRANCHES[@]}" ] && break
    echo "  invalid selection."
  done
  BRANCH="${BRANCHES[$((CHOICE-1))]}"
fi
echo ">> selected: $BRANCH"

# Checkout the branch.
git checkout "$BRANCH"

# Build it locally. Maven output is redirected to a per-branch log file under
# renovate-reports/<repo>/verify-logs/ (instead of the console); on failure its
# path is printed. This matches the layout run-all.sh writes.
if [ "${SKIP_VERIFY:-}" = "1" ]; then
  echo ">> SKIP_VERIFY=1 — skipping 'mvn clean verify'"
else
  MVN="mvn"; [ -x "./mvnw" ] && MVN="./mvnw"
  LOG_DIR="$SCRIPT_DIR/renovate-reports/$(basename "$REPO_DIR")/verify-logs"
  mkdir -p "$LOG_DIR"
  # Sanitize the branch name for use in a filename (renovate/foo -> renovate-foo).
  LOG_FILE="$LOG_DIR/$(printf '%s' "$BRANCH" | sed 's#[^A-Za-z0-9._-]#-#g').log"
  echo ">> running: $MVN clean verify  (output → $LOG_FILE; this can take a while)"
  if ! "$MVN" clean verify > "$LOG_FILE" 2>&1; then
    echo >&2
    echo "error: 'mvn clean verify' FAILED for $BRANCH — aborting (nothing pushed or merged)." >&2
    echo "       log: $LOG_FILE" >&2
    exit 1
  fi
  echo ">> build OK.  (log: $LOG_FILE)"
fi

# Dry-run: validation only — quit without pushing, merging, or any CM run.
if [ "$DRY_RUN" = 1 ]; then
  echo
  echo ">> DRY_RUN — validation complete for '$BRANCH'. No changes made"
  echo "   (nothing pushed, merged, or sent to Cloud Manager). Branch is checked out locally."
  exit 0
fi

# Decide the action: from the argument if given, otherwise ask.
if [ -z "$ACTION" ]; then
  echo
  echo "Validation complete for '$BRANCH'. Choose what to do:"
  echo "  1) push   — git push to origin (the CM remote)"
  echo "  2) merge  — merge into local '${BASE:-main}' branch"
  while :; do
    read -rp "Action [1=push, 2=merge, q to quit]: " A
    case "$A" in
      1) ACTION=push;  break ;;
      2) ACTION=merge; break ;;
      q) echo ">> nothing done. Branch '$BRANCH' is checked out locally."; exit 0 ;;
      *) echo "  invalid selection." ;;
    esac
  done
fi

case "$ACTION" in
  push)
    REMOTE_URL="$(git remote get-url origin 2>/dev/null || echo '(no origin)')"
    echo ">> pushing '$BRANCH' to origin: $REMOTE_URL"
    echo ">> commits:"
    if [ -n "$BASE" ] && git show-ref --verify --quiet "refs/remotes/origin/$BASE"; then
      git --no-pager log --oneline "origin/$BASE..$BRANCH" | sed 's/^/     /'
    else
      git --no-pager log --oneline -n 10 "$BRANCH" | sed 's/^/     /'
    fi
    git push -u origin "$BRANCH"
    echo ">> pushed. The Cloud Manager pipeline will pick it up per your branch config."
    if [ "$CM_VALIDATE" = 1 ]; then
      run_cloud_manager_validation "$BRANCH"
    fi
    ;;
  merge)
    [ -n "$BASE" ] || { echo "error: could not determine a base branch to merge into." >&2; exit 1; }
    echo ">> merging '$BRANCH' into local '$BASE' (not pushed)..."
    git checkout "$BASE"
    git merge --no-edit "$BRANCH"
    echo ">> merged into '$BASE'. Nothing was pushed to origin."
    ;;
esac
