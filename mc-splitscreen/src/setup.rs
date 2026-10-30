use crate::modrinth::{self, Downloader};
use crate::prism::{self, Prism};
use crate::util::{self, note, step, Config};
use anyhow::{bail, Context, Result};
use clap::{Args, ValueEnum};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, ValueEnum)]
pub enum ControllerMod {
    Controlify,
    Midnightcontrols,
}

impl ControllerMod {
    fn slug(self) -> &'static str {
        match self {
            Self::Controlify => "controlify",
            Self::Midnightcontrols => "midnightcontrols",
        }
    }
}

#[derive(Args)]
pub struct SetupArgs {
    /// Number of players
    #[arg(short, long, default_value_t = 4, value_parser = clap::value_parser!(u32).range(1..=4))]
    pub players: u32,
    /// Minecraft version (default: newest supported by all core mods)
    #[arg(short = 'v', long)]
    pub mc_version: Option<String>,
    /// Max RAM per joining instance in MB (default: auto)
    #[arg(short, long)]
    pub memory: Option<u64>,
    /// Prism account names in player order (default: Microsoft accounts first, then offline)
    #[arg(short, long, value_delimiter = ',')]
    pub accounts: Vec<String>,
    /// Names for offline accounts created for players without one (default: Player2, Player3, ...)
    #[arg(long, value_delimiter = ',')]
    pub offline_names: Vec<String>,
    /// Don't create offline accounts or add OfflineLAN
    #[arg(long)]
    pub no_offline: bool,
    #[arg(short, long, value_enum, default_value_t = ControllerMod::Controlify)]
    pub controller_mod: ControllerMod,
    /// Prism data folder (default: auto-detect)
    #[arg(long)]
    pub prism_data: Option<PathBuf>,
    /// Path to the Prism executable (default: auto-detect, installing if missing)
    #[arg(long)]
    pub prism_exe: Option<PathBuf>,
    /// Instance name prefix
    #[arg(long, default_value = "Splitscreen-P")]
    pub prefix: String,
    /// Seconds between launching instances
    #[arg(long, default_value_t = 20)]
    pub delay: u64,
    /// Rebuild existing instances (replaces mods/pack; keeps saves and options.txt)
    #[arg(long)]
    pub force: bool,
    /// Don't install Prism Launcher if it's missing
    #[arg(long)]
    pub skip_install: bool,
    /// Don't create a desktop shortcut / app menu entry
    #[arg(long)]
    pub no_shortcut: bool,
    /// Linux: isolate controllers with bubblewrap (each window sees only its own pad)
    #[arg(long, conflicts_with = "no_sandbox")]
    pub sandbox: bool,
    /// Linux: turn sandbox mode back off for existing instances
    #[arg(long)]
    pub no_sandbox: bool,
}

const PERF_MODS: [&str; 5] = ["lithium", "ferrite-core", "modernfix", "immediatelyfast", "entityculling"];

