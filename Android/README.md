# NetAccelerator Android

安卓无 Root 版本使用系统 `VpnService` 创建仅限本机的 DNS 通道，不修改系统 Hosts，也不会把网页流量发送到第三方 VPN 服务器。

## 当前支持

- Android 8.0（API 26）及以上。
- 一键开启/停止，停止后系统自动撤销本地 VPN 与 DNS 路由。
- 对 `config/watt-rules.tsv` 中具有可直接使用 IP 的 GitHub、GitHub Pages、GitHub Raw、GitHub Dev、GitHub App 和 Docker Hub 规则返回固定 IPv4。
- 其余域名通过受保护的直连 UDP 套接字转发到 `1.1.1.1`，不会形成 VPN 回环。
- 对已加速域名屏蔽 AAAA 响应，避免 IPv6 绕过 IPv4 加速结果。

## 为什么没有照搬全部 Windows 规则

Windows 版在本机终止 TLS，并用用户信任的本地证书重新签发，因此能兼容 Watt 中 `ignore TLS name mismatch=true` 的转发域名。安卓应用若这样做，需要用户安装 CA，并对所有目标 HTTPS 进行中间人解密；这既扩大权限，也会被启用证书固定的应用拒绝。

本版只启用不需要解密 HTTPS 的安全子集。验证码 CDN、路径重写、`pt.mossimo.net:41080` 服务器加速暂不宣称支持。应用只接管系统 DNS；自行内置 DoH 的浏览器或应用也可能绕过它。

## 构建

### GitHub Codespaces（推荐）

1. 把当前更改推送到 GitHub。
2. 在仓库页面选择 **Code → Codespaces → Create codespace on 当前分支**。
3. 等待容器创建完成。配置会在云端安装 JDK 17、Gradle 8.10.2、Android SDK 35 和 Build Tools 35.0.0，并自动检查版本。
4. 在 Codespace 中按 `Ctrl+Shift+B`，运行默认任务“构建安卓 APK”。
5. 从 `artifacts/NetAccelerator-android-debug.apk` 下载 APK；终端同时会显示 SHA-256。

也可以在 Codespace 终端执行：

```bash
bash .devcontainer/build-android.sh
```

### Android Studio

用 Android Studio 打开本目录，安装 Android SDK 35 和 JDK 17，然后构建 `app`。当前仓库没有提交 Gradle Wrapper 二进制文件；Android Studio 可使用本机 Gradle，或在可信环境中生成 Wrapper。

命令行环境准备好后可执行：

```powershell
gradle --project-dir android :app:assembleDebug
```

调试 APK 输出到 `app/build/outputs/apk/debug/app-debug.apk`。

## 真机验收

1. 安装并打开应用，点击“开启 GitHub 加速”，接受安卓的 VPN 授权。
2. 确认状态变为“加速中”，系统状态栏出现 VPN 图标。
3. 浏览器访问 `https://github.com`、`https://raw.githubusercontent.com` 和一个 `github.io` 页面。
4. 停止后确认 VPN 图标消失，普通网络仍可访问。

安卓同一时间只能启用一个 `VpnService`，因此开启本应用会与 Clash、WireGuard 等 VPN 模式互斥。
