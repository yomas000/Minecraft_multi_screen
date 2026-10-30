use crate::util::{self, note, step};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const RELEASES_API: &str = "https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest";

pub struct Prism {
    /// Command + leading args used to run Prism (e.g. `flatpak run ...`)
    pub cmd: Vec<String>,
    pub data_dir: PathBuf,
    /// The Flatpak can't run bwrap inside its own sandbox
    #[cfg_attr(windows, allow(dead_code))]
    pub is_flatpak: bool,
}

impl Prism {
    pub fn command(&self) -> Command {
        let mut c = Command::new(&self.cmd[0]);
        c.args(&self.cmd[1..]);
        c
    }

    pub fn accounts_file(&self) -> PathBuf {
        self.data_dir.join("accounts.json")
    }

    /// Instance folder, honoring a custom InstanceDir in prismlauncher.cfg
    pub fn instances_dir(&self) -> PathBuf {
        let cfg = fs::read_to_string(self.data_dir.join("prismlauncher.cfg")).unwrap_or_default();
        for line in cfg.lines() {
            if let Some(v) = line.strip_prefix("InstanceDir=") {
                let v = v.trim();
                if !v.is_empty() {
                    let p = PathBuf::from(v);
                    return if p.is_absolute() { p } else { self.data_dir.join(p) };
                }
            }
        }
        self.data_dir.join("instances")
    }
}

// ---------------------------------------------------------------- find/install

/// Find Prism, installing it if missing (unless `skip_install`).
/// `need_native` rules out the Flatpak (sandbox mode).
pub fn ensure(exe: Option<&Path>, data_dir: Option<&Path>, skip_install: bool, need_native: bool) -> Result<Prism> {
    let mut prism = match exe {
        Some(p) => Some(native(p.to_path_buf())),
        None => find(need_native),
    };
    if prism.is_none() && !skip_install {
        prism = Some(install(need_native)?);
    }
    let Some(mut prism) = prism else {
        bail!("Prism Launcher not found. Install it from https://prismlauncher.org or pass --prism-exe");
    };
    if let Some(d) = data_dir {
        prism.data_dir = d.to_path_buf();
    }
    step(format!("Prism Launcher: {}", prism.cmd.join(" ")));
    Ok(prism)
}

#[cfg(windows)]
fn appdata_prism() -> PathBuf {
    util::appdata().join("PrismLauncher")
}

#[cfg(not(windows))]
fn datahome_prism() -> PathBuf {
    util::data_home().join("PrismLauncher")
}

fn native(exe: PathBuf) -> Prism {
    // Portable installs keep their data next to the executable
    let exe_dir = exe.parent().map(Path::to_path_buf).unwrap_or_default();
    let data_dir = if exe_dir.join("portable.txt").exists() {
        exe_dir
    } else {
        #[cfg(windows)]
        let d = appdata_prism();
        #[cfg(not(windows))]
        let d = datahome_prism();
        d
    };
    Prism { cmd: vec![exe.to_string_lossy().into_owned()], data_dir, is_flatpak: false }
}

fn on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(name)).find(|p| p.is_file())
}

#[cfg(windows)]
fn find(_need_native: bool) -> Option<Prism> {
    let local = util::local_appdata();
    let mut candidates = vec![local.join(r"Programs\PrismLauncher\prismlauncher.exe")];
    for var in ["ProgramFiles", "ProgramFiles(x86)"] {
        if let Some(pf) = std::env::var_os(var) {
            candidates.push(PathBuf::from(pf).join(r"PrismLauncher\prismlauncher.exe"));
        }
    }
    // winget's portable/scoop-style installs land on PATH
    candidates.extend(on_path("prismlauncher.exe"));
    candidates.into_iter().find(|p| p.is_file()).map(native)
}

#[cfg(not(windows))]
fn find(need_native: bool) -> Option<Prism> {
    if let Some(p) = on_path("prismlauncher") {
        return Some(native(p));
    }
    let appimage = appimage_apprun();
    if appimage.is_file() {
        return Some(native_appimage(appimage));
    }
    if !need_native && flatpak_installed() {
        return Some(flatpak());
    }
    None
}

