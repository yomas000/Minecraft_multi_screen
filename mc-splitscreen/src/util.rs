use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::fs;
use std::io::{self, BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

pub const USER_AGENT: &str = concat!(
    "mc-splitscreen/",
    env!("CARGO_PKG_VERSION"),
    " (Prism Launcher splitscreen helper)"
);

pub fn step(msg: impl AsRef<str>) {
    println!("==> {}", msg.as_ref());
}

pub fn note(msg: impl AsRef<str>) {
    eprintln!("!!  {}", msg.as_ref());
}

fn env_dir(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).filter(|v| !v.is_empty()).map(PathBuf::from)
}

pub fn home() -> PathBuf {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    env_dir(var).expect("no home directory")
}

/// %APPDATA%
#[cfg(windows)]
pub fn appdata() -> PathBuf {
    env_dir("APPDATA").unwrap_or_else(|| home().join(r"AppData\Roaming"))
}

/// %LOCALAPPDATA%
#[cfg(windows)]
pub fn local_appdata() -> PathBuf {
    env_dir("LOCALAPPDATA").unwrap_or_else(|| home().join(r"AppData\Local"))
}

/// $XDG_DATA_HOME, usually ~/.local/share
#[cfg(not(windows))]
pub fn data_home() -> PathBuf {
    env_dir("XDG_DATA_HOME").unwrap_or_else(|| home().join(".local/share"))
}

/// ~/MinecraftSplitscreen: config, installed binary, controller assignments
pub fn out_dir() -> PathBuf {
    home().join("MinecraftSplitscreen")
}

fn curl(url: &str) -> Command {
    let mut c = Command::new(if cfg!(windows) { "curl.exe" } else { "curl" });
    c.args(["-fsSL", "--retry", "2", "--connect-timeout", "20", "-A", USER_AGENT, url]);
    c
}

fn run_curl(mut c: Command, url: &str) -> Result<Vec<u8>> {
    let out = c.output().context("curl is required (it ships with Windows 10+ and most Linux distros)")?;
    if !out.status.success() {
        bail!("GET {url} failed: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(out.stdout)
}

pub fn get_json(url: &str) -> Result<Value> {
    let body = run_curl(curl(url), url)?;
    serde_json::from_slice(&body).with_context(|| format!("parsing JSON from {url}"))
}

pub fn download(url: &str, dest: &Path) -> Result<()> {
    let mut c = curl(url);
    c.arg("-o").arg(dest);
    run_curl(c, url).map(drop)
}

#[cfg(windows)]
pub fn total_ram_mb() -> u64 {
    #[repr(C)]
    struct MemoryStatusEx {
        length: u32,
        memory_load: u32,
        total_phys: u64,
        avail_phys: u64,
        total_page_file: u64,
        avail_page_file: u64,
        total_virtual: u64,
        avail_virtual: u64,
        avail_extended_virtual: u64,
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GlobalMemoryStatusEx(buffer: *mut MemoryStatusEx) -> i32;
    }
    let mut m = MemoryStatusEx {
        length: std::mem::size_of::<MemoryStatusEx>() as u32,
        memory_load: 0,
        total_phys: 0,
        avail_phys: 0,
        total_page_file: 0,
        avail_page_file: 0,
        total_virtual: 0,
        avail_virtual: 0,
        avail_extended_virtual: 0,
    };
    // SAFETY: m is a correctly sized MEMORYSTATUSEX with length set
    if unsafe { GlobalMemoryStatusEx(&mut m) } == 0 {
        return 8192;
    }
    m.total_phys / 1024 / 1024
}

#[cfg(not(windows))]
pub fn total_ram_mb() -> u64 {
    fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("MemTotal:"))?.split_whitespace().nth(1)?.parse::<u64>().ok())
        .map_or(8192, |kb| kb / 1024)
}

#[cfg(windows)]
pub fn prism_running() -> bool {
    Command::new("tasklist")
        .args(["/FI", "IMAGENAME eq prismlauncher.exe", "/NH"])
        .output()
        .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).to_lowercase().contains("prismlauncher.exe"))
}

#[cfg(not(windows))]
pub fn prism_running() -> bool {
    fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .any(|e| fs::read_to_string(e.path().join("comm")).is_ok_and(|c| c.trim() == "prismlauncher"))
}

pub fn interactive() -> bool {
    io::stdin().is_terminal()
}

