# CatWrt Next

非官方后继项目，与原作者无关，基于原 CatWrt 的 GPL 代码和思路。

CatWrt Next 以 ImmortalWrt 25.12.2 为底座，延续 CatWrt 的默认配置、中文界面与 cattools 使用体验，目标是提供可复现构建、可校验更新的路由固件。目前处于开发阶段。

## 平台与默认设置

- 首先支持 x86_64，计划提供 squashfs / ext4、BIOS / UEFI 的 `img.gz` 和 `qcow2` 镜像，根分区为 1024 MB。
- 默认 LAN 地址为 `192.168.1.4`，LuCI 默认使用简体中文。
- 首次启动时 root 没有密码，LuCI 会提示设置密码；请在首次登录后完成设置。
- 软件包管理器为 apk-tools v3，防火墙使用 fw4 / nftables。
- 预装 qemu-ga（默认停用），便于在 PVE 等平台管理虚拟机；open-vm-tools 与 qemu-ga 都要提供 `/sbin/shutdown`，两者不能共存，VMware 用户需先卸载 qemu-ga 再安装 open-vm-tools。

## 从原版 CatWrt 迁移

从原版 CatWrt 迁移前，请先阅读[迁移文档](docs/migration.md)。
文档说明版本要求、备份与迁移步骤、迁移后检查清单，以及不兼容项和回滚方法。

## 构建与验证

正式构建在 GitHub Actions 中使用 ImmortalWrt 25.12 ImageBuilder 和 SDK：ImageBuilder 组装官方内核与软件包，SDK 打包项目自编软件。cattools 使用 Rust 的 musl 目标构建。发布镜像在刷入前必须校验 SHA-256。

发布参数与预装清单位于 `config/`。在 Git Bash 或 Linux 中运行 `bash scripts/verify.sh`，即可执行与 CI 共用的检查入口。本机缺少检查工具时，入口会构建验证用 Docker 镜像；需要 Git 和 Docker。Rust 检查在引入 cattools 后自动启用。

## 许可与反馈

本项目使用 **GPL-2.0-only**，全文见 [LICENSE](LICENSE)，来源与致谢见 [CREDITS.md](CREDITS.md)。反馈请通过本仓库的 GitHub Issues 提交。

## English

CatWrt Next is an unofficial successor to CatWrt, independent of its original author and based on the original GPL code and ideas. It targets x86_64 first and uses ImmortalWrt 25.12 ImageBuilder and SDK on GitHub Actions. The default LAN address is `192.168.1.4`; root initially has no password, and LuCI prompts you to set one. Licensed under GPL-2.0-only. Please report feedback through this repository's GitHub Issues.
