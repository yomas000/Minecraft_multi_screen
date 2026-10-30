# shellcheck shell=bash
# Shared helpers for the bubblewrap controller sandbox. Sourced, not run.

SANDBOX_DIR="${SANDBOX_DIR:-$HOME/MinecraftSplitscreen/sandbox}"
CONTROLLERS_CONF="$SANDBOX_DIR/controllers.conf"

# True if /dev/input/<ev> is a gamepad/joystick
is_pad() {
  local ev="$1"
  if command -v udevadm >/dev/null; then
    udevadm info -q property -n "/dev/input/$ev" 2>/dev/null | grep -qx 'ID_INPUT_JOYSTICK=1'
  else
    compgen -G "/sys/class/input/$ev/device/js*" >/dev/null
  fi
}

# Event node names (event5, ...) of physical controllers, in kernel order
list_pads() {
  local sys ev
  for sys in /sys/class/input/event*; do
    [[ -e "$sys" ]] || continue
    ev=${sys##*/}
    # Steam Input and other uinput pads live under /sys/devices/virtual
    if [[ "$(readlink -f "$sys")" == */virtual/* ]]; then continue; fi
    if is_pad "$ev"; then echo "$ev"; fi
  done | sort -V
}

pad_name() { cat "/sys/class/input/$1/device/name" 2>/dev/null || echo "$1"; }

# Stable id that survives reboots and replugging:
# uniq is the Bluetooth MAC / USB serial, phys is the USB port path
pad_id() {
  local d="/sys/class/input/$1/device" uniq phys
  uniq=$(cat "$d/uniq" 2>/dev/null || true)
  phys=$(cat "$d/phys" 2>/dev/null || true)
  printf '%s|%s\n' "$uniq" "$phys"
}

# Event node for a stored pad id, if that controller is connected
find_pad() {
  local ev
  for ev in $(list_pads); do
    if [[ "$(pad_id "$ev")" == "$1" ]]; then echo "$ev"; return 0; fi
  done
  return 1
}

# Every /dev node of the controller that owns <ev>: sibling event nodes
# (motion sensors, touchpad), js nodes, and hidraw nodes (SDL's HIDAPI
# drivers read PlayStation/Switch/Xbox pads through hidraw, not evdev)
pad_nodes() {
  local parent sys n
  parent=$(readlink -f "/sys/class/input/$1/device/..")
  for sys in /sys/class/input/event* /sys/class/input/js*; do
    [[ -e "$sys" ]] || continue
    if [[ "$(readlink -f "$sys/device/..")" == "$parent" ]]; then echo "/dev/input/${sys##*/}"; fi
  done
  for n in "$parent"/hidraw/hidraw*; do
    if [[ -e "$n" ]]; then echo "/dev/${n##*/}"; fi
  done
  return 0
}

# Pad id assigned to a player in controllers.conf ("<player>=<id>" lines)
controller_for() {
  [[ -f "$CONTROLLERS_CONF" ]] || return 1
  sed -n "s/^$1=//p" "$CONTROLLERS_CONF" | head -n1
}
