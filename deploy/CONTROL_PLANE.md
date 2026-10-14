# AeroVPN 控制面上线手册（Control Plane Deploy / TLS Runbook）

适用对象：把 `backend-spec/server-cloud.js` 部署到公网主机（当前设计目标
`www.ethworldcupcoin.xyz`），使客户端里写死的 `https://www.ethworldcupcoin.xyz`
能真正访问。

这个 Node 服务**只监听 127.0.0.1 的明文 HTTP**，TLS 终结必须由前置反向代理完成。
不要为了图省事把 `BIND_ADDR` 改成 `0.0.0.0` 直接暴露 —— 那会把凭证接口全裸在公网上。

---

## 1. 准备环境变量

```bash
cd /root/VPN/api
cp .env.example .env      # 然后填入真实值，.env 不进 git
```

必填（缺任何一个，节点都无法建立隧道；`PRODUCTION=1` 时服务会拒绝启动）：

| 变量 | 说明 |
|---|---|
| `NODE_SERVER_IP` | 节点公网 IP |
| `NODE_HY2_PASSWORD` | hysteria2 密码 |
| `NODE_HY2_OBFS_PASSWORD` | hysteria2 salamander obfs 密码 |
| `NODE_VLESS_UUID` | VLESS UUID |
| `NODE_VLESS_REALITY_PUB` / `_SHORT` | VLESS Reality 公钥 / short_id |
| `RESEND_API_KEY` / `RESEND_DOMAIN_ID` | 验证码邮件（Resend） |

多地域（可选）：按 `.env.example` 里的 `NODE_US_*` / `NODE_JP_*` / `NODE_SG_*` 填。
填了 `<PREFIX>_SERVER_IP` 该地域才出现在 `/v1/regions`，否则回落共用节点。

## 2. 启动服务

```bash
NODE_ENV=production PRODUCTION=1 node server-cloud.js
# 监听 127.0.0.1:8088（PORT 可改）
```

建议交给 systemd 托管（崩溃自动重启 + 开机自启）：

```ini
# /etc/systemd/system/aerovpn-api.service
[Unit]
Description=AeroVPN Control Plane
After=network.target

[Service]
WorkingDirectory=/root/VPN/api
EnvironmentFile=/root/VPN/api/.env
ExecStart=/usr/bin/node server-cloud.js
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now aerovpn-api
```

## 3. 反向代理 + TLS（必须）

Caddy（自动申请证书，最省事）：

```caddyfile
www.ethworldcupcoin.xyz {
    reverse_proxy 127.0.0.1:8088
}
```

Nginx + certbot：

```nginx
server {
    listen 443 ssl http2;
    server_name www.ethworldcupcoin.xyz;

    ssl_certificate     /etc/letsencrypt/live/www.ethworldcupcoin.xyz/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/www.ethworldcupcoin.xyz/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

代理就位后，**在 `.env` 里设 `TRUST_PROXY=1`**，否则登录限流会把所有请求都记在
代理自己的 IP 上（等于没有按真实客户端区分）。

> `TRUST_PROXY=1` 下服务端**只信任 `X-Real-IP`**（上面的示例用 `$remote_addr`
> 覆写，客户端无法伪造）。`X-Forwarded-For` 在 `$proxy_add_x_forwarded_for` 下
> 会保留客户端自带值，任何一条 XFF 记录都可伪造，服务端已不再读取它。若换用其他
> 反代，必须保证由代理覆写 `X-Real-IP`，否则限流会退化为按代理 IP 计数。

## 4. 上线自检

```bash
# 1) 隧道端点健康
curl -s https://www.ethworldcupcoin.xyz/health

# 2) 地域目录（应只列出你真正配置了主机的地区）
curl -s https://www.ethworldcupcoin.xyz/v1/regions

# 3) 限流生效（连续打 11 次登录，最后应返回 429）
for i in $(seq 1 11); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST \
    https://www.ethworldcupcoin.xyz/v1/auth/login \
    -H 'Content-Type: application/json' -d '{"email":"nobody@example.com","password":"x"}'
