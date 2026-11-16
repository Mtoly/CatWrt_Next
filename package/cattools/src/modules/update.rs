/* src/modules/update.rs */

use crate::api::update::{UpdateMeta, fetch_meta, update_urls};
use crate::constants::{BACKUP_FILE, RELEASE_FILE};
use crate::error::{CatoolsError, Result};
use crate::modules::package::backup_packages;
use crate::utils::system::run_command;
use crate::utils::validation::compare_versions;
use dialoguer::Confirm;
use std::cmp::Ordering;
use std::fs;
use std::path::Path;

const IMAGE_FILE: &str = "/tmp/catwrt-upgrade.img.gz";
const SYSUPGRADE_CONF: &str = "/etc/sysupgrade.conf";

struct Release {
    version: String,
    arch: String,
}

fn parse_release(content: &str) -> Result<Release> {
    let field = |key: &str| {
        content.lines().find_map(|line| {
            let (name, value) = line.split_once('=')?;
            (name.trim() == key)
                .then(|| value.trim().trim_matches(['\'', '"']).to_string())
                .filter(|value| !value.is_empty())
        })
    };
    Ok(Release {
        version: field("version").ok_or_else(|| {
            CatoolsError::ValidationError("/etc/catwrt_release 缺少 version".to_string())
        })?,
        arch: field("arch").ok_or_else(|| {
            CatoolsError::ValidationError("/etc/catwrt_release 缺少 arch".to_string())
        })?,
    })
}

fn available_update() -> Result<Option<(Release, UpdateMeta)>> {
    let content = fs::read_to_string(RELEASE_FILE).map_err(|error| {
        CatoolsError::ConfigError(format!("无法读取 {}：{}", RELEASE_FILE, error))
    })?;
    let release = parse_release(&content)?;
    let meta = fetch_meta(&update_urls()?)?;
    println!("当前版本：{}", release.version);
    println!("最新版本：{}", meta.latest);
    println!("底座版本：{}", meta.base);
    println!("发布日期：{}", meta.released);
    println!("更新说明：{}", meta.notes_url);
    if compare_versions(&release.version, &meta.latest)? != Ordering::Less {
        println!("当前版本已是最新或更新版本，无需升级。");
        return Ok(None);
    }
    Ok(Some((release, meta)))
}

/// Check for system updates.
pub fn check_update() -> Result<()> {
    println!("\n检查更新...");
    if let Some((release, meta)) = available_update()? {
        println!("发现新版本可用！");
        if Confirm::new()
            .with_prompt("是否下载镜像并准备升级？")
            .default(false)
            .interact()?
        {
            upgrade(&release, &meta)?;
        }
    }
    Ok(())
}

/// Upgrade only to a newer image from the configured metadata.
pub fn system_upgrade() -> Result<()> {
    println!("\n系统升级");
    if let Some((release, meta)) = available_update()? {
        upgrade(&release, &meta)?;
    }
    Ok(())
}

fn boot_mode(efi_path: &Path) -> &'static str {
    if efi_path.exists() { "efi" } else { "bios" }
}

fn filesystem(mounts: &str) -> &'static str {
    let mounts: Vec<Vec<&str>> = mounts
        .lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>())
        .filter(|fields| fields.len() >= 4)
        .collect();
    if mounts
        .iter()
        .any(|fields| fields[1] == "/rom" || (fields[1] == "/" && fields[2] == "squashfs"))
    {
        return "squashfs";
    }
    let overlay_on_squashfs = mounts.iter().any(|root| {
        root[1] == "/"
            && root[2] == "overlay"
            && root[3].split(',').any(|option| {
                option.strip_prefix("lowerdir=").is_some_and(|lowerdirs| {
                    lowerdirs.split(':').any(|lower| {
                        mounts.iter().any(|mount| {
                            mount[2] == "squashfs"
                                && (lower == mount[1]
                                    || lower
                                        .strip_prefix(mount[1])
                                        .is_some_and(|suffix| suffix.starts_with('/')))
                        })
                    })
                })
            })
    });
    if overlay_on_squashfs {
        "squashfs"
    } else {
        "ext4"
    }
}

fn variant(efi_path: &Path, mounts: &str) -> String {
    format!("{}-{}", filesystem(mounts), boot_mode(efi_path))
}

fn parse_free_bytes(df: &str) -> Result<u64> {
    // BusyBox may wrap a long filesystem name onto a separate line.
    let fields: Vec<&str> = df
        .lines()
        .rfind(|line| !line.trim().is_empty())
        .unwrap_or("")
        .split_whitespace()
        .collect();
    let available = if fields.len() >= 5 && fields[fields.len() - 2].ends_with('%') {
        fields[fields.len() - 3].parse::<u64>().ok()
    } else {
        None
    };
    available
        .and_then(|kib| kib.checked_mul(1024))
        .ok_or_else(|| {
            CatoolsError::ValidationError(format!(
                "无法解析命令 df -k /tmp 的可用空间：{}",
                df.chars().take(240).collect::<String>()
            ))
        })
}