pub fn run(args: SetupArgs) -> Result<()> {
    if args.sandbox && !cfg!(target_os = "linux") {
        bail!("--sandbox is Linux-only; on Windows the controller mod assigns pads");
    }
    let previous = Config::load().ok();
    let sandbox = args.sandbox || (!args.no_sandbox && previous.as_ref().is_some_and(|c| c.sandbox));

    // 1. Prism
    let prism = prism::ensure(args.prism_exe.as_deref(), args.prism_data.as_deref(), args.skip_install, sandbox)?;
    #[cfg(target_os = "linux")]
    {
        if prism.is_flatpak {
            if sandbox {
                bail!("The Prism Flatpak can't run bwrap; install native Prism (or drop --sandbox)");
            }
            prism::configure_flatpak();
        }
        if sandbox {
            crate::sandbox::check_bwrap()?;
        }
    }
    prism::wait_for_account(&prism)?;
    let inst_dir = prism.instances_dir();
    fs::create_dir_all(&inst_dir)?;

    // 2. Accounts
    let (accounts, uses_offline) = pick_accounts(&prism, &args)?;

    // 3. Versions
    let mut core = vec!["fabric-api".to_string(), args.controller_mod.slug().into(), "mc-splitscreen".into(), "sodium".into()];
    if uses_offline {
        // Lets the host turn off online-mode in the Open to LAN screen so offline players can join
        core.push("offlinelan".into());
    }
    let mc = match &args.mc_version {
        Some(v) => v.clone(),
        None => {
            step(format!("Finding newest Minecraft version supported by: {}", core.join(", ")));
            modrinth::best_mc_version(&core)?
        }
    };
    let loader = modrinth::latest_fabric_loader()?;
    step(format!("Minecraft {mc}, Fabric loader {loader}"));

    // 4. Memory
    let total = util::total_ram_mb();
    // Windows itself needs more headroom than a light Linux desktop
    let reserve = if cfg!(windows) { 4096 } else { 3072 };
    let mut mem = args.memory.unwrap_or_else(|| (total.saturating_sub(reserve) / u64::from(args.players)).min(3072));
    if mem < 2048 {
        note(format!("Only ~{mem} MB per instance ({total} MB total). Consider fewer players."));
        mem = mem.max(1536);
    }
    let host_mem = (mem + 512).min(3584);
    step(format!("RAM: host {host_mem} MB, others {mem} MB (system {total} MB)"));

    // 5. Mods
    let cache = std::env::temp_dir().join(format!("mc-splitscreen-{}", std::process::id()));
    fs::create_dir_all(&cache)?;
    let result = (|| -> Result<Vec<String>> {
        step("Downloading mods");
        let mut dl = Downloader::new(&mc, &cache);
        for m in &core {
            dl.fetch(m, true)?;
        }
        for m in PERF_MODS {
            dl.fetch(m, false)?;
        }

        // 6. Instances
        let exe = install_self()?;
        let mut instances = Vec::new();
        for i in 1..=args.players {
            let id = format!("{}{i}", args.prefix);
            let dir = inst_dir.join(&id);
            let fresh = !dir.exists();
            if fresh || args.force {
                step(format!("{} instance {id}", if fresh { "Creating" } else { "Rebuilding" }));
            } else {
                note(format!("{id} already exists; keeping its mods (use --force to rebuild)"));
            }
            let inst = Instance { dir: &dir, player: i, mc: &mc, loader: &loader, mem: if i == 1 { host_mem } else { mem } };
            inst.write(fresh || args.force, &cache, sandbox.then_some(exe.as_path()))?;
            instances.push(id);
        }
        Ok(instances)
    })();
    let _ = fs::remove_dir_all(&cache);
    let instances = result?;

    // 7. Config + shortcut
    let config = Config {
        prism: prism.cmd.clone(),
        instances: instances.clone(),
        accounts: accounts.into_iter().take(args.players as usize).collect(),
        delay: args.delay,
        sandbox,
    };
    config.save()?;
    let exe = install_self()?;
    let shortcut = if args.no_shortcut { exe.clone() } else { make_shortcut(&exe)? };

    step("Done!");
    let lan = if uses_offline {
        "Open to LAN, switch Online Mode OFF, then Apply Changes (offline players get kicked otherwise)."
    } else {
        "Open to LAN, then Apply Changes."
    };
    let pads = if sandbox {
        "Turn on Controlify's out-of-focus / unfocused input (each window only sees its own controller)."
    } else {
        "Open the controller mod's settings, pick that player's controller, and turn on\n     out-of-focus / unfocused input."
    };
    println!(
        "  Instances : {}  (in {})\n  Shortcut  : {}\n\n\
         First-time setup in each window (settings are saved afterwards):\n  \
         1. Press F11 until the window snaps to its quarter of the screen.\n  \
         2. {pads}\n  \
         3. Player 1: create a world, then Pause > {lan}\n  \
         4. Players 2-{}: Multiplayer > Direct Connection > localhost:<port shown on P1's screen>.\n\n\
         Tip: disable Steam Input for Prism so it doesn't create duplicate virtual controllers.",
        instances.join(", "),
        inst_dir.display(),
        shortcut.display(),
        args.players
    );

    #[cfg(target_os = "linux")]
    if sandbox && util::confirm("\nAssign controllers to players now?", true) {
        // Setup itself succeeded; pads can be assigned later
        if let Err(e) = crate::sandbox::assign(args.players) {
            note(format!("{e:#}\n    Run `mc-splitscreen assign` once the controllers are connected."));
        }
    }
    if util::confirm("\nLaunch splitscreen now?", true) {
        crate::launch::run(None)?;
    }
    Ok(())
}

