# Middle Server (.NET 8 / ASP.NET Core)

RemoteMessage middle server 负责：

- 管理网关注册信息与网关公钥
- 接收网关上传的短信并写入 `server.db`
- 为 Flutter 客户端提供短信查询接口
- 为客户端生成下行短信任务，并用网关公钥加密后入队
- 提供 HTTPS 与基础口令鉴权（`X-Password`）

---

## 运行时自动生成的文件

服务端无论是 `dotnet run` 还是发布后的单文件可执行程序，首次启动都会在**可执行文件同目录**自动生成：

```text
server.db
server.conf
server-cert.cer
server-cert.pfx
```

说明：

- `server.db`：SQLite 数据库，自动创建，无需手工预建
- `server.conf`：服务端配置文件，自动生成，包含端口和密码
- `server-cert.cer`：给 Flutter 客户端 / Android 网关导入信任
- `server-cert.pfx`：服务端自身 HTTPS 证书私钥文件，请妥善保管

如果老版本运行目录里还存在 `password.conf`，新版本会自动读取其中的密码并迁移到 `server.conf`。

---

## server.conf

首次启动会生成类似如下内容：

```ini
# RemoteMessage server.conf
# Generated on first start. Edit values and restart the service.
https_port=5001
password=replace-with-a-long-random-password
```

字段说明：

- `https_port`：HTTPS 监听端口
- `password`：客户端和网关调用 API 时必须放入 `X-Password` 请求头

修改 `server.conf` 后需要**重启服务**才会生效。

---

## 本地运行

```bash
dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

启动日志会打印：

- 可执行目录
- 实际读取的 `server.conf` 路径
- HTTPS 端口
- `server.db` 路径

---

## 发布为单文件可执行程序

项目已配置为 Release 发布时：

- `PublishSingleFile=true`
- 将 SQLite 原生库（例如 Linux 下的 `libe_sqlite3.so`）打包进单文件
- 允许把运行所需内容一并打包进单文件

推荐发布命令：

```bash
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj -c Release -r linux-x64 --self-contained true -o publish/linux-x64
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj -c Release -r linux-arm64 --self-contained true -o publish/linux-arm64
```

发布产物目标是**单个服务端可执行文件**；首次运行后才会在旁边生成 `server.db`、`server.conf`、证书文件。

GitHub Actions 中的 `middle-server-ci` 也已按同样方式发布 Linux x64 / Linux ARM64 单文件产物。

---

## API 能力概览

- `GET /healthz`
- `GET /api/crypto/server-public-key`
- `POST /api/gateway/register`
- `POST /api/gateway/sms/upload`
- `GET /api/gateway/pull`
- `GET /api/client/inbox`
- `POST /api/client/send`
- `POST /api/client/conversations/pin`
- `GET /api/client/conversations/pins`

服务端已增加一些基础防护：

- 固定时序口令比较，避免直接字符串比较
- 请求体大小上限（当前 256 KB）
- 基本字段长度校验
- 上传解密失败时返回统一错误，避免泄露过多内部异常细节

---

## 安全评审结论

### 当前结论

**不建议直接裸露到公网。**

当前版本更适合：

- 家庭局域网 / 公司内网
- VPN 后访问
- 放在反向代理后面（如 Caddy / Nginx），再叠加公网证书、IP 限制、日志和限流

### 原因

虽然目前已经具备：

- HTTPS
- 非对称加密的上下行消息体
- 共享口令鉴权
- 输入长度限制

但若要直接上公网，还缺少这些关键能力：

1. **更强的身份认证机制**  
   目前是单一共享密码（`X-Password`），不适合公网长期暴露。

2. **限流 / 防爆破 / 防滥用**  
   还没有针对 IP、设备、路径的速率限制和封禁策略。

3. **防重放机制**  
   目前没有 nonce / timestamp 签名校验，请求可被重复提交。

4. **更强的设备信任模型**  
   目前拿到共享密码就可以注册或替换网关公钥，不够细粒度。

5. **完备的公网运维防护**  
   例如：WAF、外层反向代理、证书自动续期、告警、备份、审计汇总等。

### 如果一定要上公网，至少建议补齐

- 反向代理 + 正规公网 TLS 证书
- 按 IP / 路径做限流
- 使用每设备独立凭据，或改成 JWT / mTLS / 签名鉴权
- 为所有写接口加入防重放字段
- 增加日志审计、监控告警与数据库备份

---

## 与客户端 / 网关配合

- Flutter 客户端与 Android 网关都要导入 `server-cert.cer`
- 两端都要配置与 `server.conf` 中一致的 `password`
- 两端都应使用 `https://<server-ip>:<https_port>`

如果你修改了端口或密码：

1. 编辑 `server.conf`
2. 重启 middle server
3. 同步更新 Flutter 客户端与 Android 网关配置

---

## 备注

- `server.db` 会在启动时自动创建，不需要手工初始化
- 证书文件丢失后会重新生成；重新生成后客户端和网关需要重新导入 `server-cert.cer`
- 如果你只关心运行，部署时通常只需要把发布出来的**单个服务端可执行文件**放到目标目录并启动即可
