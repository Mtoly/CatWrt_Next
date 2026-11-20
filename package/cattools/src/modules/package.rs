/* src/modules/package.rs */

use crate::constants::BACKUP_FILE;
use crate::error::{CatoolsError, Result};
use crate::modules::repo::{
    MIRRORS, current_base, detect_base, enable_own_repo, rewrite_feeds, validate_custom_url,
};
use crate::uci::Uci;
use crate::utils::apk;
use crate::utils::system::run_command;
use dialoguer::{Confirm, Input, Select};
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::Path;

const DISTFEEDS: &str = "/etc/apk/repositories.d/distfeeds.list";
const DISTFEEDS_BACKUP: &str = "/etc/apk/repositories.d/distfeeds.list.catwrt.bak";
const OWN_REPO: &str = "/etc/apk/repositories.d/catwrt.list";
const OWN_KEY: &str = "/etc/apk/keys/catwrt-next.pem";

struct RepoUciBackup {
    catwrt: String,
    system: String,
}

impl RepoUciBackup {
    fn capture() -> Result<Self> {
        Ok(Self {
            catwrt: run_command("uci", &["export", "catwrt"])?,
            system: run_command("uci", &["export", "system"])?,
        })
    }

    fn restore(&self) -> Result<()> {
        let uci = Uci::new();
        let mut errors = Vec::new();
        for (config, content) in [("catwrt", &self.catwrt), ("system", &self.system)] {
            let restore = || -> Result<()> {
                let path = std::env::temp_dir().join(format!(
                    "cattools-repo-restore-{}-{}.uci",
                    std::process::id(),
                    config
                ));
                let mut options = fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600);
                }
                let mut file = options.open(&path)?;
                let result = (|| -> Result<()> {
                    file.write_all(content.as_bytes())?;
                    drop(file);
                    let path = path.to_str().ok_or_else(|| {
                        CatoolsError::ConfigError("UCI 恢复文件路径不是有效的 UTF-8".into())
                    })?;
                    run_command("uci", &["-f", path, "import", config])?;
                    uci.commit(config)
                })();
                let cleanup = fs::remove_file(&path);
                result?;
                cleanup?;
                Ok(())
            };
            if let Err(error) = restore() {
                errors.push(format!("恢复 {} 失败：{}", config, error));
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(CatoolsError::ConfigError(errors.join("；")))
        }
    }
}

fn has_imm_init(export: &str) -> bool {
    export.lines().any(|line| {
        let mut fields = line.split_whitespace();
        fields.next() == Some("config")
            && fields
                .next()
                .is_some_and(|kind| kind.trim_matches(['\'', '"']) == "imm_init")
    })
}

fn restore_repo(backup: &RepoUciBackup) -> Result<()> {
    // Attempt both restores even if one fails, and report every failure.
    let feeds = fs::copy(DISTFEEDS_BACKUP, DISTFEEDS);
    let settings = backup.restore();
    match (feeds, settings) {
        (Ok(_), Ok(())) => {
            println!("已恢复软件源文件和 UCI 设置");
            Ok(())
        }
        (feeds, settings) => Err(CatoolsError::ConfigError(format!(
            "恢复未完成：文件：{}；UCI：{}",
            feeds.err().map_or_else(|| "成功".into(), |e| e.to_string()),
            settings
                .err()
                .map_or_else(|| "成功".into(), |e| e.to_string())
        ))),
    }
}

/// Configure built-in distribution mirrors or enable the project repository.
pub fn apply_repo() -> Result<()> {
    println!("\n软件源配置");
    let content = fs::read_to_string(DISTFEEDS)?;
    println!(
        "当前镜像：{}",
        detect_base(&content).map_or("未知", |mirror| mirror.label)
    );
    let options = ["切换发行版软件源", "启用 CatWrt Next 自有软件源", "返回"];
    match Select::new()
        .with_prompt("请选择操作")
        .items(&options)
        .default(0)
        .interact()?
    {
        0 => switch_mirror(&content),
        1 => enable_project_repo(),
        _ => Ok(()),
    }
}

