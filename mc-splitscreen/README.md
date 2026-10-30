# mc-splitscreen

Local splitscreen Minecraft Java (1–4 players, one controller each, one
screen) using Prism Launcher. One binary for Windows and Linux.

```
mc-splitscreen              # first run: setup; afterwards: launch
mc-splitscreen setup        # install Prism if needed, accounts, mods, instances
mc-splitscreen launch       # start every player's window, staggered
mc-splitscreen assign       # Linux sandbox mode: press a button per player
```

`setup` installs Prism Launcher if it's missing (Windows: winget, else the
official installer; Linux: pacman, else the official AppImage, extracted so
FUSE isn't needed), adds offline accounts for players without a Microsoft
account, downloads Fabric mods from Modrinth, creates `Splitscreen-P1..N`,
copies itself to `~/MinecraftSplitscreen/`, and adds a desktop shortcut.
See `mc-splitscreen setup --help` for options.

`--sandbox` (Linux) runs each instance's Java inside bubblewrap with a private
`/dev` holding only that player's controller, for when the controller mod
assigns pads wrong. `--no-sandbox` turns it back off.

## Building

Only pure-Rust crates; HTTP goes through the system `curl`.

```
cargo build --release                                   # this platform
# static Linux binary, from any OS:
rustup target add x86_64-unknown-linux-musl
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
  cargo build --release --target x86_64-unknown-linux-musl
```

On the windows-gnu toolchain without MinGW installed, put the toolchain's own
`dlltool` on PATH first:
`$(rustc --print sysroot)/lib/rustlib/x86_64-pc-windows-gnu/bin/self-contained`.
