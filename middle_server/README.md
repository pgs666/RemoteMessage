# Middle Server (ASP.NET Core / .NET 8)

## 功能

- 提供网关注册接口（保存网关公钥）
- 提供客户端发送短信任务接口（用网关公钥加密）
- 提供网关轮询接口（网关解密后执行发送）
- 提供短信上报接口（网关用服务器公钥加密上行短信）

## 本地运行

```bash
dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

默认监听地址可用环境变量 `ASPNETCORE_URLS` 指定，例如：

```bash
ASPNETCORE_URLS=http://0.0.0.0:5000 dotnet run --project middle_server/RemoteMessage.MiddleServer.csproj
```

## 发布 Linux

```bash
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj -c Release -r linux-x64 --self-contained false -o publish/linux-x64
dotnet publish middle_server/RemoteMessage.MiddleServer.csproj -c Release -r linux-arm64 --self-contained false -o publish/linux-arm64
```
