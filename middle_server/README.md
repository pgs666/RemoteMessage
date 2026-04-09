# Middle Server (.NET 8 / ASP.NET Core)

RemoteMessage Middle Server 是整个远程短信系统的核心枢纽，负责：

- 管理网关注册信息与网关公钥
- 接收网关上传的短信并解密入库
- 为 Flutter 客户端提供短信查询与发送接口
- 使用网关公钥加密下行短信任务
- 提供 HTTPS 通信与分段令牌鉴权
- 自动生成入网 QR 码，简化客户端和网关配置
- 自动维护数据库（日志轮转、数据清理、容量控制）

---

## 架构概览

```
middle_server/
├── Program.cs                          # 应用入口 & API 路由定义 (456行)
├── RemoteMessage.MiddleServer.csproj   # .NET 8 项目配置
├── Api/
│   └── ApiSupport.cs                   # API辅助工具 (346行)
│       ├── 规范化函数 (方向/SIM槽/发送状态)
│       ├── RSA公钥加密 (支持分块)
│       ├── 固定时序密码比较
│       └── 请求验证函数
├── Config/
│   ├── ServerRuntimeSettings.cs        # 运行时配置 (244行)
│   │   └── 令牌/端口/保留策略/维护间隔
│   ├── HttpsCertificateSettings.cs     # HTTPS证书配置
│   │   └── 自签名证书生成与管理
│   └── OnboardingQrBootstrap.cs        # 入网QR码生成
│       └── 首次启动自动生成QR码文件
├── Contracts/
│   └── ApiContracts.cs                 # API请求/响应DTO定义
│       ├── RegisterGatewayRequest
│       ├── SmsPayload
│       ├── SimProfileResponse
│       └── 其他数据契约
├── Core/
│   ├── MessageIdentity.cs              # 消息标识工具
│   └── RuntimeLayout.cs                # 运行时目录布局
│       └── 提供 RuntimeDirectory/ExecutablePath
├── Data/
│   └── SqliteRepository.cs             # SQLite数据访问层 (939行)
│       ├── 消息表 (messages)
│       ├── 网关注册表 (gateways)
│       ├── 下行任务表 (outbox)
│       ├── 置顶会话表 (pins)
│       ├── API日志表 (api_logs)
│       └── 自动建表与迁移
└── Security/
    ├── CryptoState.cs                  # RSA加密状态管理
    │   ├── 2048位RSA密钥对
    │   ├── PKCS#8私钥持久化
    │   └── OAEP-SHA256解密 (支持分块)
    └── GatewayRegistry.cs              # 网关注册表
        ├── 内存缓存网关信息
        └── 公钥查询/更新
```

---

## 运行时自动生成的文件

服务端无论是 `dotnet run` 还是发布后的单文件可执行程序，首次启动都会在**可执行文件同目录**自动生成：

```text
server.db                    # SQLite 数据库
server.conf                  # 服务端配置文件
server-cert.cer              # 客户端/网关注入的证书
server-cert.pfx              # 服务端自用 HTTPS 证书
server-crypto-private.pem    # 服务器 RSA 私钥
onboarding-qr.txt            # 入网 QR 码内容 (首次启动)
server.log                   # 运行日志 (自动轮转)
```

说明：

- `server.db`：SQLite 数据库，自动创建并初始化所有表结构，无需手工预建
- `server.conf`：服务端配置文件，自动生成，包含端口和三种令牌
- `server-cert.cer`：给 Flutter 客户端 / Android 网关导入信任
- `server-cert.pfx`：服务端自身 HTTPS 证书，请妥善保管
- `server-crypto-private.pem`：RSA-OAEP 解密用私钥，切勿泄露
- `onboarding-qr.txt`：包含 JSON 格式的入网配置，可直接生成 QR 码
- `server.log`：运行日志文件，自动轮转 (默认最大 32MB，保留 14 天)

---

## server.conf

首次启动会生成类似如下内容：

```ini
# RemoteMessage server.conf
# Generated on first start. Edit values and restart the service.
https_port=5001
gateway_token=<随机生成的256位高强度令牌>
client_token=<随机生成的256位高强度令牌>
admin_token=<随机生成的256位高强度令牌>
log_retention_days=14
log_max_mb=32
api_log_retention_days=30
message_retention_days=0
database_max_mb=512
maintenance_interval_minutes=60
```

