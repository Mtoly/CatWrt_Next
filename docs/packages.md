# 自有软件源

CatWrt Next 固件默认只启用 ImmortalWrt 官方源。项目自编的软件包发布在 GitHub Pages 上，由 cattools 的“配置软件源”功能或手动写入 `/etc/apk/repositories.d/catwrt.list` 后启用。

## 收录的软件包

| 包名                       | 说明                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------ |
| `catwrt-base`              | CatWrt 默认设置、banner 与软件源公钥                                                                   |
| `cattools`                 | 命令行工具菜单（升级、软件源、诊断等）                                                                 |
| `luci-app-poweroff`        | LuCI 关机按钮                                                                                          |
| `luci-i18n-poweroff-zh-cn` | 关机按钮的中文翻译                                                                                     |
| `UAmask`                   | [UA-Mask](https://github.com/Zesuy/UA-Mask) 0.4.3，基于 nftables 的 HTTP User-Agent 透明改写，默认停用 |
| `luci-app-campus-auth`     | 校园网认证的 LuCI 应用 0.8.0-r2，专有软件（`LicenseRef-Proprietary`），安装后默认停用                  |

## 用户安装

软件源启用后直接安装：

```sh
apk update
apk add UAmask
```

UAmask 安装后不会自动启动，也不改写任何流量。在 LuCI 的“服务 → UA-Mask”中启用并配置需要改写的关键词，或编辑 `/etc/config/UAmask` 后执行 `/etc/init.d/UAmask restart`。它与 OpenClash 同时运行时使用不同的防火墙链，互不覆盖；`proxy_host` 关闭时只处理局域网转发的流量。

UAmask 是 GPL-3.0-only 软件，与本项目自身的 GPL-2.0-only 代码分开授权。它的源码不进入本仓库：构建时由 `scripts/build-packages.sh` 下载上游固定版本的源码压缩包，校验 SHA-256 后用 Go 交叉编译。

### 离线安装

本项目自有软件源导出的 `.apk` 自身不含内嵌签名，签名位于仓库索引 `packages.adb` 中，并由固件内置公钥 `/etc/apk/keys/catwrt-next.pem` 验证。设备尚未联网时，需同时准备目标软件包和对应的签名索引：

1. 在联网设备上，从**同一发布标签、同一架构**的仓库目录（`repo/<版本>/x86_64/`）下载 `packages.adb` 与目标 `.apk`。如果目标包有未安装的依赖，也需一并下载依赖包及其所属仓库的 `packages.adb`（不同仓库分开放入不同子目录）。
2. 保留原文件名不变，将同一仓库的 `packages.adb` 和对应 `.apk` 放到设备上的同一目录（例如 `/mnt/pkg/`）。传输后可用 `sha256sum` 核对传输完整性；SHA256 只校验文件未损坏，不能替代签名校验。
3. 在设备上通过签名索引按包名安装（需要指定或升级到特定版本时写 `<包名>=<版本>`）：

   ```sh
   apk add --no-network --repositories-file /dev/null --repository /mnt/pkg/packages.adb cattools=1.0.1-r2
   ```

   如果依赖来自其他仓库（例如 ImmortalWrt 官方源），在同一条命令中追加对应的 `--repository <目录>/packages.adb`。

注意：

- 直接传单个 `.apk` 文件路径执行 `apk add --no-network <文件>.apk` 要求该软件包自身带有可信内嵌签名；对不含内嵌签名的裸包执行该命令会返回 `UNTRUSTED signature`。
- 遇到 `UNTRUSTED signature` 时不要加 `--allow-untrusted`（它会跳过签名校验），也不要从不可信介质导入新公钥到 `/etc/apk/keys/`，应使用固件内置公钥配合对应仓库的签名 `packages.adb` 安装。

## 维护者发布

1. 准备签名私钥，设置 `APK_SIGN_KEY` 后运行：

   ```sh
   APK_SIGN_KEY="$(cat /path/to/private-key.pem)" bash scripts/build-packages.sh
   ```

   未设置时会用临时密钥构建并给出警告，产物不能用于正式发布。脚本会校验导出的公钥与 `package/catwrt-base/files/etc/apk/keys/catwrt-next.pem` 一致。

2. 构建产物在 `out/packages/`：每个包一个 `.apk`、签名索引 `packages.adb` 和公钥。当前固定导出 6 个 APK，数量或包名不符时脚本直接失败。

3. 发布到软件源：

   ```sh
   gh workflow run repo-publish.yml -f tag=v26.12.4
   ```

   工作流会重新核对 APK 数量（6 个）和公钥，然后把产物写入 `gh-pages` 的 `repo/<tag>/x86_64/`。固件里的软件源地址与发布标签一一对应，新版本发布后旧标签仍然可用。

## 注意

- 软件包只支持 x86_64。
- 软件源索引 `packages.adb` 用项目密钥签名并校验各软件包的完整性（本项目导出的 `.apk` 自身不含内嵌签名）；设备只信任固件内置的 `catwrt-next.pem`，不要用 `--allow-untrusted` 安装未通过验签的软件包。
- 上游 ImmortalWrt 的软件包请继续从其官方源安装，自有源不镜像官方包。
