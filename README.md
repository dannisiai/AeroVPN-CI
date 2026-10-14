# AeroVPN - 面向百万级用户的商业 VPN 客户端系统
> 基于官方 `sing-box` / `libbox` 核心封装的高性能跨平台商业 VPN 解决方案（Android / iOS / macOS / Windows）

---

## 🌟 项目设计与核心原则

本项目旨在将官方开源 `sing-box` 包装成如同 **NordVPN / Surfshark / Proton VPN** 一样简单易用的消费级商业 VPN 客户端。

### 核心设计原则：
1. **统一核心**：底层统一使用官方 `sing-box` / `libbox`，无额外引入其他 VPN Core。
2. **零核心微侵入**：严禁在 `sing-box` Core 中揉入业务代码，所有鉴权、套餐、调度在业务层和后端完成，保证可长期无痛同步 upstream。
3. **极简商业体验**：普通用户只需安装、注册、登录、选择国家/城市或点击 Quick Connect 连接 VPN，彻底移除所有节点导入、订阅链接、二维码、参数编辑与底层协议配置界面。
4. **内存临时凭证**：客户端只内置官方 API 地址，所有节点由后端根据用户套餐与负载动态调度，返回短期临时凭据并在**内存中即时渲染为 sing-box 配置**，私钥和敏感 Secret 绝不持久化落地。
5. **系统级原生隧道**：
   - **Android**：基于官方 `VpnService`，实现底层 Socket `protect()` 绕过与前台保活。
   - **iOS**：基于 `NetworkExtension` (`NEPacketTunnelProvider`) 驱动 `Libbox.xcframework`。
   - **macOS**：通过管理员授权的 launchd 任务运行 sing-box，使用固定上游源码与 Go 1.27.1、CGO 关闭构建 ARM64 / Intel x86_64 双架构核心，两个架构均以 macOS 13+ 为目标。macOS 12 不在支持范围内。
   - **Windows**：双进程架构，后台以 `SYSTEM` 特权运行守护进程接管 `Wintun` 与 sing-box 核心，前台普通权限 UI 通过本地 IPC 交互。不提供 Kill Switch，不修改正常连接期间的防火墙默认策略。

---

### 隐私与路由披露（Privacy Disclosure）

以下流量**按设计不经过 VPN 隧道**，用户应知情：

1. **局域网流量**（`ip_is_private` 路由规则直连），这是消费级 VPN 的常规行为。
2. **品牌/控制面域名直连**：`config/whitelabel.json` 的 `direct_domains`
   （品牌官网、API 域名等）必须绕过隧道才能在断连时维持控制面可达。
3. **`*.cn` 后缀域名直连**：出于产品路由策略默认绕行。面向隐私敏感场景的用户
   如需全量代理，可在后续版本提供开关；当前版本此行为是既定产品决策。

## 📂 工程目录结构

```
c:/VPN/
├── config/
│   └── whitelabel.json                 # 单一事实来源 (Single Source of Truth) 白标品牌配置
│
├── backend-spec/                       # 商业控制面规范与测试服务
│   ├── openapi.yaml                    # OpenAPI 3.0 完整端点规范 (Auth, Account, Regions, Connect)
│   └── mock-server/                    # 零依赖高性能 Node.js Mock 后端
│       └── server.js                   # 包含 JWT 轮转、区域调度、短期凭证生成
│
├── core/                               # 底层 VPN 核心与特权服务
│   ├── upstream.env                    # 上游 pinned 版本 / 构建标签 / gomobile / NDK 的单一事实来源
│   ├── daemon/                         # Windows 特权助手服务 (Go 编写)
│   │   ├── main.go                     # Wintun 管理、核心生命周期、实时遥测 IPC
│   │   ├── legacy_firewall_cleanup.go  # 旧版防火墙遗留规则及策略备份恢复
│   │   └── vpn-daemon.exe              # 本地编译产物（.gitignore，不随仓分发）
│   └── scripts/                        # 官方 upstream 自动化构建脚本
│       ├── build_android_aar.sh        # 一键编译 Android libbox.aar（含真伪校验）
│       ├── build_apple_xcframework.sh  # 一键编译 Apple Libbox.xcframework（含真伪校验）
│       └── build_windows_daemon.ps1    # 编译 Windows 特权守护进程
│
├── client/                             # 跨平台 Flutter 商业客户端 (Windows/Android/iOS/macOS)
│   ├── lib/
│   │   ├── config/                     # 白标品牌与现代化深色主题系统
│   │   ├── core/
│   │   │   ├── api/                    # 商业 REST API Client (401 自动无缝 Token 刷新)
│   │   │   ├── engine/                 # 核心【内存】sing-box JSON 配置生成器
│   │   │   ├── security/               # 安全存储 (SecureVault)
│   │   │   └── vpn/                    # 跨平台 VPN 服务统一接口与遥测
│   │   ├── state/                      # 响应式状态管理 (Auth, Account, Region, VPN)
│   │   ├── ui/                         # NordVPN 风格深色消费级用户界面
│   │   └── main.dart                   # 客户端主入口
│   ├── android/                        # Android 原生宿主 (AeroVpnService.kt)
│   ├── ios/                            # iOS 原生宿主 (PacketTunnelProvider.swift)
│   └── test/                           # 单元测试与端到端配置校验
│
└── scripts/
    └── sync_whitelabel.js              # 白标配置一键同步注入工具
```