字段说明：

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `https_port` | 5001 | HTTPS 监听端口 |
| `gateway_token` | 随机生成 | 网关 API 鉴权令牌 (X-Gateway-Token) |
| `client_token` | 随机生成 | 客户端 API 鉴权令牌 (X-Client-Token) |
| `admin_token` | 随机生成 | 管理 API 鉴权令牌 (X-Admin-Token) |
| `log_retention_days` | 14 | 运行日志保留天数 |
| `log_max_mb` | 32 | 运行日志文件大小上限 |
| `api_log_retention_days` | 30 | API 访问日志保留天数 |
| `message_retention_days` | 0 | 短信保留天数 (0=永久) |
| `database_max_mb` | 512 | 数据库文件大小上限 |
| `maintenance_interval_minutes` | 60 | 自动维护任务间隔 |

修改 `server.conf` 后需要**重启服务**才会生效。

---


## ????? IP ????

????????? `onboarding-qr.txt` ??`serverBaseUrl` ????????

1. ???????? `REMOTE_MESSAGE_SERVER_BASE_URL`????????
2. ?????????? IPv4?????? `169.254.x.x`??
3. ?????????10/172.16-31/192.168????? `https://<ip>:<https_port>`?

?????`Config/OnboardingQrBootstrap.cs` ?? `ResolveServerBaseUrl()`?

???????????????? `REMOTE_MESSAGE_SERVER_BASE_URL`?????????????? IP?

## 本地运行

```bash
dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

启动日志会打印：

- 可执行目录、可执行文件路径
- 实际读取的 `server.conf` 路径
- HTTPS 端口
- `server.db` 路径
- `server-crypto-private.pem` 路径
- 令牌鉴权已启用 (分段令牌模式)
- 维护策略详情 (日志/数据保留周期、数据库大小限制)
- 首次启动时生成入网 QR 码

---

## 发布为单文件可执行程序

项目已配置为 Release 发布时：

- `PublishSingleFile=true`
- `IncludeNativeLibrariesForSelfExtract=true` - 将 SQLite 原生库打包进单文件
- `IncludeAllContentForSelfExtract=true` - 将所有依赖打包进单文件
- `EnableCompressionInSingleFile=true` - 启用压缩
- `PublishTrimmed=false` - 不裁剪 (避免反射问题)
- `DebugType=embedded` - 嵌入式调试信息

推荐发布命令：

```bash
# Linux x64
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj \
  -c Release -r linux-x64 --self-contained true \
  -o publish/linux-x64

# Linux ARM64 (如树莓派)
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj \
  -c Release -r linux-arm64 --self-contained true \
  -o publish/linux-arm64
