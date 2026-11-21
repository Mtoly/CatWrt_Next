/* src/menu.rs */

use crate::error::Result;
use dialoguer::Select;

const MIGRATION_MARKER_PATH: &str = "/etc/catwrt_migrated";
const MIGRATION_DOC_URL: &str = "https://github.com/Mtoly/CatWrt_Next/blob/main/docs/migration.md";

fn migration_notice(marker_present: bool) -> Option<String> {
    marker_present.then(|| {
        format!(
            "提示：当前配置可能来自其他固件（如原版 CatWrt），请参考迁移说明：{MIGRATION_DOC_URL}"
        )
    })
}

#[derive(Debug, Clone)]
pub enum MenuOption {
    SetIp,
    NetworkWizard,
    ApplyRepo,
    NetworkDiagnostic,
    SystemDebug,
    CheckUpdate,
    SystemUpgrade,
    PackageBackup,
    UtilitiesMenu,
    Exit,
}

#[derive(Debug, Clone)]
pub enum UtilitiesMenuOption {
    ConfigureTailscale,
    ConfigureTtyd,
    InstallApk,
    DeploySslCert,
    ResetPassword,
    SystemReset,
    Back,
}

pub struct Menu;

impl Menu {
    pub fn show() -> Result<MenuOption> {
        let options = [
            "设置 IP 地址",
            "网络向导",
            "软件源配置",
            "网络诊断",
            "系统诊断",
            "检查更新",
            "系统升级",
            "软件包备份/恢复",
            "实用工具",
            "退出",
        ];

        if let Some(notice) = migration_notice(std::path::Path::new(MIGRATION_MARKER_PATH).exists())
        {
            println!("{notice}");
        }

        let selection = Select::new()
            .with_prompt("CatWrt 配置工具 - 请选择功能")
            .items(&options)
            .default(0)
            .interact()
            .map_err(|e| crate::error::CatoolsError::IoError(std::io::Error::other(e)))?;

        Ok(match selection {
            0 => MenuOption::SetIp,
            1 => MenuOption::NetworkWizard,
            2 => MenuOption::ApplyRepo,
            3 => MenuOption::NetworkDiagnostic,
            4 => MenuOption::SystemDebug,
            5 => MenuOption::CheckUpdate,
            6 => MenuOption::SystemUpgrade,
            7 => MenuOption::PackageBackup,
            8 => MenuOption::UtilitiesMenu,
            9 => MenuOption::Exit,
            _ => MenuOption::Exit,
        })
    }

    pub fn show_utilities() -> Result<UtilitiesMenuOption> {
        let options = [
            "Tailscale 配置",
            "TTYD 免密登录",
            "本地 APK 安装",
            "SSL 证书部署",
            "重置 root 密码",
            "系统重置",
            "返回主菜单",
        ];

        let selection = Select::new()
            .with_prompt("实用工具 - 请选择功能")
            .items(&options)
            .default(0)
            .interact()
            .map_err(|e| crate::error::CatoolsError::IoError(std::io::Error::other(e)))?;

        Ok(match selection {
            0 => UtilitiesMenuOption::ConfigureTailscale,
            1 => UtilitiesMenuOption::ConfigureTtyd,
            2 => UtilitiesMenuOption::InstallApk,
            3 => UtilitiesMenuOption::DeploySslCert,
            4 => UtilitiesMenuOption::ResetPassword,
            5 => UtilitiesMenuOption::SystemReset,
            6 => UtilitiesMenuOption::Back,
            _ => UtilitiesMenuOption::Back,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{MIGRATION_DOC_URL, migration_notice};

    #[test]
    fn migration_notice_with_marker_contains_document_link() {
        let notice = migration_notice(true).expect("migration marker should produce a notice");
        assert!(notice.contains(MIGRATION_DOC_URL));
        assert!(notice.contains("migration.md"));
    }

    #[test]
    fn migration_notice_without_marker_is_absent() {
        assert_eq!(migration_notice(false), None);
    }
}
