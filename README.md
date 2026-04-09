# RemoteMessage

RemoteMessage 是一个完整的三端协作远程短信系统，允许你通过 Android 手机作为网关，在任何设备上收发短信。

## 系统架构

```
┌─────────────────┐      HTTPS/RSA-OAEP      ┌─────────────────┐      HTTPS/RSA-OAEP      ┌─────────────────┐
│  Flutter Client │ ◄──────────────────────► │  Middle Server  │ ◄──────────────────────► │ Android Gateway │
│  (任意设备)      │                          │   (.NET 8)      │                          │  (安卓手机)      │
└─────────────────┘                          └─────────────────┘                          └─────────────────┘
  • 查看/搜索短信                          • 消息中转                                  • 收发系统短信
  • 发送短信                              • 公钥管理                                  • 历史短信同步
  • 会话管理/置顶                         • 数据持久化                                • 内网WebUI
  • 本地SQLite缓存                        • 会话置顶                                   • 双卡支持
```

### 数据流向

**上行（网关→客户端）：**
```
Android手机收到短信 → RSA-OAEP加密 → Middle Server解密入库 → Flutter客户端轮询拉取
```

**下行（客户端→网关）：**
```
Flutter客户端发起发送请求 → Middle Server用网关公钥加密任务 → Android网关轮询获取 → 解密后发送
```

---

## 项目结构

```text
RemoteMessage/
├── client/                              # Flutter客户端
│   ├── flutter_client_source/
│   │   └── lib/
│   │       ├── main.dart                # 应用入口
│   │       └── src/
│   │           ├── app.dart             # 应用主组件 (主题/启动)
│   │           ├── app_data.dart        # 数据层 (SQLite/设置/HTTP)
│   │           ├── message_home_page.dart  # 主页面 (会话列表/聊天)
│   │           ├── compose_message_page.dart  # 编写短信页面
│   │           ├── settings_page.dart   # 设置页 (服务器/证书/主题)
│   │           ├── onboarding_qr.dart   # QR码解析/生成
│   │           └── android_launcher_icon_service.dart  # Android图标切换
│   ├── icons/                           # 应用图标资源
│   ├── apply_client_icons.py            # 图标自动注入脚本
│   └── configure_client_app_identity.py # 应用身份配置脚本 (包名/显示名)
├── middle_server/                       # 中间服务器 (.NET 8)
│   ├── Program.cs                       # 应用入口 & API路由
│   ├── RemoteMessage.MiddleServer.csproj
│   ├── README.md                        # 服务器详细文档
│   ├── Api/
│   │   └── ApiSupport.cs                # API辅助 (验证/加密/规范化)
│   ├── Config/
│   │   ├── ServerRuntimeSettings.cs     # 运行时配置 (令牌/端口/保留策略)
│   │   ├── HttpsCertificateSettings.cs  # HTTPS证书配置
│   │   └── OnboardingQrBootstrap.cs     # 首次启动QR码生成
│   ├── Contracts/
│   │   └── ApiContracts.cs              # API请求/响应DTO
│   ├── Core/
│   │   ├── MessageIdentity.cs           # 消息标识工具
│   │   └── RuntimeLayout.cs             # 运行时目录布局
│   ├── Data/
│   │   └── SqliteRepository.cs          # SQLite数据访问层
│   ├── Infrastructure/
│   │   └── FileLogger.cs                # 文件日志提供程序
│   └── Security/
│       ├── CryptoState.cs               # RSA加密状态管理
│       └── GatewayRegistry.cs           # 网关注册表
├── android_gateway/                     # Android网关应用
│   ├── build.gradle                     # 根项目构建配置
│   ├── settings.gradle                  # Gradle设置
│   ├── gradle.properties                # Gradle属性
│   ├── app/
│   │   ├── build.gradle                 # 应用构建配置
│   │   ├── proguard-rules.pro           # ProGuard混淆规则
│   │   └── src/main/
│   │       ├── AndroidManifest.xml      # 应用清单
│   │       ├── java/cn/ac/studio/rmg/
│   │       │   ├── GatewayRuntime.kt         # 核心运行时 (1494行)
│   │       │   │   └── 网关注册/加密解密/短信收发/历史同步/队列管理
│   │       │   ├── MainActivity.kt           # 主界面 (867行)
│   │       │   │   └── 配置表单/操作按钮/QR扫描/WebUI管理
│   │       │   ├── SmsReceiver.kt            # SMS广播接收器
│   │       │   ├── SmsSendStatusReceiver.kt  # 短信发送状态接收器
│   │       │   ├── MmsReceiver.kt            # MMS广播接收器
│   │       │   ├── RespondViaMessageService.kt # 快速回复服务
│   │       │   ├── GatewayLocalDb.kt         # SQLite本地数据库
│   │       │   ├── GatewaySyncWorker.kt      # WorkManager定期同步
│   │       │   ├── GatewayWebUiServer.kt     # 内网WebUI服务器
│   │       │   ├── GatewaySimSupport.kt      # 多SIM卡支持
│   │       │   ├── GatewayCertificateStore.kt # 证书存储
│   │       │   ├── GatewaySecretStore.kt     # 密钥存储
│   │       │   ├── GatewayDebugLog.kt        # 调试日志
│   │       │   ├── GatewayForegroundService.kt # 前台服务
│   │       │   ├── GatewayPermissionCenter.kt # 权限管理中心
│   │       │   ├── GatewaySmsStatusContract.kt # 短信状态契约
│   │       │   ├── GatewayLogActivity.kt     # 日志查看Activity
│   │       │   └── PermissionAndRoleHelper.kt # 权限和角色辅助
│   │       └── res/
│   │           ├── layout/              # 布局文件
│   │           ├── values/              # 英文字符串
│   │           └── values-zh-rCN/       # 中文字符串
│   └── signing/                         # 签名配置 (git-ignored)
├── .github/workflows/                   # CI/CD流水线
│   ├── flutter-client.yml               # 客户端多平台构建
│   ├── android-gateway.yml              # 网关APK构建
│   └── middle-server.yml                # 服务器发布
├── artifacts_dl/                        # 历史构建产物下载
├── .gitignore
├── RemoteMessage.sln                    # Visual Studio解决方案
└── README.md                            # 本文件
```