```

发布产物目标是**单个服务端可执行文件**；首次运行后才会在旁边生成 `server.db`、`server.conf`、证书文件。

GitHub Actions 中的 `middle-server-ci` 也已按同样方式发布 Linux x64 / Linux ARM64 单文件产物。

---

## API 端点详解

### 健康检查 (无需鉴权)

```
GET /healthz
Response: { "ok": true }
```

### 加密 (无需鉴权)

```
GET /api/crypto/server-public-key
Response: { "publicKey": "<PEM格式的RSA公钥>" }
```

### 网关接口 (需要 X-Gateway-Token)

#### 注册网关
```
POST /api/gateway/register
Request: {
  "deviceId": "android-arm64-gateway",
  "publicKeyPem": "<网关RSA公钥PEM>"
}
Response: { "ok": true }
```

#### 上传短信
```
POST /api/gateway/sms/upload
Request: {
  "messages": [
    {
      "id": "uuid",
      "phone": "+8613800138000",
      "content": "短信内容",
      "timestamp": 1234567890000,
      "direction": "inbound",
      "simSlotIndex": 0,
      "simPhoneNumber": "+8613800138000",
      "simCount": 2
    }
  ]
}
Response: { "accepted": 1, "duplicates": 0 }
```

#### 拉取发送任务
```
GET /api/gateway/pull
Response: {
  "tasks": [
    {
      "messageId": "uuid",
      "phone": "+8613800138000",
      "content": "<RSA-OAEP加密的短信内容>",
      "simSlotIndex": 0
    }
  ]
}
```

#### 上报状态
```
POST /api/gateway/status
Request: {
  "messageId": "uuid",
  "status": "sent|failed",
  "errorCode": 0,
  "errorMessage": null
}
Response: { "ok": true }
```

### 客户端接口 (需要 X-Client-Token)

#### 查询短信
```
GET /api/client/inbox?sinceTs=<时间戳>&limit=<数量>&phone=<号码>
Response: {
  "messages": [...],
  "lastSyncTs": 1234567890000
}
```

#### 发送短信
```
POST /api/client/send
Request: {
  "phone": "+8613800138000",
  "content": "短信内容",
  "simSlotIndex": 0  // 可选
}
Response: { "queued": true, "messageId": "uuid" }
```

#### 置顶会话
```
POST /api/client/conversations/pin
Request: { "phone": "+8613800138000", "pinned": true }
Response: { "ok": true }
```

#### 获取置顶列表
```
GET /api/client/conversations/pins
Response: { "pins": ["+8613800138000", ...] }
```

#### 获取SIM卡配置
```
GET /api/client/sim-profiles
Response: {
  "simProfiles": [
    { "slotIndex": 0, "phoneNumber": "+8613800138000", "displayName": "SIM1" },
    { "slotIndex": 1, "phoneNumber": "+8613800138001", "displayName": "SIM2" }
  ]
}
```

#### 查询网关状态
```
GET /api/client/gateway/status
Response: {
  "deviceId": "android-arm64-gateway",
  "lastSeenAt": 1234567890000,
  "isOnline": true,
  "onlineWindowMs": 120000
}
```

### 管理接口 (需要 X-Admin-Token)

#### 触发维护
```
POST /api/admin/maintenance
Response: {
  "cleanedApiLogs": 100,
  "cleanedMessages": 50,
  "databaseSizeBytes": 12345678
}
```

#### 获取系统统计
```
GET /api/admin/stats
Response: {
  "totalMessages": 10000,
  "totalGateways": 1,
  "databaseSizeBytes": 12345678,
  "uptimeSeconds": 86400
}
```

---

## 安全机制

### 分段令牌鉴权

服务端使用三种独立的令牌：
- `X-Gateway-Token`：Android 网关访问网关接口
- `X-Client-Token`：Flutter 客户端访问客户端接口
- `X-Admin-Token`：管理员工具访问管理接口

优势：
1. **权限隔离**：网关令牌无法访问客户端接口，反之亦然
2. **独立轮换**：可单独更换某个令牌而不影响其他端
3. **审计追踪**：通过令牌类型可明确区分请求来源

### 固定时序比较

所有令牌比较均使用 `CryptographicOperations.FixedTimeEquals`，避免时序攻击：

```csharp
bool matches = CryptographicOperations.FixedTimeEquals(
    providedTokenBytes, 
    expectedTokenBytes
);
```

### RSA-OAEP 加密

- 密钥长度：2048 位
- 填充模式：OAEP with SHA-256
- 分块支持：长消息自动分块加密，用 `.` 连接各块
- 公钥导出：PEM 格式，供客户端和网关使用

### 输入防护

- 请求体大小上限：256 KB
- 字段长度校验：避免超长输入
- 解密失败统一返回：不泄露内部异常细节

---

## 数据库结构

### messages (短信表)

```sql
CREATE TABLE messages (
    id TEXT PRIMARY KEY,              -- 消息UUID
    device_id TEXT NOT NULL,          -- 网关设备ID
    phone TEXT NOT NULL,              -- 对方号码
    content TEXT NOT NULL,            -- 短信内容
    timestamp INTEGER NOT NULL,       -- 时间戳 (毫秒)
    direction TEXT NOT NULL,          -- inbound/outbound
    sim_slot_index INTEGER,           -- SIM卡槽索引
    sim_phone_number TEXT,            -- SIM卡号码
    sim_count INTEGER,                -- 总SIM卡数
    send_status TEXT,                 -- queued/dispatched/sent/failed
    send_error_code INTEGER,          -- 发送错误码
    send_error_message TEXT,          -- 错误描述
    updated_at INTEGER                -- 更新时间戳
);
```

### gateways (网关注册表)

```sql
CREATE TABLE gateways (
    device_id TEXT PRIMARY KEY,       -- 设备ID
    public_key_pem TEXT NOT NULL,     -- RSA公钥PEM
    registered_at INTEGER NOT NULL,   -- 注册时间戳
    last_seen_at INTEGER              -- 最后在线时间戳
);
```

### outbox (下行任务表)

```sql
CREATE TABLE outbox (
    id TEXT PRIMARY KEY,              -- 任务UUID
    device_id TEXT NOT NULL,          -- 目标网关
    phone TEXT NOT NULL,              -- 接收号码
    encrypted_content TEXT NOT NULL,  -- RSA加密内容
    sim_slot_index INTEGER,           -- SIM卡槽
    status TEXT NOT NULL,             -- pending/sent/failed
    created_at INTEGER NOT NULL,      -- 创建时间戳
    sent_at INTEGER                   -- 发送时间戳
);
```

### pins (置顶会话表)

```sql
CREATE TABLE pins (
    client_profile_id TEXT NOT NULL,  -- 客户端配置ID
    phone TEXT NOT NULL,              -- 对方号码
    pinned_at INTEGER NOT NULL,       -- 置顶时间戳
    PRIMARY KEY (client_profile_id, phone)
);
```

### api_logs (API访问日志表)

```sql
CREATE TABLE api_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    method TEXT NOT NULL,             -- HTTP方法
    path TEXT NOT NULL,               -- 请求路径
    status_code INTEGER NOT NULL,     -- 响应状态码
    ip_address TEXT,                  -- 客户端IP
    timestamp INTEGER NOT NULL        -- 时间戳
);
```

---

## 与客户端 / 网关配合

### 快速入网 (推荐)

服务端首次启动会生成 `onboarding-qr.txt`，内容类似：

```json
{
  "serverBaseUrl": "https://192.168.1.100:5001",
  "clientToken": "随机生成的客户端令牌",
  "gatewayToken": "随机生成的网关令牌"
}
```

1. Android 网关：打开应用 → 点击"扫描 QR 码" → 扫描此文件生成的二维码
2. Flutter 客户端：打开设置页 → 点击"扫描 QR 码" → 扫描此文件生成的二维码

### 手动配置

- Flutter 客户端与 Android 网关都要导入 `server-cert.cer`
- 两端都要配置与 `server.conf` 中一致的令牌
- 两端都应使用 `https://<server-ip>:<https_port>`

