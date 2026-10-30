#!/usr/bin/env bash
# =============================================================================
# setup-os-sandbox.sh
#
# Linux-only fallback for splitscreen controller assignment. Instead of
# trusting the controller mod to pick the right pad, each instance runs Java
# inside bubblewrap with a private /dev that holds only that player's
# controller (plus GPU/audio). Every window can only ever see its own pad.
#
# What it does:
#   1. Installs bubblewrap/jq if missing; checks bwrap works on this kernel
#   2. Runs ../mod_path/setup-mc-splitscreen.sh if its instances don't exist yet
#   3. Copies Splitscreen-P1..N to Sandbox-P1..N (saves are not copied) so the
#      mod-only setup keeps working unchanged
#   4. Sets each copy's Prism "Wrapper command" to mc-sandbox-wrap.sh <player>
#   5. Installs helper scripts to ~/MinecraftSplitscreen/sandbox/ and a
#      "Minecraft Splitscreen (Sandbox)" desktop entry
#
# Needs native Prism Launcher (distro package or AppImage via --prism-cmd).
# The Flatpak can't run bwrap inside its own sandbox.
#
# Re-running is safe: existing Sandbox instances are skipped unless --force,
# which re-copies everything except saves and options.txt.
# =============================================================================
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
MOD_SETUP="$HERE/../mod_path/setup-mc-splitscreen.sh"
SANDBOX_DIR="$HOME/MinecraftSplitscreen/sandbox"

# ---------------------------- defaults ---------------------------------------
PLAYERS=4
PREFIX="Sandbox-P"
SOURCE_PREFIX="Splitscreen-P"
ACCOUNTS_CSV=""
PRISM_DATA="$HOME/.local/share/PrismLauncher"
PRISM_CMD_STR=""
LAUNCH_DELAY=20
FORCE=0
SKIP_INSTALL=0
MOD_ARGS=()

# ---------------------------- helpers ----------------------------------------
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options] [-- options for mod_path/setup-mc-splitscreen.sh]

  -p, --players N          Number of players, 1-4 (default: 4)
  -a, --accounts A,B,C,D   Prism account names in player order
                           (default: Microsoft accounts first, then offline)
      --prefix NAME        Sandbox instance prefix (default: Sandbox-P)
      --source-prefix NAME Instances to copy from (default: Splitscreen-P)
      --prism-data DIR     Prism data folder (default: ~/.local/share/PrismLauncher)
      --prism-cmd CMD      Prism command, e.g. an AppImage path (default: prismlauncher)
      --delay SECONDS      Delay between launching instances (default: 20)
      --force              Re-copy existing sandbox instances (keeps saves/options)
      --skip-install       Don't install packages
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--players)     PLAYERS="$2"; shift 2 ;;
    -a|--accounts)    ACCOUNTS_CSV="$2"; shift 2 ;;
    --prefix)         PREFIX="$2"; shift 2 ;;
    --source-prefix)  SOURCE_PREFIX="$2"; shift 2 ;;
    --prism-data)     PRISM_DATA="$2"; shift 2 ;;
    --prism-cmd)      PRISM_CMD_STR="$2"; shift 2 ;;
    --delay)          LAUNCH_DELAY="$2"; shift 2 ;;
    --force)          FORCE=1; shift ;;
    --skip-install)   SKIP_INSTALL=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    --)               shift; MOD_ARGS=("$@"); break ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == Linux ]] || die "The OS sandbox only works on Linux (use mod_path on Windows)"
[[ "$PLAYERS" =~ ^[1-4]$ ]] || die "--players must be 1-4"
[[ "$SANDBOX_DIR" != *" "* ]] || die "Home folder path contains a space; Prism's wrapper command can't handle that"

SUDO=""
if [[ $EUID -ne 0 ]]; then SUDO="sudo"; fi

pkg_install() {
  if   command -v pacman  >/dev/null; then $SUDO pacman -S --needed --noconfirm "$@"
  elif command -v apt-get >/dev/null; then $SUDO apt-get update -qq && $SUDO apt-get install -y "$@"
  elif command -v dnf     >/dev/null; then $SUDO dnf install -y "$@"
  elif command -v zypper  >/dev/null; then $SUDO zypper --non-interactive install "$@"
  else die "No supported package manager found. Install manually: $*"
  fi
}

