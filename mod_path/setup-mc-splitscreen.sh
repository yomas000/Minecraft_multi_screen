#!/usr/bin/env bash
# =============================================================================
# setup-mc-splitscreen.sh
#
# Sets up Prism Launcher for local splitscreen Minecraft Java (1-4 players,
# one controller each) on Linux.
#
# What it does:
#   1. Installs curl/jq and Prism Launcher if missing (pacman, or Flatpak)
#   2. Picks the newest Minecraft release supported by every core mod
#   3. Downloads Fabric mods (+ their required dependencies) from Modrinth:
#        core: fabric-api, controlify (or midnightcontrols), mc-splitscreen, sodium
#        (+ offlinelan when offline accounts are used)
#        perf: lithium, ferrite-core, modernfix, immediatelyfast, entityculling
#   4. Creates one Prism instance per player with RAM sized to this machine
#      and low-end-friendly options.txt (no pause on lost focus, music only on P1)
#   5. Writes ~/MinecraftSplitscreen/launch-splitscreen.sh + a desktop entry
#
# Players without their own Microsoft account get an offline Prism account
# (Player2, Player3, ... or --offline-names), and OfflineLAN is added so the
# host can turn off online-mode when opening to LAN. --no-offline disables this.
#
# Re-running is safe: existing instances are skipped unless --force is given.
# --force replaces mod jars and instance config but never touches saves or
# options.txt.
# =============================================================================
set -euo pipefail

# ---------------------------- defaults ---------------------------------------
PLAYERS=4
MC_VERSION=""
MEM_MB=""
PREFIX="Splitscreen-P"
ACCOUNTS_CSV=""
OFFLINE_CSV=""
NO_OFFLINE=0
CONTROLLER_MOD="controlify"
PRISM_DATA=""
FORCE=0
SKIP_INSTALL=0
LAUNCH_DELAY=20

PERF_MODS=(lithium ferrite-core modernfix immediatelyfast entityculling)

API="https://api.modrinth.com/v2"
UA="mc-splitscreen-setup/1.0 (Prism Launcher splitscreen helper)"
OUT_DIR="$HOME/MinecraftSplitscreen"

# ---------------------------- helpers ----------------------------------------
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [options]

  -p, --players N          Number of players, 1-4 (default: 4)
  -v, --mc-version VER     Minecraft version (default: newest supported by all core mods)
  -m, --memory MB          Max RAM per joining instance in MB (default: auto)
  -a, --accounts A,B,C,D   Prism account names in player order
                           (default: accounts already added to Prism, in order)
      --offline-names A,B  Names for offline accounts created for players
                           without an account (default: Player2, Player3, ...)
      --no-offline         Don't create offline accounts or add OfflineLAN
  -c, --controller-mod M   controlify (default) or midnightcontrols
      --prism-data DIR     Prism data folder (default: auto-detect)
      --prefix NAME        Instance name prefix (default: Splitscreen-P)
      --delay SECONDS      Delay between launching instances (default: 20)
      --force              Rebuild existing instances (keeps saves/options)
      --skip-install       Don't install packages
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--players)        PLAYERS="$2"; shift 2 ;;
    -v|--mc-version)     MC_VERSION="$2"; shift 2 ;;
    -m|--memory)         MEM_MB="$2"; shift 2 ;;
    -a|--accounts)       ACCOUNTS_CSV="$2"; shift 2 ;;
    --offline-names)     OFFLINE_CSV="$2"; shift 2 ;;
    --no-offline)        NO_OFFLINE=1; shift ;;
    -c|--controller-mod) CONTROLLER_MOD="$2"; shift 2 ;;
    --prism-data)        PRISM_DATA="$2"; shift 2 ;;
    --prefix)            PREFIX="$2"; shift 2 ;;
    --delay)             LAUNCH_DELAY="$2"; shift 2 ;;
    --force)             FORCE=1; shift ;;
    --skip-install)      SKIP_INSTALL=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

[[ "$PLAYERS" =~ ^[1-4]$ ]] || die "--players must be 1-4"
case "$CONTROLLER_MOD" in controlify|midnightcontrols) ;; *) die "--controller-mod must be controlify or midnightcontrols" ;; esac
CORE_MODS=(fabric-api "$CONTROLLER_MOD" mc-splitscreen sodium)

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