#[cfg(windows)]
fn install(_need_native: bool) -> Result<Prism> {
    step("Installing Prism Launcher");
    let winget_ok = Command::new("winget")
        .args(["install", "--id", "PrismLauncher.PrismLauncher", "-e", "--accept-source-agreements", "--accept-package-agreements"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !winget_ok {
        note("winget unavailable or failed; using the installer from GitHub");
        let arch = if cfg!(target_arch = "aarch64") { "MSVC-arm64-Setup" } else { "MSVC-Setup" };
        let asset = release_asset(|n| n.ends_with(".exe") && n.contains("Windows") && n.contains("Setup") && n.contains(arch))?;
        let setup = std::env::temp_dir().join("PrismLauncher-Setup.exe");
        util::download(&asset, &setup)?;
        // NSIS silent install, per-user into %LOCALAPPDATA%\Programs
        let ok = Command::new(&setup).arg("/S").status()?.success();
        let _ = fs::remove_file(&setup);
        if !ok {
            bail!("Prism installer failed");
        }
    }
    find(false).context("Prism was installed but prismlauncher.exe wasn't found; pass --prism-exe")
}

#[cfg(not(windows))]
fn install(need_native: bool) -> Result<Prism> {
    step("Installing Prism Launcher");
    if on_path("pacman").is_some() {
        let ok = Command::new("sudo")
            .args(["pacman", "-S", "--needed", "--noconfirm", "prismlauncher"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            if let Some(p) = on_path("prismlauncher") {
                return Ok(native(p));
            }
        }
        note("pacman install failed; falling back to the AppImage");
    }
    if let Ok(p) = install_appimage() {
        return Ok(p);
    }
    if !need_native && on_path("flatpak").is_some() {
        note("AppImage install failed; trying Flatpak");
        let ok = Command::new("flatpak")
            .args(["install", "--user", "-y", "flathub", "org.prismlauncher.PrismLauncher"])
            .status()?
            .success();
        if ok {
            let p = flatpak();
            configure_flatpak();
            return Ok(p);
        }
    }
    bail!("Couldn't install Prism Launcher automatically. Install it from https://prismlauncher.org and re-run")
}

/// Latest GitHub release asset URL whose name matches
fn release_asset(matches: impl Fn(&str) -> bool) -> Result<String> {
    let rel = util::get_json(RELEASES_API)?;
    rel["assets"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|a| a["name"].as_str().is_some_and(&matches))
        .and_then(|a| a["browser_download_url"].as_str().map(String::from))
        .context("no matching Prism release download")
}

#[cfg(not(windows))]
fn appimage_dir() -> PathBuf {
    util::data_home().join("mc-splitscreen").join("prism")
}

#[cfg(not(windows))]
fn appimage_apprun() -> PathBuf {
    appimage_dir().join("squashfs-root").join("AppRun")
}

#[cfg(not(windows))]
fn native_appimage(apprun: PathBuf) -> Prism {
    Prism {
        cmd: vec![apprun.to_string_lossy().into_owned()],
        data_dir: util::data_home().join("PrismLauncher"),
        is_flatpak: false,
    }
}

/// Download and extract the official AppImage. Extracting means FUSE isn't
/// needed, and the result is an ordinary native install (works with bwrap).
#[cfg(not(windows))]
fn install_appimage() -> Result<Prism> {
    use std::os::unix::fs::PermissionsExt;
    let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
    let url = release_asset(|n| n.ends_with(".AppImage") && n.contains(arch))?;
    let dir = appimage_dir();
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir)?;
    let file = dir.join("PrismLauncher.AppImage");
    util::download(&url, &file)?;
    fs::set_permissions(&file, fs::Permissions::from_mode(0o755))?;
    let ok = Command::new(&file)
        .arg("--appimage-extract")
        .current_dir(&dir)
        .stdout(std::process::Stdio::null())
        .status()?
        .success();
    let _ = fs::remove_file(&file);
    let apprun = appimage_apprun();
    if !ok || !apprun.is_file() {
        bail!("extracting the Prism AppImage failed");
    }
    Ok(native_appimage(apprun))
}

#[cfg(not(windows))]
const FLATPAK_ID: &str = "org.prismlauncher.PrismLauncher";

#[cfg(not(windows))]
fn flatpak_installed() -> bool {
    on_path("flatpak").is_some()
        && Command::new("flatpak")
            .args(["info", FLATPAK_ID])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
}

#[cfg(not(windows))]
fn flatpak() -> Prism {
    Prism {
        cmd: vec!["flatpak".into(), "run".into(), FLATPAK_ID.into()],
        data_dir: util::home().join(".var/app").join(FLATPAK_ID).join("data/PrismLauncher"),
        is_flatpak: true,
    }
}

/// Let the Flatpak sandbox see every controller
#[cfg(not(windows))]
pub fn configure_flatpak() {
    let _ = Command::new("flatpak").args(["override", "--user", "--device=all", FLATPAK_ID]).status();
}

// ---------------------------------------------------------------- accounts

#[derive(Clone, Debug)]
pub struct Account {
    pub name: String,
    pub offline: bool,
}

fn read_accounts_json(path: &Path) -> Result<Value> {
    let text = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))
}

