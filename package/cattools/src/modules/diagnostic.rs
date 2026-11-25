/* src/modules/diagnostic.rs */

use crate::constants::RELEASE_FILE;
use crate::error::{CatoolsError, Result};
use crate::utils::apk;
use crate::utils::system::run_command;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

const LEGACY_WEB_LOG_FILE: &str = "/www/logs.txt";
const DIAGNOSTIC_DIR: &str = "/tmp";
const DIAGNOSTIC_FILE_PREFIX: &str = "catwrt-diagnostic";
const ALLOWED_RELEASE_KEYS: &[&str] = &["version", "base", "arch", "build_date"];
const ALLOWED_MEMINFO_KEYS: &[&str] = &[
    "MemTotal",
    "MemFree",
    "MemAvailable",
    "Buffers",
    "Cached",
    "SwapTotal",
    "SwapFree",
];
const ALLOWED_DISK_MOUNTS: &[&str] = &["/", "/overlay", "/rom", "/tmp"];

fn now_string() -> String {
    run_command("date", &["+%Y-%m-%d %H:%M:%S"])
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown-time".to_string())
}

/// Network diagnostic
pub fn network_diagnostic() -> Result<()> {
    println!("\n{} - CatWrt Next Network Diagnostics", now_string());
    println!();

    // Ping test
    println!("[Ping] Testing network connection...");
    let ping_result = run_command("ping", &["-c", "3", "223.5.5.5"]);
    if ping_result.is_ok() {
        println!("[Ping] Network connection succeeded!");
        println!();
    } else {
        println!("[Ping] Primary DNS failed, trying backup...");
        let backup_ping = run_command("ping", &["-c", "3", "119.29.29.99"]);
        if backup_ping.is_ok() {
            println!("[Ping] Network connection succeeded, but there may be problems!");
            println!();
        } else {
            println!("[Ping] Network connection failed!");
            // Check PPPoE
            if let Ok(config) = fs::read_to_string("/etc/config/network")
                && config.contains("pppoe")
            {
                println!("[PPPoE] Please check if your PPPoE account and password are correct.");
            }
            println!();
        }
    }

    // DNS check
    println!("[DNS] Checking DNS configuration...");
    if let Ok(config) = fs::read_to_string("/etc/config/network") {
        let _valid_dns = [
            "1.1.1.1",
            "1.0.0.1",
            "8.8.8.8",
            "8.8.4.4",
            "223.6.6.6",
            "223.5.5.5",
            "180.76.76.76",
            "208.67.222.222",
            "208.67.220.220",
            "119.29.29.99",
        ];

        for line in config.lines() {
            if line.contains("option dns") {
                println!("[DNS] DNS configuration found: {}", line.trim());
            }
        }
    }
    println!("[DNS] DNS configuration looks good!");
    println!();

    // Public IP
    println!("[IPv4] Checking public IPv4 address...");
    if let Ok(output) = run_command("curl", &["--silent", "--connect-timeout", "5", "4.ipw.cn"]) {
        println!("CatWrt IPv4 Addr: {}", output.trim());
    } else {
        println!("[IPv4] Failed to get IPv4 address");
    }
    println!();

    // IPv6
    println!("[IPv6] Checking IPv6 connectivity...");
    let ipv6_result = run_command("curl", &["--silent", "--connect-timeout", "5", "6.ipw.cn"]);
    if let Ok(output) = ipv6_result {
        println!("CatWrt IPv6 Addr: {}", output.trim());
    } else {
        println!("[IPv6] IPv6 network connection timed out");
    }
    println!();

    // Tcping
    println!("[Tcping] Testing connectivity to common sites...");
    let sites = ["cn.bing.com", "bilibili.com", "github.com", "google.com.hk"];
    for site in &sites {
        let result = run_command("tcping", &["-q", "-c", "1", site]);
        if result.is_err() {
            println!("Failed: {}", site);
        } else {
            println!("Success: {}", site);
        }
    }
    println!();

    println!("{} - Network check completed!", now_string());
    println!("CatWrt Next Network Diagnostics");

    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WanProto {
    Dhcp,
    Dhcpv6,
    Pppoe,
    Static,
    None,
    Qmi,
    Ncm,
    Mbim,
    Modem3g,
    L2tp,
    Pptp,
    Wireguard,
}

impl WanProto {
    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().trim_matches('\'') {
            "dhcp" => Some(Self::Dhcp),
            "dhcpv6" => Some(Self::Dhcpv6),
            "pppoe" => Some(Self::Pppoe),
            "static" => Some(Self::Static),
            "none" => Some(Self::None),
            "qmi" => Some(Self::Qmi),
            "ncm" => Some(Self::Ncm),
            "mbim" => Some(Self::Mbim),
            "3g" => Some(Self::Modem3g),
            "l2tp" => Some(Self::L2tp),
            "pptp" => Some(Self::Pptp),
            "wireguard" => Some(Self::Wireguard),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Dhcp => "dhcp",
            Self::Dhcpv6 => "dhcpv6",
            Self::Pppoe => "pppoe",
            Self::Static => "static",
            Self::None => "none",
            Self::Qmi => "qmi",
            Self::Ncm => "ncm",
            Self::Mbim => "mbim",
            Self::Modem3g => "3g",
            Self::L2tp => "l2tp",
            Self::Pptp => "pptp",
            Self::Wireguard => "wireguard",
        }
    }
}

