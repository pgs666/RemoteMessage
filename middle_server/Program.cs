using System.Net;
using System.Text.Json;

var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);
var serverLogPath = Path.Combine(RuntimeLayout.RuntimeDirectory, "server.log");
const long DefaultGatewayOnlineWindowMs = 120_000;

var serverSettings = new ServerRuntimeSettings();
var httpsSettings = new HttpsCertificateSettings();
var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.SetMinimumLevel(LogLevel.Information);
builder.Logging.AddSimpleConsole(options =>
{
    options.TimestampFormat = "yyyy-MM-dd HH:mm:ss.fff ";
    options.SingleLine = true;
});
builder.Logging.AddProvider(new FileLoggerProvider(serverLogPath, serverSettings.LogMaxBytes, serverSettings.LogRetentionDays));
builder.WebHost.ConfigureKestrel(options =>
{
    options.Limits.MaxRequestBodySize = 256 * 1024;
    options.Limits.Http2.MaxStreamsPerConnection = 100;
    options.Listen(IPAddress.Any, serverSettings.HttpsPort, listen => listen.UseHttps(httpsSettings.Certificate));
});
builder.Services.AddSingleton<CryptoState>();
builder.Services.AddSingleton<GatewayRegistry>();
builder.Services.AddSingleton<SqliteRepository>();
builder.Services.AddSingleton(serverSettings);
builder.Services.AddSingleton(httpsSettings);
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.DefaultBufferSize = 16 * 1024;
});

var app = builder.Build();
var startupRepo = app.Services.GetRequiredService<SqliteRepository>();
var startupCrypto = app.Services.GetRequiredService<CryptoState>();

app.Logger.LogInformation(
    "RemoteMessage middle server starting. Runtime directory={RuntimeDirectory}; ExecutablePath={ExecutablePath}; AppContext.BaseDirectory={AppContextBaseDirectory}",
    RuntimeLayout.RuntimeDirectory,
    RuntimeLayout.ExecutablePath,
    AppContext.BaseDirectory
);
app.Logger.LogInformation("Loaded config {ServerConfPath}; HTTPS port={HttpsPort}", serverSettings.ServerConfigFilePath, serverSettings.HttpsPort);
app.Logger.LogInformation("Runtime files are created beside the executable: server.db, server.conf, server-cert.cer, server-cert.pfx, server-crypto-private.pem");
app.Logger.LogInformation("SQLite database path: {DatabaseFilePath}", startupRepo.DatabaseFilePath);
app.Logger.LogInformation("Server log path: {ServerLogPath}", serverLogPath);
app.Logger.LogInformation("Server crypto private key path: {ServerCryptoKeyPath}", startupCrypto.PrivateKeyFilePath);
app.Logger.LogInformation("Auth enabled: token-only segmented headers (X-Gateway-Token / X-Client-Token / X-Admin-Token).");
app.Logger.LogInformation(
    "Maintenance policy: every {IntervalMinutes} min; log retention {LogDays} days / {LogMaxMb} MB; api_logs {ApiLogDays} days; messages {MessageDays} days (0=keep); db max {DbMaxMb} MB.",
    serverSettings.MaintenanceIntervalMinutes,
    serverSettings.LogRetentionDays,
    serverSettings.LogMaxBytes / (1024 * 1024),
    serverSettings.ApiLogRetentionDays,
    serverSettings.MessageRetentionDays,
    serverSettings.DatabaseMaxBytes / (1024 * 1024)
);
if (serverSettings.IsFirstStart)
{
    OnboardingQrBootstrap.WriteFirstStartArtifacts(serverSettings, app.Logger);
}
app.Logger.LogWarning("Security review result: this service is suitable for LAN/VPN or reverse-proxied deployment, but it is not sufficient for direct public internet exposure without stronger auth, rate limiting, replay protection, and monitoring.");

app.Use(async (context, next) =>
{
    var repo = context.RequestServices.GetRequiredService<SqliteRepository>();
    var sec = context.RequestServices.GetRequiredService<ServerRuntimeSettings>();

    var path = context.Request.Path.Value ?? string.Empty;
    var requiresAuth = !path.Equals("/healthz", StringComparison.OrdinalIgnoreCase);

    var begin = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    if (requiresAuth)
    {
        if (!IsRequestAuthorized(context.Request, sec))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new { error = "invalid credentials" });
            repo.InsertApiLog(context.Request.Method, path, 401, context.Connection.RemoteIpAddress?.ToString() ?? "unknown", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - begin);
            return;
        }
    }

    await next();
    repo.InsertApiLog(context.Request.Method, path, context.Response.StatusCode, context.Connection.RemoteIpAddress?.ToString() ?? "unknown", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - begin);
});

app.MapGet("/healthz", () => Results.Ok(new { ok = true }));

