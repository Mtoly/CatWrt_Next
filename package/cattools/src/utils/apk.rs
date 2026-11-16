/* src/utils/apk.rs */

use crate::error::{CatoolsError, Result};
use std::fs;
use std::path::Path;
use std::process::{Command, Output};

pub const WORLD_FILE: &str = "/etc/apk/world";

fn execute(args: &[&str]) -> Result<Output> {
    Command::new("apk")
        .args(args)
        .output()
        .map_err(|e| CatoolsError::CommandError(format!("无法执行 apk: {}", e)))
}

fn check_status(command: &str, output: Output) -> Result<()> {
    if !output.status.success() {
        return Err(CatoolsError::CommandError(format!(
            "{} 退出状态 {}: {}",
            command,
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    Ok(())
}

pub fn update() -> Result<()> {
    check_status("apk update", execute(&["update"])?)
}

pub fn add(packages: &[&str]) -> Result<()> {
    if packages.is_empty() {
        return Ok(());
    }
    let mut args = vec!["add", "--"];
    args.extend_from_slice(packages);
    check_status("apk add", execute(&args)?)
}

pub fn is_installed(name: &str) -> Result<bool> {
    let output = execute(&["info", "-e", name])?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => {
            check_status("apk info -e", output)?;
            Ok(false)
        }
    }
}

pub fn parse_world(content: &str) -> Vec<String> {
    content
        .lines()
        .flat_map(|line| line.split('#').next().unwrap_or("").split_whitespace())
        .filter_map(|token| {
            let name = token.split(['@', '<', '>', '=', '~']).next().unwrap_or("");
            if name.is_empty() {
                None
            } else {
                Some(name.to_string())
            }
        })
        .collect()
}

pub fn installed_names() -> Result<Vec<String>> {
    Ok(parse_world(&fs::read_to_string(WORLD_FILE)?))
}

pub fn add_local(path: &str) -> Result<()> {
    let path = Path::new(path).canonicalize()?;
    if !path.is_file() || path.extension().and_then(|ext| ext.to_str()) != Some("apk") {
        return Err(CatoolsError::ValidationError(
            "请选择本地 .apk 软件包文件".to_string(),
        ));
    }
    let path = path
        .to_str()
        .ok_or_else(|| CatoolsError::ValidationError("软件包路径不是有效的 UTF-8".to_string()))?;
    check_status(
        "apk add --allow-untrusted",
        execute(&["add", "--allow-untrusted", "--", path])?,
    )
}

#[cfg(test)]
mod tests {
    use super::parse_world;

    #[test]
    fn parse_whitespace_and_comments() {
        assert_eq!(
            parse_world("\n # Explicit packages\n tailscale\ttcpdump  # tools\n\ncurl\r\n"),
            vec!["tailscale", "tcpdump", "curl"]
        );
        assert!(parse_world(" \t\n# empty world\n").is_empty());
    }

    #[test]
    fn strip_version_constraints() {
        assert_eq!(
            parse_world("alpha>=1 beta=2 gamma~3 delta<=4 epsilon>5 zeta<6 eta~=7"),
            vec!["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta"]
        );
    }

    #[test]
    fn strip_repository_tags_and_constraints() {
        assert_eq!(
            parse_world("alpha@testing beta@stable>=2 gamma=3@testing lib-example+tools~1"),
            vec!["alpha", "beta", "gamma", "lib-example+tools"]
        );
    }
}
