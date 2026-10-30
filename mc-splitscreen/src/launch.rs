#[cfg(target_os = "linux")]
use crate::util;
use crate::util::{step, Config};
use anyhow::{bail, Context, Result};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::Duration;

/// Start every instance, staggered so RAM/disk don't spike all at once.
/// Prism is single-instance: later launches are forwarded to the running one.
pub fn run(delay: Option<u64>) -> Result<()> {
    let config = Config::load()?;
    if config.prism.is_empty() || config.instances.is_empty() {
        bail!("{} is incomplete; re-run `mc-splitscreen setup`", Config::path().display());
    }
    let delay = delay.unwrap_or(config.delay);

    #[cfg(target_os = "linux")]
    if config.sandbox && !crate::sandbox::has_assignments() {
        if util::interactive() {
            crate::sandbox::assign(config.instances.len() as u32)?;
        } else {
            util::note("No controller assignments yet: player N gets the Nth controller. Run `mc-splitscreen assign` to choose.");
        }
    }

    for (i, inst) in config.instances.iter().enumerate() {
        let mut cmd = Command::new(&config.prism[0]);
        cmd.args(&config.prism[1..]).args(["-l", inst]);
        let account = config.accounts.get(i).filter(|a| !a.is_empty());
        if let Some(a) = account {
            cmd.args(["-a", a]);
        }
        step(format!("Launching {inst}{}", account.map(|a| format!(" as {a}")).unwrap_or_default()));
        cmd.stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("starting {}", config.prism[0]))?;
        if i + 1 < config.instances.len() {
            sleep(Duration::from_secs(delay));
        }
    }
    Ok(())
}