app.MapGet("/api/crypto/server-public-key", (CryptoState crypto) =>
{
    return Results.Ok(new { publicKey = crypto.ServerPublicKeyPem });
});

app.MapPost("/api/gateway/register", (RegisterGatewayRequest req, GatewayRegistry registry, SqliteRepository repo) =>
{
    if (ApiSupport.ValidateRegisterGatewayRequest(req) is { } error)
    {
        return error;
    }

    registry.Upsert(req.DeviceId, req.PublicKeyPem);
    repo.UpsertGateway(req.DeviceId, req.PublicKeyPem);
    return Results.Ok(new { ok = true, req.DeviceId });
});

app.MapPost("/api/gateway/sim-state", (UpsertGatewaySimStateRequest req, SqliteRepository repo) =>
{
    if (ApiSupport.ValidateGatewaySimStateRequest(req) is { } error)
    {
        return error;
    }

    repo.ReplaceGatewaySimProfiles(req.DeviceId, req.Profiles);
    repo.TouchGatewayLastSeen(req.DeviceId);
    return Results.Ok(new { ok = true, count = req.Profiles.Count });
});

app.MapPost("/api/gateway/sms/upload", (UploadSmsRequest req, CryptoState crypto, SqliteRepository repo, ILogger<Program> logger) =>
{
    if (ApiSupport.ValidateUploadSmsRequest(req) is { } error)
    {
        return error;
    }

    repo.TouchGatewayLastSeen(req.DeviceId);

    try
    {
        var plain = crypto.DecryptWithServerPrivateKey(req.EncryptedPayloadBase64);
        var payload = JsonSerializer.Deserialize<GatewaySmsPayload>(plain, jsonOptions);
        plain = string.Empty;
        if (payload is null)
        {
            return Results.BadRequest("invalid payload");
        }

        if (ApiSupport.ValidateGatewayPayload(payload) is { } payloadError)
        {
            return payloadError;
        }

        var normalizedDirection = ApiSupport.NormalizeDirection(payload.Direction);
        var normalizedSimSlot = ApiSupport.NormalizeSimSlotIndex(payload.SimSlotIndex);
        var normalizedSimPhone = ApiSupport.NormalizeOptionalText(payload.SimPhoneNumber, 64);
        var normalizedSimCount = ApiSupport.NormalizeSimCount(payload.SimCount);
        var uploadedSimProfile = repo.ResolveGatewaySimProfile(req.DeviceId, normalizedSimSlot);

        var normalized = new SmsPayload(
            Id: string.IsNullOrWhiteSpace(payload.MessageId)
                ? MessageIdentity.Build(req.DeviceId, payload.Phone, payload.Content, payload.Timestamp, normalizedDirection, normalizedSimSlot)
                : payload.MessageId!,
            DeviceId: req.DeviceId,
            Phone: payload.Phone,
            Content: payload.Content,
            Timestamp: payload.Timestamp,
            Direction: normalizedDirection,
            SimSlotIndex: normalizedSimSlot ?? uploadedSimProfile?.SlotIndex,
            SimPhoneNumber: normalizedSimPhone ?? uploadedSimProfile?.PhoneNumber,
            SimCount: normalizedSimCount ?? uploadedSimProfile?.SimCount
        );

        var isNew = repo.InsertMessageIfNotExists(normalized);
        return Results.Ok(new { ok = true, deduplicated = !isNew, messageId = normalized.Id });
    }
    catch (Exception ex)
    {
        logger.LogWarning(ex, "Failed to decrypt or store gateway upload for device {DeviceId}", req.DeviceId);
        return Results.BadRequest(new { error = "invalid encrypted payload" });
    }
});

app.MapGet("/api/client/inbox", (long? sinceTs, int? limit, string? phone, SqliteRepository repo) =>
{
    if (!string.IsNullOrWhiteSpace(phone) && !ApiSupport.IsValidPhone(phone))
    {
        return Results.BadRequest("phone invalid");
    }

    var list = repo.QueryMessages(sinceTs, limit ?? 5000, phone);
    return Results.Ok(list);
});

app.MapGet("/api/client/gateways", (int? limit, long? onlineWindowMs, SqliteRepository repo) =>
{
    var normalizedWindowMs = Math.Clamp(onlineWindowMs ?? DefaultGatewayOnlineWindowMs, 5_000, 86_400_000);
    var list = repo.ListGateways(limit ?? 200, normalizedWindowMs);
    return Results.Ok(list);
});

app.MapGet("/api/client/gateways/{deviceId}/online", (string deviceId, long? onlineWindowMs, SqliteRepository repo) =>
{
    if (string.IsNullOrWhiteSpace(deviceId) || deviceId.Length > 128)
    {
        return Results.BadRequest("deviceId required");
    }

    var normalizedWindowMs = Math.Clamp(onlineWindowMs ?? DefaultGatewayOnlineWindowMs, 5_000, 86_400_000);
    var status = repo.GetGatewayOnlineStatus(deviceId, normalizedWindowMs);
    return status is null
        ? Results.NotFound("gateway not found")
        : Results.Ok(status);
});