---

## 🚀 快速启动与本地测试流程

系统已自带全套可立即联调运行的本地模拟控制面与特权 VPN 守护进程。

> **核心二进制不在仓库内**（`.gitignore` 明确排除，见 `core/upstream.env` 的 pinned 版本）：
> `libbox.aar` / `Libbox.xcframework` / `sing-box.exe` / `core/daemon/sing-box.exe` 都需要先产出，
> 否则移动端会报 "Missing libbox"、Windows 守护进程会报 "Official sing-box core not found"：
>
> ```bash
> ./core/scripts/build_android_aar.sh        # libbox.aar（需 Go + Android SDK/NDK 28.0.13004108，数分钟）
> ./core/scripts/build_apple_xcframework.sh  # Libbox.xcframework（需 Go + Xcode，数分钟）
> ./scripts/fetch_upstream_cores.sh "" windows  # Windows 直接下载固定官方 release
> python3 scripts/build_macos_core.py          # macOS Intel + ARM；需 Go 1.27.1、Git、Python 3.9+
> python3 scripts/build_macos_core.py --verify client/macos/Runner/sing-box
> python3 scripts/verify_upstream_artifact.py --aar client/android/app/libs/libbox.aar
> ```
>
> Windows 上可用 `python scripts/build_macos_core.py` 交叉编译相同的双架构 macOS 核心，不执行核心。构建固定 `core/upstream.env` 的版本、提交、功能标签与 Go 版本，拒绝脏的上游源码；依赖按上游 `go.sum` 和 Go checksum database 校验。`core/macos_build.json` 固定构建配方与两个切片的 SHA-256、架构、最低系统版本。构建只使用已安装的固定 Go，不自动下载其他工具链。
>
> Mac App 仍需 Xcode / Flutter 构建。Xcode 复制前校验核心；CI 进一步检查完整 App 内主程序、核心和框架的双架构及最低版本，防止依赖提高到 macOS 13 以上。升级固定版本或配方时，同步清单并用 `--update-checksums` 重新构建、复核哈希；日常构建不使用该参数。原 `fetch_macos_core.*` 命令保留兼容入口，现均从源码构建。
>
> 所有产出都会经过 `scripts/verify_upstream_artifact.py` 校验：占位 stub（无 `jni/*.so`、
> 只有几百字节、或缺少 libbox v1.13+ 类/头文件符号）会被直接拒绝；Android release 构建另有
> Gradle 任务兜底，不会把占位品打进 APK。

### 1. 启动本地商业控制面 (Mock API Server)
```powershell
node backend-spec\mock-server\server.js
# 运行在 http://127.0.0.1:8080
# 商业严格模式：无预置账号，需先 POST /v1/auth/send-code -> /v1/auth/register 注册
# 密码重置同样走真实验证码流程（15分钟有效），无硬编码 123456
# 节点密钥经 NODE_* 环境变量注入（见 backend-spec/.env.example）
```

### 2. 启动 Windows 特权守护进程
```powershell
.\core\daemon\vpn-daemon.exe
# 运行在 http://127.0.0.1:9527
# 负责拉起 sing-box 核心（Wintun 由核心内嵌加载）
# 安装器为安装用户在 %LOCALAPPDATA%\AeroVPN\ipc.token 配置独立令牌；服务只读取注册表指定的该用户档案
```

### 3. 一键同步白标品牌信息
```powershell
node scripts\sync_whitelabel.js
```

### 4. 运行客户端单元与引擎测试
```powershell
cd client
flutter test
```

### 5. 启动客户端 (Windows / Chrome / 移动设备)
```powershell
cd client
flutter run -d windows
# 或运行到网页端预览
flutter run -d chrome
```

---

## 🔒 商业安全实施规范