api() { curl -fsSL -A "$UA" "$@"; }

# Modrinth versions of a project for Fabric, optionally filtered to one MC version
mod_versions_json() {
  local id="$1" mc="${2:-}"
  local args=(--data-urlencode 'loaders=["fabric"]')
  if [[ -n "$mc" ]]; then args+=(--data-urlencode "game_versions=[\"$mc\"]"); fi
  api -G "$API/project/$id/version" "${args[@]}"
}

# ---------------------------- 1. dependencies --------------------------------
PRISM_CMD=()
PRISM_DEFAULT_DATA=""
detect_prism() {
  if command -v prismlauncher >/dev/null; then
    PRISM_CMD=(prismlauncher)
    PRISM_DEFAULT_DATA="$HOME/.local/share/PrismLauncher"
    return 0
  fi
  if command -v flatpak >/dev/null && flatpak info org.prismlauncher.PrismLauncher >/dev/null 2>&1; then
    PRISM_CMD=(flatpak run org.prismlauncher.PrismLauncher)
    PRISM_DEFAULT_DATA="$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher"
    return 0
  fi
  return 1
}

install_prism() {
  if command -v pacman >/dev/null; then
    pkg_install prismlauncher
  else
    if ! command -v flatpak >/dev/null; then pkg_install flatpak; fi
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --user -y flathub org.prismlauncher.PrismLauncher
    # Make sure the sandbox can see every controller
    flatpak override --user --device=all org.prismlauncher.PrismLauncher
  fi
}

