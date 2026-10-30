# Minecraft Splitscreen (Java Edition)

Console-style couch co-op for Minecraft Java Edition on one PC: up to 4
players, each with their own controller and their own window, playing the
same world on one screen.

```
┌───────────┬───────────┐
│ Player 1  │ Player 2  │
│ (host)    │           │
├───────────┼───────────┤
│ Player 3  │ Player 4  │
│           │           │
└───────────┴───────────┘
```

It's built on [Prism Launcher](https://prismlauncher.org) and a handful of
Fabric mods. One tool installs Prism, creates an instance per player,
downloads the mods, and launches all the windows. It works on **Windows** and
**Linux** and is tuned for **lower-end hardware**.

## Quick start

1. Download the file for your system from [`releases/`](releases/):
   - Windows: `mc-splitscreen-windows-x86_64.exe`
   - Linux: `mc-splitscreen-linux-x86_64`
2. **Close Prism Launcher** if it's open.
3. Run it.
   - **Windows:** double-click it. SmartScreen may warn about an unsigned
     app: choose *More info → Run anyway*.
   - **Linux:** `chmod +x mc-splitscreen-linux-x86_64 && ./mc-splitscreen-linux-x86_64`
4. If Prism has no Microsoft account yet, it opens: sign in with an account
   that owns Minecraft, then close Prism and setup continues.
5. Answer **Y** to *Launch splitscreen now?*

After that, start the game with the **Minecraft Splitscreen** shortcut on your
desktop (Windows) or in your app menu (Linux). Running the program again does
the same thing.

## First game

The windows open about 20 seconds apart. The first time, in **each** window:

1. **Press F11** until the window snaps into its quarter of the screen. It
   remembers the position.
2. Open **Controlify** settings, pick that player's controller, and turn on
   **out-of-focus / unfocused input**. Otherwise only the window you last
   clicked responds.

Then, to play together:

3. **Player 1** creates or loads a world, then *Pause → Open to LAN*. Turn
   **Online Mode OFF**, note the port number, and click **Apply Changes**.
4. **Players 2–4**: *Multiplayer → Direct Connection →* `localhost:<port>`.

> Typing a fixed port (e.g. `25565`) in the Open to LAN screen every time lets
> the other players save it as a server.

## Accounts

Player 1 uses your Microsoft account. Players without their own Microsoft
account get **offline accounts** (`Player2`, `Player3`, …) created
automatically, and the OfflineLAN mod is added so they can join. This is why
Online Mode must be **OFF** when opening to LAN.

- Choose names: `mc-splitscreen setup --offline-names Sam,Riley,Alex`
  (3–16 letters, digits or `_`)
- If everyone has their own Microsoft account, add them in Prism
  (*Settings → Accounts*) before setup; they're used in order.
- Offline players have default skins.
- Keep Online Mode the same every session for a world. Switching it changes
  player IDs, so inventories and progress won't carry over.

## Commands

```
mc-splitscreen              first run: setup; afterwards: launch
mc-splitscreen setup        install Prism if needed, accounts, mods, instances
mc-splitscreen launch       start every player's window
mc-splitscreen assign       Linux sandbox mode: pick each player's controller
mc-splitscreen --help       all options (also: setup --help)
```

Useful `setup` options:

| Option | What it does |
|---|---|
| `-p, --players N` | 1–4 players (default 4) |
| `-v, --mc-version VER` | Minecraft version (default: newest every core mod supports) |
| `-m, --memory MB` | RAM per window (default: sized to your PC) |
| `-a, --accounts A,B,C` | Prism accounts in player order |
| `--offline-names A,B` | Names for auto-created offline accounts |
| `--no-offline` | Don't create offline accounts |
| `-c, --controller-mod` | `controlify` (default) or `midnightcontrols` |
| `--delay SECONDS` | Gap between window launches (default 20) |
| `--force` | Rebuild instances (replaces mods; keeps worlds and settings) |
| `--sandbox` | Linux: isolate controllers (see below) |
| `--skip-install` / `--prism-exe PATH` / `--prism-data DIR` | Use an existing or custom Prism |

Setup is safe to re-run. Existing instances keep their mods unless you pass
`--force`, which removes **all** mod jars in them, including ones you added.

## What gets installed

- **Prism Launcher** if it's missing. Windows: winget, or the official
  installer. Linux: pacman, or the official AppImage, extracted to
  `~/.local/share/mc-splitscreen/prism`.
