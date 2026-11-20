/* src/modules/advanced.rs */

use crate::error::Result;
use crate::uci::Uci;
use crate::utils::apk;
use crate::utils::system::{restart_service, run_command, run_shell};
use dialoguer::{Confirm, Input};
use std::fs;
use std::path::Path;

/// Configure Tailscale
pub fn configure_tailscale() -> Result<()> {
    println!("\n配置 Tailscale");

    // Check if tailscale is installed
    if !apk::is_installed("tailscale")? {
        println!("Tailscale 未安装");

        if Confirm::new()
            .with_prompt("是否安装 Tailscale？")
            .default(true)
            .interact()?
        {
            println!("\n安装 Tailscale...");
            apk::update()?;
            apk::add(&["tailscale"])?;
            println!("✓ Tailscale 安装完成");
        } else {
            return Ok(());
        }
    }

    // Start tailscale daemon
    println!("\n启动 Tailscale 服务...");
    let _ = run_command("tailscaled", &[]);

    // Start tailscale up
    println!("\n配置 Tailscale...");
    println!("请访问下面的链接完成设备认证：");
    run_command("tailscale", &["up"])?;

    println!("\n✓ Tailscale 配置完成");

    Ok(())
}

/// Configure TTYD passwordless login (DANGEROUS!)
pub fn configure_ttyd() -> Result<()> {
    println!("\n配置 TTYD 免密登录");
    println!("\n警告: 此操作将允许任何人无需密码访问您的终端！");
    println!("这是一个严重的安全风险，仅建议在完全隔离的测试环境中使用。");

    if !Confirm::new()
        .with_prompt("您确定要继续吗？")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    if !Confirm::new()
        .with_prompt("再次确认: 这将使您的系统容易受到攻击，确定继续？")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    // Modify TTYD configuration
    let uci = Uci::new();
    uci.set("ttyd.@ttyd[0].command", "/bin/login -f root")?;
    uci.commit("ttyd")?;

    restart_service("ttyd")?;

    println!("\n✓ TTYD 免密登录已配置");
    println!("警告: 请尽快恢复正常配置！");

    Ok(())
}

/// Deploy SSL certificate
pub fn deploy_ssl_cert() -> Result<()> {
    println!("\n部署 SSL 证书");

    let cert_path: String = Input::new()
        .with_prompt("请输入证书压缩包路径 (ZIP 格式)")
        .interact_text()?;

    if !Path::new(&cert_path).exists() {
        println!("[ERROR] 文件不存在: {}", cert_path);
        return Ok(());
    }

    // Extract ZIP using system unzip command (OpenWrt dependency)
    println!("\n解压证书文件...");
    let extract_dir = "/tmp/ssl_cert";
    let _ = fs::remove_dir_all(extract_dir);
    fs::create_dir_all(extract_dir)?;
    run_command("unzip", &["-o", &cert_path, "-d", extract_dir]).or_else(|_| {
        run_shell(&format!(
            "busybox unzip -o '{}' -d '{}'",
            cert_path, extract_dir
        ))
    })?;

    println!("✓ 证书文件已解压到: {}", extract_dir);

    // Find certificate files
    println!("\n查找证书文件...");
    let list_output = run_command("find", &[extract_dir, "-type", "f"])
        .or_else(|_| run_shell(&format!("busybox find '{}' -type f", extract_dir)))?;

    let mut cert_file: Option<String> = None;
    let mut key_file: Option<String> = None;

    for filename in list_output.lines() {
        if filename.ends_with(".pem") || filename.ends_with(".crt") {
            cert_file = Some(filename.to_string());
        } else if filename.ends_with(".key") {
            key_file = Some(filename.to_string());
        }
    }

    if cert_file.is_none() || key_file.is_none() {
        println!("[ERROR] 未找到有效的证书文件 (.pem/.crt 和 .key)");
        return Ok(());
    }

    let cert_file = cert_file.unwrap();
    let key_file = key_file.unwrap();

    println!("找到证书: {}", cert_file);
    println!("找到密钥: {}", key_file);

    // Copy to uhttpd directory
    let dest_cert = "/etc/uhttpd.crt";
    let dest_key = "/etc/uhttpd.key";

    fs::copy(&cert_file, dest_cert)?;
    fs::copy(&key_file, dest_key)?;

    // Configure uhttpd
    let uci = Uci::new();
    uci.set("uhttpd.main.cert", dest_cert)?;
    uci.set("uhttpd.main.key", dest_key)?;
    uci.commit("uhttpd")?;

    restart_service("uhttpd")?;

    println!("\n✓ SSL 证书部署完成！");
    println!("HTTPS 服务已启用");

    Ok(())
}

/// Reset root password to default
pub fn reset_root_password() -> Result<()> {
    println!("\n重置 root 密码");
    println!("密码将被重置为: password");

    if !Confirm::new()
        .with_prompt("确认重置密码？")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    // Use passwd command to set password
    println!("\n重置密码...");

    // Create a script to set password non-interactively
    let script = r#"#!/bin/sh
echo "root:password" | chpasswd
"#;

    let script_path = "/tmp/reset_passwd.sh";
    fs::write(script_path, script)?;
    run_command("chmod", &["+x", script_path])?;
    run_command("sh", &[script_path])?;
    fs::remove_file(script_path)?;

    println!("✓ root 密码已重置为: password");
    println!("请尽快修改密码！");

    Ok(())
}

/// System reset (factory reset)
pub fn system_reset() -> Result<()> {
    println!("\n系统重置");
    println!("\n警告: 此操作将删除所有配置和数据！");
    println!("设备将恢复到出厂设置！");

    if !Confirm::new()
        .with_prompt("确认要重置系统？")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    if !Confirm::new()
        .with_prompt("再次确认: 这将删除所有数据，确定继续？")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    if !Confirm::new()
        .with_prompt("最后确认: 所有配置和数据将永久丢失！")
        .default(false)
        .interact()?
    {
        println!("已取消");
        return Ok(());
    }

    println!("\n执行系统重置...");
    run_command("firstboot", &["-y"])?;

    println!("\n✓ 系统重置完成");
    println!("设备将在 5 秒后重启...");

    std::thread::sleep(std::time::Duration::from_secs(5));
    let _ = run_command("reboot", &[]);

    Ok(())
}
