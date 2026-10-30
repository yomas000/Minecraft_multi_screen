use crate::util::{self, note};
use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::collections::HashSet;
use std::path::Path;

const API: &str = "https://api.modrinth.com/v2";

fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// Fabric versions of a project, optionally only those for one MC version
fn versions(id: &str, mc: Option<&str>) -> Result<Vec<Value>> {
    let mut url = format!("{API}/project/{id}/version?loaders={}", enc(r#"["fabric"]"#));
    if let Some(mc) = mc {
        url += &format!("&game_versions={}", enc(&format!(r#"["{mc}"]"#)));
    }
    Ok(util::get_json(&url)?.as_array().cloned().unwrap_or_default())
}

/// Newest Minecraft release that every one of `mods` has a Fabric build for
pub fn best_mc_version(mods: &[String]) -> Result<String> {
    let tags = util::get_json(&format!("{API}/tag/game_version"))?;
    let mut releases: Vec<(&str, &str)> = tags
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| t["version_type"] == "release")
        .filter_map(|t| Some((t["date"].as_str()?, t["version"].as_str()?)))
        .collect();
    releases.sort_by(|a, b| b.0.cmp(a.0)); // ISO dates sort as strings

    let mut sets = Vec::new();
    for m in mods {
        let set: HashSet<String> = versions(m, None)
            .with_context(|| format!("mod '{m}' not found on Modrinth"))?
            .iter()
            .flat_map(|v| v["game_versions"].as_array().cloned().unwrap_or_default())
            .filter_map(|g| g.as_str().map(String::from))
            .collect();
        sets.push(set);
    }
    releases
        .iter()
        .map(|(_, v)| *v)
        .find(|v| sets.iter().all(|s| s.contains(*v)))
        .map(String::from)
        .context("No Minecraft release is supported by all core mods")
}

pub fn latest_fabric_loader() -> Result<String> {
    let loaders = util::get_json("https://meta.fabricmc.net/v2/versions/loader")?;
    loaders
        .as_array()
        .into_iter()
        .flatten()
        .find(|l| l["stable"] == true)
        .and_then(|l| l["version"].as_str().map(String::from))
        .context("Could not get Fabric loader version")
}

/// Downloads mods (and their required dependencies) into a folder
pub struct Downloader<'a> {
    pub mc: &'a str,
    pub dest: &'a Path,
    seen: HashSet<String>,
}

impl<'a> Downloader<'a> {
    pub fn new(mc: &'a str, dest: &'a Path) -> Self {
        Self { mc, dest, seen: HashSet::new() }
    }

    /// Required mods fail the setup; optional ones are skipped with a warning
    pub fn fetch(&mut self, id: &str, required: bool) -> Result<()> {
        self.fetch_as(id, id, required)
    }

    fn fetch_as(&mut self, id: &str, label: &str, required: bool) -> Result<()> {
        let list = match versions(id, Some(self.mc)) {
            Ok(l) => l,
            Err(e) if !required => {
                note(format!("Skipping '{id}' ({e:#})"));
                return Ok(());
            }
            Err(e) => return Err(e.context(format!("mod '{id}' not found on Modrinth"))),
        };
        // Prefer release builds; Modrinth lists newest first
        let Some(ver) = list.iter().find(|v| v["version_type"] == "release").or(list.first()) else {
            if required {
                bail!("No Fabric build of '{id}' for {}", self.mc);
            }
            note(format!("Skipping '{id}' (no build for {})", self.mc));
            return Ok(());
        };
        let pid = ver["project_id"].as_str().unwrap_or(id).to_string();
        if !self.seen.insert(pid) {
            return Ok(());
        }
        let files = ver["files"].as_array().context("version has no files")?;
        let file = files.iter().find(|f| f["primary"] == true).or(files.first()).context("version has no files")?;
        let name = file["filename"].as_str().context("file has no name")?;
        let url = file["url"].as_str().context("file has no url")?;
        println!("    {label:<18} {name}");
        util::download(url, &self.dest.join(name))?;

        for dep in ver["dependencies"].as_array().into_iter().flatten() {
            if dep["dependency_type"] == "required" {
                if let Some(dep_id) = dep["project_id"].as_str() {
                    self.fetch_as(dep_id, "  (dependency)", true)?;
                }
            }
        }
        Ok(())
    }
}