- Prism instances `Splitscreen-P1` … `P4`, with Fabric and these mods from
  [Modrinth](https://modrinth.com):
  - [Controlify](https://modrinth.com/mod/controlify): controller support
  - [Splitscreen Support](https://modrinth.com/mod/mc-splitscreen): F11 window snapping
  - [OfflineLAN](https://modrinth.com/mod/offlinelan): lets offline accounts join
  - [Fabric API](https://modrinth.com/mod/fabric-api) and required dependencies
  - Performance: [Sodium](https://modrinth.com/mod/sodium), [Lithium](https://modrinth.com/mod/lithium),
    [FerriteCore](https://modrinth.com/mod/ferrite-core), [ModernFix](https://modrinth.com/mod/modernfix),
    [ImmediatelyFast](https://modrinth.com/mod/immediatelyfast), [Entity Culling](https://modrinth.com/mod/entityculling)
    (each is skipped if it has no build for the chosen version)
- Low-end-friendly game settings (render distance 8, 60 FPS cap, no pause
  when a window loses focus, music only in Player 1's window). Applied only
  to new instances.
- `~/MinecraftSplitscreen/` (Windows: `%USERPROFILE%\MinecraftSplitscreen\`):
  the program, its `config.json`, and controller assignments.
- A desktop shortcut (Windows) or app menu entry (Linux).

## Hardware

RAM is the limit: every player runs a separate copy of Minecraft. Setup
splits your RAM automatically (about 2–3 GB per window, a bit more for the
host).

| Total RAM | Players |
|---|---|
| 8 GB | 2 |
| 12–16 GB | 3–4 |
| 16 GB+ | 4 comfortably |

On Linux, enabling zram helps on low-memory machines.

## Linux sandbox mode (controller fallback)

If Controlify gives two windows the same controller, or pads swap around,
use sandbox mode:

```
./mc-splitscreen-linux-x86_64 setup --sandbox
```

Each window's Java runs inside [bubblewrap](https://github.com/containers/bubblewrap)
with a private `/dev` that contains only that player's controller (plus GPU
and audio), so a window physically can't see anyone else's pad. Setup then
asks each player to press a button to claim their controller. The choice is
saved by Bluetooth address or USB port, so it holds across reboots. Re-run it
any time with `mc-splitscreen assign`.

Requirements: `bubblewrap` installed, and a **native** Prism (the Flatpak
can't do this; setup installs the AppImage instead if needed). On Ubuntu
24.04+, AppArmor may block it; setup checks this and tells you what to look
at. Turn it off with `setup --no-sandbox`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Setup says "Close Prism Launcher first" | Prism rewrites its account file on exit. Close it fully (check the system tray) and re-run. |
| Offline players get "Failed to verify username" | Online Mode wasn't turned off, or *Apply Changes* wasn't clicked, on Player 1's Open to LAN screen. |
| The world doesn't show up in the LAN list | Normal between windows on one PC. Use Direct Connection with `localhost:<port>`. |
| Only the last-clicked window responds to its controller | Turn on Controlify's out-of-focus / unfocused input in that window. |
| Duplicate or extra controllers | Close Steam, or disable Steam Input for Prism. |
| A window is slow or crashes | Too little RAM for that many players. Try fewer players or `setup --memory 2048`. |
| Windows didn't open after setup | Setup only launches if you answer Y. Use the desktop shortcut. |

## Scripts (alternative)

The same setup also exists as plain scripts, if you'd rather not run a binary:

- [`mod_path/Setup-MCSplitscreen.ps1`](mod_path/Setup-MCSplitscreen.ps1) (Windows PowerShell 5.1+)
- [`mod_path/setup-mc-splitscreen.sh`](mod_path/setup-mc-splitscreen.sh) (Linux, needs `curl` and `jq`)
- [`os_sandbox/setup-os-sandbox.sh`](os_sandbox/setup-os-sandbox.sh): Linux sandbox mode on top of the script setup

The binary is the main, most tested path.

## Building from source

Source is in [`mc-splitscreen/`](mc-splitscreen/). It uses only pure-Rust
crates; downloads go through the system `curl`.

```
cd mc-splitscreen
cargo build --release

# static Linux binary, buildable from any OS:
rustup target add x86_64-unknown-linux-musl
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
  cargo build --release --target x86_64-unknown-linux-musl
```

See [`mc-splitscreen/README.md`](mc-splitscreen/README.md) for toolchain notes.

## Credits

This project only automates setup. The real work is done by
[Prism Launcher](https://prismlauncher.org) and the mod authors linked above,
especially pcal43's Splitscreen Support and isXander's Controlify. Not
affiliated with Mojang or Microsoft; each Player 1 needs a legitimate copy of
Minecraft Java Edition.

## License

[MIT](LICENSE). The mods and Prism Launcher it downloads have their own
licenses.