/// Yes/no prompt; `default` on empty input, always no when not interactive
pub fn confirm(question: &str, default: bool) -> bool {
    if !interactive() {
        return false;
    }
    print!("{question} {} ", if default { "[Y/n]" } else { "[y/N]" });
    let _ = io::stdout().flush();
    let mut line = String::new();
    if io::stdin().lock().read_line(&mut line).is_err() {
        return default;
    }
    match line.trim().chars().next() {
        Some('y' | 'Y') => true,
        Some('n' | 'N') => false,
        _ => default,
    }
}

/// Write text with LF endings and no BOM (Prism's parsers dislike BOMs)
pub fn write_text(path: &Path, text: &str) -> Result<()> {
    fs::write(path, text.replace("\r\n", "\n")).with_context(|| format!("writing {}", path.display()))
}

/// Set keys in the [General] section of a Prism instance.cfg, keeping
/// everything else (uuid, play time, UI state) as Prism wrote it.
pub fn set_cfg(path: &Path, values: &[(&str, String)]) -> Result<()> {
    let text = fs::read_to_string(path).unwrap_or_default();
    let mut out = Vec::new();
    let mut done = vec![false; values.len()];
    let mut in_general = false;
    let mut saw_general = false;

    let flush = |out: &mut Vec<String>, done: &mut Vec<bool>| {
        for (i, (k, v)) in values.iter().enumerate() {
            if !done[i] {
                out.push(format!("{k}={v}"));
                done[i] = true;
            }
        }
    };

    for line in text.lines() {
        if line.starts_with('[') {
            if in_general {
                flush(&mut out, &mut done);
            }
            in_general = line.trim() == "[General]";
            saw_general |= in_general;
            out.push(line.to_string());
            continue;
        }
        if in_general {
            if let Some((i, _)) = values
                .iter()
                .enumerate()
                .find(|(_, (k, _))| line.split_once('=').is_some_and(|(lk, _)| lk == *k))
            {
                if !done[i] {
                    out.push(format!("{}={}", values[i].0, values[i].1));
                    done[i] = true;
                }
                continue;
            }
        }
        out.push(line.to_string());
    }
    if !saw_general {
        out.insert(0, "[General]".to_string());
        let mut extra = Vec::new();
        flush(&mut extra, &mut done);
        out.splice(1..1, extra);
    } else {
        flush(&mut out, &mut done);
    }
    write_text(path, &(out.join("\n") + "\n"))
}

/// Saved by `setup`, read by `launch` (and by `wrap` for its paths)
pub struct Config {
    pub prism: Vec<String>,
    pub instances: Vec<String>,
    pub accounts: Vec<String>,
    pub delay: u64,
    pub sandbox: bool,
}

impl Config {
    pub fn path() -> PathBuf {
        out_dir().join("config.json")
    }

    pub fn load() -> Result<Self> {
        let path = Self::path();
        let text = fs::read_to_string(&path)
            .with_context(|| format!("reading {} (run `mc-splitscreen setup` first)", path.display()))?;
        let v: Value = serde_json::from_str(&text)?;
        let strings = |key: &str| -> Vec<String> {
            v[key].as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect()).unwrap_or_default()
        };
        Ok(Self {
            prism: strings("prism"),
            instances: strings("instances"),
            accounts: strings("accounts"),
            delay: v["delay"].as_u64().unwrap_or(20),
            sandbox: v["sandbox"].as_bool().unwrap_or(false),
        })
    }

    pub fn save(&self) -> Result<()> {
        fs::create_dir_all(out_dir())?;
        let v = serde_json::json!({
            "prism": self.prism,
            "instances": self.instances,
            "accounts": self.accounts,
            "delay": self.delay,
            "sandbox": self.sandbox,
        });
        write_text(&Self::path(), &serde_json::to_string_pretty(&v)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_cfg_updates_general_only() {
        let dir = std::env::temp_dir().join(format!("mcs-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let p = dir.join("instance.cfg");
        fs::write(&p, "[General]\nname=Old\nuuid=abc\n\n[UI]\nname=ui\n").unwrap();
        set_cfg(&p, &[("name", "New".into()), ("WrapperCommand", "/x wrap 1".into())]).unwrap();
        let out = fs::read_to_string(&p).unwrap();
        assert_eq!(out, "[General]\nname=New\nuuid=abc\n\nWrapperCommand=/x wrap 1\n[UI]\nname=ui\n");

        let q = dir.join("new.cfg");
        set_cfg(&q, &[("a", "1".into())]).unwrap();
        assert_eq!(fs::read_to_string(&q).unwrap(), "[General]\na=1\n");
        fs::remove_dir_all(&dir).unwrap();
    }
}