/// Accounts in player order, creating offline ones for players without an
/// account. Returns (accounts, any player uses an offline account).
fn pick_accounts(prism: &Prism, args: &SetupArgs) -> Result<(Vec<String>, bool)> {
    let known = prism::accounts(prism);
    let mut accounts = if args.accounts.is_empty() {
        known.iter().map(|a| a.name.clone()).collect()
    } else {
        args.accounts.clone()
    };
    accounts.truncate(args.players as usize);

    if !args.no_offline {
        let mut to_add = Vec::new();
        let mut names = args.offline_names.iter();
        while accounts.len() < args.players as usize {
            let name = names.next().cloned().unwrap_or_else(|| format!("Player{}", accounts.len() + 1));
            if !prism::valid_offline_name(&name) {
                bail!("Offline name '{name}' must be 3-16 letters, digits or _");
            }
            if accounts.iter().any(|a| a.eq_ignore_ascii_case(&name)) {
                bail!("Account '{name}' is already assigned to another player");
            }
            if !known.iter().any(|a| a.name.eq_ignore_ascii_case(&name)) {
                to_add.push(name.clone());
            }
            accounts.push(name);
        }
        if !to_add.is_empty() {
            step(format!("Adding offline Prism accounts: {}", to_add.join(", ")));
            prism::add_offline_accounts(prism, &to_add)?;
        }
    }
    if accounts.len() < args.players as usize {
        note(format!(
            "Only {} account(s) for {} players. Each player needs their own account to join the LAN world.",
            accounts.len(),
            args.players
        ));
    }

    let known = prism::accounts(prism);
    let uses_offline = accounts.iter().any(|n| known.iter().any(|a| a.offline && a.name.eq_ignore_ascii_case(n)));
    Ok((accounts, uses_offline))
}

struct Instance<'a> {
    dir: &'a Path,
    player: u32,
    mc: &'a str,
    loader: &'a str,
    mem: u64,
}

