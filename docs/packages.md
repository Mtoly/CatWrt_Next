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

## 用户安装

软件源启用后直接安装：

```sh
apk update
apk add UAmask
```

UAmask 安装后不会自动启动，也不改写任何流量。在 LuCI 的“服务 → UA-Mask”中启用并配置需要改写的关键词，或编辑 `/etc/config/UAmask` 后执行 `/etc/init.d/UAmask restart`。它与 OpenClash 同时运行时使用不同的防火墙链，互不覆盖；`proxy_host` 关闭时只处理局域网转发的流量。

UAmask 是 GPL-3.0-only 软件，与本项目自身的 GPL-2.0-only 代码分开授权。它的源码不进入本仓库：构建时由 `scripts/build-packages.sh` 下载上游固定版本的源码压缩包，校验 SHA-256 后用 Go 交叉编译。

## 维护者发布

1. 准备签名私钥，设置 `APK_SIGN_KEY` 后运行：

   ```sh
   APK_SIGN_KEY="$(cat /path/to/private-key.pem)" bash scripts/build-packages.sh
   ```

   未设置时会用临时密钥构建并给出警告，产物不能用于正式发布。脚本会校验导出的公钥与 `package/catwrt-base/files/etc/apk/keys/catwrt-next.pem` 一致。

2. 构建产物在 `out/packages/`：每个包一个 `.apk`、签名索引 `packages.adb` 和公钥。当前固定导出 5 个 APK，数量或包名不符时脚本直接失败。

3. 发布到软件源：

   ```sh
   gh workflow run repo-publish.yml -f tag=v26.12.4
   ```

   工作流会重新核对 APK 数量（5 个）和公钥，然后把产物写入 `gh-pages` 的 `repo/<tag>/x86_64/`。固件里的软件源地址与发布标签一一对应，新版本发布后旧标签仍然可用。

## 注意

- 软件包只支持 x86_64。
- 软件源索引与包都用项目密钥签名；设备只信任固件内置的 `catwrt-next.pem`，不要用 `--allow-untrusted` 安装第三方包。
- 上游 ImmortalWrt 的软件包请继续从其官方源安装，自有源不镜像官方包。