if [[ $SKIP_INSTALL -eq 0 ]]; then
  missing=()
  for t in curl jq; do
    if ! command -v "$t" >/dev/null; then missing+=("$t"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Installing: ${missing[*]}"
    pkg_install "${missing[@]}"
  fi
  if ! detect_prism; then
    log "Installing Prism Launcher"
    install_prism
  fi
fi
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"
detect_prism || die "Prism Launcher not found"
log "Prism Launcher: ${PRISM_CMD[*]}"

# ---------------------------- 2. Prism data / accounts -----------------------
PRISM_DATA="${PRISM_DATA:-$PRISM_DEFAULT_DATA}"
ACCOUNTS_FILE="$PRISM_DATA/accounts.json"

account_count() {
  if [[ -f "$ACCOUNTS_FILE" ]]; then
    jq '[.accounts[]?] | length' "$ACCOUNTS_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

if [[ "$(account_count)" -eq 0 ]]; then
  warn "Prism has no accounts yet."
  log  "Opening Prism. Finish the first-run wizard and add each player's Microsoft account"
  log  "(Settings > Accounts), then close Prism."
  "${PRISM_CMD[@]}" >/dev/null 2>&1 || true
  [[ "$(account_count)" -gt 0 ]] || die "Still no accounts in $ACCOUNTS_FILE"
fi

# Instance folder (respects a custom InstanceDir in prismlauncher.cfg)
INST_DIR="$PRISM_DATA/instances"
if [[ -f "$PRISM_DATA/prismlauncher.cfg" ]]; then
  custom=$(grep -E '^InstanceDir=' "$PRISM_DATA/prismlauncher.cfg" | head -n1 | cut -d= -f2- || true)
  if [[ -n "$custom" ]]; then
    if [[ "$custom" = /* ]]; then INST_DIR="$custom"; else INST_DIR="$PRISM_DATA/$custom"; fi
  fi
fi
mkdir -p "$INST_DIR"

# Account names, Microsoft accounts first so P1 (the LAN host) gets a real account
list_accounts() {
  jq -r '[.accounts[]? | select(.profile.name)]
         | (map(select(.type != "Offline")) + map(select(.type == "Offline")))
         | .[].profile.name' "$ACCOUNTS_FILE"
}

# Case-insensitive membership: in_list NAME ITEMS...
in_list() {
  local x="$1" y
  shift
  for y in "$@"; do
    if [[ "${y,,}" == "${x,,}" ]]; then return 0; fi
  done
  return 1
}

# Java's UUID.nameUUIDFromBytes("OfflinePlayer:<name>"), same as Prism and the server
offline_uuid() {
  local h b6 b8
  h=$(printf 'OfflinePlayer:%s' "$1" | md5sum | cut -c1-32)
  b6=$(( (16#${h:12:2} & 0x0f) | 0x30 ))
  b8=$(( (16#${h:16:2} & 0x3f) | 0x80 ))
  printf '%s%02x%s%02x%s\n' "${h:0:12}" "$b6" "${h:14:2}" "$b8" "${h:18}"
}

# Same shape Prism saves for Settings > Accounts > Add Offline
add_offline_accounts() {
  local n tmp now
  if pgrep -x prismlauncher >/dev/null 2>&1; then
    die "Close Prism Launcher first (it rewrites accounts.json on exit), then re-run"
  fi
  now=$(date +%s)
  cp "$ACCOUNTS_FILE" "$ACCOUNTS_FILE.bak"
  for n in "$@"; do
    tmp=$(jq --arg n "$n" --arg id "$(offline_uuid "$n")" \
             --arg ct "$(tr -d '-' </proc/sys/kernel/random/uuid)" --argjson now "$now" \
      '.accounts = (.accounts // []) + [{
         type: "Offline",
         ygg: {iat: $now, token: "0", extra: {clientToken: $ct, userName: $n}},
         profile: {id: $id, name: $n, skin: {id: "", url: "", variant: ""}, capes: []},
         entitlement: {canPlayMinecraft: true, ownsMinecraft: true}
       }]' "$ACCOUNTS_FILE")
    printf '%s\n' "$tmp" >"$ACCOUNTS_FILE"
  done
}

# Accounts per player
ACCOUNTS=()
if [[ -n "$ACCOUNTS_CSV" ]]; then
  IFS=',' read -r -a ACCOUNTS <<<"$ACCOUNTS_CSV"
else
  mapfile -t ACCOUNTS < <(list_accounts)
fi
if [[ ${#ACCOUNTS[@]} -lt $PLAYERS && $NO_OFFLINE -eq 0 ]]; then
  mapfile -t KNOWN < <(list_accounts)
  OFFLINE_NAMES=()
  if [[ -n "$OFFLINE_CSV" ]]; then IFS=',' read -r -a OFFLINE_NAMES <<<"$OFFLINE_CSV"; fi
  TO_ADD=()
  j=0
  while [[ ${#ACCOUNTS[@]} -lt $PLAYERS ]]; do
    n="${OFFLINE_NAMES[$j]:-Player$(( ${#ACCOUNTS[@]} + 1 ))}"
    j=$(( j + 1 ))
    [[ "$n" =~ ^[A-Za-z0-9_]{3,16}$ ]] || die "Offline name '$n' must be 3-16 letters, digits or _"
    if in_list "$n" ${ACCOUNTS[@]+"${ACCOUNTS[@]}"}; then die "Account '$n' is already assigned to another player"; fi
    if ! in_list "$n" ${KNOWN[@]+"${KNOWN[@]}"}; then TO_ADD+=("$n"); fi
    ACCOUNTS+=("$n")
  done
  if [[ ${#TO_ADD[@]} -gt 0 ]]; then
    log "Adding offline Prism accounts: ${TO_ADD[*]}"
    add_offline_accounts "${TO_ADD[@]}"
  fi
fi
if [[ ${#ACCOUNTS[@]} -lt $PLAYERS ]]; then
  warn "Only ${#ACCOUNTS[@]} account(s) for $PLAYERS players. Each player needs their own account"
  warn "to join the LAN world; add more in Prism and re-run, or edit the launcher script later."
fi

mapfile -t OFFLINE_IN_PRISM < <(jq -r '.accounts[]? | select(.type == "Offline") | .profile.name // empty' "$ACCOUNTS_FILE")
USES_OFFLINE=0
for ((i = 0; i < PLAYERS && i < ${#ACCOUNTS[@]}; i++)); do
  if in_list "${ACCOUNTS[$i]}" ${OFFLINE_IN_PRISM[@]+"${OFFLINE_IN_PRISM[@]}"}; then USES_OFFLINE=1; fi
done
if [[ $USES_OFFLINE -eq 1 ]]; then
  if [[ "$(jq '[.accounts[]? | select(.type == "MSA")] | length' "$ACCOUNTS_FILE")" -eq 0 ]]; then
    warn "Prism needs at least one Microsoft account that owns Minecraft, or offline accounts launch in demo mode."
  fi
  # Lets the host turn off online-mode in the Open to LAN screen so offline players can join
  CORE_MODS+=(offlinelan)
fi

# ---------------------------- 3. versions ------------------------------------
pick_mc_version() {
  local tags m v s ok
  local sets=()
  tags=$(api "$API/tag/game_version" |
         jq -r '[.[] | select(.version_type=="release")] | sort_by(.date) | reverse | .[].version')
  for m in "${CORE_MODS[@]}"; do
    sets+=("$(mod_versions_json "$m" | jq -r '[.[].game_versions[]] | unique | .[]')")
  done
  while read -r v; do
    ok=1
    for s in "${sets[@]}"; do
      if ! grep -qxF "$v" <<<"$s"; then ok=0; break; fi
    done
    if [[ $ok -eq 1 ]]; then echo "$v"; return 0; fi
  done <<<"$tags"
  return 1
}

if [[ -z "$MC_VERSION" ]]; then
  log "Finding newest Minecraft version supported by: ${CORE_MODS[*]}"
  MC_VERSION=$(pick_mc_version) || die "No Minecraft release is supported by all core mods"
fi
LOADER=$(api https://meta.fabricmc.net/v2/versions/loader | jq -r '[.[] | select(.stable)][0].version')
[[ -n "$LOADER" && "$LOADER" != "null" ]] || die "Could not get Fabric loader version"
log "Minecraft $MC_VERSION, Fabric loader $LOADER"

# ---------------------------- 4. memory --------------------------------------
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ -z "$MEM_MB" ]]; then
  MEM_MB=$(( (TOTAL_MB - 3072) / PLAYERS ))
  if [[ $MEM_MB -gt 3072 ]]; then MEM_MB=3072; fi
fi
if [[ $MEM_MB -lt 2048 ]]; then
  warn "Only ~${MEM_MB} MB per instance (${TOTAL_MB} MB total). Consider fewer players."
  if [[ $MEM_MB -lt 1536 ]]; then MEM_MB=1536; fi
fi
HOST_MEM=$(( MEM_MB + 512 ))
if [[ $HOST_MEM -gt 3584 ]]; then HOST_MEM=3584; fi
log "RAM: host ${HOST_MEM} MB, others ${MEM_MB} MB (system ${TOTAL_MB} MB)"

# ---------------------------- 5. mods ----------------------------------------
CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT
declare -A SEEN=()

fetch_mod() {
  local id="$1" required="$2" json ver pid file url name dep
  if ! json=$(mod_versions_json "$id" "$MC_VERSION"); then
    if [[ $required -eq 1 ]]; then die "Mod '$id' not found on Modrinth"; fi
    warn "Skipping '$id' (not found)"; return 0
  fi
  ver=$(jq -c '([.[] | select(.version_type=="release")] + .)[0] // empty' <<<"$json")
  if [[ -z "$ver" ]]; then
    if [[ $required -eq 1 ]]; then die "No Fabric build of '$id' for $MC_VERSION"; fi
    warn "Skipping '$id' (no build for $MC_VERSION)"; return 0
  fi
  pid=$(jq -r '.project_id' <<<"$ver")
  if [[ -n "${SEEN[$pid]:-}" ]]; then return 0; fi
  SEEN[$pid]=1
  file=$(jq -c '(.files | (map(select(.primary)) + .))[0]' <<<"$ver")
  url=$(jq -r '.url' <<<"$file")
  name=$(jq -r '.filename' <<<"$file")
  printf '    %-18s %s\n' "$id" "$name"
  api -o "$CACHE/$name" "$url"
  while read -r dep; do
    if [[ -n "$dep" ]]; then fetch_mod "$dep" 1; fi
  done < <(jq -r '.dependencies[]? | select(.dependency_type=="required" and .project_id != null) | .project_id' <<<"$ver")
}

log "Downloading mods"
for m in "${CORE_MODS[@]}"; do fetch_mod "$m" 1; done
for m in "${PERF_MODS[@]}"; do fetch_mod "$m" 0; done

# ---------------------------- 6. instances -----------------------------------
write_options() {
  local path="$1" player="$2" music="0.0"
  if [[ $player -eq 1 ]]; then music="1.0"; fi
  cat >"$path" <<EOF
pauseOnLostFocus:false
fullscreen:false
renderDistance:8
simulationDistance:6
maxFps:60
enableVsync:false
graphicsMode:0
renderClouds:"false"
ao:false
entityShadows:false
particles:2
biomeBlendRadius:0
soundCategory_music:$music
onboardAccessibility:false
skipMultiplayerWarnings:true
joinedFirstServer:true
tutorialStep:none
narrator:0
EOF
}

INSTANCES=()
for ((i = 1; i <= PLAYERS; i++)); do
  id="${PREFIX}${i}"
  dir="$INST_DIR/$id"
  INSTANCES+=("$id")

  if [[ -d "$dir" && $FORCE -eq 0 ]]; then
    warn "$id already exists, skipping (use --force to rebuild)"
    continue
  fi
  log "Creating instance $id"

  gamedir="$dir/minecraft"
  if [[ -d "$dir/.minecraft" ]]; then gamedir="$dir/.minecraft"; fi
  mkdir -p "$gamedir/mods"
  rm -f "$gamedir/mods/"*.jar
  cp "$CACHE"/*.jar "$gamedir/mods/"

  mem=$MEM_MB
  if [[ $i -eq 1 ]]; then mem=$HOST_MEM; fi

  cat >"$dir/instance.cfg" <<EOF
[General]
ConfigVersion=1.3
InstanceType=OneSix
name=Splitscreen P$i
iconKey=default
OverrideMemory=true
MinMemAlloc=512
MaxMemAlloc=$mem
OverrideJavaArgs=true
JvmArgs=-XX:+UseG1GC -XX:MaxGCPauseMillis=50 -XX:+ParallelRefProcEnabled
EOF

  cat >"$dir/mmc-pack.json" <<EOF
{
    "components": [
        { "important": true, "uid": "net.minecraft", "version": "$MC_VERSION" },
        { "uid": "net.fabricmc.fabric-loader", "version": "$LOADER" }
    ],
    "formatVersion": 1
}
EOF

  if [[ ! -f "$gamedir/options.txt" ]]; then write_options "$gamedir/options.txt" "$i"; fi
done

# ---------------------------- 7. launcher ------------------------------------
mkdir -p "$OUT_DIR"
LAUNCHER="$OUT_DIR/launch-splitscreen.sh"
{
  echo '#!/usr/bin/env bash'
  echo '# Generated by setup-mc-splitscreen.sh. Edit ACCOUNTS if player accounts change.'
  printf 'PRISM=(%s)\n'     "$(printf '%q ' "${PRISM_CMD[@]}")"
  printf 'INSTANCES=(%s)\n' "$(printf '%q ' "${INSTANCES[@]}")"
  if [[ ${#ACCOUNTS[@]} -gt 0 ]]; then
    printf 'ACCOUNTS=(%s)\n' "$(printf '%q ' "${ACCOUNTS[@]}")"
  else
    echo 'ACCOUNTS=()'
  fi
  printf 'DELAY=${DELAY:-%s}\n' "$LAUNCH_DELAY"
  cat <<'EOF'
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
EOF
} >"$LAUNCHER"
chmod +x "$LAUNCHER"

DESKTOP="$HOME/.local/share/applications/minecraft-splitscreen.desktop"
mkdir -p "$(dirname "$DESKTOP")"
cat >"$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Minecraft Splitscreen
Comment=Launch $PLAYERS-player splitscreen Minecraft
Exec=$LAUNCHER
Icon=applications-games
Terminal=false
Categories=Game;
EOF

# ---------------------------- done -------------------------------------------
LAN_STEP="Open to LAN."
if [[ $USES_OFFLINE -eq 1 ]]; then
  LAN_STEP="Open to LAN, and switch Online Mode OFF there (offline players get kicked otherwise)."
fi
cat <<EOF

$(log "Done!")
  Instances : ${INSTANCES[*]}  (in $INST_DIR)
  Launcher  : $LAUNCHER  (also "Minecraft Splitscreen" in your app menu)

First-time setup in each window (settings are saved afterwards):
  1. Press F11 until the window snaps to its quarter of the screen.
  2. Open $CONTROLLER_MOD settings, pick that player's controller, and turn on
     out-of-focus / unfocused input.
  3. Player 1: create a world, then Pause > $LAN_STEP
  4. Players 2-$PLAYERS: Multiplayer > the LAN world should appear (or Direct Connect
     to localhost:<port shown in P1's chat>).

Tip: if Steam is running, disable Steam Input for Prism so it doesn't
create duplicate virtual controllers.
EOF
