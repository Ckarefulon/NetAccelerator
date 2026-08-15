# NetAccelerator

> 安卓无 Root 版本源码位于 [`android/`](android/README.md)。它使用仅本机的 `VpnService` DNS 通道，保留 Windows 版本不变；仓库已配置 GitHub Codespaces 云端构建，能力边界和构建方式见安卓说明。

NetAccelerator 是只保留 **Github** 与 **国外验证码平台** 的轻量 Watt Toolkit Hosts 模式实现。它本身不是全局 `CONNECT` 代理，也不会修改、停止或重启 Clash。

## 与 Watt Toolkit 相同的核心链路

1. 本机反向代理监听 `127.0.0.1:80` 和 `127.0.0.1:443`。
2. 仅在服务真实自检通过后，向 Hosts 写入带边界标记的目标域名映射。
3. 浏览器访问目标域名时连接本机；上游使用与 Watt 相同的现代 `SocketsHttpHandler` 连接池和应用层 HTTP 反向代理，不再为每个请求创建裸 `TcpClient + SslStream` 隧道。
4. `ConnectCallback` 按 Watt 顺序尝试配置 IP、转发域名 DNS、原域名 DNS，并保持原域名 SNI；启用 HTTP/2 多连接。
5. 每个域名首次 Handler 生命周期为 10 秒，后续为 100 秒，旧连接延迟回收，避免失效连接长期驻留。
6. 普通 Watt 规则优先使用配置 IP、转发域名 DNS、原域名 DNS，失败后才接入现有 Clash；服务器加速规则反向排序。Clash 的 GitHub 规则仍为 DIRECT，程序不修改 Clash 规则或系统代理。
7. 退出时只删除 `# NetAccelerator Start` 至 `# NetAccelerator End`，不覆盖其它 Hosts 内容。

目标域名来自当前 Watt Toolkit 中截图所示的两个启用组，完整清单位于 `config/domains.txt`，包括 Github Dev/API/Assets/Education/Resources/Uploads/UserContent、Git Push、Github App、Docker Hub、Github.io、Hugging Face、Greasy Fork，以及 Google reCAPTCHA、hCaptcha、Arkose Labs。

Hugging Face 与 Greasy Fork 在 Watt 中标记为 Beta，并依赖 Watt 后端签发的短期 `X-Watt-Token`。NetAccelerator 不读取或伪造 Watt 的账号令牌；这两项在令牌不可用时通过现有系统代理兼容转发。其余 GitHub 与验证码项目直接使用 Watt 缓存中的转发域名或优选 IP。

## 使用

双击 `启动.bat`。第一次启动会出现 UAC，并创建仅供本机反向代理使用的 NetAccelerator 根证书和覆盖目标域名的服务器证书。叶证书签发完成后会删除根证书私钥，只保留受信任公钥，避免运行期间继续签发其它证书。

Watt Toolkit 与 NetAccelerator 都需要占用 80/443，不能同时开启加速：

- 当前 Watt 正在加速时，NetAccelerator 只显示端口冲突，不修改 Hosts，不停止 Watt，也不触碰 Clash。
- 要改用 NetAccelerator，请由你在 Watt 界面手动停止加速服务，然后点击 NetAccelerator 的“重新开启加速”。无需退出 Watt，更不要关闭 Clash。

只有真实完成 `本机 TLS → 可信 DNS → GitHub 上游 TLS → HTTP 2xx/3xx` 自检后，托盘才会提示“加速已真实就绪”。

## 安全与恢复

- 系统代理始终保持原状；Clash 的 `127.0.0.1:7897` 不会被覆盖。
- 服务退出时自动恢复 Hosts。
- 若进程异常终止，右键以管理员身份运行 `恢复网络.bat`；它只删除 NetAccelerator 自己的 Hosts 区块。
- `runtime/hosts-backup.txt` 仅在服务生效期间生成，用于人工审计/紧急恢复；日志和状态也集中在 `runtime/`。

## 主要文件

- `src/NetAcceleratorServer.cs`：可维护源码。
- `bin/NetAcceleratorServer.dll`、`bin/NetAcceleratorServer.runtimeconfig.json`：基于本机 .NET 10 运行时的轻量服务。
- `src/build_core.ps1`：无需安装 SDK，使用现有运行时重新编译服务。
- `config/domains.txt`：两个加速组的精确域名清单。
- `config/watt-rules.tsv`：从当前 Watt 本地缓存提取的转发目标、优选 IP 和服务器加速规则。
- `config/transport-proxy.txt`：显式指定上游传输入口；当前为现有 Clash 的 `http://127.0.0.1:7897`，用于避免 UAC 提权进程读取到不同的用户代理环境。程序只连接该入口，不修改或关闭 Clash。
- `config/certificate-info.json`、`certificates/NetAcceleratorRootCA.cer`：服务器证书指纹与仅含公钥的本地根证书。
- `scripts/setup_https.ps1`：幂等证书准备。
- `scripts/tray.ps1`、`scripts/launch_tray.ps1`、`启动.bat`：托盘与启动生命周期。
- `scripts/恢复网络.ps1`、`恢复网络.bat`：异常退出后的定向恢复。