1. **凭证生命周期**：
   - 用户密码经 scrypt（内存困难，N=2^15/r=8，版本化记录 `v1$scrypt$...`）哈希后校验；旧版无盐/带盐 SHA-256 账号在下次成功登录时透明升级，不丢账号。客户端绝不保存明文密码。
   - Access Token（生产 30 天）与 Refresh Token 保存在系统安全存储区（Keychain / Keystore / Credential Locker）；服务端只持久化令牌的 SHA-256 摘要，明文令牌不落盘。`refresh` 接口做旧对轮转（防重放），`/v1/auth/logout` 撤销当前会话，过期会话定时清扫。
   - 隧道临时凭证在服务端以独立的 connect-session 记录管理（TTL 3600s，`/v1/connect/revoke` 可撤销，`/v1/connect/sessions` 可查询），并按套餐 `max_devices` 在服务端强制设备数配额；节点侧的即时吊销需节点配套接口（见 `deploy/CONTROL_PLANE.md` 的遗留限制）。
   - 遇到 401 Unauthorized 时，底层 API Client 会自动利用 Refresh Token 发起轮转重试，对用户无感。
   - 注意：控制面 token 为服务端 opaque 随机串（`aat_/art_`），并非 JWT（见 `openapi.yaml:BearerAuth` 注释）。
2. **连接凭据隔离 (Zero-Disk Footprint)**：
   - 节点分配通过 `POST /v1/connect` 动态下发短期凭据（TTL 3600 秒）。
   - 客户端由 `SingboxConfigBuilder` 直接在内存中组装生成符合 sing-box v1.14 规范的 JSON 字符串（兼容基线为 pinned `v1.14.3`，见 `core/upstream.env`）。
   - 生成的配置直接传递给 `libbox` / 守护进程启动隧道。配置**由本仓代码仅在内存中组装**；随后各端交给官方核心的方式不同，**这不是"绝不落地"**：
     - **Windows**：守护进程把配置写入临时文件（SYSTEM 账户的临时目录，该目录 ACL 才是真正的保护，Windows 上 `os.Chmod` 只影响只读位、不改 ACL），隧道停止或核心退出即删除；
     - **macOS standalone**：特权模式把配置写入 0700 应用私有目录内的 0600 文件，并由一次性 launchd job 管理核心；停止时按固定 job label 卸载，不直接向 PID 发信号；
     - **iOS**：配置放进 `NETunnelProviderProtocol.providerConfiguration`，**由系统持久化到磁盘**（与上游 sing-box-for-apple 的 start-options 持久化行为一致），这是系统在扩展被重启后恢复隧道所必需的。
3. **DNS 防泄漏与 Kill Switch**：
   - sing-box `dns` 模块的 DNS 缓存自 v1.14.0 起恒为独立缓存（`independent_cache` 选项已废弃并移除），远程 DNS 强制走加密代理出口；`route.rules` 首条为 `{"action": "sniff"}`（v1.13.0 起嗅探必须由路由动作开启，见下）。
   - `strict_route` 是核心运行时的 TUN 路由/DNS 设置，不等于核心退出后的系统级断网保护。**平台差异**：
     - **Windows**：已删除防火墙 Kill Switch、设置开关、IPC 控制接口和启动/退出时的保护逻辑；正常连接不检查其他出站 Allow 规则、不设置默认出站 Block。保留 `strict_route=true` 用于隧道路由和 DNS。服务启动/卸载仅清理旧 AeroVPN 的固定规则名，并在有备份时恢复旧版改动前的策略；无可靠备份时不猜测或重置用户默认策略。VPN 意外退出后可能恢复普通网络直连；
     - **macOS**：没有操作系统级防火墙归属，**仅依赖 sing-box `strict_route`**（App 内开关如实反映用户选择，切换后需重新连接才生效）；
     - **Android**：本 App 不控制系统级 VPN 锁定；`VpnService.Builder.setBlocking` 只改变 TUN 文件描述符的读写阻塞模式，不是断网保护；
     - **iOS**：`NETunnelProviderProtocol.includeAllNetworks` + `NEOnDemandRuleConnect`（上游 sing-box-for-apple 的等价做法），由扩展的 `includeAllNetworks()` 反馈给核心；运行中切换会保存配置并重启当前隧道；启用 `includeAllNetworks` 时 sing-box 栈切换为 `gvisor`，因为上游 `sing-tun` 不允许此时使用 `mixed`/`system`。
   - 每会话 `clash_api.secret` 由客户端随机生成（`SingboxConfigBuilder.generateClashSecret`），经 IPC/`MethodChannel` 透传给 daemon/原生遥测并以 `Authorization: Bearer` 轮询 `127.0.0.1:9090/traffic`（Apple 扩展自身也轮询该接口）。
   - Windows IPC 令牌不再放在共享的 `%ProgramData%`，也不会镜像到所有账户：管理员安装时，守护进程从交互式 shell 解析实际桌面用户的 SID 和 `%LOCALAPPDATA%`，把令牌写入受保护 DACL 的用户档案，并把唯一授权档案登记到服务 HKLM `Parameters`；SYSTEM 守护进程只读取这个档案，缺少配置或令牌时**默认拒绝**（fail-closed）。升级时服务先停止并轮换令牌，安装后客户端以原始用户运行。服务当前只授权安装时选中的一个 Windows 用户。
