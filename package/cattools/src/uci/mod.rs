/* src/uci/mod.rs */

pub mod dhcp;
pub mod firewall;
pub mod network;
pub mod system;

use crate::error::{CatoolsError, Result};
use crate::utils::system::run_command;
use std::process::Command;

pub struct Uci;

impl Uci {
    pub fn new() -> Self {
        Self
    }

    #[allow(dead_code)]
    pub fn get(&self, path: &str) -> Result<String> {
        let output = run_command("uci", &["get", path])?;
        Ok(output.trim().to_string())
    }

    pub fn get_optional(&self, path: &str) -> Result<Option<String>> {
        let command = format!("uci -q get {}", path);
        let output = Command::new("uci")
            .args(["-q", "get", path])
            .output()
            .map_err(|error| {
                CatoolsError::CommandError(format!(
                    "无法执行命令 {}：{}；stderr：无（未启动）",
                    command, error
                ))
            })?;
        if output.status.success() {
            return Ok(Some(
                String::from_utf8_lossy(&output.stdout).trim().to_string(),
            ));
        }
        // Quiet UCI returns 1 with no output when the option is absent.
        if output.status.code() == Some(1) && output.stdout.is_empty() && output.stderr.is_empty() {
            return Ok(None);
        }
        Err(CatoolsError::CommandError(format!(
            "命令 {} 退出状态 {}；stderr：{}",
            command,
            output.status,
            String::from_utf8_lossy(&output.stderr)
        )))
    }

    pub fn set(&self, path: &str, value: &str) -> Result<()> {
        run_command("uci", &["set", &format!("{}={}", path, value)])?;
        Ok(())
    }

    pub fn delete(&self, path: &str) -> Result<()> {
        run_command("uci", &["delete", path])?;
        Ok(())
    }

    pub fn commit(&self, config: &str) -> Result<()> {
        run_command("uci", &["commit", config])?;
        Ok(())
    }

    #[allow(dead_code)]
    pub fn add_list(&self, path: &str, value: &str) -> Result<()> {
        run_command("uci", &["add_list", &format!("{}={}", path, value)])?;
        Ok(())
    }
}

impl Default for Uci {
    fn default() -> Self {
        Self::new()
    }
}
