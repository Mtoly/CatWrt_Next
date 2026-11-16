/* src/utils/system.rs */

use crate::error::{CatoolsError, Result};
use std::process::Command;

pub fn check_root() -> Result<()> {
    let output = Command::new("id")
        .arg("-u")
        .output()
        .map_err(|e| CatoolsError::CommandError(format!("Failed to check user ID: {}", e)))?;

    let uid = String::from_utf8_lossy(&output.stdout).trim().to_string();

    if uid != "0" {
        return Err(CatoolsError::CommandError(
            "This tool requires root privileges. Please run with sudo or as root.".to_string(),
        ));
    }

    Ok(())
}

pub fn check_openwrt() -> Result<()> {
    if !std::path::Path::new("/etc/openwrt_release").exists() {
        return Err(CatoolsError::CommandError(
            "This tool is designed for OpenWrt/CatWrt systems.".to_string(),
        ));
    }
    Ok(())
}

pub fn run_command(cmd: &str, args: &[&str]) -> Result<String> {
    let command = format!("{} {}", cmd, args.join(" "));
    let output = Command::new(cmd).args(args).output().map_err(|e| {
        CatoolsError::CommandError(format!(
            "无法执行命令 {}：{}；stderr：无（未启动）",
            command, e
        ))
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(CatoolsError::CommandError(format!(
            "命令 {} 退出状态 {}；stderr：{}",
            command, output.status, stderr
        )));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn run_shell(command: &str) -> Result<String> {
    run_command("sh", &["-c", command])
}

pub fn restart_service(service: &str) -> Result<()> {
    run_command("/etc/init.d", &[service, "restart"])?;
    Ok(())
}
