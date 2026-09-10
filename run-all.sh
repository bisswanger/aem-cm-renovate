#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  aem-cm-renovate  ·  ALL  (end-to-end driver)
#  Generate every Renovate branch, validate each one, and optionally push the
#  ones that pass. DRY-RUN by default.
# ══════════════════════════════════════════════════════════════════════════════
#
# Steps:
#   1. run Renovate locally to generate all renovate/* branches (+ per-branch reports)
#   2. loop over each branch and validate it by delegating to validate-push.sh
#   3. push the branches that validated OK  (only when --push is given)
#   4. write a promotion summary report
#
# Branch validation is NOT reimplemented here: each branch is handed to
# validate-push.sh, the single source of truth for what "validate a branch"
# means (mvn clean verify, plus the optional Adobe Cloud Manager pipeline run
# with --cloud-manager). This keeps run-all and validate-push in lock-step.
#
# DRY-RUN by default: it validates and reports what WOULD be pushed, but pushes
# nothing. Pass --push to actually push the validated branches to origin (CM).
#
# Run with -h/--help for full usage (see the usage() function below).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG="$(basename "$0")"

usage() {
  cat <<EOF
$PROG — generate, validate, and (optionally) push all Renovate branches.

Runs the full loop for a Cloud Manager checkout: generate every renovate/* branch,
validate each one (via validate-push.sh), and — only with --push — push the
branches that pass to origin. A Markdown promotion summary is written at the end.

Each branch is validated by delegating to validate-push.sh, so run-all performs
exactly the same checks as promoting a single branch by hand: 'mvn clean verify',
plus — with --cloud-manager — a real Adobe Cloud Manager pipeline run.

USAGE
  $PROG <repo-path> [--push] [--cloud-manager] [--skip-generate]
  $PROG -h | --help

ARGUMENTS
  repo-path        Full path to the target CM checkout. Required; no default.

OPTIONS
  --push           Push branches that validate OK to origin (the CM remote).
                   Without this flag the script is DRY-RUN: it validates and
                   reports, but pushes nothing.
  --cloud-manager, --cm
                   For each passing branch, additionally run an Adobe Cloud
                   Manager pipeline validation (same as validate-push.sh
                   --cloud-manager). Builds from the CM remote, so it implies
                   --push. Requires the CM_* environment variables below.
  --skip-generate  Skip step 1 (do not re-run Renovate); validate the renovate/*
                   branches already present in the checkout.
  -h, --help       Show this help and exit.

ENVIRONMENT
  SKIP_VERIFY=1     Skip 'mvn clean verify' (treats every branch as validated).
                    Passed through to validate-push.sh. Useful for a fast dry-run
                    of the loop itself.
  LIMIT=N           Cap the generate step at ~N update branches (default: 0 = unlimited).
  GITHUB_COM_TOKEN  Passed through to the generate step for richer release notes.
  KEEP_GITEA=1      Passed through to the generate step (keep the Gitea container).

  CM_*              Cloud Manager credentials/config consumed by validate-push.sh
                    when --cloud-manager is given (CM_PROGRAM_ID, CM_PIPELINE_ID,
                    CM_CLIENT_ID, CM_CLIENT_SECRET, CM_TECHNICAL_ACCOUNT_ID,
                    CM_TECHNICAL_ACCOUNT_EMAIL, CM_IMS_ORG_ID, CM_SCOPES, and the
                    optional CM_IMS_ENV / CM_BASE_URL). See 'validate-push.sh --help'.

OUTPUT
  renovate-reports/<repo>/promotion-summary.md   the per-branch result table
  renovate-reports/<repo>/verify-logs/<branch>.log   validate-push output per branch
    (validate-push.sh also writes the raw 'mvn' output under
     .renovate-tmp/validation/<branch>.log)

NOTES
  - Validation runs once PER branch, so a full run can take a long time.
  - --push pushes to the real CM remote for every branch that passes; the flag is
    your explicit opt-in (there is no per-branch prompt). Dry-run is the default.

EXAMPLES
  $PROG /full/path/to/aem-cm-project                 # dry-run: validate + report
  $PROG /full/path/to/aem-cm-project --push          # validate + push passing ones
  $PROG /full/path/to/aem-cm-project --push --cloud-manager  # + CM pipeline run
  $PROG /full/path/to/aem-cm-project --skip-generate # reuse existing branches
EOF
}

# --- parse args ---------------------------------------------------------------
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

REPO_ARG=""; PUSH=0; SKIP_GENERATE=0; CM_VALIDATE=0
for a in "$@"; do
  case "$a" in
    --push)              PUSH=1 ;;
    --cloud-manager|--cm) CM_VALIDATE=1 ;;
    --skip-generate)     SKIP_GENERATE=1 ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  echo "error: unknown option '$a'" >&2; echo >&2; usage >&2; exit 1 ;;
    *)                   [ -z "$REPO_ARG" ] && REPO_ARG="$a" || { echo "error: unexpected argument '$a'" >&2; exit 1; } ;;
  esac
done

# Cloud Manager validation builds from the CM remote, so it requires a push.
[ "$CM_VALIDATE" = 1 ] && PUSH=1

if [ -z "$REPO_ARG" ]; then
  echo "error: no repo path given." >&2
  echo >&2
  usage >&2
  exit 1
fi
[ -d "$REPO_ARG/.git" ] || { echo "error: '$REPO_ARG' is not a git checkout" >&2; exit 1; }
REPO_DIR="$(cd "$REPO_ARG" && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"
REPORTS_DIR="$SCRIPT_DIR/renovate-reports/$REPO_NAME"

MODE="DRY-RUN (no push)"
[ "$PUSH" = 1 ] && MODE="PUSH (validated branches → origin)"
[ "$CM_VALIDATE" = 1 ] && MODE="PUSH + Cloud Manager validation (validated branches → origin)"
echo ">> repo: $REPO_DIR"
echo ">> mode: $MODE"

# --- step 1: generate branches ------------------------------------------------
if [ "$SKIP_GENERATE" = 1 ]; then
  echo ">> [1/4] skipping generation (--skip-generate)"
else
  echo ">> [1/4] generating renovate/* branches..."
  "$SCRIPT_DIR/renovate-local.sh" "$REPO_DIR"
fi

cd "$REPO_DIR"

# Refuse to run with a dirty working tree (untracked files are fine).
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: working tree has uncommitted changes — commit/stash them first." >&2
  exit 1
fi

# Determine the base branch to return to / merge target.
BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [ -z "$BASE" ]; then
  for b in main master; do git show-ref --verify --quiet "refs/heads/$b" && BASE="$b" && break; done
fi
[ -n "$BASE" ] && git checkout -q "$BASE"

mapfile -t BRANCHES < <(git branch --list 'renovate/*' --format '%(refname:short)' | sort)
if [ "${#BRANCHES[@]}" -eq 0 ]; then
  echo ">> no renovate/* branches found — nothing to validate."
  exit 0
fi

# --- step 2 & 3: validate each branch (via validate-push.sh), push passing ones -
# Branch validation is delegated to validate-push.sh so run-all and the
# single-branch promote path run the EXACT same checks:
#   - dry-run   → validate-push.sh <repo> <branch> --dry-run   (verify only)
#   - --push    → validate-push.sh <repo> <branch> push        (verify + push)
#   - --cloud-manager adds the CM pipeline run (implies push).
# SKIP_VERIFY and the CM_* vars are read from the environment by validate-push.sh.
VALIDATE_PUSH="$SCRIPT_DIR/validate-push.sh"
[ -x "$VALIDATE_PUSH" ] || { echo "error: validate-push.sh not found/executable at $VALIDATE_PUSH" >&2; exit 1; }

LOGDIR="$REPORTS_DIR/verify-logs"; mkdir -p "$LOGDIR"
sanitize(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#-#g'; }

declare -a ROWS
pass=0; fail=0; pushed=0
echo ">> [2/4] validating ${#BRANCHES[@]} branch(es) via validate-push.sh..."
i=0
for b in "${BRANCHES[@]}"; do
  i=$((i+1))
  printf ">> (%d/%d) %s ... " "$i" "${#BRANCHES[@]}" "$b"
  log="$LOGDIR/$(sanitize "$b").log"

  # Build the validate-push.sh invocation for this branch/mode.
  vp_args=("$REPO_DIR" "$b")
  if [ "$PUSH" = 1 ]; then
    vp_args+=("push")
    [ "$CM_VALIDATE" = 1 ] && vp_args+=("--cloud-manager")
  else
    vp_args+=("--dry-run")
  fi

  if "$VALIDATE_PUSH" "${vp_args[@]}" > "$log" 2>&1; then
    ok=1
  else
    ok=0
  fi

  if [ "$ok" = 1 ]; then
    pass=$((pass+1))
    if [ "$PUSH" = 1 ]; then
      pushed=$((pushed+1))
      validation="✅ pass"
      action="pushed"; [ "$CM_VALIDATE" = 1 ] && action="pushed + CM validated"
    else
      validation="✅ pass"
      action="would push (dry-run)"
    fi
  else
    fail=$((fail+1))
    validation="❌ fail"
    action="not pushed (validation failed)"
  fi
  echo "$validation"
  ROWS+=("| \`$b\` | $validation | $action | [log](verify-logs/$(sanitize "$b").log) |")
done

[ -n "$BASE" ] && git checkout -q "$BASE"

# --- step 4: promotion summary report -----------------------------------------
SUMMARY="$REPORTS_DIR/promotion-summary.md"
{
  echo "# Renovate promotion summary — $REPO_NAME"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Mode: **$MODE**"
  echo
  echo "**${#BRANCHES[@]}** branches · **$pass** validated · **$fail** failed · **$pushed** pushed"
  echo
  echo "| Branch | Validation | Action | Log |"
  echo "|---|---|---|---|"
  printf '%s\n' "${ROWS[@]}"
  echo
} > "$SUMMARY"

echo
echo ">> [3/4] validated: $pass ok, $fail failed"
echo ">> [4/4] summary written: $SUMMARY"
if [ "$PUSH" = 1 ]; then
  echo ">> pushed $pushed validated branch(es) to origin."
else
  echo ">> dry-run: nothing pushed. Re-run with --push to push the $pass validated branch(es)."
fi
