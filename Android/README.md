# NetAccelerator Android

安卓无 Root 版本使用系统 `VpnService` 创建仅限本机的 DNS 通道，不修改系统 Hosts，也不会把网页流量发送到第三方 VPN 服务器。

## 当前支持

- Android 8.0（API 26）及以上。
- 一键开启/停止，停止后系统自动撤销本地 VPN 与 DNS 路由。
- 规则不再写死在 Java 代码中：应用内置安全基线，并从本仓库的 `android-rules.json` 每次启动刷新、运行中每 6 小时刷新；远程内容校验成功后原子缓存，失败继续使用最近缓存。
- 加速域名会把配置候选 IPv4 与原域名的实时 A 记录合并返回，单个优选 IP 失效时客户端仍有原站地址可尝试。
- 普通域名优先使用 DNSPod DoH，再使用 Cloudflare DoH；两者均超时后才降级到 DNSPod、阿里公共 DNS 的明文 UDP，以避免整个设备断网。
- 对已加速域名屏蔽 AAAA 响应，避免 IPv6 绕过 IPv4 加速结果。

## 为什么没有照搬全部 Windows 规则

Windows 版在本机终止 TLS，并用用户信任的本地证书重新签发，因此能兼容 Watt 中 `ignore TLS name mismatch=true` 的转发域名。安卓应用若这样做，需要用户安装 CA，并对所有目标 HTTPS 进行中间人解密；这既扩大权限，也会被启用证书固定的应用拒绝。

本版只启用不需要解密 HTTPS 的安全子集。验证码 CDN、路径重写、`pt.mossimo.net:41080` 服务器加速暂不宣称支持。应用只接管系统 DNS；私人 DNS 或自行内置 DoH 的浏览器/应用仍可能绕过它。DNS 候选链不能替代 Windows 版的 TCP/TLS 反代；TCP 层阻断严重时应使用独立的代理/VPN 工具，且安卓系统同一时刻只能有一个 `VpnService`。

## 规则更新

远程规则地址为：

```text
https://raw.githubusercontent.com/Ckarefulon/NetAccelerator/main/Android/app/src/main/assets/android-rules.json
```

更新该 JSON 并推送到 `main` 后，已安装的应用会自动获得新候选 IP，无需重新发布 APK。规则文件只接受合法域名和 IPv4 字面量，单域名最多 8 个候选，最大 256 KiB；下载失败或格式不合法不会覆盖现有缓存。

JSON 中的 IP 只是首选候选，不是唯一地址。应用每次收到加速域名查询时，都会通过上述 DoH 链直接获取原域名的当前 A 记录并合并进响应；因此即使长期不开 Watt、远程规则没有及时更新，仍能获得原站最新地址。

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
gradle --project-dir Android :app:assembleDebug
```

调试 APK 输出到 `app/build/outputs/apk/debug/app-debug.apk`。

## 真机验收

1. 安装并打开应用，点击“开启 GitHub 加速”，接受安卓的 VPN 授权。
2. 确认状态变为“加速中”，系统状态栏出现 VPN 图标。
3. 浏览器访问 `https://github.com`、`https://raw.githubusercontent.com` 和一个 `github.io` 页面。
4. 停止后确认 VPN 图标消失，普通网络仍可访问。

安卓同一时间只能启用一个 `VpnService`，因此开启本应用会与 Clash、WireGuard 等 VPN 模式互斥。
