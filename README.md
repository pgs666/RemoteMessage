# RemoteMessage

这是一个三端架构的远程短信收发示例工程，包含：

1. **Flutter 客户端**（Windows / Android / iOS / Linux x64 / Linux ARM）
2. **原生 Android ARM64 网关端**（部署在有短信能力的手机）
3. **中间服务器（.NET 8）**（负责转发与密钥管理，支持 Linux x64 / Linux ARM 发布）

> 目标是提供一套可扩展的基础骨架（MVP），并通过 **RSA 非对称加密 + HTTPS 证书信任**提升端到端安全性。

---

## 目录结构

```text
.
├─ .github/workflows/
│  ├─ flutter-client.yml
│  ├─ android-gateway.yml
│  └─ middle-server.yml
├─ client/
│  └─ flutter_client_source/
│     └─ lib/
│        └─ main.dart
├─ android_gateway/
│  ├─ settings.gradle
│  ├─ build.gradle
│  └─ app/
│     ├─ build.gradle
│     └─ src/main/...
└─ middle_server/
   ├─ RemoteMessage.MiddleServer.csproj
   └─ Program.cs
```

---

## 关键设计

- 服务器在启动时生成 RSA 密钥对：
  - 公钥供网关端加密上行短信（手机 -> 服务器）
  - 私钥仅在服务器内存中用于解密
- Android 网关端首次启动生成本地 RSA 密钥对并向服务器注册公钥
- 客户端发起“发送短信”请求时：
  - 服务器使用网关公钥加密指令并入队
  - 网关轮询获取任务后使用私钥解密，再调用 `SmsManager` 发送
- 新增历史与去重机制：
  - 网关可执行“历史短信同步”（读取系统短信数据库）
  - 服务端基于 `messageId` 做去重存储
  - 客户端支持 `sinceTs` 增量拉取并本地缓存，避免重复获取
- 三端持久化（私有 SQLite 思路）：
  - 服务端：运行后在可执行文件同目录生成 `server.db`，持久化消息、出站队列、置顶会话
  - 网关端：`gateway_private.db` 持久化待上报队列，离线可积压、在线自动补传
  - 客户端：私有 SQLite 文件持久化消息/设置/置顶
- 网关端增强：
  - 可申请默认短信角色（Default SMS app）
  - 可引导电池优化白名单与使用情况访问（保活辅助）
  - 内网 WebUI（端口 8088，仅 LAN/本机访问）
  - 双卡可选发送（Subscription ID）
- 中间服务器增强：
  - 密码鉴权（`X-Password`）
  - 同目录自动生成 / 读取 `password.conf`
  - 同目录自动生成 HTTPS 自签名证书：`server-cert.cer` / `server-cert.pfx`
  - SQLite 持久化 gateway 注册信息
  - API 访问日志持久化

---

## GitHub 仓库状态（已创建并推送）

- 仓库地址：`https://github.com/pgs666/RemoteMessage`
- 默认分支：`main`
- 首次初始化提交：`feat: bootstrap RemoteMessage mono-repo with client/gateway/server and CI`

如需在其他环境复现，可参考命令：

```bash
git init
git add .
git commit -m "feat: bootstrap RemoteMessage mono-repo with client/gateway/server and CI"
git branch -M main
gh repo create RemoteMessage --public --source . --remote origin --push
```

---

## GitHub Actions

- `flutter-client.yml`
  - 在 CI 中动态生成 Flutter 工程并覆盖 `lib/main.dart`
  - 构建：Linux / Windows / Android APK / iOS(no-codesign)
  - Linux job 已补齐 `libgtk-3-dev` 依赖，修复 `gtk+-3.0` 缺失导致的编译失败
  - iOS 产物新增上传 `Runner.app` 压缩包（`flutter-ios-no-codesign-app`）
  - iOS 产物新增上传 unsigned IPA（`flutter-ios-unsigned-ipa`）
- `android-gateway.yml`
  - 构建原生 Android 网关 APK
- `middle-server.yml`
  - `dotnet publish` 输出 Linux x64 与 Linux ARM64 产物
  - 已改为 `--self-contained true` + `PublishSingleFile=true`，将运行库打包进产物

### 最近一次运行状态（当前）

- `middle-server-ci`：✅ success  
  - 运行链接：`https://github.com/pgs666/RemoteMessage/actions/runs/24058464579`
- `android-gateway-ci`：❌ failure（已定位并修复）  
  - 运行链接：`https://github.com/pgs666/RemoteMessage/actions/runs/24058464595`
  - 原因：缺少 `android.useAndroidX=true`
  - 修复：已新增 `android_gateway/gradle.properties`
- `flutter-client-ci`：⏳ in_progress  
  - 运行链接：`https://github.com/pgs666/RemoteMessage/actions/runs/24058464587`

---

## 功能完善度验证（按目标需求）

### 1) Flutter 客户端（Windows / Android / iOS / Linux）

