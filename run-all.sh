#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  aem-cm-renovate  ·  ALL  (end-to-end driver)
#  Generate every Renovate branch, validate each with `mvn clean verify`, and
#  optionally push the ones that pass. DRY-RUN by default.
# ══════════════════════════════════════════════════════════════════════════════
#
# Steps:
#   1. run Renovate locally to generate all renovate/* branches (+ per-branch reports)
#   2. loop over each branch and validate it with `mvn clean verify`
#   3. push the branches that validated OK  (only when --push is given)
#   4. write a promotion summary report
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
build each one with 'mvn clean verify', and — only with --push — push the branches
that pass to origin. A Markdown promotion summary is written at the end.

USAGE
  $PROG <repo-path> [--push] [--skip-generate]
  $PROG -h | --help

ARGUMENTS
  repo-path        Full path to the target CM checkout. Required; no default.

OPTIONS
  --push           Push branches that pass 'mvn clean verify' to origin (the CM
                   remote). Without this flag the script is DRY-RUN: it validates
                   and reports, but pushes nothing.
  --skip-generate  Skip step 1 (do not re-run Renovate); validate the renovate/*
                   branches already present in the checkout.
  -h, --help       Show this help and exit.

ENVIRONMENT
  SKIP_VERIFY=1     Skip 'mvn clean verify' (treats every branch as validated).
                    Useful for a fast dry-run of the loop itself.
  LIMIT=N           Cap the generate step at ~N update branches (default: 0 = unlimited).
  GITHUB_COM_TOKEN  Passed through to the generate step for richer release notes.
  KEEP_GITEA=1      Passed through to the generate step (keep the Gitea container).

OUTPUT
  renovate-reports/<repo>/promotion-summary.md   the per-branch result table
  renovate-reports/<repo>/verify-logs/<branch>.log   full 'mvn' output per branch

NOTES
  - 'mvn clean verify' runs once PER branch, so a full run can take a long time.
  - --push pushes to the real CM remote for every branch that passes; the flag is
    your explicit opt-in (there is no per-branch prompt). Dry-run is the default.

EXAMPLES
  $PROG /full/path/to/aem-cm-project                 # dry-run: validate + report
  $PROG /full/path/to/aem-cm-project --push          # validate + push passing ones
  $PROG /full/path/to/aem-cm-project --skip-generate # reuse existing branches
EOF
}

# --- parse args ---------------------------------------------------------------
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

REPO_ARG=""; PUSH=0; SKIP_GENERATE=0
for a in "$@"; do
  case "$a" in
    --push)          PUSH=1 ;;
    --skip-generate) SKIP_GENERATE=1 ;;
    -h|--help)       usage; exit 0 ;;
    -*)              echo "error: unknown option '$a'" >&2; echo >&2; usage >&2; exit 1 ;;
    *)               [ -z "$REPO_ARG" ] && REPO_ARG="$a" || { echo "error: unexpected argument '$a'" >&2; exit 1; } ;;
  esac
done

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

MODE="DRY-RUN (no push)"; [ "$PUSH" = 1 ] && MODE="PUSH (validated branches → origin)"
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

# --- step 2 & 3: validate each branch, push the ones that pass -----------------
LOGDIR="$REPORTS_DIR/verify-logs"; mkdir -p "$LOGDIR"
MVN="mvn"; [ -x "./mvnw" ] && MVN="./mvnw"
sanitize(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#-#g'; }

declare -a ROWS
pass=0; fail=0; pushed=0
echo ">> [2/4] validating ${#BRANCHES[@]} branch(es) with '$MVN clean verify'..."
i=0
for b in "${BRANCHES[@]}"; do
  i=$((i+1))
  printf ">> (%d/%d) %s ... " "$i" "${#BRANCHES[@]}" "$b"
  git checkout -q "$b"
  log="$LOGDIR/$(sanitize "$b").log"

  if [ "${SKIP_VERIFY:-}" = "1" ]; then
    echo "skipped-verify" ; echo "SKIP_VERIFY=1" > "$log"; ok=1; validation="⏭ skipped"
  elif "$MVN" clean verify > "$log" 2>&1; then
    echo "PASS"; ok=1; validation="✅ pass"
  else
    echo "FAIL (see $log)"; ok=0; validation="❌ fail"
  fi

  if [ "$ok" = 1 ]; then
    pass=$((pass+1))
    if [ "$PUSH" = 1 ]; then
      if git push -u origin "$b" >>"$log" 2>&1; then action="pushed"; pushed=$((pushed+1))
      else action="push FAILED (see log)"; fi
    else
      action="would push (dry-run)"
    fi
  else
    fail=$((fail+1))
    action="not pushed (build failed)"
  fi
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