4. **日志脱敏**：
   - Release 构建下日志级别设置为 `warn`，禁用 verbose 数据包跟踪，防止逆向分析节点特征。

---

## 🗺️ 上游 4 端对照（SagerNet）

| 上游 | 本仓复用方式 | 说明 |
|---|---|---|
| `SagerNet/sing-box v1.14.3`（pinned tag，见 `core/upstream.env`） | `sing-box run/check + clash_api` 黑盒 + `gomobile bind ./experimental/libbox`（上游 gomobile fork） | 协议/加密/TUN 零自研，`tags=with_quic,with_wireguard,with_utls,with_clash_api,with_gvisor`（hysteria2 需要 `with_quic`；`with_ech` 已被上游移除、加入即编译失败） |
| `SagerNet/sing-box-for-android` | `AeroVpnService.kt + MainActivity.kt` 复刻 `VpnService.Builder/protect()` 与 `BoxService` 启动序列 | 对齐上游 libbox v1.13+ 接口：`Libbox.setup(SetupOptions)` → `CommandServer(handler, platformInterface)` → `startOrReloadService(...)`；因 AAR 在构建期产出，采用反射适配层；发布构建会校验 `libbox.aar` 真伪（无 `jni/*.so` 或缺少 v1.13+ 类直接失败） |
| `SagerNet/sing-box-for-apple` | `PacketTunnelProvider.swift + AppDelegate.swift` 复刻 `NEPacketTunnelProvider` | 对齐上游 `LibboxSetup` → `LibboxNewCommandServer` → `startOrReloadService`，网络设置由 core 传入的 `TunOptions` 推导；Kill Switch 用 `includeAllNetworks` + on-demand 对齐，且按上游 `sing-tun` 约束在 iOS 开启时使用 `gvisor`；需真 `Libbox.xcframework`（同样有线前校验）；macOS 无扩展 target 时主走 standalone（官方 `sing-box` 二进制）；特权核心由短期 launchd job 管理，没有常驻自研守护进程 |
| `SagerNet/sing-box-for-desktop` + `experimental/boxdd` | Windows 双进程（`Flutter→127.0.0.1:9527→Go daemon→sing-box.exe`） | 上游桌面端为 Electron + LocalSystem 服务 + 命名管道 gRPC + 对端进程身份认证；本仓为自研 Go 守护进程 + loopback HTTP + 安装用户独立令牌（见安全规范第 3 条），Windows 不提供 Kill Switch |

> **libbox 接口版本说明**：上游在 **v1.13.0** 移除了 `Libbox.newService` / `BoxService` 入口，改为
> `Libbox.setup(SetupOptions)` + `CommandServer(handler, platformInterface)` + `StartOrReloadService`
> （Android 侧 `Libbox.setup(...)` / `CommandServer(...)`；Apple 侧 `LibboxSetup(...)` / `LibboxNewCommandServer(...)`）。
> 本仓移动端已对齐该接口；`newService` 仅作为 < v1.13 旧 AAR 的兼容回退保留。
>
> **配置兼容基线**（`SingboxConfigBuilder`，均由 pinned 核心实测）：`inbound.sniff` /
> `sniff_override_destination`（v1.13.0 移除，只能用 `{"action":"sniff"}` 路由规则替代）、
> `geosite`/`geoip` 规则项（v1.12.0 移除）、`block` 特殊出站（v1.13.0 移除）、
> WireGuard 出站（v1.13.0 移除，改用 `endpoints`）、`independent_cache`（v1.14.0 废弃）。
> 新增配置项前请先确认 pinned 版本仍然接受它 —— sing-box 对已移除字段是**报错**而不是忽略。

详见 `THIRD_PARTY_NOTICES.md`（GPL-3.0 义务与命名限制）。

---

## ⚖️ 开源协议 (GPL-3.0) 商业合规指南

1. **行业标杆实践 (Proton VPN / Mullvad 模式)**：
   - 将客户端 UI 与桥接代码开源，赢得百万级对隐私要求极高的用户信任。
   - **商业核心资产闭源**：全球机房集群、Anycast 调度算法、抗封锁规则库、计费网关与用户数据均运行在自有云端控制面，开源客户端脱离官方 API 凭据无法使用。
2. **进程隔离方案 (Process Separation via IPC)**：
   - 底层 `sing-box` 作为独立可执行程序运行，仅通过操作系统本地命名管道或 Loopback IPC 进行松耦合通信，商业 UI 作为独立进程发布，符合 GPL 独立衍生作品边界。