如果你修改了端口或令牌：

1. 编辑 `server.conf`
2. 重启 middle server
3. 同步更新 Flutter 客户端与 Android 网关配置

---

## 日志系统

### 控制台日志

- 格式：`yyyy-MM-dd HH:mm:ss.fff [LEVEL] message`
- 级别：Information 及以上
- 单行输出，避免多行日志打断阅读

### 文件日志

- 路径：`server.log` (可执行文件同目录)
- 轮转策略：文件大小超过 `log_max_mb` (默认 32MB) 时创建新文件
- 保留策略：保留 `log_retention_days` 天 (默认 14 天)
- 自动清理：维护任务定期检查并删除过期日志

### 启动日志示例

```
2026-04-09 10:00:00.123 [INF] RemoteMessage middle server starting. Runtime directory=/opt/remotemessage; ExecutablePath=/opt/remotemessage/RemoteMessage.MiddleServer; AppContext.BaseDirectory=/opt/remotemessage/
2026-04-09 10:00:00.234 [INF] Loaded config /opt/remotemessage/server.conf; HTTPS port=5001
2026-04-09 10:00:00.345 [INF] Runtime files are created beside the executable: server.db, server.conf, server-cert.cer, server-cert.pfx, server-crypto-private.pem
2026-04-09 10:00:00.456 [INF] SQLite database path: /opt/remotemessage/server.db
2026-04-09 10:00:00.567 [INF] Server log path: /opt/remotemessage/server.log
2026-04-09 10:00:00.678 [INF] Server crypto private key path: /opt/remotemessage/server-crypto-private.pem
2026-04-09 10:00:00.789 [INF] Auth enabled: token-only segmented headers (X-Gateway-Token / X-Client-Token / X-Admin-Token).
2026-04-09 10:00:00.890 [INF] Maintenance policy: every 60 min; log retention 14 days / 32 MB; api_logs 30 days; messages 0 days (keep); db max 512 MB.
2026-04-09 10:00:00.901 [WRN] Security review result: this service is suitable for LAN/VPN or reverse-proxied deployment, but it is not sufficient for direct public internet exposure without stronger auth, rate limiting, replay protection, and monitoring.
```