app.MapGet("/api/client/device-sims", (string deviceId, SqliteRepository repo) =>
{
    if (string.IsNullOrWhiteSpace(deviceId) || deviceId.Length > 128)
    {
        return Results.BadRequest("deviceId required");
    }

    return Results.Ok(repo.GetGatewaySimProfiles(deviceId));
});

app.MapPost("/api/client/conversations/pin", (PinConversationRequest req, SqliteRepository repo) =>
{
    if (ApiSupport.ValidatePinRequest(req) is { } error)
    {
        return error;
    }

    repo.SetPinned(req.Phone, req.Pinned);
    return Results.Ok(new { ok = true });
});

app.MapGet("/api/client/conversations/pins", (SqliteRepository repo) =>
{
    return Results.Ok(repo.GetPinnedPhones());
});

app.MapPost("/api/client/send", (SendSmsRequest req, GatewayRegistry registry, SqliteRepository repo) =>
{
    if (ApiSupport.ValidateSendRequest(req) is { } error)
    {
        return error;
    }

    if (!registry.TryGetPublicKey(req.DeviceId, out var pem) || string.IsNullOrWhiteSpace(pem))
    {
        pem = repo.GetGatewayPublicKey(req.DeviceId);
        if (string.IsNullOrWhiteSpace(pem))
        {
            return Results.NotFound("gateway not registered");
        }

        registry.Upsert(req.DeviceId, pem);
    }

    var gatewaySims = repo.GetGatewaySimProfiles(req.DeviceId);
    GatewaySimProfileRecord? selectedSim = null;
    if (req.SimSlotIndex.HasValue)
    {
        selectedSim = gatewaySims.FirstOrDefault(x => x.SlotIndex == req.SimSlotIndex.Value);
        if (gatewaySims.Count > 0 && selectedSim is null)
        {
            return Results.BadRequest("simSlotIndex invalid");
        }
    }
    else if (gatewaySims.Count > 0)
    {
        selectedSim = gatewaySims[0];
    }

    var outboundSimSlot = selectedSim?.SlotIndex ?? ApiSupport.NormalizeSimSlotIndex(req.SimSlotIndex);
    var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    var outbound = new SmsPayload(
        Id: MessageIdentity.Build(req.DeviceId, req.TargetPhone, req.Content, now, "outbound", outboundSimSlot),
        DeviceId: req.DeviceId,
        Phone: req.TargetPhone,
        Content: req.Content,
        Timestamp: now,
        Direction: "outbound",
        SimSlotIndex: outboundSimSlot,
        SimPhoneNumber: selectedSim?.PhoneNumber,
        SimCount: selectedSim?.SimCount ?? gatewaySims.Select(x => (int?)x.SimCount).DefaultIfEmpty().Max(),
        SendStatus: "queued",
        UpdatedAt: now
    );
    var instruction = new OutboundInstruction(outbound.Id, req.TargetPhone, req.Content, outboundSimSlot);
    var plain = JsonSerializer.Serialize(instruction, jsonOptions);
    var encrypted = ApiSupport.EncryptByPublicKey(plain, pem);

    repo.EnqueueOutbound(req.DeviceId, encrypted);
    repo.InsertMessageIfNotExists(outbound);

    return Results.Ok(new { ok = true, message = outbound });
});

app.MapGet("/api/gateway/pull", (string deviceId, SqliteRepository repo) =>
{
    if (string.IsNullOrWhiteSpace(deviceId) || deviceId.Length > 128)
    {
        return Results.BadRequest("deviceId required");
    }

    repo.TouchGatewayLastSeen(deviceId);
    var found = repo.LeaseNextOutbound(deviceId);
    if (found is null)
    {
        return Results.NoContent();
    }

    return Results.Ok(found);
});

app.MapPost("/api/gateway/pull/ack", (AckOutboundRequest req, SqliteRepository repo) =>
{
    if (ApiSupport.ValidateAckOutboundRequest(req) is { } error)
    {
        return error;
    }

    repo.TouchGatewayLastSeen(req.DeviceId);
    var acked = repo.AckOutbound(req.DeviceId, req.OutboxId, req.AckToken);
    return acked
        ? Results.Ok(new { ok = true })
        : Results.NotFound(new { ok = false, error = "pending outbound not found" });
});