# ---------------------------- 1. dependencies --------------------------------
if [[ $SKIP_INSTALL -eq 0 ]]; then
  missing=()
  if ! command -v bwrap >/dev/null; then missing+=(bubblewrap); fi
  if ! command -v jq    >/dev/null; then missing+=(jq); fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing: ${missing[*]}"
    pkg_install "${missing[@]}"
  fi
fi
command -v bwrap >/dev/null || die "bubblewrap (bwrap) is required"
command -v jq    >/dev/null || die "jq is required"

if ! bwrap --dev-bind / / --dev /dev true 2>/dev/null; then
  die "bwrap can't create a sandbox here. On Ubuntu 24.04+ AppArmor blocks unprivileged
    user namespaces for unconfined programs; check: sysctl kernel.apparmor_restrict_unprivileged_userns"
fi

if [[ -n "$PRISM_CMD_STR" ]]; then
  read -r -a PRISM_CMD <<<"$PRISM_CMD_STR"
elif command -v prismlauncher >/dev/null; then
  PRISM_CMD=(prismlauncher)
else
  die "Native Prism Launcher not found. The Flatpak can't run bwrap; install the distro
    package (or use --prism-cmd /path/to/PrismLauncher.AppImage)"
fi
log "Prism Launcher: ${PRISM_CMD[*]}"

