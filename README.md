# RemoteMessage

RemoteMessage 是一个三端协作的远程短信系统：

1. **Flutter 客户端**：查看短信、发送短信、搜索和置顶会话
2. **Android 网关端**：部署在真实安卓手机上，负责收短信、发短信、同步历史短信
3. **Middle Server (.NET 8)**：负责消息中转、网关注册、公钥管理和消息持久化

当前仓库已经包含：

- 可运行的三端代码
- GitHub Actions 构建流水线
- HTTPS 自签名证书导入流程
- 非对称加密收发链路
- 短信历史同步、去重、自动刷新与本地缓存

---

## 目录结构

```text
.
├─ .github/workflows/
│  ├─ android-gateway.yml
│  ├─ flutter-client.yml
│  └─ middle-server.yml
├─ android_gateway/
│  ├─ build.gradle
│  ├─ settings.gradle
│  └─ app/src/main/...
├─ client/
│  └─ flutter_client_source/
│     └─ lib/main.dart
└─ middle_server/
   ├─ Program.cs
   ├─ RemoteMessage.MiddleServer.csproj
   └─ README.md
```

---

## 当前功能状态

### Flutter 客户端

- 支持 Windows / Android / iOS / Linux 构建
- 会话列表 + 聊天窗口
- 新建短信
- 搜索会话 / 内容
- 会话置顶
- 本地 SQLite 缓存消息、设置、置顶状态
- 全量加载与增量同步
- 自动轮询刷新，减少手动点击刷新依赖
- 加载 / 同步进度显示，避免长时间无反馈
- 设置页可导入 `server-cert.cer`
- HTTPS 模式下仅信任导入的服务端证书

### Android 网关端

- 注册网关公钥到服务器
- 接收系统短信并上报服务器
- 轮询服务器并发送待发短信
- 历史短信同步
- 历史同步进度条与进度文案
- 历史同步增量化：会记住上次同步到的短信时间戳
- 本地待上传队列 SQLite 持久化
- 队列按 `messageId` 去重
- 自动补传 + 自动轮询，降低手动刷新的必要性
- 默认短信应用申请 / 电池优化引导 / 使用情况访问引导
- 内网 WebUI 控制页
- 支持导入服务端证书

### Middle Server

- 网关注册与公钥持久化
- 网关上行短信解密入库
- 客户端短信查询接口
- 客户端下发短信任务给网关
- 消息去重
- 会话置顶接口
- API 访问日志入库
- 启动时自动生成数据库、配置文件、证书文件
- 通过 `server.conf` 控制端口和共享密码
- 发布为 Linux x64 / Linux ARM64 单文件可执行程序
- SQLite 原生库会随单文件发布一起打包

---

## 三端数据与安全模型

### 基本链路

- **网关 -> 服务器**：
  - 网关获取服务器公钥
  - 用服务器公钥加密短信上报内容
  - 服务器用内存中的私钥解密并落库

- **客户端 -> 服务器 -> 网关**：
  - 客户端请求服务器发送短信
  - 服务器取出网关公钥并加密下发指令
  - 网关轮询任务并用自己的私钥解密后发送

### 持久化文件

- 服务端：`server.db`
- 网关端：`gateway_private.db`
- Flutter 客户端：本地私有 SQLite

### HTTPS 与证书

服务端首次启动会在可执行文件目录生成：

```text
server.db
server.conf
server-cert.cer
server-cert.pfx
```

- `server-cert.cer`：给 Flutter 客户端与 Android 网关导入
- `server-cert.pfx`：服务端自用

---

## Quick Start

### 1. 启动 middle server

```bash
dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

首次启动后会自动生成：

- `server.db`
- `server.conf`
- `server-cert.cer`
- `server-cert.pfx`

`server.conf` 示例：

```ini
# RemoteMessage server.conf
https_port=5001
password=replace-with-a-long-random-password
```

修改 `server.conf` 后重启服务。

### 2. 配置 Android 网关

在手机上：

1. 安装 Android 网关 APK
2. 填写：
   - Server Base URL：`https://<服务器IP>:<https_port>`
   - Device ID
   - Password：与 `server.conf` 一致
3. 导入 `server-cert.cer`
4. 点击 **Register**
5. 允许短信权限并尽量授予默认短信应用角色

### 3. 配置 Flutter 客户端

1. 安装 / 运行客户端
2. 打开设置页
3. 填写：
   - Server Base URL：`https://<服务器IP>:<https_port>`
   - Device ID：与网关一致
   - Password：与 `server.conf` 一致
4. 导入 `server-cert.cer`

---

## 构建与 CI

### GitHub Actions

- `flutter-client.yml`
  - 构建 Linux / Windows / Android / iOS(no-codesign)
- `android-gateway.yml`
  - 构建并签名 Android Debug APK
- `middle-server.yml`
  - 发布 Linux x64 / Linux ARM64 单文件服务端产物

### 当前发布特性

middle server 的 Release 发布包含：

- `PublishSingleFile=true`
- `IncludeNativeLibrariesForSelfExtract=true`
- `IncludeAllContentForSelfExtract=true`
- `EnableCompressionInSingleFile=true`

也就是说 Linux 下的 SQLite 原生库（例如 `libe_sqlite3.so`）会打进服务端单文件，不再要求手工额外部署该库。

---

## 安全评审结论

### 当前是否足够直接暴露公网？

**结论：不够。**

当前实现适合：

- 局域网
- 家庭网络
- 内网穿透后的受控环境
- VPN 后访问
- 反向代理之后再叠加更强防护

### 已具备的基础安全措施

- HTTPS
- 手工导入并固定信任服务端证书
- 网关 / 服务端之间非对称加密
- 共享密码鉴权（`X-Password`）
- 固定时序密码比较
- 基础字段长度限制
- 请求体大小限制
- 上传解密失败时使用较保守的统一错误返回

### 还不足以直面公网的原因

1. 仍然是**单一共享密码**，不是设备级或用户级认证
2. 缺少**限流 / 防爆破 / 封禁策略**
3. 缺少**防重放机制**（nonce / timestamp / 签名）
4. 缺少更严格的**设备信任和撤销机制**
5. 缺少公网级别的**监控、告警、备份、审计与外层反向代理防护**

### 如果你要上公网，建议至少补齐

- 反向代理（Nginx / Caddy）+ 正式证书
- 限流 / IP 访问控制
- JWT / mTLS / 每设备独立凭据
- 防重放签名机制
- 数据库备份与日志监控

---

## 注意事项

1. Android 真机权限、后台保活和厂商限制会直接影响可靠性。
2. 服务端如果重新生成证书，客户端和网关都要重新导入 `server-cert.cer`。
3. 当前三端已经能稳定工作，但公网安全仍建议通过外层网关和附加鉴权进一步加强。
4. 历史短信同步已支持增量化；首次同步量大时会显示进度。
5. Flutter 客户端已经加入自动刷新和加载进度，但在弱网下仍建议保留手动同步作为兜底。

---

## 仓库

- GitHub: `https://github.com/pgs666/RemoteMessage`
- 默认分支：`main`

如果只想看 middle server 的细节，请继续阅读：`middle_server/README.md`
