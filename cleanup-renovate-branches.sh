#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  aem-cm-renovate  ·  CLEANUP
#  Delete all local renovate/* branches from a checkout.
# ══════════════════════════════════════════════════════════════════════════════
#
# These branches are local-only (never pushed to the real origin), so this just
# removes what the harness created. Run with -h/--help for full usage.

set -euo pipefail

PROG="$(basename "$0")"

usage() {
  cat <<EOF
$PROG — delete local renovate/* branches from a checkout.

The renovate/* branches are local-only (never pushed to origin); this removes
what the harness created. It only ever touches refs under renovate/*.

USAGE
  $PROG <repo-path> [--dry-run]
  $PROG -h | --help

ARGUMENTS
  repo-path    Full path to the target CM checkout. Required; no default.

OPTIONS
  --dry-run    List the branches that would be deleted, but delete nothing.
  -h, --help   Show this help and exit.

BEHAVIOR
  - If you are currently on a renovate/* branch, it checks out the base branch
    (main/master) first so the branch can be removed.
  - Deletes with 'git branch -D' (these branches are never merged into main).

EXAMPLES
  $PROG /full/path/to/aem-cm-project
  $PROG /full/path/to/aem-cm-project --dry-run
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# The target repo must be given explicitly as a path. No default, no guessing.
if [ -z "${1:-}" ] || [ "$1" = "--dry-run" ]; then
  echo "error: no repo path given." >&2
  echo >&2
  usage >&2
  exit 1
fi
REPO_DIR="$1"
DRY=""
[ "${2:-}" = "--dry-run" ] && DRY=1
[ -d "$REPO_DIR/.git" ] || { echo "error: '$REPO_DIR' is not a git checkout" >&2; exit 1; }
REPO_DIR="$(cd "$REPO_DIR" && pwd)"    # normalize to an absolute path

cd "$REPO_DIR"

mapfile -t BRANCHES < <(git branch --list 'renovate/*' --format '%(refname:short)')
if [ "${#BRANCHES[@]}" -eq 0 ]; then
  echo "No renovate/* branches in $(basename "$REPO_DIR") — nothing to clean."
  exit 0
fi

# If currently on a renovate/* branch, move off it first so it can be deleted.
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT" == renovate/* ]]; then
  FALLBACK="main"; git show-ref --verify --quiet refs/heads/main || FALLBACK="$(git symbolic-ref --short HEAD 2>/dev/null || echo master)"
  echo ">> currently on '$CURRENT'; checking out '$FALLBACK' first"
  [ -z "$DRY" ] && git checkout -q "$FALLBACK"
fi

echo ">> ${#BRANCHES[@]} renovate/* branch(es) in $(basename "$REPO_DIR"):"
for b in "${BRANCHES[@]}"; do echo "   $b"; done

if [ -n "$DRY" ]; then
  echo ">> --dry-run: nothing deleted."
  exit 0
fi

# -D (force) because these branches were never merged into main.
git branch -D "${BRANCHES[@]}" >/dev/null
echo ">> deleted ${#BRANCHES[@]} branch(es)."