# ---------------------------- 2. base instances ------------------------------
INST_DIR="$PRISM_DATA/instances"
if [[ -f "$PRISM_DATA/prismlauncher.cfg" ]]; then
  custom=$(grep -E '^InstanceDir=' "$PRISM_DATA/prismlauncher.cfg" | head -n1 | cut -d= -f2- || true)
  if [[ -n "$custom" ]]; then
    if [[ "$custom" = /* ]]; then INST_DIR="$custom"; else INST_DIR="$PRISM_DATA/$custom"; fi
  fi
fi

need_base=0
for ((i = 1; i <= PLAYERS; i++)); do
  if [[ ! -d "$INST_DIR/${SOURCE_PREFIX}$i" ]]; then need_base=1; fi
done
if [[ $need_base -eq 1 ]]; then
  [[ -f "$MOD_SETUP" ]] || die "Missing $MOD_SETUP"
  log "Creating base instances with mod_path/setup-mc-splitscreen.sh"
  extra=()
  if [[ $SKIP_INSTALL -eq 1 ]]; then extra+=(--skip-install); fi
  bash "$MOD_SETUP" --players "$PLAYERS" --prism-data "$PRISM_DATA" --prefix "$SOURCE_PREFIX" \
    ${extra[@]+"${extra[@]}"} ${MOD_ARGS[@]+"${MOD_ARGS[@]}"}
fi

# ---------------------------- 3. helper scripts ------------------------------
mkdir -p "$SANDBOX_DIR"
cp "$HERE"/bin/*.sh "$SANDBOX_DIR/"
chmod +x "$SANDBOX_DIR"/*.sh
log "Installed helpers to $SANDBOX_DIR"

# ---------------------------- 4. sandbox instances ---------------------------
# set_cfg FILE KEY VALUE: set KEY in the [General] section of a Prism instance.cfg
set_cfg() {
  local tmp
  tmp=$(mktemp)
  awk -v k="$2" -v v="$3" '
    $0 ~ "^" k "=" { if (!done) print k "=" v; done = 1; next }
    { print }
    /^\[General\]$/ && !done { print k "=" v; done = 1 }
    END { if (!done) print k "=" v }' "$1" >"$tmp"
  mv "$tmp" "$1"
}

INSTANCES=()
for ((i = 1; i <= PLAYERS; i++)); do
  src="$INST_DIR/${SOURCE_PREFIX}$i"
  id="${PREFIX}$i"
  dst="$INST_DIR/$id"
  INSTANCES+=("$id")

  if [[ -d "$dst" && $FORCE -eq 0 ]]; then
    warn "$id already exists, skipping (use --force to re-copy)"
    continue
  fi
  log "Creating $id from ${SOURCE_PREFIX}$i"

  # Worlds live on P1's side only; never overwrite them or tuned options
  excludes=(--exclude=./minecraft/saves --exclude=./minecraft/logs --exclude=./minecraft/crash-reports
            --exclude=./.minecraft/saves --exclude=./.minecraft/logs --exclude=./.minecraft/crash-reports)
  for g in minecraft .minecraft; do
    if [[ -f "$dst/$g/options.txt" ]]; then excludes+=("--exclude=./$g/options.txt"); fi
    rm -f "$dst/$g/mods/"*.jar 2>/dev/null || true
  done
  mkdir -p "$dst"
  tar -C "$src" "${excludes[@]}" -cf - . | tar -C "$dst" -xf -

  # Prism tracks instances by these; a copied uuid would clash with the source
  sed -i -E '/^(uuid|lastLaunchTime|lastTimePlayed|totalTimePlayed)=/d' "$dst/instance.cfg"
  set_cfg "$dst/instance.cfg" name "Sandbox P$i"
  set_cfg "$dst/instance.cfg" OverrideCommands true
  set_cfg "$dst/instance.cfg" WrapperCommand "$SANDBOX_DIR/mc-sandbox-wrap.sh $i"
done

# ---------------------------- 5. launcher ------------------------------------
ACCOUNTS=()
if [[ -n "$ACCOUNTS_CSV" ]]; then
  IFS=',' read -r -a ACCOUNTS <<<"$ACCOUNTS_CSV"
elif [[ -f "$PRISM_DATA/accounts.json" ]]; then
  # Microsoft accounts first so P1 (the LAN host) gets a real account
  mapfile -t ACCOUNTS < <(jq -r '[.accounts[]? | select(.profile.name)]
    | (map(select(.type != "Offline")) + map(select(.type == "Offline")))
    | .[].profile.name' "$PRISM_DATA/accounts.json")
fi
if [[ ${#ACCOUNTS[@]} -lt $PLAYERS ]]; then
  warn "Only ${#ACCOUNTS[@]} account(s) for $PLAYERS players; run mod_path/setup-mc-splitscreen.sh"
  warn "to create offline accounts, or edit $SANDBOX_DIR/sandbox.conf."
fi

{
  echo '# Generated by setup-os-sandbox.sh'
  printf 'PRISM=(%s)\n'     "$(printf '%q ' "${PRISM_CMD[@]}")"
  printf 'INSTANCES=(%s)\n' "$(printf '%q ' "${INSTANCES[@]}")"
  printf 'ACCOUNTS=(%s)\n'  "$(if [[ ${#ACCOUNTS[@]} -gt 0 ]]; then printf '%q ' "${ACCOUNTS[@]:0:$PLAYERS}"; fi)"
  printf 'PLAYERS=%s\n'     "$PLAYERS"
  printf 'DELAY=%s\n'       "$LAUNCH_DELAY"
} >"$SANDBOX_DIR/sandbox.conf"

DESKTOP="$HOME/.local/share/applications/minecraft-splitscreen-sandbox.desktop"
mkdir -p "$(dirname "$DESKTOP")"
cat >"$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Minecraft Splitscreen (Sandbox)
Comment=Launch $PLAYERS-player splitscreen Minecraft, one controller per window
Exec=$SANDBOX_DIR/launch-sandbox.sh
Icon=applications-games
Terminal=false
Categories=Game;
EOF

# ---------------------------- done -------------------------------------------
log "Done!"
cat <<EOF
  Instances : ${INSTANCES[*]}  (in $INST_DIR)
  Launcher  : $SANDBOX_DIR/launch-sandbox.sh  (also "Minecraft Splitscreen (Sandbox)" in your app menu)
  Assign    : $SANDBOX_DIR/assign-controllers.sh

Each window only sees its own controller, so in-game you just need
Controlify's out-of-focus / unfocused input turned on. Same LAN steps as
before: P1 opens to LAN (Online Mode OFF for offline players), others
Direct Connect to localhost:<port>.

Close Steam (or disable Steam Input for Prism) first: its virtual pads are
ignored, but Steam can hold the real ones.
EOF

if [[ -t 0 ]]; then
  read -r -p "Assign controllers to players now? [Y/n] " ans
  if [[ ! "$ans" =~ ^[Nn] ]]; then "$SANDBOX_DIR/assign-controllers.sh" "$PLAYERS"; fi
fi
