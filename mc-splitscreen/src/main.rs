//! mc-splitscreen: local splitscreen Minecraft Java with Prism Launcher.
//! Run with no arguments to set up on first use and launch afterwards.

mod launch;
mod modrinth;
mod prism;
#[cfg(target_os = "linux")]
mod sandbox;
mod setup;
mod util;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(version, about = "Local splitscreen Minecraft Java with Prism Launcher")]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// Install Prism if needed, create accounts, download mods, build instances
    Setup(setup::SetupArgs),
    /// Launch every player's instance
    Launch {
        /// Seconds between instances (default: value saved by setup)
        #[arg(long)]
        delay: Option<u64>,
    },
    /// Linux sandbox mode: choose which controller belongs to which player
    #[cfg(target_os = "linux")]
    Assign {
        /// Number of players (default: number of instances)
        players: Option<u32>,
    },
}

/// Setup with all defaults, for the no-argument (double-click) run
#[derive(Parser)]
struct DefaultSetup {
    #[command(flatten)]
    args: setup::SetupArgs,
}

fn main() {
    let raw: Vec<String> = std::env::args().collect();

    // Prism's wrapper command: `mc-splitscreen wrap <player> <java> <args...>`.
    // Parsed by hand so Java's own -flags never reach clap.
    #[cfg(target_os = "linux")]
    if raw.get(1).map(String::as_str) == Some("wrap") {
        let result = match raw.get(2).and_then(|p| p.parse::<u32>().ok()).filter(|p| *p >= 1) {
            Some(player) => sandbox::wrap(player, &raw[3..]),
            None => Err(anyhow::anyhow!("usage: mc-splitscreen wrap <player> <command...>")),
        };
        if let Err(e) = result {
            eprintln!("[sandbox] error: {e:#}");
            std::process::exit(1);
        }
    }

    let double_clicked = raw.len() == 1;
    if let Err(e) = run(Cli::parse()) {
        eprintln!("error: {e:#}");
        // Keep a double-clicked console window open long enough to read the error
        if double_clicked && util::interactive() {
            eprintln!("\nPress Enter to close.");
            let _ = std::io::stdin().read_line(&mut String::new());
        }
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    match cli.cmd {
        Some(Cmd::Setup(args)) => setup::run(args),
        Some(Cmd::Launch { delay }) => launch::run(delay),
        #[cfg(target_os = "linux")]
        Some(Cmd::Assign { players }) => {
            let players = match players {
                Some(p) => p,
                None => util::Config::load().map(|c| c.instances.len() as u32).unwrap_or(4),
            };
            sandbox::assign(players)
        }
        None if util::Config::path().exists() => launch::run(None),
        None => {
            util::step("First run: setting up (use `mc-splitscreen setup --help` for options)");
            setup::run(DefaultSetup::parse_from(["mc-splitscreen"]).args)
        }
    }
}