fn required_free_bytes(size: u64) -> Result<u64> {
    let size = if size == 0 { 400 * 1024 * 1024 } else { size };
    let required = (u128::from(size) * 6).div_ceil(5);
    u64::try_from(required)
        .map_err(|_| CatoolsError::ValidationError("镜像大小超出可用空间计算范围".to_string()))
}

fn check_free_space(available: u64, size: u64) -> Result<u64> {
    let required = required_free_bytes(size)?;
    if available < required {
        return Err(CatoolsError::ValidationError(format!(
            "/tmp 空间不足：可用 {} 字节，需要 {} 字节（镜像大小含 20% 余量）",
            available, required
        )));
    }
    Ok(required)
}

fn compare_sha256(expected: &str, actual: &str) -> Result<()> {
    let valid = |hash: &str| hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit());
    if !valid(expected) || !valid(actual) || !expected.eq_ignore_ascii_case(actual) {
        return Err(CatoolsError::ValidationError(format!(
            "sha256 校验失败：预期 {}，实际 {}；禁止刷入",
            expected, actual
        )));
    }
    Ok(())
}

fn verify_download(path: &str, expected: &str) -> Result<()> {
    let output = run_command("sha256sum", &[path])?;
    let actual = output.split_whitespace().next().unwrap_or("");
    if let Err(error) = compare_sha256(expected, actual) {
        fs::remove_file(path).map_err(|remove_error| {
            CatoolsError::ValidationError(format!(
                "{}；删除未验证镜像 {} 失败：{}",
                error, path, remove_error
            ))
        })?;
        return Err(error);
    }
    Ok(())
}

fn download_image(url: &str) -> Result<()> {
    let mut failures = Vec::new();
    for (tool, args) in [
        ("uclient-fetch", vec!["-O", IMAGE_FILE, url]),
        ("wget", vec!["-O", IMAGE_FILE, url]),
        ("curl", vec!["-fL", "-o", IMAGE_FILE, url]),
    ] {
        println!("使用 {} 下载镜像：{}", tool, url);
        match run_command(tool, &args) {
            Ok(_) => return Ok(()),
            Err(error) => {
                eprintln!("镜像下载失败：{}", error);
                failures.push(error.to_string());
            }
        }
    }
    Err(CatoolsError::ApiError(format!(
        "所有镜像下载工具均失败：\n{}",
        failures.join("\n")
    )))
}

fn include_backup(content: &str) -> String {
    if content
        .lines()
        .any(|line| line.split('#').next().unwrap_or("").trim() == BACKUP_FILE)
    {
        return content.to_string();
    }
    let separator = if content.is_empty() || content.ends_with('\n') {
        ""
    } else {
        "\n"
    };
    format!("{}{}{}\n", content, separator, BACKUP_FILE)
}

fn preserve_package_backup() -> Result<()> {
    backup_packages()?;
    let content = match fs::read_to_string(SYSUPGRADE_CONF) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(error.into()),
    };
    let updated = include_backup(&content);
    if updated != content {
        fs::write(SYSUPGRADE_CONF, updated)?;
    }
    Ok(())
}