---

## 维护任务

服务端内置自动维护任务，默认每 60 分钟执行一次：

### 日志清理
- 删除超过 `log_retention_days` 天的旧日志文件
- 确保当前日志文件大小不超过 `log_max_mb`

### API 日志清理
- 删除 `api_logs` 表中超过 `api_log_retention_days` 天的记录

### 消息清理
- 如果 `message_retention_days > 0`，删除超过该天数的短信记录
- `message_retention_days = 0` 表示永久保留

### 数据库容量控制
- 检查 `server.db` 文件大小
- 如果超过 `database_max_mb`，尝试清理旧数据

---

## 安全评审结论

### 当前结论

**不建议直接裸露到公网。**

当前版本更适合：

- 家庭局域网 / 公司内网
- VPN 后访问
- 放在反向代理后面（如 Caddy / Nginx），再叠加公网证书、IP 限制、日志和限流

### 已具备的安全措施

- HTTPS (自签名证书)
- RSA-OAEP 加密的上下行消息体
- 分段令牌鉴权 (X-Gateway-Token / X-Client-Token / X-Admin-Token)
- 固定时序比较防时序攻击
- 输入长度限制
- 请求体大小上限 (256 KB)
- 解密失败统一错误返回

### 若直接上公网还缺少

1. **限流 / 防爆破 / 防滥用**
   还没有针对 IP、设备、路径的速率限制和封禁策略。

2. **防重放机制**
   目前没有 nonce / timestamp 签名校验，请求可被重复提交。

3. **更强的设备信任模型**
   目前拿到令牌就可以访问对应接口，缺少设备指纹绑定。

4. **完备的公网运维防护**
   例如：WAF、外层反向代理、证书自动续期、告警、备份、审计汇总等。

### 如果一定要上公网，至少建议补齐

- 反向代理 + 正规公网 TLS 证书
- 按 IP / 路径做限流
- 使用动态令牌或 JWT / mTLS / 签名鉴权
- 为所有写接口加入防重放字段
- 增加日志审计、监控告警与数据库备份

---

## 故障排查

### 常见问题

#### 1. 启动失败：端口被占用

```
Failed to bind to address http://[::]:5001: address already in use.
```

**解决方案**：修改 `server.conf` 中的 `https_port` 为其他端口。

#### 2. 客户端/网关连接失败

```
HttpRequestException: The SSL connection could not be established
```

**解决方案**：确保客户端/网关已导入 `server-cert.cer`。

#### 3. 令牌鉴权失败

```
401 Unauthorized
```

**解决方案**：检查客户端/网关的请求头是否包含正确的令牌，且与 `server.conf` 一致。

#### 4. 数据库文件过大

**解决方案**：
- 调整 `database_max_mb` 和 `message_retention_days`
- 手动触发维护：`POST /api/admin/maintenance` (需要 X-Admin-Token)

#### 5. 证书丢失

**解决方案**：重启服务，证书会自动重新生成。然后客户端/网关需要重新导入新的 `server-cert.cer`。

---

## 备注

- `server.db` 会在启动时自动创建并初始化所有表结构，不需要手工初始化
- 证书文件和私钥文件丢失后会重新生成；重新生成后客户端和网关需要重新导入 `server-cert.cer`
- 如果你只关心运行，部署时通常只需要把发布出来的**单个服务端可执行文件**放到目标目录并启动即可
- 推荐在生产环境中使用 `onboarding-qr.txt` 配合 QR 码生成器生成二维码，方便客户端和网关扫描
- 所有令牌都是高强度随机字符串，请勿使用弱密码或短字符串替换
