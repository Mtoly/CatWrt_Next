/* src/modules/package.rs */

use crate::constants::{BACKUP_FILE, BETA_MIRROR_OPTIONS, MIRROR_OPTIONS};
use crate::error::Result;
use crate::utils::apk;
use crate::utils::system::{download_text, url_exists};
use crate::{api::repo::fetch_repo_source, constants::BASE_REPO_URL};
use dialoguer::{Confirm, Input, Select};
use std::collections::HashSet;
use std::fs;

/// Apply repository configuration
pub fn apply_repo() -> Result<()> {
    println!("\n软件源配置");

    // Read release file
    let release_content = fs::read_to_string("/etc/catwrt_release")
        .unwrap_or_else(|_| "arch=amd64\nversion=v25.8".to_string());

    let arch = release_content
        .lines()
        .find(|line| line.starts_with("arch="))
        .and_then(|line| line.split('=').nth(1))
        .unwrap_or("amd64");

    let version = release_content
        .lines()
        .find(|line| line.starts_with("version="))
        .and_then(|line| line.split('=').nth(1))
        .unwrap_or("v25.8");

    println!("\n当前架构: {}", arch);
    println!("当前版本: {}", version);

    let mut repo_url = format!("{}/{}", BASE_REPO_URL, arch);
    let mut is_beta = version.contains("beta") || version.contains("Beta");

    if let Ok(Some(source)) = fetch_repo_source(arch, version) {
        repo_url = source.url;
        is_beta = source.beta;
    }

    println!("\nINFO ================================================================");
    println!(
        "软件源纯属免费分享，但你可以使用免费的境外软件源托管，如果你需要更快的速度请使用主站。"
    );
    println!("本人不对所有软件进行保证，我们没有提供第三方商业服务，使用风险需要自行承担。");
    println!("你需要同意 CatWrt 软件源用户协议，请确认是否继续。");
    println!("=========================================================================");

    if !Confirm::new()
        .with_prompt("是否继续？")
        .default(true)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    let conf_file = if is_beta {
        println!("\n你目前使用的 BETA 版本，只能拉取临时镜像站软件源");
        let selection = Select::new()
            .with_prompt("请选择软件源")
            .items(BETA_MIRROR_OPTIONS)
            .default(1)
            .interact()?;

        match selection {
            0 => "netlify.conf",
            1 => "vercel.conf",
            _ => "vercel.conf",
        }
    } else {
        println!("\n请选择要使用的软件源:");
        let selection = Select::new().items(MIRROR_OPTIONS).default(3).interact()?;

        match selection {
            0 => {
                let code: String = Input::new().with_prompt("请输入支持代码").interact_text()?;

                if code != "cat666" {
                    println!("[ERROR] 支持代码无效，请重新选择");
                    return apply_repo();
                }
                "distfeeds.conf"
            }
            1 => "github.conf",
            2 => "cfnetlify.conf",
            3 => "netlify.conf",
            4 => "cfvercel.conf",
            5 => "vercel.conf",
            _ => "netlify.conf",
        }
    };

    let conf_url = format!("{}/{}", repo_url.trim_end_matches('/'), conf_file);

    println!("[INFO] 下载配置: {}", conf_url);

    if !url_exists(&conf_url) {
        if repo_url.contains("/history/") {
            let fallback_url = format!("{}/{}/{}", BASE_REPO_URL, arch, conf_file);
            println!("[WARN] 历史源配置不存在，尝试回退: {}", fallback_url);
            if url_exists(&fallback_url) {
                println!("[INFO] 使用回退软件源配置");
                apply_repo_with_url(&fallback_url)?;
                return Ok(());
            }
        }

        return Err(crate::error::CatoolsError::ApiError(format!(
            "repo conf 不存在: {}",
            conf_url
        )));
    }

    // Download config
    apply_repo_with_url(&conf_url)?;

    println!("✓ 软件源配置已完成！");
    println!("  可以使用 apk add <pkg> 来安装插件/组件/内核模块");

    Ok(())
}

fn apply_repo_with_url(conf_url: &str) -> Result<()> {
    let config_content = download_text(conf_url)
        .map_err(|e| crate::error::CatoolsError::ApiError(format!("下载配置失败: {}", e)))?;

    fs::create_dir_all("/etc/apk/repositories.d")?;
    fs::write("/etc/apk/repositories.d/distfeeds.list", config_content)?;

    println!("[INFO] 更新软件源索引...");
    apk::update()?;

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
    use super::missing_packages;
    use crate::utils::apk::parse_world;

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
