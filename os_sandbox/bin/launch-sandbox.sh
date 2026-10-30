#!/usr/bin/env bash
# Launch every sandboxed splitscreen instance, staggered.
# Settings come from sandbox.conf (written by setup-os-sandbox.sh).
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
# shellcheck source=sandbox-lib.sh
source "$here/sandbox-lib.sh"
# shellcheck source=/dev/null
source "$SANDBOX_DIR/sandbox.conf"
DELAY="${DELAY_OVERRIDE:-$DELAY}"

if [[ ! -f "$CONTROLLERS_CONF" ]]; then
  if [[ -t 0 ]]; then
    "$here/assign-controllers.sh" "$PLAYERS"
  else
    echo "No controllers.conf yet: player N gets the Nth controller. Run assign-controllers.sh to choose." >&2
  fi
fi

last=$(( ${#INSTANCES[@]} - 1 ))
for i in "${!INSTANCES[@]}"; do
  args=(-l "${INSTANCES[$i]}")
  if [[ -n "${ACCOUNTS[$i]:-}" ]]; then args+=(-a "${ACCOUNTS[$i]}"); fi
  echo "Launching ${INSTANCES[$i]} ${ACCOUNTS[$i]:+as ${ACCOUNTS[$i]}}"
  "${PRISM[@]}" "${args[@]}" >/dev/null 2>&1 &
  # Stagger launches so RAM/disk don't spike all at once
  if [[ $i -lt $last ]]; then sleep "$DELAY"; fi
done
wait
