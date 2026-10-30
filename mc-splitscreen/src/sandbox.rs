//! Linux-only controller isolation: each instance runs Java inside bubblewrap
//! with a private /dev that holds only that player's controller (plus GPU and
//! audio), so no window can see or grab anyone else's pad.

use crate::util::{self, note, step};
use anyhow::{bail, Context, Result};
use std::collections::HashSet;
use std::fs;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;

fn controllers_conf() -> PathBuf {
    util::out_dir().join("controllers.conf")
}

fn sys_input(node: &str) -> PathBuf {
    Path::new("/sys/class/input").join(node)
}

fn read_trim(p: &Path) -> String {
    fs::read_to_string(p).map(|s| s.trim().to_string()).unwrap_or_default()
}

/// udev tags joysticks/gamepads with ID_INPUT_JOYSTICK; read its database
/// directly so we don't depend on udevadm. Falls back to a joydev js node.
fn is_pad(ev: &str) -> bool {
    let dev = read_trim(&sys_input(ev).join("dev")); // "13:69"
    if let Ok(db) = fs::read_to_string(format!("/run/udev/data/c{dev}")) {
        return db.lines().any(|l| l == "E:ID_INPUT_JOYSTICK=1");
    }
    fs::read_dir(sys_input(ev).join("device"))
        .into_iter()
        .flatten()
        .flatten()
        .any(|e| e.file_name().to_string_lossy().starts_with("js"))
}

fn node_number(name: &str) -> u32 {
    name.trim_start_matches(|c: char| !c.is_ascii_digit()).parse().unwrap_or(u32::MAX)
}

/// Event node names (event5, ...) of physical controllers, in kernel order
pub fn list_pads() -> Vec<String> {
    let mut pads: Vec<String> = fs::read_dir("/sys/class/input")
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("event"))
        // Steam Input and other uinput pads live under /sys/devices/virtual
        .filter(|n| !fs::canonicalize(sys_input(n)).is_ok_and(|p| p.to_string_lossy().contains("/virtual/")))
        .filter(|n| is_pad(n))
        .collect();
    pads.sort_by_key(|n| node_number(n));
    pads
}

pub fn pad_name(ev: &str) -> String {
    let n = read_trim(&sys_input(ev).join("device/name"));
    if n.is_empty() { ev.to_string() } else { n }
}

/// Stable id that survives reboots and replugging: uniq is the Bluetooth
/// MAC / USB serial, phys is the USB port path
fn pad_id(ev: &str) -> String {
    let d = sys_input(ev).join("device");
    format!("{}|{}", read_trim(&d.join("uniq")), read_trim(&d.join("phys")))
}

fn find_pad(id: &str) -> Option<String> {
    list_pads().into_iter().find(|ev| pad_id(ev) == id)
}

/// Every /dev node of the controller that owns `ev`: sibling event nodes
/// (motion sensors, touchpad), js nodes, and hidraw nodes (SDL's HIDAPI
/// drivers read PlayStation/Switch/Xbox pads through hidraw, not evdev)
fn pad_nodes(ev: &str) -> Vec<String> {
    let parent = |node: &str| fs::canonicalize(sys_input(node).join("device/.."));
    let Ok(owner) = parent(ev) else { return vec![format!("/dev/input/{ev}")] };
    let mut nodes: Vec<String> = fs::read_dir("/sys/class/input")
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("event") || n.starts_with("js"))
        .filter(|n| parent(n).is_ok_and(|p| p == owner))
        .map(|n| format!("/dev/input/{n}"))
        .collect();
    nodes.extend(
        fs::read_dir(owner.join("hidraw"))
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| format!("/dev/{}", e.file_name().to_string_lossy())),
    );
    nodes.sort();
    nodes
}

/// controllers.conf: "<player>=<pad id>" lines, '#' comments
fn assigned(player: u32) -> Option<Option<String>> {
    let text = fs::read_to_string(controllers_conf()).ok()?;
    let prefix = format!("{player}=");
    Some(text.lines().find_map(|l| l.strip_prefix(&prefix).map(String::from)))
}

// ---------------------------------------------------------------- wrap