fn upgrade(release: &Release, meta: &UpdateMeta) -> Result<()> {
    let mounts = fs::read_to_string("/proc/mounts")?;
    let variant = variant(Path::new("/sys/firmware/efi"), &mounts);
    println!("当前架构：{}，镜像变体：{}", release.arch, variant);
    let image = match meta.image(&release.arch, &variant) {
        Ok(image) => image,
        Err(error) => {
            println!("{}；已取消升级", error);
            return Ok(());
        }
    };
    let available = parse_free_bytes(&run_command("df", &["-k", "/tmp"])?)?;
    let required = check_free_space(available, image.size)?;
    println!("/tmp 可用 {} 字节，需要 {} 字节", available, required);
    download_image(&image.url)?;
    verify_download(IMAGE_FILE, &image.sha256)?;
    println!("镜像 sha256 校验通过");
    preserve_package_backup()?;

    println!("升级将重启设备，请先保存重要数据，升级过程中请勿断电。");
    if !Confirm::new()
        .with_prompt("确认刷入已验证的镜像？")
        .default(false)
        .interact()?
    {
        println!("已取消升级");
        return Ok(());
    }
    let keep_settings = Confirm::new()
        .with_prompt("是否保留当前设置？")
        .default(true)
        .interact()?;
    if !keep_settings {
        println!("不保留设置会清除当前配置，软件包备份也不会随配置恢复。");
        if !Confirm::new()
            .with_prompt("确认清除设置并升级？")
            .default(false)
            .interact()?
        {
            println!("已取消升级");
            return Ok(());
        }
    }

    // Recheck after interactive prompts, immediately before the only flashing command.
    verify_download(IMAGE_FILE, &image.sha256)?;
    let args = if keep_settings {
        vec!["-v", IMAGE_FILE]
    } else {
        vec!["-n", "-v", IMAGE_FILE]
    };
    run_command("sysupgrade", &args)?;
    println!("升级命令已完成，设备即将重启。");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_requires_real_version_and_arch() {
        let release = parse_release("version='v26.12-dev'\nbase=test\narch=x86_64\n").unwrap();
        assert_eq!(release.version, "v26.12-dev");
        assert_eq!(release.arch, "x86_64");
        for content in ["", "version=v26.12", "arch=x86_64", "version=\narch=x86_64"] {
            assert!(parse_release(content).is_err());
        }
    }

    #[test]
    fn detect_filesystem_from_mounts() {
        for (mounts, expected) in [
            ("/dev/root / ext4 rw 0 0\n", "ext4"),
            (
                "/dev/root /rom squashfs ro 0 0\noverlayfs:/overlay / overlay rw 0 0\n",
                "squashfs",
            ),
            ("/dev/root / squashfs ro 0 0\n", "squashfs"),
            (
                "/dev/root /lower squashfs ro 0 0\noverlay / overlay rw,lowerdir=/lower/base 0 0\n",
                "squashfs",
            ),
            (
                "/dev/root /lower squashfs ro 0 0\noverlay / overlay rw,lowerdir=/lower-other 0 0\n",
                "ext4",
            ),
            (
                "/dev/root / ext4 rw 0 0\noverlay /data overlay rw,lowerdir=/data/base 0 0\n",
                "ext4",
            ),
            (
                "/dev/loop0 /other squashfs ro 0 0\n/dev/root / ext4 rw 0 0\n",
                "ext4",
            ),
            ("invalid\n", "ext4"),
        ] {
            assert_eq!(filesystem(mounts), expected, "{mounts}");
        }
    }

    #[test]
    fn detect_boot_from_supplied_path() {
        let existing = Path::new(env!("CARGO_MANIFEST_DIR"));
        let absent = existing.join("nonexistent-efi-fixture");
        assert_eq!(boot_mode(existing), "efi");
        assert_eq!(boot_mode(&absent), "bios");
        assert_eq!(variant(existing, "/dev/root / ext4 rw 0 0"), "ext4-efi");
        assert_eq!(
            variant(&absent, "/dev/root /rom squashfs ro 0 0"),
            "squashfs-bios"
        );
    }

    #[test]
    fn sha256_must_be_valid_and_match_case_insensitively() {
        let expected = "a".repeat(64);
        assert!(compare_sha256(&expected, &"A".repeat(64)).is_ok());
        let actual = "b".repeat(64);
        let error = compare_sha256(&expected, &actual).unwrap_err().to_string();
        assert!(error.contains(&expected));
        assert!(error.contains(&actual));
        for invalid in ["", "a", &"g".repeat(64), &"a".repeat(63)] {
            assert!(compare_sha256(invalid, invalid).is_err());
            assert!(compare_sha256(&expected, invalid).is_err());
        }
    }

    #[test]
    fn free_space_includes_margin_and_unknown_size_fallback() {
        assert_eq!(check_free_space(1200, 1000).unwrap(), 1200);
        assert!(check_free_space(1199, 1000).is_err());
        assert_eq!(required_free_bytes(1).unwrap(), 2);
        let fallback = 480 * 1024 * 1024;
        assert_eq!(check_free_space(fallback, 0).unwrap(), fallback);
        assert!(check_free_space(fallback - 1, 0).is_err());
        assert!(check_free_space(u64::MAX, u64::MAX).is_err());
    }

    #[test]
    fn parse_busybox_df_and_reject_bad_output() {
        let normal = concat!(
            "Filesystem 1K-blocks Used Available Use% Mounted on\n",
            "tmpfs 1024 24 1000 2% /tmp\n"
        );
        let wrapped = concat!(
            "Filesystem 1K-blocks Used Available Use% Mounted on\n",
            "long-filesystem\n 1024 24 1000 2% /tmp\n"
        );
        assert_eq!(parse_free_bytes(normal).unwrap(), 1000 * 1024);
        assert_eq!(parse_free_bytes(wrapped).unwrap(), 1000 * 1024);
        assert_eq!(parse_free_bytes("tmpfs 1024 1024 0 100% /tmp").unwrap(), 0);
        for invalid in ["", "Filesystem Available", "tmpfs 1024 0 unknown 0% /tmp"] {
            assert!(parse_free_bytes(invalid).is_err());
        }
    }

    #[test]
    fn backup_entry_is_appended_once() {
        for content in [
            "",
            "/etc/config/",
            "/etc/config/\n",
            "# /etc/catwrt_apk_world.bak\n",
        ] {
            let updated = include_backup(content);
            assert_eq!(include_backup(&updated), updated);
            assert!(updated.ends_with(&format!("{}\n", BACKUP_FILE)));
        }
        let present = format!(" {} # package backup\n/etc/config/\n", BACKUP_FILE);
        assert_eq!(include_backup(&present), present);
    }
}
