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
│   │   └── lib/main.dart                # 客户端全部源码 (单文件, 1763行)
│   ├── icons/                           # 应用图标资源
│   └── apply_client_icons.py            # 图标自动注入脚本
├── middle_server/                       # 中间服务器 (.NET 8)
│   ├── Program.cs                       # 服务器全部源码 (1733行)
│   ├── RemoteMessage.MiddleServer.csproj
│   └── README.md                        # 服务器详细文档
├── android_gateway/                     # Android网关应用
│   ├── app/src/main/
│   │   ├── java/com/remotemessage/gateway/
│   │   │   ├── GatewayRuntime.kt        # 核心运行时 (注册/加密/同步)
│   │   │   ├── MainActivity.kt          # 主界面
│   │   │   ├── SmsReceiver.kt           # 短信广播接收器
│   │   │   ├── GatewayLocalDb.kt        # 本地SQLite队列
│   │   │   ├── GatewayWebUiServer.kt    # 内网WebUI
│   │   │   ├── GatewaySimSupport.kt     # 多SIM卡支持
│   │   │   └── ...                      # 其他组件
│   │   └── res/                         # 资源文件 (含中英文字符串)
│   ├── build.gradle                     # 项目构建配置
│   └── app/build.gradle                 # 应用构建配置
├── .github/workflows/                   # CI/CD流水线
│   ├── flutter-client.yml               # 客户端多平台构建
│   ├── android-gateway.yml              # 网关APK构建
│   └── middle-server.yml                # 服务器发布
└── README.md                            # 本文件
```

---

## 核心功能

### Flutter客户端
- **跨平台支持**：Linux / Windows / Android / iOS (no-codesign)
- **会话管理**：会话列表、聊天窗口、搜索、置顶
- **短信收发**：查看历史短信、新建并发送短信
- **本地缓存**：SQLite存储消息、设置、置顶状态
- **智能同步**：自动轮询刷新 (5秒间隔)、增量同步、加载进度显示
- **证书管理**：设置页导入 `server-cert.cer`，HTTPS模式仅信任导入的证书
- **双卡支持**：显示并选择网关端的SIM卡槽
- **主题切换**：Material 3设计，支持亮色/暗色主题
- **国际化**：简体中文 / 英文双语
- **响应式布局**：桌面端左右分栏，移动端导航切换

### Android网关
- **短信网关**：将Android手机转变为短信网关服务器
- **实时接收**：高优先级广播接收系统短信 (优先级999)
- **加密上报**：RSA-OAEP加密后上传至服务器
- **任务轮询**：定期拉取服务器下发的发送任务
- **历史同步**：批量同步历史短信，支持断点续传 (记住上次同步时间戳)
- **队列管理**：本地SQLite持久化待上传队列，按 `messageId` 去重
- **多SIM卡**：自动识别并上报SIM卡槽信息，支持双卡设备
- **内网WebUI**：基于NanoHTTPD的局域网控制页，远程触发操作
- **权限引导**：默认短信应用申请、电池优化豁免、使用情况访问引导
- **自动重试**：后台WorkManager定期同步 (15分钟间隔)，自动补传
- **证书支持**：导入服务端自签名证书

### Middle Server
- **.NET 8 / ASP.NET Core**：现代高性能后端框架
- **自动初始化**：首次启动自动生成数据库、配置文件、证书
- **网关注册**：管理网关公钥，支持多网关
- **加密转发**：RSA-OAEP加密/解密上下行消息
- **消息去重**：自动过滤重复短信
- **会话置顶**：客户端置顶会话持久化
- **API日志**：所有接口访问记录入库
- **单文件发布**：Linux x64 / Linux ARM64 单文件可执行程序
- **内置SQLite**：原生库打包进单文件，无需额外部署
- **配置管理**：`server.conf` 控制端口和密码，旧版 `password.conf` 自动迁移

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
```

编辑 `server.conf` 修改端口和密码：
```ini
https_port=5001
password=replace-with-a-long-random-password
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
2. 打开应用，填写配置：
   - **Server Base URL**：`https://<服务器IP>:5001`
   - **Device ID**：自定义设备标识
   - **Password**：与 `server.conf` 中的密码一致
