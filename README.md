<p align="center">
  <img src="https://raw.githubusercontent.com/pgs666/RemoteMessage/main/client/icons/Icon12-iOS-Default-1024x1024%401x.png" alt="RemoteMessage icon" width="160" />
</p>

# RemoteMessage

RemoteMessage 是一个完整的三端协作远程短信系统，允许你通过 Android 手机作为网关，在任何设备上收发短信。

## 系统架构

```
┌─────────────────┐      HTTPS/RSA-OAEP      ┌─────────────────┐      HTTPS/RSA-OAEP      ┌─────────────────┐
│  Flutter Client │ ◄──────────────────────► │  Middle Server  │ ◄──────────────────────► │ Android Gateway │
│  (任意设备)      │                          │    (Rust)       │                          │  (安卓手机)      │
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
├── middle_server_rust/                  # 中间服务器 (Rust)
│   ├── Cargo.toml                       # Rust crate 配置
│   ├── Cargo.lock                       # 锁定依赖版本
│   ├── README.md                        # 服务器详细文档
│   └── src/
│       ├── main.rs                      # 应用入口 & HTTPS 服务启动
│       ├── api.rs                       # API 路由/验证/响应
│       ├── repository.rs                # SQLite 数据访问层
│       ├── crypto.rs                    # RSA-OAEP-SHA256 加解密
│       ├── certificate.rs               # 自签证书生成与加载
│       ├── config.rs                    # 运行时配置 (令牌/端口/保留策略)
│       ├── onboarding.rs                # 首次启动 QR 码生成
│       ├── models.rs                    # API 请求/响应 DTO
│       ├── registry.rs                  # 网关公钥注册表
│       ├── logger.rs                    # 文件日志
│       └── runtime.rs                   # 运行时目录布局
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
- **证书管理**：设置页导入 `server-cert.cer` 根证书，HTTPS模式仅信任导入的证书
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
- **证书支持**：导入服务端根证书
- **QR码扫描**：使用ZXing库扫描入网QR码
- **前台服务**：保持网关应用在后台运行
- **日志查看**：内置调试日志和活动日志查看器

### Middle Server
- **Rust / Axum / Tokio**：现代高性能异步后端
- **自动初始化**：首次启动自动生成数据库、配置文件、证书、QR码
- **网关注册**：管理网关公钥，支持多网关
- **加密转发**：RSA-OAEP加密/解密上下行消息
- **消息去重**：自动过滤重复短信
- **会话置顶**：客户端置顶会话持久化
- **API日志**：所有接口访问记录入库
- **Release 二进制**：Linux x64 / Linux ARM64 / Windows x64 / Windows ARM64 可执行程序
- **内置SQLite**：原生库打包进单文件，无需额外部署
- **令牌鉴权**：分段令牌机制 (X-Gateway-Token / X-Client-Token / X-Admin-Token)
- **维护策略**：可配置的日志轮转、数据保留、数据库大小限制
- **QR码生成**：首次启动自动生成入网QR码，方便客户端和网关快速配置

---

## 使用教程（预编译产物）

本教程指导你如何下载并使用预编译产物，无需编译源码。

### 前置准备

1. **网络环境**：确保三端在同一局域网或可通过网络互访
2. **服务器 IP**：确定 Middle Server 所在设备的局域网 IP 地址（例如 `192.168.1.100`）
3. **下载预编译产物**：从 GitHub Release 页面下载

---

### 第一步：部署 Middle Server

#### 1.1 下载服务端程序

从 [GitHub Releases](https://github.com/pgs666/RemoteMessage/releases) 下载对应平台的单文件可执行程序：

- **Linux x64**：`RemoteMessageServer-linux-x64`
- **Linux ARM64**（树莓派等）：`RemoteMessageServer-linux-arm64`
- **Windows x64**：`RemoteMessageServer-windows-x64`
- **Windows ARM64**：`RemoteMessageServer-windows-arm64.exe`

#### 1.2 解压并运行

**Linux:**
```bash
# 添加执行权限
chmod +x RemoteMessageServer-linux-x64

