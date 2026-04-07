# RemoteMessage

这是一个三端架构的远程短信收发示例工程，包含：

1. **Flutter 客户端**（Windows / Android / iOS / Linux x64 / Linux ARM）
2. **原生 Android ARM64 网关端**（部署在有短信能力的手机）
3. **中间服务器（.NET 8）**（负责转发与密钥管理，支持 Linux x64 / Linux ARM 发布）

> 目标是提供一套可扩展的基础骨架（MVP），并通过 **RSA 非对称加密**提升端到端安全性。

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
  - 服务端：`middle_server/data/server.db` 持久化消息、出站队列、置顶会话
  - 网关端：`gateway_private.db` 持久化待上报队列，离线可积压、在线自动补传
  - 客户端：私有本地数据库文件（当前以 sqlite-like JSON 落地）持久化消息/设置/置顶

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
  - 聊天软件风格 UI（会话列表 + 聊天窗口 + 气泡消息）
  - 新建短信对话（New SMS 弹窗）
  - 设置页（服务器地址、设备ID、主题模式）
  - 自动深色模式（System）与手动 Light/Dark
  - 增量同步与全量加载（`sinceTs` / Load All）
  - 本地缓存去重（按 `messageId`），避免重复获取同一短信
  - 会话搜索 + 置顶（本地优先，服务端接口同步）
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
  - 手动 Flush Pending Uploads 按钮
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
3. 当前服务端使用内存队列，生产环境建议替换为 Redis / MQ + 数据库存储。