---

## 核心功能

### Flutter客户端
- **跨平台支持**：Linux / Windows / Android / iOS (no-codesign)
- **会话管理**：会话列表、聊天窗口、搜索、置顶
- **短信收发**：查看历史短信、新建并发送短信
- **本地缓存**：SQLite存储消息、设置、置顶状态
- **智能同步**：自动轮询刷新 (20秒间隔)、增量同步、加载进度显示
- **证书管理**：设置页导入 `server-cert.cer`，HTTPS模式仅信任导入的证书
- **双卡支持**：显示并选择网关端的SIM卡槽
- **主题切换**：Material 3设计，支持亮色/暗色主题
- **国际化**：简体中文 / 英文双语
- **响应式布局**：桌面端左右分栏，移动端导航切换
- **联系人集成**：读取手机联系人并显示在短信列表中
- **QR码入网**：支持扫描QR码快速配置服务器信息
- **Android启动器图标**：支持默认/亮色/暗色三种图标模式切换

### Android网关
- **短信网关**：将Android手机转变为短信网关服务器
- **实时接收**：高优先级广播接收系统短信
- **加密上报**：RSA-OAEP加密后上传至服务器
- **任务轮询**：定期拉取服务器下发的发送任务
- **历史同步**：批量同步历史短信，支持断点续传
- **队列管理**：本地SQLite持久化待上传队列，去重
- **多SIM卡**：自动识别并上报SIM卡槽信息，支持双卡设备
- **内网WebUI**：基于NanoHTTPD的局域网控制页
- **权限引导**：默认短信应用申请、电池优化豁免、使用情况访问引导
- **自动重试**：后台WorkManager定期同步，自动补传
- **证书支持**：导入服务端自签名证书
- **QR码扫描**：使用ZXing库扫描入网QR码
- **前台服务**：保持网关应用在后台运行
- **日志查看**：内置调试日志和活动日志查看器

### Middle Server
- **.NET 8 / ASP.NET Core**：现代高性能后端框架
- **自动初始化**：首次启动自动生成数据库、配置文件、证书、QR码
- **网关注册**：管理网关公钥，支持多网关
- **加密转发**：RSA-OAEP加密/解密上下行消息
- **消息去重**：自动过滤重复短信
- **会话置顶**：客户端置顶会话持久化
- **API日志**：所有接口访问记录入库
- **单文件发布**：Linux x64 / Linux ARM64 单文件可执行程序
- **内置SQLite**：原生库打包进单文件，无需额外部署
- **令牌鉴权**：分段令牌机制 (X-Gateway-Token / X-Client-Token / X-Admin-Token)
- **维护策略**：可配置的日志轮转、数据保留、数据库大小限制
- **QR码生成**：首次启动自动生成入网QR码，方便客户端和网关快速配置

---

## 快速开始

### 1. 启动Middle Server

```bash
dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

首次启动后会在可执行文件同目录自动生成：
```
server.db              # SQLite数据库
server.conf            # 配置文件
server-cert.cer        # 客户端/网关注入的证书
server-cert.pfx        # 服务端自用证书
server-crypto-private.pem  # 服务器RSA私钥
onboarding-qr.txt      # 入网QR码内容 (首次启动)
```

编辑 `server.conf` 修改端口和令牌：
```ini
https_port=5001
gateway_token=replace-with-a-long-random-string
client_token=replace-with-a-long-random-string
admin_token=replace-with-a-long-random-string
```

**发布为单文件 (推荐生产环境)：**
```bash
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj \
  -c Release -r linux-x64 --self-contained true \
  -o publish/linux-x64