fn switch_mirror(content: &str) -> Result<()> {
    let from = current_base(content)?;
    let mut options: Vec<&str> = MIRRORS.iter().map(|mirror| mirror.label).collect();
    options.extend(["自定义 HTTPS 镜像", "返回"]);
    let default = detect_base(content)
        .and_then(|current| MIRRORS.iter().position(|mirror| mirror.key == current.key))
        .unwrap_or(1);
    let selection = Select::new()
        .with_prompt("请选择软件源")
        .items(&options)
        .default(default)
        .interact()?;
    let (key, base) = if let Some(mirror) = MIRRORS.get(selection) {
        (mirror.key, mirror.base.to_string())
    } else if selection == MIRRORS.len() {
        let input: String = Input::new()
            .with_prompt("请输入镜像基础地址（例如 https://example.org/mirror）")
            .interact_text()?;
        ("custom", validate_custom_url(&input)?)
    } else {
        return Ok(());
    };
    let rewritten = rewrite_feeds(content, from, &base)?;
    println!("目标镜像：{}", base);
    if !Confirm::new()
        .with_prompt("确认切换软件源？")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    let backup = RepoUciBackup::capture()?;
    fs::copy(DISTFEEDS, DISTFEEDS_BACKUP)?;
    println!("已备份到 {}", DISTFEEDS_BACKUP);
    let apply = || -> Result<()> {
        fs::write(DISTFEEDS, rewritten)?;
        let uci = Uci::new();
        uci.set("catwrt.repo.mirror", key)?;
        uci.set(
            "catwrt.repo.custom",
            if key == "custom" { "1" } else { "0" },
        )?;
        if key == "custom" {
            uci.set("catwrt.repo.url", &base)?;
        }
        if !has_imm_init(&backup.system) {
            run_command("uci", &["add", "system", "imm_init"])?;
        }
        uci.set("system.@imm_init[0].apk_mirror", &base)?;
        uci.commit("catwrt")?;
        uci.commit("system")?;
        Ok(())
    };
    if let Err(error) = apply() {
        eprintln!("切换失败：{}", error);
        restore_repo(&backup)?;
        return Err(error);
    }

    println!("正在执行 apk update...");
    if let Err(error) = apk::update() {
        eprintln!("软件源索引更新失败：{}", error);
        if Confirm::new()
            .with_prompt("是否恢复备份及原来的 UCI 设置？")
            .default(true)
            .interact()?
        {
            restore_repo(&backup)?;
        } else {
            println!("已保留新软件源及 UCI 设置；备份位于 {}", DISTFEEDS_BACKUP);
        }
        return Err(error);
    }
    println!("✓ 软件源配置完成，apk update 成功");
    Ok(())
}

fn enable_project_repo() -> Result<()> {
    if !Path::new(OWN_KEY).is_file() {
        return Err(CatoolsError::ConfigError(format!(
            "缺少自有软件源公钥 {}，无法启用",
            OWN_KEY
        )));
    }
    println!("自有软件源可能尚未发布，发布前 apk update 失败属于预期情况。");
    let content = fs::read_to_string(OWN_REPO)?;
    let rewritten = enable_own_repo(&content)?;
    if rewritten
        .lines()
        .any(|line| !line.starts_with('#') && (line.contains('<') || line.contains('>')))
    {
        return Err(CatoolsError::ConfigError(
            "自有软件源地址尚未配置，请先将 catwrt.list 中的占位地址替换为已发布的仓库地址".into(),
        ));
    }
    if !Confirm::new()
        .with_prompt("确认启用 CatWrt Next 自有软件源？")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }
    fs::write(OWN_REPO, rewritten)?;
    println!("已启用自有软件源，正在执行 apk update...");
    apk::update()?;
    println!("✓ 自有软件源已启用，apk update 成功");
    Ok(())
}