app.MapPost("/api/gateway/outbound-status", (OutboundStatusUpdateRequest req, SqliteRepository repo) =>
{
    if (ApiSupport.ValidateOutboundStatusRequest(req) is { } error)
    {
        return error;
    }

    repo.TouchGatewayLastSeen(req.DeviceId);
    var status = ApiSupport.NormalizeSendStatus(req.Status);
    if (status is null)
    {
        return Results.BadRequest("status invalid");
    }

    var normalized = req with
    {
        Status = status,
        SimSlotIndex = ApiSupport.NormalizeSimSlotIndex(req.SimSlotIndex),
        SimPhoneNumber = ApiSupport.NormalizeOptionalText(req.SimPhoneNumber, 64),
        SimCount = ApiSupport.NormalizeSimCount(req.SimCount),
        ErrorMessage = ApiSupport.NormalizeOptionalText(req.ErrorMessage, 512),
        Timestamp = req.Timestamp > 0 ? req.Timestamp : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
    };

    var updated = repo.UpsertOutboundStatus(normalized);
    return Results.Ok(new { ok = true, updated });
});

app.MapPost("/api/admin/clear-server-data", (ClearServerDataRequest req, SqliteRepository repo, ILogger<Program> logger) =>
{
    if (ApiSupport.ValidateClearServerDataRequest(req) is { } error)
    {
        return error;
    }

    var result = repo.ClearServerData();
    logger.LogWarning(
        "Server data cleared via admin API. Messages={MessagesCleared}, Outbox={OutboxCleared}, Pinned={PinnedConversationsCleared}, SimProfiles={GatewaySimProfilesCleared}, ApiLogs={ApiLogsCleared}",
        result.MessagesCleared,
        result.OutboxCleared,
        result.PinnedConversationsCleared,
        result.GatewaySimProfilesCleared,
        result.ApiLogsCleared
    );
    return Results.Ok(new { ok = true, result });
});

var maintenanceCancellation = new CancellationTokenSource();
app.Lifetime.ApplicationStopping.Register(() => maintenanceCancellation.Cancel());
_ = Task.Run(() => RunMaintenanceLoopAsync(app, serverSettings, maintenanceCancellation.Token));

app.Run();

static bool IsRequestAuthorized(HttpRequest request, ServerRuntimeSettings settings)
{
    static bool HeaderMatches(Microsoft.AspNetCore.Http.IHeaderDictionary headers, string headerName, string expected)
    {
        var provided = headers[headerName].ToString();
        return ApiSupport.PasswordMatches(provided, expected);
    }

    var path = request.Path.Value ?? string.Empty;
    var headers = request.Headers;

    if (path.StartsWith("/api/gateway/", StringComparison.OrdinalIgnoreCase))
    {
        return HeaderMatches(headers, "X-Gateway-Token", settings.GatewayToken);
    }

    if (path.StartsWith("/api/client/", StringComparison.OrdinalIgnoreCase))
    {
        return HeaderMatches(headers, "X-Client-Token", settings.ClientToken);
    }

    if (path.StartsWith("/api/admin/", StringComparison.OrdinalIgnoreCase))
    {
        return HeaderMatches(headers, "X-Admin-Token", settings.AdminToken);
    }

    if (path.StartsWith("/api/crypto/", StringComparison.OrdinalIgnoreCase))
    {
        return HeaderMatches(headers, "X-Gateway-Token", settings.GatewayToken)
            || HeaderMatches(headers, "X-Client-Token", settings.ClientToken)
            || HeaderMatches(headers, "X-Admin-Token", settings.AdminToken);
    }

    return false;
}

static async Task RunMaintenanceLoopAsync(WebApplication app, ServerRuntimeSettings settings, CancellationToken cancellationToken)
{
    var interval = TimeSpan.FromMinutes(Math.Clamp(settings.MaintenanceIntervalMinutes, 5, 1440));

    void RunOnce()
    {
        try
        {
            using var scope = app.Services.CreateScope();
            var repo = scope.ServiceProvider.GetRequiredService<SqliteRepository>();
            var result = repo.RunMaintenance(settings);
            if (result.HasChanges)
            {
                app.Logger.LogInformation(
                    "Maintenance cleaned: apiLogs={ApiLogsDeleted}, messages={MessagesDeleted}, outbox={OutboxDeleted}, orphanPins={OrphanPinsDeleted}, dbVacuumed={DbVacuumed}, dbBytes={DatabaseBytes}",
                    result.ApiLogsDeleted,
                    result.MessagesDeleted,
                    result.OutboxDeleted,
                    result.OrphanPinsDeleted,
                    result.DatabaseVacuumed,
                    result.DatabaseBytes
                );
            }
        }
        catch (Exception ex)
        {
            app.Logger.LogWarning(ex, "Maintenance loop failed");
        }
    }

    RunOnce();

    using var timer = new PeriodicTimer(interval);
    try
    {
        while (await timer.WaitForNextTickAsync(cancellationToken))
        {
            RunOnce();
        }
    }
    catch (OperationCanceledException)
    {
    }
}