```

### 2. 配置Android网关

1. 构建并安装APK到手机：
   ```bash
   gradle -p android_gateway :app:assembleDebug
   ```
2. 打开应用，选择以下任一方式配置：
   - **扫描QR码**：扫描服务端生成的 `onboarding-qr.txt` 中的QR码
   - **手动填写**：
     - **Server Base URL**：`https://<服务器IP>:5001`
     - **Gateway Token**：与 `server.conf` 中的 `gateway_token` 一致
3. 导入 `server-cert.cer`
4. 点击 **Register** 注册到服务器
5. 授予短信权限，建议设置为默认短信应用

### 3. 配置Flutter客户端

客户端构建方式多样，详见下方 [构建指南](#构建指南)。

运行后：
1. 打开设置页，选择以下任一方式配置：
   - **扫描QR码**：扫描服务端生成的入网QR码
   - **手动填写**：
     - **Server Base URL**：`https://<服务器IP>:5001`
     - **Client Token**：与 `server.conf` 中的 `client_token` 一致
2. 导入 `server-cert.cer` (HTTPS自签名证书)
3. 返回主页即可看到会话列表

---

## 构建指南

### 前置要求
- **Flutter客户端**：Flutter SDK (stable), Python 3 + Pillow, Java 17 (Android), Ninja + GTK (Linux)
- **Android网关**：Java 17, Gradle 8.7, Android SDK (API 34, min SDK 23)
- **Middle Server**：.NET 8.0 SDK

### Flutter客户端

CI采用动态生成Flutter项目骨架 + 注入源码的策略，手动构建同理：

```bash
# 1. 创建Flutter项目
flutter create --platforms=android,ios,linux,windows client/flutter_client_build

# 2. 添加依赖
cd client/flutter_client_build
flutter pub add path path_provider sqlite3 file_selector flutter_secure_storage flutter_contacts image_picker

# 3. 注入源码
cp ../flutter_client_source/lib/main.dart lib/main.dart
cp -r ../flutter_client_source/lib/src lib/src

# 4. 配置应用身份 (包名/显示名/图标)
python ../configure_client_app_identity.py .

# 5. 应用图标
python ../apply_client_icons.py . ../icons

# 6. 构建目标平台
flutter build linux       # Linux
flutter build windows     # Windows
flutter build apk         # Android
flutter build ios --no-codesign  # iOS
```

### Android网关

```bash
# Debug APK
gradle -p android_gateway :app:assembleDebug

# 带签名的Release APK (需配置签名)
ANDROID_KEYSTORE_PATH=... ANDROID_KEY_ALIAS=... \
ANDROID_KEYSTORE_PASSWORD=... ANDROID_KEY_PASSWORD=... \
gradle -p android_gateway :app:assembleRelease
```

### Middle Server

```bash
# 开发运行
dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj

# 发布单文件
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj \
  -c Release -r linux-x64 --self-contained true \
  -o publish/linux-x64

dotnet publish middle_server/RemoteMessage.MiddleServer.csproj \
  -c Release -r linux-arm64 --self-contained true \
  -o publish/linux-arm64
```

---

## CI/CD流水线

本项目通过GitHub Actions实现自动化构建：

| Workflow | 触发条件 | 构建产物 |
|----------|----------|----------|
| **flutter-client.yml** | push / PR | Linux / Windows / Android (signed APK) / iOS (no-codesign app + unsigned IPA) |
| **android-gateway.yml** | push / PR | Android Debug APK |
| **middle-server.yml** | push / PR | Linux x64 / Linux ARM64 单文件可执行程序 |

**签名密钥**：Android构建通过GitHub Secrets配置签名，CI自动解码keystore并完成签名。

---

## 安全模型

### 加密链路

```
┌──────────────────────────────────────────────────────────────┐
│                       网关 → 服务器                           │
│  1. 网关获取服务器公钥 (/api/crypto/server-public-key)        │
│  2. 用公钥加密短信内容 (RSA-OAEP SHA256)                      │
│  3. 服务器用内存私钥解密 → 入库                                │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                    客户端 → 服务器 → 网关                      │
│  1. 客户端请求发送短信 (/api/client/send)                     │
│  2. 服务器取出网关公钥 → 加密下发指令                          │
│  3. 网关轮询获取任务 (/api/gateway/pull)                      │
│  4. 用私钥解密 → 发送短信                                     │
└──────────────────────────────────────────────────────────────┘
```

### 鉴权机制
- **分段令牌**：`X-Gateway-Token` / `X-Client-Token` / `X-Admin-Token` 三种独立令牌
- **自动生成**：首次启动自动生成高强度随机令牌
- **固定时序比较**：防时序攻击
- **请求体限制**：最大256KB
- **字段长度校验**：基础输入防护

### HTTPS与证书
- 服务端自签名证书，首次启动自动生成
- 客户端/网关手动导入 `.cer` 文件
- 客户端HTTPS模式下仅信任导入的证书

### 数据持久化
| 组件 | 存储 | 文件名 |
|------|------|--------|
| Middle Server | SQLite | `server.db` |
| Android Gateway | SQLite | `gateway_local.db` |
| Flutter Client | SQLite | `app_data.sqlite` (应用私有目录) |

### 维护策略
Middle Server内置自动维护任务：
- **日志轮转**：默认保留14天，最大32MB
- **API日志清理**：默认保留30天
- **消息保留**：可配置保留天数 (0=永久)
- **数据库大小限制**：默认最大512MB
- **维护间隔**：默认每60分钟执行一次

---

## API 端点

### 健康检查
- `GET /healthz`

### 加密
- `GET /api/crypto/server-public-key`

### 网关接口 (需要 X-Gateway-Token)
- `POST /api/gateway/register` - 注册网关
- `POST /api/gateway/sms/upload` - 上传短信
- `GET /api/gateway/pull` - 拉取发送任务
- `POST /api/gateway/status` - 上报状态

### 客户端接口 (需要 X-Client-Token)
- `GET /api/client/inbox` - 查询短信
- `POST /api/client/send` - 发送短信
- `POST /api/client/conversations/pin` - 置顶会话
- `GET /api/client/conversations/pins` - 获取置顶列表
- `GET /api/client/sim-profiles` - 获取SIM卡配置
- `GET /api/client/gateway/status` - 查询网关状态

### 管理接口 (需要 X-Admin-Token)
- `POST /api/admin/maintenance` - 触发维护任务
- `GET /api/admin/stats` - 获取系统统计

---

## 安全评审结论

**当前版本适合：** 局域网 / 家庭网络 / VPN / 内网穿透 / 反向代理后的受控环境

**不建议直接暴露公网**，原因：
1. 令牌认证虽然分段，但仍为预共享密钥模式
2. 缺少限流/防爆破/封禁策略
3. 缺少防重放机制 (nonce/timestamp/签名)
4. 缺少设备信任和撤销机制
5. 缺少公网级监控/告警/备份/审计

**若需上公网，建议补齐：**
- 反向代理 (Nginx/Caddy) + 正式证书
- 限流/IP访问控制
- JWT/mTLS/动态令牌机制
- 防重放签名机制
- 数据库备份与日志监控

---

## 注意事项

1. **Android真机限制**：权限、后台保活和厂商限制会直接影响可靠性
2. **证书更新**：服务端重新生成证书后，客户端和网关需重新导入
3. **令牌同步**：修改 `server.conf` 中的令牌后，需同步更新三端配置
4. **首次同步**：历史短信首次同步量大时会显示进度，请耐心等待
5. **弱网环境**：客户端有自动刷新，但弱网下仍建议保留手动同步作为兜底
6. **单文件发布**：Linux下的SQLite原生库 (`libe_sqlite3.so`) 已打包进服务端单文件
7. **QR码入网**：推荐使用QR码快速配置，避免手动输入错误
8. **数据库维护**：服务端会自动清理过期数据，无需手动干预

---

## 技术栈

| 组件 | 技术 | 语言 | 核心依赖 |
|------|------|------|----------|
| Flutter Client | Flutter (Material 3) | Dart | sqlite3, path_provider, file_selector, flutter_secure_storage, flutter_contacts, image_picker |
| Android Gateway | Android (Kotlin) | Kotlin | OkHttp 4.12, NanoHTTPD 2.3.1, WorkManager, AndroidX, ZXing 3.5.3 |
| Middle Server | ASP.NET Core | C# | Microsoft.Data.Sqlite 8.0.4, QRCoder 1.7.1, System.Security.Cryptography |
| CI/CD | GitHub Actions | - | Flutter Action, .NET Setup, Gradle, Java 17 |
| 工具脚本 | Python 3 | Python | Pillow (图标生成), plistlib (iOS配置) |

---

## 包名与应用标识

| 组件 | 包名/命名空间 | 应用ID |
|------|--------------|--------|
| Android Gateway | `cn.ac.studio.rmg` | `cn.ac.studio.rmg` |
| Flutter Client (Android) | `cn.ac.studio.rmc` | `cn.ac.studio.rmc` |
| Middle Server | `RemoteMessage.MiddleServer` | N/A |

---

## 仓库信息

- **GitHub**: https://github.com/pgs666/RemoteMessage
- **默认分支**: `main`

如需深入了解Middle Server的实现细节，请阅读：[middle_server/README.md](middle_server/README.md)