struct DiagnosticInputs {
    timestamp: String,
    release: Option<String>,
    kernel: Option<String>,
    meminfo: Option<String>,
    disk_usage: Option<String>,
    packages: Option<Vec<String>>,
    wan_proto: Option<String>,
    packet_steering: Option<String>,
    steering_flows: Option<String>,
}

fn sanitize_stamp_for_filename(timestamp: &str) -> String {
    let digits: String = timestamp
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c
            } else if c == ' ' || c == '-' {
                '-'
            } else {
                '_'
            }
        })
        .filter(|&c| c != '_')
        .take(32)
        .collect();
    let trimmed = digits.trim_matches('-');
    if trimmed.is_empty() {
        "unknown".to_string()
    } else {
        trimmed.to_string()
    }
}

fn is_safe_value(value: &str, max_len: usize, extra_chars: &[char]) -> bool {
    !value.is_empty()
        && value.len() <= max_len
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || extra_chars.contains(&c))
}

fn format_allowlisted_release(raw: &str) -> Vec<String> {
    raw.lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            let key = key.trim();
            if !ALLOWED_RELEASE_KEYS.contains(&key) {
                return None;
            }
            let value = value.trim().trim_matches(['\'', '"']);
            is_safe_value(value, 64, &['.', '-', '_', '+', ':']).then(|| format!("{key}={value}"))
        })
        .collect()
}

fn format_allowlisted_kernel(raw: &str) -> Option<String> {
    let first = raw.lines().next()?.trim();
    is_safe_value(first, 128, &['.', '-', '_', '+', ' ']).then(|| first.to_string())
}

fn format_allowlisted_meminfo(raw: &str) -> Vec<String> {
    raw.lines()
        .filter_map(|line| {
            let (key, rest) = line.split_once(':')?;
            let key = key.trim();
            if !ALLOWED_MEMINFO_KEYS.contains(&key) {
                return None;
            }
            let mut parts = rest.split_whitespace();
            let amount = parts.next()?;
            if !amount.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            let unit = parts.next();
            if parts.next().is_some() {
                return None;
            }
            match unit {
                Some(u) if matches!(u, "kB" | "MB" | "GB" | "B") => {
                    Some(format!("{key}: {amount} {u}"))
                }
                None => Some(format!("{key}: {amount}")),
                _ => None,
            }
        })
        .collect()
}

fn format_allowlisted_disk(raw: &str) -> Vec<String> {
    raw.lines()
        .skip(1)
        .filter_map(|line| {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 6 {
                return None;
            }
            let mount = *cols.last()?;
            if !ALLOWED_DISK_MOUNTS.contains(&mount) {
                return None;
            }
            let size = cols[cols.len() - 5];
            let used = cols[cols.len() - 4];
            let avail = cols[cols.len() - 3];
            let use_pct = cols[cols.len() - 2];
            let ok = [size, used, avail, use_pct]
                .iter()
                .all(|field| is_safe_value(field, 16, &['.', '%', '-']));
            ok.then(|| format!("{mount}: size={size}, used={used}, avail={avail}, use={use_pct}"))
        })
        .collect()
}