- ✅ 已实现基础功能：
  - 自适应 UI：
    - 桌面端：会话+聊天平铺
    - 手机端：会话列表页 -> 聊天详情页
  - 标题统一为项目名 `RemoteMessage`
  - 新建短信对话（New SMS 弹窗）
  - 设置页（服务器地址、设备ID、密码、主题模式）
  - 使用系统文件选择器导入服务端 `server-cert.cer`
  - 当使用 HTTPS 时，仅信任导入的服务器证书
  - 自动深色模式（System）与手动 Light/Dark
  - 增量同步与全量加载（`sinceTs` / Load All）
  - 本地缓存去重（按 `messageId`），避免重复获取同一短信
  - 会话搜索 + 置顶（本地优先，服务端接口同步）
  - 本地 SQLite 持久化（消息、元信息、置顶、设置）
  - 发送短信任务（`/api/client/send`）
- ⚠️ 当前状态：**MVP+**（已具备聊天体验与缓存）
- 🔧 后续建议：SQLite 持久化、消息已送达状态、搜索/置顶会话

### 2) Android 原生网关（ARM64）

- ✅ 已实现基础功能：
  - 接收系统 SMS 广播并上报服务器
  - 轮询服务器拉取待发送任务并调用 `SmsManager` 发送
  - 本地生成 RSA 密钥对、向服务器注册公钥
  - 历史短信同步按钮（读取系统短信并批量上报）
  - 上报时附带 `messageId` + `direction` 便于服务端去重
  - 本地私有SQLite待上报队列（弱网重试）
  - 周期自动同步 Worker（网络可用时自动补传并轮询任务）
  - 可选 SIM 子卡发送（Subscription ID）
  - 手动 Flush Pending Uploads 按钮
  - 内网 WebUI 控制面板（Register/Poll/Sync/Flush）
  - 密码配置与请求头注入（`X-Password`）
  - 使用系统文件选择器导入服务端证书，并在 HTTPS 下信任该证书
- ✅ CI 失败点已修复：AndroidX 配置已补齐
- ⚠️ 生产前仍需完善：前台服务保活、重试队列、双卡支持、权限引导细化

### 3) Middle Server（.NET 8，Linux x64 / ARM64）

- ✅ 已实现基础功能：
  - 服务器公钥下发
  - 网关注册与公钥保存
  - 上行短信解密入库（SQLite持久化）
  - 下行任务使用网关公钥加密并供网关拉取
  - `messageId` 去重与 `sinceTs` 增量查询
  - 会话置顶持久化接口
  - `password.conf` + `X-Password` 鉴权 + request 日志
  - 启动时自动生成并启用 HTTPS 自签名证书
  - gateway 公钥持久化表（重启后不丢失）
- ✅ CI 已通过 Linux x64/arm64 发布流程
- ⚠️ 生产前仍需完善：持久化存储、鉴权、审计日志、限流与告警

### 4) 非对称加密（安全性）

- ✅ 已落地 RSA OAEP-SHA256 基础流程：
  - 网关 -> 服务器：使用服务器公钥加密上行短信
  - 服务器 -> 网关：使用网关公钥加密下行指令
- ⚠️ 仍建议增强：密钥轮换、设备吊销、签名验签、防重放 nonce/timestamp

---

## 注意事项

1. Android 真机短信权限和后台保活策略会影响收发可靠性。
2. iOS 构建在 CI 中使用 `--no-codesign`，仅用于验证编译通过。
3. 当前发送链路已做 SQLite 持久化，但生产环境仍建议结合 Redis / MQ、审计与告警能力进一步增强可靠性。
4. 若 Flutter 客户端或 Android 网关配置的是 `https://` 地址，则必须先导入服务端生成的 `server-cert.cer`。

---

## 密码验证

- 服务端首次运行会在同目录自动创建 `password.conf`
- 默认格式：

```ini
# RemoteMessage password.conf
password=your-password-here
```

- 客户端与网关端需要配置相同密码，所有受保护接口通过请求头 `X-Password` 传递
- 若密码错误，服务端将返回 `401 invalid password`

---

## HTTPS 证书生成与导入

- 服务端首次运行后，会在可执行文件同目录生成以下文件：

```text
server.db
password.conf
server-cert.cer
server-cert.pfx
```

- 默认 HTTPS 监听端口为 `5001`
- 可通过环境变量 `REMOTE_MESSAGE_HTTPS_PORT` 修改 HTTPS 端口
- `server-cert.cer` 用于导入到 Flutter 客户端与 Android 网关，建立对服务端自签名证书的信任
- `server-cert.pfx` 由服务端自身加载使用，请勿随意泄露

### Flutter 客户端导入步骤

1. 在服务端运行目录找到 `server-cert.cer`
2. 打开 Flutter 客户端设置页
3. 点击 **导入服务器证书**
4. 通过系统文件选择器选择 `server-cert.cer`
5. 将服务器地址配置为 `https://<服务器IP>:5001`

### Android 网关导入步骤

1. 在服务端运行目录找到 `server-cert.cer`
2. 将证书传到安卓手机
3. 打开网关 App，点击 **Import Server Certificate / 导入服务器证书**
4. 通过系统文件选择器选择 `server-cert.cer`
5. 将服务器地址配置为 `https://<服务器IP>:5001`

### 安全说明

- 两个客户端在 HTTPS 模式下都会只信任导入的服务器证书
- 这样可以避免明文 HTTP 传输密码与消息元数据
- 如果服务端重新生成证书，需要在两个客户端重新导入新证书
