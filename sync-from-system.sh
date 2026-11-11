#!/bin/bash
# sync-from-system.sh: copy the plugins you are running back into this repo.
#
# Omarchy loads plugins from ~/.config/omarchy/plugins/, and it does not allow
# symlinks there, so that folder can't simply be this repo. Edit and test the
# live copies, then run this before you commit:
#
#   ./sync-from-system.sh          copy every plugin this repo tracks
#   ./sync-from-system.sh --dry    only show what would change
#
# Only plugins that already exist under plugins/ are synced, so nothing else
# from your plugins folder can end up in the repo by accident.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIVE=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins
DRY=()
[[ ${1:-} == --dry ]] && DRY=(--dry-run)

command -v rsync >/dev/null || { echo "sync-from-system.sh: needs rsync" >&2; exit 1; }

for dir in "$REPO"/plugins/*/; do
  id=$(basename "$dir")
  if [[ ! -d $LIVE/$id ]]; then
    echo "skip $id (not installed)"
    continue
  fi
  echo "== $id"
  rsync -a --delete --itemize-changes "${DRY[@]}" \
    --exclude __pycache__ --exclude '*.bak*' --exclude '*.tmp' --exclude '*.orig' \
    "$LIVE/$id/" "$dir" | sed 's/^/   /'
done

echo
git -C "$REPO" status --short