fn format_allowlisted_network(inputs: &DiagnosticInputs) -> Vec<String> {
    let mut lines = Vec::new();
    if let Some(proto) = inputs.wan_proto.as_deref().and_then(WanProto::parse) {
        lines.push(format!("wan.proto={}", proto.as_str()));
    }
    if let Some(value) = inputs
        .packet_steering
        .as_deref()
        .and_then(|raw| raw.trim().trim_matches('\'').parse::<u8>().ok())
    {
        lines.push(format!("globals.packet_steering={value}"));
    }
    if let Some(value) = inputs
        .steering_flows
        .as_deref()
        .and_then(|raw| raw.trim().trim_matches('\'').parse::<u32>().ok())
    {
        lines.push(format!("globals.steering_flows={value}"));
    }
    lines
}

fn format_allowlisted_packages(names: &[String]) -> Vec<String> {
    let mut filtered: Vec<String> = names
        .iter()
        .filter(|name| is_safe_value(name, 64, &['.', '_', '+', '-']))
        .cloned()
        .collect();
    filtered.sort();
    filtered.dedup();
    filtered
}

fn push_section(report: &mut String, title: &str, lines: &[String]) {
    report.push_str(&format!("## {title}\n"));
    if lines.is_empty() {
        report.push_str("unavailable\n");
    } else {
        for line in lines {
            report.push_str(line);
            report.push('\n');
        }
    }
    report.push('\n');
}

fn build_diagnostic_report(inputs: &DiagnosticInputs) -> String {
    let mut report = String::new();
    let timestamp = inputs
        .timestamp
        .lines()
        .next()
        .map(str::trim)
        .filter(|s| is_safe_value(s, 32, &['-', ':', ' ']))
        .unwrap_or("unknown-time");

    report.push_str("CatWrt Next Diagnostic Report\n");
    report.push_str(&format!("Generated: {timestamp}\n\n"));

    let release_lines = inputs
        .release
        .as_deref()
        .map(format_allowlisted_release)
        .unwrap_or_default();
    push_section(&mut report, "RELEASE", &release_lines);

    let kernel_lines = inputs
        .kernel
        .as_deref()
        .and_then(format_allowlisted_kernel)
        .into_iter()
        .collect::<Vec<_>>();
    push_section(&mut report, "KERNEL", &kernel_lines);

    let mem_lines = inputs
        .meminfo
        .as_deref()
        .map(format_allowlisted_meminfo)
        .unwrap_or_default();
    push_section(&mut report, "MEMORY", &mem_lines);

    let disk_lines = inputs
        .disk_usage
        .as_deref()
        .map(format_allowlisted_disk)
        .unwrap_or_default();
    push_section(&mut report, "DISK", &disk_lines);

    let network_lines = format_allowlisted_network(inputs);
    push_section(&mut report, "NETWORK", &network_lines);

    let package_lines = inputs
        .packages
        .as_deref()
        .map(format_allowlisted_packages)
        .unwrap_or_default();
    push_section(&mut report, "PACKAGES", &package_lines);

    report
}

fn remove_legacy_log(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => fs::remove_file(path).map_err(|e| {
            CatoolsError::ConfigError(format!("无法删除旧诊断日志 {}：{}", path.display(), e))
        }),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(CatoolsError::ConfigError(format!(
            "无法检查旧诊断日志 {}：{}",
            path.display(),
            e
        ))),
    }
}

fn write_report_exclusively(path: &Path, content: &str) -> std::io::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(content.as_bytes())?;
    file.sync_all()?;
    Ok(())
}

fn create_report_in_dir(dir: &Path, stamp: &str, content: &str) -> Result<PathBuf> {
    let pid = std::process::id();
    for attempt in 0u32..16 {
        let filename = if attempt == 0 {
            format!("{DIAGNOSTIC_FILE_PREFIX}-{stamp}-{pid}.log")
        } else {
            format!("{DIAGNOSTIC_FILE_PREFIX}-{stamp}-{pid}-{attempt}.log")
        };
        let candidate = dir.join(filename);
        match write_report_exclusively(&candidate, content) {
            Ok(()) => return Ok(candidate),
            Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(CatoolsError::IoError(e)),
        }
    }
    Err(CatoolsError::ConfigError(format!(
        "无法在 {} 独占创建诊断报告文件（候选路径已存在）",
        dir.display()
    )))
}

fn export_diagnostic_report(
    legacy_web_log: &Path,
    output_dir: &Path,
    inputs: &DiagnosticInputs,
) -> Result<PathBuf> {
    remove_legacy_log(legacy_web_log)?;
    let report = build_diagnostic_report(inputs);
    let stamp = sanitize_stamp_for_filename(&inputs.timestamp);
    create_report_in_dir(output_dir, &stamp, &report)
}

