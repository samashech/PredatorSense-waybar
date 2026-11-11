#!/bin/bash
# install.sh: copy the Omarchy shell plugins from this repo into place and put them on the bar.
#
#   ./install.sh                 install every component
#   ./install.sh fans pet        install only the ones you name
#   ./install.sh --list          show the component names
#
# Components: fans keyboard nowbar tasks cleaner pet
# (Mechanical key sounds are part of "keyboard".)
#
# This script never uses sudo. Drivers, groups and udev rules are covered in agent.md.
# An existing copy of a plugin is moved to ~/.local/state/predator-suite/backup-<time>/ first.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins
BACKUP=${XDG_STATE_HOME:-$HOME/.local/state}/predator-suite/backup-$(date +%Y%m%d-%H%M%S)

# name  plugin-id  placement (arguments for `omarchy bar put`)
COMPONENTS=(
  "fans     samashech.fans        --section centerEnd --index 0"
  "keyboard samashech.audio-sync  --section centerEnd --index 0"
  "nowbar   samashech.nowbar      --section centerBegin"
  "pet      samashech.pet         --section left --after omarchy.workspaces"
  "cleaner  samashech.cleaner     --section right"
  "tasks    samashech.tasks       --section right"
)

die() { echo "install.sh: $*" >&2; exit 1; }

if [[ ${1:-} == --list ]]; then
  for c in "${COMPONENTS[@]}"; do read -r name id _ <<<"$c"; echo "$name ($id)"; done
  exit 0
fi

command -v omarchy-shell >/dev/null || die "omarchy-shell not found. These plugins need the Omarchy shell; see agent.md for Waybar (fans only)."

wanted=("$@")
pick() {
  [[ ${#wanted[@]} -eq 0 ]] && return 0
  local w; for w in "${wanted[@]}"; do [[ $w == "$1" ]] && return 0; done
  return 1
}
for w in "${wanted[@]}"; do
  found=0; for c in "${COMPONENTS[@]}"; do read -r name _ <<<"$c"; [[ $name == "$w" ]] && found=1; done
  (( found )) || die "unknown component '$w' (try --list)"
done

mkdir -p "$DEST"
installed=()
for c in "${COMPONENTS[@]}"; do
  read -r name id placement <<<"$c"
  pick "$name" || continue
  src="$REPO/plugins/$id"
  [[ -f $src/manifest.json ]] || die "missing $src"
  if [[ -e $DEST/$id ]]; then
    if diff -rq --exclude=__pycache__ "$src" "$DEST/$id" >/dev/null 2>&1; then
      echo "= $id is already up to date"
    else
      mkdir -p "$BACKUP"
      mv "$DEST/$id" "$BACKUP/$id"
      echo "~ $id: old copy moved to $BACKUP/$id"
    fi
  fi
  if [[ ! -e $DEST/$id ]]; then
    cp -r "$src" "$DEST/$id"
    find "$DEST/$id" -name __pycache__ -prune -exec rm -rf {} +
    omarchy plugin validate "$DEST/$id" >/dev/null || die "$id failed validation"
    echo "+ $id installed"
  fi
  installed+=("$id|$placement")
done

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 1

for entry in "${installed[@]}"; do
  id=${entry%%|*}; placement=${entry#*|}
  if omarchy bar get "$id" id >/dev/null 2>&1; then
    echo "= $id is already on the bar"
  else
    # shellcheck disable=SC2086
    omarchy bar put "$id" $placement >/dev/null 2>&1 || omarchy bar put "$id" >/dev/null
    echo "+ $id added to the bar"
  fi
done

cat <<'EOF'

Done. If a widget doesn't show up, run: omarchy restart shell

Still to do by hand (agent.md explains each one):
  fans      a fan-control driver and write access to it (agent.md steps 2-4)
  keyboard  the facer driver for /dev/acer-gkbbl-*; your user in the "input" group
            for the typing ripple and key sounds
  nowbar    Spotify queue: create a Spotify app, then `nowq setup <client-id>` and `nowq login`
  cleaner   pacman-contrib (for paccache) for the "old package versions" item
EOF