impl Instance<'_> {
    /// `rebuild` replaces mods and the component pack; config is always updated.
    /// `wrapper` is this program's path when sandbox mode is on.
    fn write(&self, rebuild: bool, cache: &Path, wrapper: Option<&Path>) -> Result<()> {
        // Prism uses `minecraft`; older MultiMC-style instances use `.minecraft`
        let game = if self.dir.join(".minecraft").is_dir() { self.dir.join(".minecraft") } else { self.dir.join("minecraft") };
        let mods = game.join("mods");
        fs::create_dir_all(&mods)?;

        if rebuild {
            for e in fs::read_dir(&mods)?.flatten() {
                if e.path().extension().is_some_and(|x| x == "jar") {
                    fs::remove_file(e.path())?;
                }
            }
            for e in fs::read_dir(cache)?.flatten() {
                fs::copy(e.path(), mods.join(e.file_name()))?;
            }
            // Only MC + loader; Prism resolves intermediary/LWJGL itself
            let pack = json!({
                "components": [
                    { "important": true, "uid": "net.minecraft", "version": self.mc },
                    { "uid": "net.fabricmc.fabric-loader", "version": self.loader }
                ],
                "formatVersion": 1
            });
            util::write_text(&self.dir.join("mmc-pack.json"), &serde_json::to_string_pretty(&pack)?)?;
        }

        let cfg = self.dir.join("instance.cfg");
        let mut values = vec![
            ("ConfigVersion", "1.3".to_string()),
            ("InstanceType", "OneSix".into()),
            ("name", format!("Splitscreen P{}", self.player)),
            ("iconKey", "default".into()),
            ("OverrideMemory", "true".into()),
            ("MinMemAlloc", "512".into()),
            ("MaxMemAlloc", self.mem.to_string()),
            ("OverrideJavaArgs", "true".into()),
            ("JvmArgs", "-XX:+UseG1GC -XX:MaxGCPauseMillis=50 -XX:+ParallelRefProcEnabled".into()),
        ];
        match wrapper {
            Some(exe) => {
                let exe = exe.to_string_lossy();
                let exe = if exe.contains(' ') { format!("\"{exe}\"") } else { exe.into_owned() };
                values.push(("OverrideCommands", "true".into()));
                values.push(("WrapperCommand", format!("{exe} wrap {}", self.player)));
            }
            // Only undo our own wrapper, never one the user set
            None if fs::read_to_string(&cfg).unwrap_or_default().lines().any(|l| l.starts_with("WrapperCommand=") && l.contains(" wrap ")) => {
                values.push(("OverrideCommands", "false".into()));
                values.push(("WrapperCommand", String::new()));
            }
            None => {}
        }
        util::set_cfg(&cfg, &values)?;

        let opts = game.join("options.txt");
        if !opts.exists() {
            let music = if self.player == 1 { "1.0" } else { "0.0" };
            util::write_text(
                &opts,
                &format!(
                    "pauseOnLostFocus:false\nfullscreen:false\nrenderDistance:8\nsimulationDistance:6\n\
                     maxFps:60\nenableVsync:false\ngraphicsMode:0\nrenderClouds:\"false\"\nao:false\n\
                     entityShadows:false\nparticles:2\nbiomeBlendRadius:0\nsoundCategory_music:{music}\n\
                     onboardAccessibility:false\nskipMultiplayerWarnings:true\njoinedFirstServer:true\n\
                     tutorialStep:none\nnarrator:0\n"
                ),
            )?;
        }
        Ok(())
    }
}

/// Copy this program to ~/MinecraftSplitscreen so shortcuts and Prism's
/// wrapper command keep working if the download is moved or deleted
fn install_self() -> Result<PathBuf> {
    let current = std::env::current_exe()?;
    let name = if cfg!(windows) { "mc-splitscreen.exe" } else { "mc-splitscreen" };
    let target = util::out_dir().join(name);
    fs::create_dir_all(util::out_dir())?;
    let same = fs::canonicalize(&current).ok() == fs::canonicalize(&target).ok();
    if !same {
        // Can't overwrite a running exe on Windows, but can rename it out of the way
        if target.exists() {
            let old = target.with_extension("old");
            let _ = fs::remove_file(&old);
            let _ = fs::rename(&target, &old);
        }
        fs::copy(&current, &target).with_context(|| format!("installing to {}", target.display()))?;
    }
    Ok(target)
}

#[cfg(windows)]
fn make_shortcut(exe: &Path) -> Result<PathBuf> {
    // PowerShell resolves the real Desktop (it may be redirected to OneDrive);
    // paths go through env vars so no quoting can break the script
    let out = std::process::Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Minecraft Splitscreen.lnk'; \
             $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); \
             $s.TargetPath = $env:MCS_EXE; $s.Arguments = 'launch'; \
             $s.WorkingDirectory = $env:MCS_DIR; $s.Save(); $lnk",
        ])
        .env("MCS_EXE", exe)
        .env("MCS_DIR", util::out_dir())
        .output()?;
    if !out.status.success() {
        note("Couldn't create the desktop shortcut");
    }
    Ok(PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()))
}

#[cfg(not(windows))]
fn make_shortcut(exe: &Path) -> Result<PathBuf> {
    let desktop = util::data_home().join("applications/minecraft-splitscreen.desktop");
    fs::create_dir_all(desktop.parent().unwrap())?;
    util::write_text(
        &desktop,
        &format!(
            "[Desktop Entry]\nType=Application\nName=Minecraft Splitscreen\n\
             Comment=Launch splitscreen Minecraft\nExec=\"{}\" launch\nIcon=applications-games\n\
             Terminal=false\nCategories=Game;\n",
            exe.display()
        ),
    )?;
    Ok(desktop)
}