/// Accounts in Prism, Microsoft accounts first so P1 (the LAN host) gets a real one
pub fn accounts(prism: &Prism) -> Vec<Account> {
    let Ok(v) = read_accounts_json(&prism.accounts_file()) else { return Vec::new() };
    let mut list: Vec<Account> = v["accounts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|a| {
            let name = a["profile"]["name"].as_str()?.to_string();
            Some(Account { name, offline: a["type"].as_str() == Some("Offline") })
        })
        .collect();
    list.sort_by_key(|a| a.offline); // stable: keeps Prism's order within each group
    list
}

/// Open Prism until the user has added at least one Microsoft account
pub fn wait_for_account(prism: &Prism) -> Result<()> {
    if accounts(prism).iter().any(|a| !a.offline) {
        return Ok(());
    }
    note("Prism has no Microsoft account yet.");
    step("Opening Prism. Finish the first-run wizard, add a Microsoft account that owns");
    step("Minecraft (Settings > Accounts), then CLOSE Prism to continue.");
    prism.command().spawn().context("starting Prism")?;
    sleep(Duration::from_secs(5));
    while util::prism_running() {
        sleep(Duration::from_secs(2));
    }
    if !accounts(prism).iter().any(|a| !a.offline) {
        bail!("Still no Microsoft account in {}", prism.accounts_file().display());
    }
    Ok(())
}

/// Java's UUID.nameUUIDFromBytes("OfflinePlayer:<name>"), as Prism and the server compute it
pub fn offline_uuid(name: &str) -> String {
    let mut b = md5::compute(format!("OfflinePlayer:{name}")).0;
    b[6] = (b[6] & 0x0f) | 0x30;
    b[8] = (b[8] & 0x3f) | 0x80;
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn valid_offline_name(name: &str) -> bool {
    (3..=16).contains(&name.len()) && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Random-enough 32-hex client token (Prism uses a v4 UUID; nothing checks it)
fn client_token(name: &str) -> String {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default();
    format!("{:x}", md5::compute(format!("{name}:{nanos}:{}", std::process::id())))
}

/// Add offline accounts in the same shape Prism saves for Settings > Accounts > Add Offline
pub fn add_offline_accounts(prism: &Prism, names: &[String]) -> Result<()> {
    if util::prism_running() {
        bail!("Close Prism Launcher first (it rewrites accounts.json on exit), then re-run.");
    }
    let path = prism.accounts_file();
    let mut v = read_accounts_json(&path)?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let list = v["accounts"].as_array_mut().context("accounts.json has no accounts list")?;
    for name in names {
        list.push(json!({
            "type": "Offline",
            "ygg": {
                "iat": now,
                "token": "0",
                "extra": { "clientToken": client_token(name), "userName": name }
            },
            "profile": {
                "id": offline_uuid(name),
                "name": name,
                // Prism drops a profile without a skin object
                "skin": { "id": "", "url": "", "variant": "" },
                "capes": []
            },
            "entitlement": { "canPlayMinecraft": true, "ownsMinecraft": true }
        }));
    }
    fs::copy(&path, path.with_extension("json.bak"))?;
    util::write_text(&path, &serde_json::to_string_pretty(&v)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offline_uuid_matches_java() {
        assert_eq!(offline_uuid("Notch"), "b50ad385829d3141a2167e7d7539ba7f");
        assert_eq!(offline_uuid("Player2"), "aed5efd4551b3965bc28ae21aa072a66");
    }

    #[test]
    fn offline_names() {
        assert!(valid_offline_name("Player_2"));
        assert!(!valid_offline_name("ab"));
        assert!(!valid_offline_name("has space"));
    }
}