# 运行
./RemoteMessageServer-linux-x64
```

**Windows:**
```cmd
REM 解压 ZIP 文件后，双击运行 RemoteMessageServer-windows-x64.exe
```

#### 1.3 首次启动自动生成的文件

首次运行后，会在程序同目录自动生成：

```
server.db                    # SQLite 数据库（自动创建表结构）
server.conf                  # 配置文件（包含端口、admin token 和保留策略）
server-cert.cer              # HTTPS 根证书（需导入到客户端和网关）
server-cert.pem              # HTTPS 服务端证书
server-key.pem               # HTTPS 服务端私钥
server-crypto-private.pem    # RSA 私钥（用于解密短信）
onboarding-client-<id>.txt   # 客户端入网 QR 码内容
onboarding-gateway-<id>.txt  # 网关入网 QR 码内容
server.log                   # 运行日志文件
```

#### 1.4 查看配置信息

打开 `server.conf` 查看服务端配置：

```ini
https_port=5001
admin_token=<自动生成的24字节Base64字符串>
log_retention_days=14
log_max_mb=32
api_log_retention_days=30
message_retention_days=0
db_max_mb=512
maintenance_interval_minutes=60
```

**重要**：复制并保存 `admin_token`。客户端和网关 token 只会在创建凭据时写入 onboarding 文件或打印到终端，请保存对应的 `onboarding-client-<id>.txt` / `onboarding-gateway-<id>.txt`。

#### 1.5 获取入网 QR 码

查看 `onboarding-client-<id>.txt` 或 `onboarding-gateway-<id>.txt` 文件，内容类似：

```
{"format":"RMS2","role":"client|gateway","serverBaseUrl":"https://192.168.1.100:5001","clientToken|gatewayToken":"..."}
```

你可以：
- **方式1**：使用在线 QR 码生成器（如 https://www.qr-code-generator.com/），将此文本生成 QR 码图片
- **方式2**：使用手机扫描 onboarding 文件中的 ASCII QR 码
- **方式3**：直接手动复制其中的地址和令牌

#### 1.6 保持服务器运行

- **前台运行**（调试用）：直接运行程序即可
- **后台运行**（生产环境）：
  ```bash
  # Linux 使用 nohup
  nohup ./RemoteMessageServer-linux-x64 > /dev/null 2>&1 &
  
  # 或使用 systemd 服务（推荐）
  sudo systemctl enable remotemessage
  sudo systemctl start remotemessage
  ```

**验证服务器运行**：打开浏览器访问 `https://localhost:5001/healthz`，应看到 `{"ok":true}`。

---

### 第二步：安装并配置 Android 网关

#### 2.1 下载网关 APK