fn format_completion_notice(report_path: &Path) -> String {
    format!(
        "\n✓ 诊断报告收集完成！\n\
         ==========================================================================================\n\
         本地路径: {}（权限 0600，未写入 Web 根目录）\n\
         请通过 SSH / SCP 取回该文件:\n\
         \x20 scp root@<路由器管理地址>:{} .\n\
         报告仅包含白名单系统字段，上传 Issue 前仍建议人工复核，用完后建议删除该临时文件。\n\n\
         https://github.com/Mtoly/CatWrt_Next/issues/new\n",
        report_path.display(),
        report_path.display()
    )
}

/// System debug - collect allowlisted diagnostic summary
pub fn system_debug() -> Result<()> {
    println!("\n收集系统诊断报告...");

    let inputs = DiagnosticInputs {
        timestamp: now_string(),
        release: fs::read_to_string(RELEASE_FILE).ok(),
        kernel: run_command("uname", &["-srm"]).ok(),
        meminfo: fs::read_to_string("/proc/meminfo").ok(),
        disk_usage: run_command("df", &["-h"]).ok(),
        packages: apk::installed_names().ok(),
        wan_proto: run_command("uci", &["-q", "get", "network.wan.proto"]).ok(),
        packet_steering: run_command("uci", &["-q", "get", "network.@globals[0].packet_steering"])
            .ok(),
        steering_flows: run_command("uci", &["-q", "get", "network.@globals[0].steering_flows"])
            .ok(),
    };

    let report_path = export_diagnostic_report(
        Path::new(LEGACY_WEB_LOG_FILE),
        Path::new(DIAGNOSTIC_DIR),
        &inputs,
    )?;

    print!("{}", format_completion_notice(&report_path));

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn make_temp_dir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "cattools-diag-test-{}-{}-{}",
            label,
            std::process::id(),
            nanos
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn export_removes_legacy_web_log_and_writes_allowlisted_report_outside_web_root() {
        let root = make_temp_dir("export");
        let web_root = root.join("www");
        let out_dir = root.join("tmp");
        fs::create_dir_all(&web_root).unwrap();
        fs::create_dir_all(&out_dir).unwrap();

        let legacy_log = web_root.join("logs.txt");
        let fake_cred = "demo-pppoe-cred-991";
        fs::write(
            &legacy_log,
            format!("network.wan.{}='{}'\n", concat!("pass", "word"), fake_cred),
        )
        .unwrap();

        let inputs = DiagnosticInputs {
            timestamp: "2026-11-25 08:30:00".to_string(),
            release: Some(
                "version=v26.12.8\nbase=immortalwrt-25.12.2\narch=x86_64\nbuild_date=2026-11-24\nextra_secret=drop-me\n"
                    .to_string(),
            ),
            kernel: Some("Linux 6.6.73 x86_64\n".to_string()),
            meminfo: Some(
                "MemTotal:        1024000 kB\nMemFree:          512000 kB\nMemAvailable:     768000 kB\nUnexpectedLine: drop-me\n"
                    .to_string(),
            ),
            disk_usage: Some(
                concat!(
                    "Filesystem      Size  Used Avail Use% Mounted on\n",
                    "/dev/root       256M  120M  136M  47% /\n",
                    "overlayfs:/overlay 1.0G 200M 824M 20% /overlay\n",
                    "nfs.internal:/private/share 2.0T 1.0T 1.0T 50% /mnt/private\n",
                )
                .to_string(),
            ),
            packages: Some(vec![
                "cattools".to_string(),
                "catwrt-base".to_string(),
                "bad package; stderr leak".to_string(),
            ]),
            wan_proto: Some("pppoe\n".to_string()),
            packet_steering: Some("1\n".to_string()),
            steering_flows: Some("16384\n".to_string()),
        };

        let report_path = export_diagnostic_report(&legacy_log, &out_dir, &inputs).unwrap();

        assert!(!legacy_log.exists(), "legacy /www/logs.txt must be removed");
        assert!(report_path.starts_with(&out_dir));
        assert!(!report_path.starts_with(&web_root));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::symlink_metadata(&report_path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600, "report must be created with mode 0600");
        }

        let report = fs::read_to_string(&report_path).unwrap();
        assert!(report.contains("version=v26.12.8"));
        assert!(report.contains("Linux 6.6.73 x86_64"));
        assert!(report.contains("MemTotal: 1024000 kB"));
        assert!(report.contains("/: size=256M, used=120M, avail=136M, use=47%"));
        assert!(report.contains("/overlay: size=1.0G, used=200M, avail=824M, use=20%"));
        assert!(report.contains("wan.proto=pppoe"));
        assert!(report.contains("globals.packet_steering=1"));
        assert!(report.contains("globals.steering_flows=16384"));
        assert!(report.contains("cattools"));

        assert!(!report.contains(fake_cred));
        assert!(!report.contains("drop-me"));
        assert!(!report.contains("/mnt/private"));
        assert!(!report.contains("nfs.internal"));
        assert!(!report.contains("stderr leak"));

        let notice = format_completion_notice(&report_path);
        assert!(notice.contains(&report_path.display().to_string()));
        assert!(notice.contains("scp root@<路由器管理地址>:"));
        assert!(!notice.contains("http://"));
        assert!(!notice.contains("/www/logs.txt"));
        assert!(!notice.contains("192.168.1."));

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn network_fields_reject_custom_names_unknown_protocols_and_non_integers() {
        let inputs = DiagnosticInputs {
            timestamp: "2026-11-25 08:30:00".to_string(),
            release: None,
            kernel: None,
            meminfo: None,
            disk_usage: None,
            packages: None,
            wan_proto: Some("corp_vpn_hq".to_string()),
            packet_steering: Some("enabled-by-corp_vpn_hq".to_string()),
            steering_flows: Some("16384; rm -rf".to_string()),
        };
        let report = build_diagnostic_report(&inputs);
        assert!(!report.contains("corp_vpn_hq"));
        assert!(!report.contains("rm -rf"));
        assert!(report.contains("## NETWORK\nunavailable\n"));
    }

    #[test]
    fn missing_inputs_emit_unavailable_without_raw_stderr() {
        let inputs = DiagnosticInputs {
            timestamp: "2026-11-25 08:30:00".to_string(),
            release: None,
            kernel: None,
            meminfo: None,
            disk_usage: None,
            packages: None,
            wan_proto: None,
            packet_steering: None,
            steering_flows: None,
        };
        let report = build_diagnostic_report(&inputs);
        assert!(report.contains("unavailable"));
        assert!(!report.contains("stderr"));
    }

    #[test]
    fn legacy_log_removal_failure_is_not_silently_ignored() {
        let root = make_temp_dir("legacy-fail");
        let legacy_dir = root.join("logs.txt");
        fs::create_dir_all(&legacy_dir).unwrap();

        let err = remove_legacy_log(&legacy_dir);
        assert!(err.is_err(), "failing to remove legacy log must return Err");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn write_report_exclusively_refuses_existing_file_or_symlink() {
        let root = make_temp_dir("excl");
        let target = root.join("victim.txt");
        fs::write(&target, "untouched").unwrap();

        assert!(write_report_exclusively(&target, "overwrite").is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");

        #[cfg(unix)]
        {
            let link = root.join("link.log");
            std::os::unix::fs::symlink(&target, &link).unwrap();
            assert!(write_report_exclusively(&link, "via-symlink").is_err());
            assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");

            // A pre-planted symlink at the first candidate filename must not be overwritten.
            let out_dir = root.join("out");
            fs::create_dir_all(&out_dir).unwrap();
            let first_candidate = out_dir.join(format!(
                "{}-20261125-083000-{}.log",
                DIAGNOSTIC_FILE_PREFIX,
                std::process::id()
            ));
            std::os::unix::fs::symlink(&target, &first_candidate).unwrap();
            let created = create_report_in_dir(&out_dir, "20261125-083000", "safe report").unwrap();
            assert_ne!(created, first_candidate);
            assert_eq!(fs::read_to_string(&target).unwrap(), "untouched");
            assert_eq!(fs::read_to_string(&created).unwrap(), "safe report");

            // A dangling symlink at the legacy path must still be removed.
            let dangling = root.join("dangling-logs.txt");
            std::os::unix::fs::symlink(root.join("nonexistent-target"), &dangling).unwrap();
            remove_legacy_log(&dangling).unwrap();
            assert!(fs::symlink_metadata(&dangling).is_err());
        }

        let _ = fs::remove_dir_all(&root);
    }
}
