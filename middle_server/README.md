# Middle Server (ASP.NET Core / .NET 8)

## 功能

- 提供网关注册接口（保存网关公钥）
- 提供客户端发送短信任务接口（用网关公钥加密）
- 提供网关轮询接口（网关解密后执行发送）
- 提供短信上报接口（网关用服务器公钥加密上行短信）
- 启动时自动生成并启用 HTTPS 自签名证书
- 在可执行文件同目录保存 `server.db` / `password.conf` / `server-cert.cer` / `server-cert.pfx`

## 本地运行

```bash
dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

默认监听 HTTPS `5001` 端口，可通过环境变量 `REMOTE_MESSAGE_HTTPS_PORT` 指定，例如：

```bash
REMOTE_MESSAGE_HTTPS_PORT=5443 dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

首次运行后，产物目录 / 运行目录会生成：

```text
server.db
password.conf
server-cert.cer
server-cert.pfx
```

- `password.conf`：客户端和网关都要使用相同密码，通过 `X-Password` 传递
- `server-cert.cer`：给 Flutter 客户端与 Android 网关导入信任
- `server-cert.pfx`：服务端自身加载使用

## 发布 Linux

```bash
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj -c Release -r linux-x64 --self-contained true -p:PublishSingleFile=true -o publish/linux-x64
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj -c Release -r linux-arm64 --self-contained true -p:PublishSingleFile=true -o publish/linux-arm64
```

发布后的可执行文件首次启动时，同样会在其所在目录生成数据库、密码文件和 HTTPS 证书文件。