/// Prism wrapper command: `mc-splitscreen wrap <player> <java> <args...>`
pub fn wrap(player: u32, cmd: &[String]) -> Result<()> {
    if cmd.is_empty() {
        bail!("wrap: no command to run");
    }
    let mut args: Vec<String> = ["--die-with-parent", "--dev-bind", "/", "/", "--dev", "/dev", "--dir", "/dev/input"]
        .map(String::from)
        .to_vec();
    // GPU (Mesa + NVIDIA), audio and shared memory; never other input devices
    let mut hw = vec![PathBuf::from("/dev/dri"), PathBuf::from("/dev/snd"), PathBuf::from("/dev/dxg")];
    hw.extend(
        fs::read_dir("/dev")
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("nvidia"))
            .map(|e| e.path()),
    );
    for p in hw.iter().filter(|p| p.exists()) {
        let p = p.to_string_lossy().into_owned();
        args.extend(["--dev-bind".into(), p.clone(), p]);
    }
    if Path::new("/dev/shm").is_dir() {
        args.extend(["--bind", "/dev/shm", "/dev/shm"].map(String::from));
    }

    let pad = match assigned(player) {
        // No assignments yet: player N gets the Nth controller
        None => list_pads().into_iter().nth(player as usize - 1),
        Some(None) => None,
        Some(Some(id)) => {
            let found = find_pad(&id);
            if found.is_none() {
                eprintln!("[sandbox] P{player}: assigned controller ({id}) not connected, starting without one");
            }
            found
        }
    };
    match pad {
        Some(ev) => {
            let nodes = pad_nodes(&ev);
            eprintln!("[sandbox] P{player}: {} -> {}", pad_name(&ev), nodes.join(" "));
            for n in nodes {
                args.extend(["--dev-bind".into(), n.clone(), n]);
            }
        }
        None => eprintln!("[sandbox] P{player}: no controller"),
    }

    args.push("--".into());
    args.extend(cmd.iter().cloned());
    let err = Command::new("bwrap").args(&args).exec();
    Err(err).context("running bwrap")
}

/// Check bwrap exists and can build a sandbox on this kernel
pub fn check_bwrap() -> Result<()> {
    let ok = Command::new("bwrap")
        .args(["--dev-bind", "/", "/", "--dev", "/dev", "true"])
        .status()
        .map(|s| s.success());
    match ok {
        Ok(true) => Ok(()),
        Ok(false) => bail!(
            "bwrap can't create a sandbox here. On Ubuntu 24.04+ AppArmor blocks unprivileged user\n\
             namespaces for unconfined programs; check: sysctl kernel.apparmor_restrict_unprivileged_userns"
        ),
        Err(_) => bail!("bubblewrap (bwrap) is required for --sandbox; install the 'bubblewrap' package"),
    }
}

// ---------------------------------------------------------------- assign

/// input_event is { timeval, u16 type, u16 code, s32 value }; timeval is
/// 16 bytes on 64-bit and 8 on 32-bit
const EVENT_SIZE: usize = if cfg!(target_pointer_width = "64") { 24 } else { 16 };
const EV_KEY: u16 = 1;

/// Each player presses a button on their pad in turn
pub fn assign(players: u32) -> Result<()> {
    let pads = list_pads();
    if pads.is_empty() {
        bail!("No controllers found. Connect them (and close Steam if it's grabbing them), then retry.");
    }
    println!("Found {} controller(s):", pads.len());
    for ev in &pads {
        println!("  {}", pad_name(ev));
    }

    // One reader thread per pad, all reporting button presses to one channel
    let (tx, rx) = mpsc::channel::<String>();
    for ev in &pads {
        let mut f = fs::File::open(format!("/dev/input/{ev}")).with_context(|| {
            format!("can't read /dev/input/{ev}; add yourself to the 'input' group or log in at the local seat")
        })?;
        let tx = tx.clone();
        let ev = ev.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; EVENT_SIZE];
            while f.read_exact(&mut buf).is_ok() {
                let off = EVENT_SIZE - 8;
                let kind = u16::from_ne_bytes([buf[off], buf[off + 1]]);
                let value = i32::from_ne_bytes([buf[off + 4], buf[off + 5], buf[off + 6], buf[off + 7]]);
                if kind == EV_KEY && value == 1 && tx.send(ev.clone()).is_err() {
                    break;
                }
            }
        });
    }
    drop(tx);

    if (pads.len() as u32) < players {
        note(format!("Only {} controller(s); the other players start without one.", pads.len()));
    }
    let players = players.min(pads.len() as u32);
    let mut taken = HashSet::new();
    let mut conf = vec!["# Generated by `mc-splitscreen assign`: <player>=<uniq>|<phys>".to_string()];
    for p in 1..=players {
        println!("\nPlayer {p}: press a button on your controller...");
        let ev = loop {
            let ev = rx.recv().context("controller reader stopped")?;
            if !taken.contains(&ev) {
                break ev;
            }
        };
        println!("  -> {}", pad_name(&ev));
        conf.push(format!("# P{p}: {}", pad_name(&ev)));
        conf.push(format!("{p}={}", pad_id(&ev)));
        taken.insert(ev);
    }
    std::fs::create_dir_all(util::out_dir())?;
    util::write_text(&controllers_conf(), &(conf.join("\n") + "\n"))?;
    step(format!("Saved to {}", controllers_conf().display()));
    Ok(())
}

pub fn has_assignments() -> bool {
    controllers_conf().exists()
}