从 [GitHub Releases](https://github.com/pgs666/RemoteMessage/releases) 下载：

- **网关 APK**：`RemoteMessageGateway-android.apk`

#### 2.2 安装到 Android 手机

**方式1：USB 安装**
```bash
# 启用手机 USB 调试，连接电脑
adb install RemoteMessageGateway-android.apk
```

**方式2：直接传输**
- 将 APK 文件传输到手机
- 在手机上点击 APK 文件安装（需允许"未知来源应用"）

#### 2.3 首次启动配置

1. **打开应用**，你会看到配置界面

2. **选择配置方式**：

   **方式A：扫描 QR 码（推荐）**
   - 点击 **"Scan QR"** 按钮
   - 扫描服务器生成的 `onboarding-gateway-<id>.txt` 中的 QR 码
   - 自动填充服务器地址和网关令牌

   **方式B：手动填写**
   - **Server Base URL**：`https://<服务器IP>:5001`
     - 例如：`https://192.168.1.100:5001`
   - **Device ID**：自定义设备标识，例如 `my-android-phone`
   - **Gateway Token**：从 `onboarding-gateway-<id>.txt` 复制 `gatewayToken` 的值，或运行服务端时使用 `--new-gateway` 新建

3. **导入服务器证书**
   - 点击 **"Import Certificate"** 按钮
   - 选择从服务器目录复制过来的 `server-cert.cer` 文件
   - 提示导入成功后继续

4. **注册到服务器**
   - 点击 **"Register"** 按钮
   - 等待提示注册成功

5. **授予权限**
   - 应用会请求短信权限，点击 **"允许"**
   - **强烈建议**：设置为默认短信应用，不然会导致短信发送功能异常
     - 点击 **"Set as Default SMS"** 按钮
     - 在系统弹窗中确认
   - **可选但推荐**：忽略电池优化
     - 点击 **"Ignore Battery Optimization"** 按钮

6. **启动前台服务**
   - 点击 **"Start Foreground Service"** 按钮
   - 通知栏会显示持续运行的通知，确保后台同步不被杀死

#### 2.4 验证网关工作

- 查看应用界面状态，应显示 **"Registered"** 和 **"Online"**
- 打开手机自带短信应用，发送一条测试短信到你的手机
- 返回网关应用，应看到短信已拦截并上传成功

#### 2.5 使用内网 WebUI（可选）

网关内置局域网 Web 控制面板：

1. 在电脑浏览器访问：`http://<手机IP>:8088`
   - 例如：`http://192.168.1.101:8088`
2. 页面上显示：
   - 服务器地址、设备 ID
   - SIM 卡信息（卡槽、号码）
   - 操作按钮（注册、轮询、同步历史短信等）

#### 2.6 同步历史短信（可选）

如需将手机已有的历史短信同步到服务器：

1. 在网关应用中点击 **"Sync Historical SMS"**
2. 等待同步进度条完成
3. 同步完成后，历史短信会在客户端显示

---

### 第三步：安装并配置 Flutter 客户端

根据你的设备平台选择对应的客户端：

#### 3.1 下载客户端

从 [GitHub Releases](https://github.com/pgs666/RemoteMessage/releases) 下载：

| 平台 | 文件 | 说明 |
|------|------|------|
| **Windows** | `flutter-client-windows.zip` | 解压后运行 `RemoteMessage.exe` |
| **Windows (安装包)** | `flutter-client-windows-setup.exe` | Inno Setup 安装包 |
| **Linux (tar.gz)** | `flutter-client-linux.tar.gz` | 解压后运行 `RemoteMessage` |
| **Linux (deb)** | `flutter-client-linux.deb` | Debian/Ubuntu 安装包 |
| **Linux (rpm)** | `flutter-client-linux.rpm` | Fedora/CentOS 安装包 |
| **Linux (AppImage)** | `flutter-client-linux.AppImage` | 直接运行 |
| **Android** | `flutter-client-android.apk` | 安装到手机 |
| **iOS** | `flutter-client-ios.ipa` | 需侧载（未签名） |

#### 3.2 安装客户端

**Windows:**
- 方式1：双击 `flutter-client-windows-setup.exe` 按向导安装
- 方式2：解压 ZIP 后双击运行 `RemoteMessage.exe`

**Linux:**
```bash
# 方式1：deb 包（Ubuntu/Debian）
sudo dpkg -i flutter-client-linux.deb

# 方式2：tar.gz
tar -xzf flutter-client-linux.tar.gz
cd flutter-client-linux
./RemoteMessage

# 方式3：AppImage
chmod +x flutter-client-linux.AppImage
./flutter-client-linux.AppImage
```

**macOS:**
```bash
# 解压后拖入 Applications
unzip flutter-client-macos.zip
# 或双击运行
```

**Android:**
```bash
adb install flutter-client-android.apk
```

#### 3.3 首次启动配置

1. **打开应用**，进入主界面

2. **打开设置页**：
   - 点击左上角菜单按钮（三条横线图标）
   - 选择 **"Settings"**

3. **选择配置方式**：

   **方式A：扫描 QR 码（推荐）**
   - 在设置页点击 **"Scan Onboarding QR"**
   - 扫描服务器生成的 `onboarding-client-<id>.txt` 中的 QR 码
   - 自动填充服务器地址和客户端令牌

   **方式B：手动填写**
   - 点击 **"Server Settings"** 区域
   - **Server Base URL**：`https://<服务器IP>:5001`
   - **Client Token**：从 `onboarding-client-<id>.txt` 复制 `clientToken` 的值，或运行服务端时使用 `--new-client` 新建
   - **Device ID**：与网关保持一致（例如 `my-android-phone`）

4. **导入服务器根证书**（HTTPS 自签名根证书）
   - 在设置页点击 **"Import Server Certificate"**
   - 选择从服务器目录复制过来的 `server-cert.cer` 文件
   - 提示导入成功后继续

5. **保存设置**
   - 点击 **"Save"** 按钮
   - 返回主页面

#### 3.4 验证客户端工作

1. **查看会话列表**
   - 主页应显示从网关同步过来的短信会话
   - 每个会话显示对方号码、最后一条消息、时间

2. **查看短信详情**
   - 点击任意会话进入聊天视图
   - 显示该号码的所有历史短信

3. **发送测试短信**
   - 点击 **"Compose"** 按钮（铅笔图标）
   - 输入对方号码和短信内容
   - 如果网关是多卡设备，可选择 SIM 卡槽
   - 点击发送

4. **验证自动刷新**
   - 客户端默认每 20 秒自动同步一次
   - 等待新短信自动出现，或下拉手动刷新

#### 3.5 高级功能使用

**置顶会话：**
- 在会话列表长按某个会话
- 选择 **"Pin"** 将其置顶

**搜索会话：**
- 在主页顶部搜索框输入关键词
- 支持搜索号码或短信内容

**联系人集成（Android）：**
- 授予联系人权限后，会话列表会显示联系人姓名而非号码

**主题切换：**
- 设置页可选择亮色/暗色/跟随系统主题

**Android 启动器图标：**
- 设置页可切换默认/亮色/暗色三种图标模式

**多 Profile 管理：**
- 设置页可添加多个服务器配置
- 在不同服务器之间快速切换

---

### 第四步：完整工作流程验证

#### 4.1 接收短信测试

1. 让其他人给你的 Android 网关手机发短信
2. 等待约 20 秒（客户端自动刷新间隔）
3. 在 Flutter 客户端查看是否收到短信
4. 或下拉手动刷新立即查看

#### 4.2 发送短信测试

1. 在 Flutter 客户端点击 **"Compose"**
2. 输入号码和内容并发送
3. 查看 Android 网关手机的已发送短信
4. 确认对方收到短信

#### 4.3 历史短信同步

1. 在网关应用中点击 **"Sync History"**
2. 等待同步完成
3. 在客户端查看历史短信是否出现

---

### 常见问题排查

#### Q1: 客户端连接失败，提示 TLS 错误

**原因**：未导入服务端根证书

**解决**：
1. 从服务器目录复制 `server-cert.cer` 到客户端设备
2. 在客户端设置页点击 **"Import Server Certificate"**
3. 选择该证书文件

#### Q2: 网关注册失败

**可能原因**：
- 服务器地址填写错误
- 网关令牌不正确
- 网络不通

**排查步骤**：
1. 确认 `onboarding-gateway-<id>.txt` 中的 `gatewayToken` 与网关填写的一致
2. 在网关手机浏览器访问 `https://<服务器IP>:5001/healthz`，确认可达
3. 查看服务器日志 `server.log` 中的错误信息

#### Q3: 客户端看不到短信

**可能原因**：
- 网关未成功注册
- 网关未上传短信
- 客户端令牌不正确

**排查步骤**：
1. 检查网关应用状态，确认显示 **"Registered"** 和 **"Online"**
2. 在网关应用点击 **"Poll & Send"** 手动触发一次轮询
3. 检查客户端设置中的 client token 与 `onboarding-client-<id>.txt` 一致
4. 在客户端设置页点击 **"Sync Now"** 手动同步

#### Q4: Android 网关后台被杀死

**解决方案**：
1. 在网关应用中点击 **"Start Foreground Service"**
2. 忽略电池优化（设置页按钮）
3. 在手机设置中将应用设为"不受限制"的后台运行
4. 不同手机厂商可能有额外限制，请参考对应品牌的后台保活设置

#### Q5: 修改了 server.conf 后客户端/网关连不上

**原因**：修改配置后未重启服务器

**解决**：
1. 停止当前运行的服务器进程
2. 重新启动服务器
3. 如果修改了端口或令牌，需同步更新客户端和网关的配置

---

## 快速开始

### 1. 启动Middle Server

```bash
cargo run --release --manifest-path middle_server_rust/Cargo.toml
```

首次启动后会在可执行文件同目录自动生成：
```
server.db              # SQLite数据库
server.conf            # 配置文件
server-cert.cer        # 客户端/网关注入的根证书
server-cert.pem        # HTTPS 服务端证书
server-key.pem         # HTTPS 服务端私钥
server-crypto-private.pem  # 服务器RSA私钥
onboarding-client-<id>.txt   # 客户端入网QR码内容
onboarding-gateway-<id>.txt  # 网关入网QR码内容
```

编辑 `server.conf` 修改端口、admin token 和保留策略：
```ini
https_port=5001
admin_token=replace-with-a-long-random-string
# 客户端/网关 token 通过首次启动生成的 onboarding 文件或 --new-client / --new-gateway 创建
```

**发布为单文件 (推荐生产环境)：**
```bash
cargo build --release --manifest-path middle_server_rust/Cargo.toml
# 输出：middle_server_rust/target/release/remote_message_middle_server
```

### 2. 配置Android网关

1. 构建并安装APK到手机：
   ```bash
   gradle -p android_gateway :app:assembleDebug
   ```
2. 打开应用，选择以下任一方式配置：
   - **扫描QR码**：扫描服务端生成的 `onboarding-gateway-<id>.txt` 中的QR码
   - **手动填写**：
     - **Server Base URL**：`https://<服务器IP>:5001`
     - **Gateway Token**：与 `onboarding-gateway-<id>.txt` 中的 `gatewayToken` 一致
3. 导入 `server-cert.cer`
4. 点击 **Register** 注册到服务器
5. 授予短信权限，建议设置为默认短信应用

### 3. 配置Flutter客户端

客户端构建方式多样，详见下方 [构建指南](#构建指南)。

运行后：
1. 打开设置页，选择以下任一方式配置：
   - **扫描QR码**：扫描服务端生成的 `onboarding-client-<id>.txt`
   - **手动填写**：
     - **Server Base URL**：`https://<服务器IP>:5001`
     - **Client Token**：与 `onboarding-client-<id>.txt` 中的 `clientToken` 一致
2. 导入 `server-cert.cer` (HTTPS 根证书)
3. 返回主页即可看到会话列表

---

## 构建指南

### 前置要求
- **Flutter客户端**：Flutter SDK (stable), Python 3 + Pillow, Java 17 (Android), Ninja + GTK (Linux)
- **Android网关**：Java 17, Gradle 8.7, Android SDK (API 34, min SDK 23)
- **Middle Server**：Rust stable toolchain

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

# 5. 配置桌面版额外资源（Linux / Windows / macOS 字体）
python ../configure_client_desktop_support.py .

# 6. 应用图标
python ../apply_client_icons.py . ../icons

# 7. 构建目标平台
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
cargo run --release --manifest-path middle_server_rust/Cargo.toml

# 发布 Release 二进制
cargo build --release --manifest-path middle_server_rust/Cargo.toml
```

---

## CI/CD流水线

本项目通过GitHub Actions实现自动化构建：

| Workflow | 触发条件 | 构建产物 |
|----------|----------|----------|
| **flutter-client.yml** | push / PR | Linux / Windows / Android (signed APK) / iOS (no-codesign app + unsigned IPA) |
| **android-gateway.yml** | push / PR | Android Debug APK |
| **middle-server.yml** | push / PR | Linux x64 / Linux ARM64 / Windows x64 / Windows ARM64 可执行程序 |

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
- 服务端根证书和 TLS 证书，首次启动自动生成
- 客户端/网关手动导入 `.cer` 根证书
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
6. **Release 二进制**：Rust 服务端使用 `rusqlite` bundled SQLite，发布时无需单独准备 SQLite 动态库
7. **QR码入网**：推荐使用QR码快速配置，避免手动输入错误
8. **数据库维护**：服务端会自动清理过期数据，无需手动干预

---

## 技术栈

| 组件 | 技术 | 语言 | 核心依赖 |
|------|------|------|----------|
| Flutter Client | Flutter (Material 3) | Dart | sqlite3, path_provider, file_selector, flutter_secure_storage, flutter_contacts, image_picker |
| Android Gateway | Android (Kotlin) | Kotlin | OkHttp 4.12, NanoHTTPD 2.3.1, WorkManager, AndroidX, ZXing 3.5.3 |
| Middle Server | Axum + Tokio | Rust | rusqlite, rustls, rsa, qrcode |
| CI/CD | GitHub Actions | - | Flutter Action, Rust toolchain, Gradle, Java 17 |
| 工具脚本 | Python 3 | Python | Pillow (图标生成), plistlib (iOS配置) |

---

## 包名与应用标识

| 组件 | 包名/命名空间 | 应用ID |
|------|--------------|--------|
| Android Gateway | `cn.ac.studio.rmg` | `cn.ac.studio.rmg` |
| Flutter Client (Android) | `cn.ac.studio.rmc` | `cn.ac.studio.rmc` |
| Middle Server | `remote_message_middle_server` | N/A |

---

## 仓库信息

- **GitHub**: https://github.com/pgs666/RemoteMessage
- **默认分支**: `main`

如需深入了解Middle Server的实现细节，请阅读：[middle_server_rust/README.md](middle_server_rust/README.md)