3. 导入 `server-cert.cer`
4. 点击 **Register** 注册到服务器
5. 授予短信权限，建议设置为默认短信应用

### 3. 配置Flutter客户端

客户端构建方式多样，详见下方 [构建指南](#构建指南)。

运行后：
1. 打开设置页
2. 填写：
   - **Server Base URL**：`https://<服务器IP>:5001`
   - **Device ID**：与网关一致
   - **Password**：与 `server.conf` 一致
3. 导入 `server-cert.cer`
4. 返回主页即可看到会话列表

---

## 构建指南

### 前置要求
- **Flutter客户端**：Flutter SDK (stable), Python 3 + Pillow, Java 17 (Android), Ninja + GTK (Linux)
- **Android网关**：Java 17, Gradle 8.7, Android SDK (API 34, min SDK 26)
- **Middle Server**：.NET 8.0 SDK

### Flutter客户端

CI采用动态生成Flutter项目骨架 + 注入源码的策略，手动构建同理：

```bash
# 1. 创建Flutter项目
flutter create --platforms=android,ios,linux,windows client/flutter_client_build

# 2. 添加依赖
cd client/flutter_client_build
flutter pub add path path_provider sqlite3 file_selector

# 3. 注入源码
cp ../flutter_client_source/lib/main.dart lib/main.dart

# 4. 应用图标
python ../apply_client_icons.py . ../icons

# 5. 构建目标平台
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
│  2. 用公钥加密短信内容 (RSA-OAEP)                             │
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
- **共享密码**：`X-Password` 请求头，客户端和网关必须与 `server.conf` 一致
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
| Android Gateway | SQLite | `gateway_private.db` |
| Flutter Client | SQLite | `client_private.sqlite` (应用私有目录) |

---

## 安全评审结论

**当前版本适合：** 局域网 / 家庭网络 / VPN / 内网穿透 / 反向代理后的受控环境

**不建议直接暴露公网**，原因：
1. 单一共享密码，非设备级/用户级认证
2. 缺少限流/防爆破/封禁策略
3. 缺少防重放机制 (nonce/timestamp/签名)
4. 缺少设备信任和撤销机制
5. 缺少公网级监控/告警/备份/审计

**若需上公网，建议补齐：**
- 反向代理 (Nginx/Caddy) + 正式证书
- 限流/IP访问控制
- JWT/mTLS/每设备独立凭据
- 防重放签名机制
- 数据库备份与日志监控

---

## 注意事项

1. **Android真机限制**：权限、后台保活和厂商限制会直接影响可靠性
2. **证书更新**：服务端重新生成证书后，客户端和网关需重新导入
3. **密码同步**：修改 `server.conf` 中的密码后，需同步更新三端配置
4. **首次同步**：历史短信首次同步量大时会显示进度，请耐心等待
5. **弱网环境**：客户端有自动刷新，但弱网下仍建议保留手动同步作为兜底
6. **单文件发布**：Linux下的SQLite原生库 (`libe_sqlite3.so`) 已打包进服务端单文件

---

## 技术栈

| 组件 | 技术 | 语言 | 核心依赖 |
|------|------|------|----------|
| Flutter Client | Flutter (Material 3) | Dart | sqlite3, path_provider, file_selector |
| Android Gateway | Android (Kotlin) | Kotlin | OkHttp 4.12, NanoHTTPD 2.3.1, WorkManager, AndroidX |
| Middle Server | ASP.NET Core | C# | Microsoft.Data.Sqlite 8.0.4, System.Security.Cryptography |
| CI/CD | GitHub Actions | - | Flutter Action, .NET Setup, Gradle, Java 17 |

---

## 仓库信息

- **GitHub**: https://github.com/pgs666/RemoteMessage
- **默认分支**: `main`
- **许可证**: 参见仓库LICENSE文件

如需深入了解Middle Server的实现细节，请阅读：[middle_server/README.md](middle_server/README.md)
