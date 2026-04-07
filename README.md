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

---

## 本地初始化 Git 与推送到 GitHub

> 由于当前环境无法直接使用你的 GitHub 账号创建远程仓库，请在本地执行以下命令：

```bash
git init
git add .
git commit -m "feat: bootstrap RemoteMessage mono-repo with 3 projects and CI"
git branch -M main
git remote add origin https://github.com/<你的用户名>/RemoteMessage.git
git push -u origin main
```

如果你安装并登录了 GitHub CLI，也可直接创建仓库：

```bash
gh repo create RemoteMessage --public --source . --remote origin --push
```

---

## GitHub Actions

- `flutter-client.yml`
  - 在 CI 中动态生成 Flutter 工程并覆盖 `lib/main.dart`
  - 构建：Linux / Windows / Android APK / iOS(no-codesign)
- `android-gateway.yml`
  - 构建原生 Android 网关 APK
- `middle-server.yml`
  - `dotnet publish` 输出 Linux x64 与 Linux ARM64 产物

---

## 注意事项

1. Android 真机短信权限和后台保活策略会影响收发可靠性。
2. iOS 构建在 CI 中使用 `--no-codesign`，仅用于验证编译通过。
3. 当前服务端使用内存队列，生产环境建议替换为 Redis / MQ + 数据库存储。
