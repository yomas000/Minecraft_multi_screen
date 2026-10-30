#!/usr/bin/env bash
# Prism "Wrapper command" for one splitscreen player:
#   mc-sandbox-wrap.sh <player> <java> <java args...>
#
# Runs Minecraft in a bubblewrap sandbox whose /dev holds only GPU/audio nodes
# and this player's controller, so the game can't see anyone else's pad.
# Everything else (files, network, display, audio sockets) is shared as normal,
# so LAN play over localhost still works.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=sandbox-lib.sh
source "$here/sandbox-lib.sh"

player="$1"
shift

args=(--die-with-parent --dev-bind / / --dev /dev --dir /dev/input)
# GPU (Mesa + NVIDIA), audio, shared memory; never other input devices
for n in /dev/dri /dev/snd /dev/nvidia* /dev/dxg; do
  if [[ -e "$n" ]]; then args+=(--dev-bind "$n" "$n"); fi
done
if [[ -d /dev/shm ]]; then args+=(--bind /dev/shm /dev/shm); fi

ev=""
if [[ -f "$CONTROLLERS_CONF" ]]; then
  id=$(controller_for "$player" || true)
  if [[ -n "$id" ]]; then
    ev=$(find_pad "$id" || true)
    if [[ -z "$ev" ]]; then
      echo "[sandbox] P$player: assigned controller ($id) not connected, starting without one" >&2
    fi
  fi
else
  # No assignments yet: player N gets the Nth controller
  ev=$(list_pads | sed -n "${player}p")
fi

if [[ -n "$ev" ]]; then
  mapfile -t nodes < <(pad_nodes "$ev")
  for n in "${nodes[@]}"; do args+=(--dev-bind "$n" "$n"); done
  echo "[sandbox] P$player: $(pad_name "$ev") -> ${nodes[*]}" >&2
else
  echo "[sandbox] P$player: no controller" >&2
fi

exec bwrap "${args[@]}" -- "$@"
