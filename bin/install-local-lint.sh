#!/usr/bin/env bash
# Installs (or removes) the local lint pre-push hook in one or more repos.
#
# Usage:
#   install-local-lint.sh [--uninstall] <repo> [<repo> ...]
#   install-local-lint.sh [--uninstall] --all <parent-dir>   every git repo directly under parent-dir
#
# Example:
#   install-local-lint.sh ~/git/modernisation-platform-ai-application-builder
#   install-local-lint.sh --all ~/git
set -euo pipefail

SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-local-lint.sh"
[ -x "$SETUP" ] || { echo "error: $SETUP not found or not executable." >&2; exit 1; }

action="--install"
if [ "${1:-}" = "--uninstall" ]; then action="--uninstall"; shift; fi

repos=()
if [ "${1:-}" = "--all" ]; then
  parent="${2:-}"
  [ -d "$parent" ] || { echo "error: --all needs a directory." >&2; exit 1; }
  for d in "$parent"/*/; do
    [ -e "${d}.git" ] && repos+=("${d%/}")
  done
else
  repos=("$@")
fi

[ "${#repos[@]}" -gt 0 ] || { echo "error: no repositories given. See --help in the header." >&2; exit 1; }

ok=0; failed=()
for repo in "${repos[@]}"; do
  echo "== $repo"
  if [ -e "$repo/.git" ] && (cd "$repo" && "$SETUP" "$action"); then
    ok=$((ok + 1))
  else
    failed+=("$repo")
  fi
done

echo
echo "Done: $ok succeeded, ${#failed[@]} failed."
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'Failed: %s\n' "${failed[@]}"
  exit 1
fi