/// Backup packages
pub fn backup_packages() -> Result<()> {
    println!("\n备份软件包...");

    // Preserve the complete world file, including constraints and repository tags.
    let content = fs::read_to_string(apk::WORLD_FILE)?;
    let count = apk::parse_world(&content).len();
    fs::write(BACKUP_FILE, content)?;

    println!("✓ 已备份 {} 个软件包到 {}", count, BACKUP_FILE);
    Ok(())
}

fn missing_packages(backup_content: &str, installed: Vec<String>) -> Vec<String> {
    let installed: HashSet<String> = installed.into_iter().collect();
    let mut missing: Vec<String> = apk::parse_world(backup_content)
        .into_iter()
        .filter(|name| !installed.contains(name))
        .collect();
    missing.sort();
    missing.dedup();
    missing
}

/// Restore packages
pub fn restore_packages() -> Result<()> {
    println!("\n恢复软件包...");

    // Read backup
    let backup_content = fs::read_to_string(BACKUP_FILE)?;

    // Calculate missing
    let missing = missing_packages(&backup_content, apk::installed_names()?);

    if missing.is_empty() {
        println!("✓ 所有软件包都已安装，无需恢复");
        return Ok(());
    }

    println!("发现 {} 个缺失的软件包:", missing.len());
    for pkg in &missing {
        println!("  - {}", pkg);
    }

    if !Confirm::new()
        .with_prompt("是否安装这些软件包？")
        .default(true)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    // Install missing packages
    println!("\n开始安装...");
    let packages: Vec<&str> = missing.iter().map(String::as_str).collect();
    apk::add(&packages)?;

    println!("\n✓ 软件包恢复完成！");
    Ok(())
}

/// Package backup/restore menu
pub fn package_backup_restore_menu() -> Result<()> {
    let options = ["备份当前软件包", "恢复软件包", "返回"];
    let selection = Select::new()
        .with_prompt("软件包管理")
        .items(&options)
        .default(0)
        .interact()?;

    match selection {
        0 => backup_packages()?,
        1 => restore_packages()?,
        2 => {}
        _ => {}
    }

    Ok(())
}

/// Install an explicitly selected local APK.
pub fn install_apk() -> Result<()> {
    println!("\n本地 APK 安装");

    let options = ["选择本地 .apk 文件", "返回"];
    let selection = Select::new()
        .with_prompt("请选择安装方式")
        .items(&options)
        .default(0)
        .interact()?;

    match selection {
        0 => {
            // Local file
            let path: String = Input::new()
                .with_prompt("请输入本地 APK 文件路径（允许安装未签名的软件包）")
                .interact_text()?;

            println!("安装 {}...", path);
            apk::add_local(&path)?;
            println!("✓ 安装完成");
        }
        1 => {}
        _ => {}
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{has_imm_init, missing_packages};
    use crate::utils::apk::parse_world;

    #[test]
    fn find_existing_imm_init_section_in_uci_export() {
        assert!(has_imm_init(
            "package system\n\nconfig imm_init\n\toption apk_mirror 'https://example.org'\n"
        ));
        assert!(has_imm_init("config 'imm_init' 'defaults'\n"));
        assert!(!has_imm_init(
            "config system\n\toption description 'imm_init'\n"
        ));
    }

    #[test]
    fn restore_only_missing_world_names() {
        assert_eq!(
            missing_packages(
                "tailscale@testing>=1 curl=2 tcpdump~3 curl=2\n# backup\n",
                parse_world("tailscale=4 base-files")
            ),
            vec!["curl", "tcpdump"]
        );
        assert!(missing_packages("curl=2", parse_world("curl=3")).is_empty());
        assert!(missing_packages("# empty backup", parse_world("curl")).is_empty());
    }
}