done
```

## 5. 已知限制 / 后续

- **数据库是单文件 `db.json`**：并发写、备份、扩容都受限。多地域/多实例前应迁移到
  Postgres 或 Redis（限流计数也要跟着搬到共享存储，见下）。
- **限流是进程内内存计数**：单实例下有效；一旦水平扩容，每个实例各算一份额度，
  攻击者额度会翻倍。扩容时把 `rateBuckets` 换到 Redis。
- ~~密码哈希是带盐 SHA-256~~ **已修复**：现为 scrypt（内存困难，N=2^15/r=8，
  ~64 MiB）版本化记录（`v1$scrypt$...`）；旧的无盐/带盐 SHA-256 账号在下次成功登录时
  透明升级，不会丢失账号。提升 `N` 时递增 `PASSWORD_FORMAT_VERSION` 即可平滑过渡。
- `db.json` 与 `.env` 都必须排除在版本控制之外（`.gitignore` 已覆盖 `*.env`；
  确认 `db.json` 不要被 `git add -f` 带上）。

---

## 附：证书与代码签名（客户端侧，独立于本手册）

本手册只解决**服务端**的 TLS。客户端分发包的签名是另一件事：

| 平台 | 需要 | 存放 |
|---|---|---|
| Android | release keystore（`.jks`）+ 口令 | CI secrets：`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` |
| iOS | Apple 开发者账号 + NE 权限的 App ID + 描述文件 | CI secrets：`IOS_CERTIFICATE_P12_BASE64` / `IOS_CERTIFICATE_PASSWORD` / `IOS_PROVISIONING_PROFILE_BASE64` / `IOS_TEAM_ID` |
| macOS | Developer ID 证书（公证另需 `APPLE_ID`/`APP_SPECIFIC_PASSWORD`/`TEAM_ID`） | 同上 Apple 系列 secrets |
| Windows | OV/EV 代码签名证书（`.pfx`） | CI secrets：`WINDOWS_CERT_PFX_BASE64` / `WINDOWS_CERT_PASSWORD` |

这些目前都**未配置**（仓库 secrets 为空），因此 CI 产出的是未签名/自签名包，
仅能内部测试，不能直接面向终端用户分发。


---

## 6. 数据保护、备份与密钥轮换（加固后）

### 6.1 OTP pepper（`OTP_HMAC_SECRET`）

- **必填**。验证码只存 HMAC 摘要，明文码不落盘。生成：
  ```bash
  openssl rand -hex 32
  ```
- 它必须是独立强随机值，**不得**复用 `RESEND_API_KEY` 或其他凭据充当（服务端已移除该回退）。
- 轮换影响：旧摘要立即失效，仅影响未使用的 15 分钟验证码；用户重新获取即可。
- 泄露处置：立即轮换 + 使 `db.json` 中 `verify_codes` 全部作废（删除该表即可）。

### 6.2 `db.json` 权限、备份与恢复

```bash
chown root:root /root/VPN/api/db.json && chmod 600 /root/VPN/api/db.json
# 热备份（写入是 原子临时文件+rename，任意时刻拷贝都是完整文件）：
cp -a /root/VPN/api/db.json /var/backups/aerovpn/db-$(date +%F-%H%M).json
# 恢复：停服务 -> 覆盖 -> 起服务
systemctl stop aerovpn-api && cp /var/backups/aerovpn/db-....json /root/VPN/api/db.json && systemctl start aerovpn-api
```

- **升级迁移（显式、带备份）**：旧版 `db.json` 中会话以明文 token 为键并内含明文
  token。新版首次启动会自动迁移为“仅摘要”存储：迁移前先写
  `db.json.backup-legacy-session-migration-<时间戳>`，日志明确打印，可随时用备份回滚。
  明文 token 在迁移后从磁盘消失；持有旧 token 的客户端不受影响（摘要可对上）。
- 数据文件损坏时服务**拒绝覆盖**（先备份 `db.json.backup-corrupt-load-*` 再重建空库）。

### 6.3 会话与凭据生命周期

- 登录会话：access/refresh 只存 SHA-256 摘要；`/v1/auth/refresh` 轮换（旧对作废，防重放）；
  新增 `/v1/auth/logout` 撤销；过期会话每小时清扫。
- 隧道连接会话：独立于登录会话，存于 `connectSessions`（TTL 3600s，服务端过期清扫，
  `POST /v1/connect/revoke` 可按会话或全量撤销，`GET /v1/connect/sessions` 可列出）。
- **遗留限制（需节点侧配合）**：撤销目前只在控制面生效。下发的节点凭证是节点的
  静态配置（`NODE_HY2_PASSWORD` / `NODE_VLESS_UUID`），不随会话签发或轮换，
  控制面的 `revoked` / `expiresAt` 只是记录。在节点具备凭证校验/吊销接口
  （sing-box 服务端用户管理或短时凭证网关）之前，已下发凭证在节点侧**长期有效，
  与 TTL 无关**；当前唯一能真正作废旧凭证的手段是轮换节点凭据（改 `.env` 并同步
  节点配置后重启节点）。
- **按会话派生凭证（opt-in，`NODE_PER_USER_CREDENTIALS=1`）**：开启后 `/v1/connect`
  不再下发共享静态凭证，而是按 `(user, connect session, expiry)` 派生唯一凭证
  （HMAC-SHA256，密钥 `CONNECT_CRED_SECRET`；VLESS UUID 为 RFC 4122 v5）。
  泄漏影响面从"全体用户"缩到"单会话"，且可在节点日志中归因；会话过期/撤销后
  控制面停止续发。**前置条件**：节点必须运行同样派生逻辑的用户管理集成
  （sing-box hysteria2/VLESS `users[]` 动态下发），否则节点不认新凭证——
  未部署该集成前此开关保持关闭，行为与静态模式完全一致（有回归测试覆盖）。
- 流量配额（`traffic_used_gb`）：控制面只做判定，计量必须由节点上报；未接入前该字段
  不生效（`traffic_gb>0` 且无用量数据时不拦截）。

### 6.4 多实例与限流

限流计数在进程内存中：重启清零、多实例各算各的（攻击者额度 = 单实例额度 × 实例数）。
扩容前把 `rateBuckets` 迁到 Redis，或在可信边缘（反代/网关）做限流并把本服务的
`__global_auth` 关小。见上文“已知限制”。
