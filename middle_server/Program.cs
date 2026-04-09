using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Linq;
using Microsoft.Data.Sqlite;

var jsonOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web);
var serverLogPath = Path.Combine(RuntimeLayout.RuntimeDirectory, "server.log");

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
builder.Logging.AddProvider(new FileLoggerProvider(serverLogPath));
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
if (serverSettings.Password.Length < 16)
{
    app.Logger.LogWarning("Configured password is shorter than 16 characters. Use a long random password before any internet exposure.");
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
        var password = context.Request.Headers["X-Password"].ToString();
        if (!PasswordMatches(password, sec.Password))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new { error = "invalid password" });
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
    if (ValidateRegisterGatewayRequest(req) is { } error)
    {
        return error;
    }

    registry.Upsert(req.DeviceId, req.PublicKeyPem);
    repo.UpsertGateway(req.DeviceId, req.PublicKeyPem);
    return Results.Ok(new { ok = true, req.DeviceId });
});

app.MapPost("/api/gateway/sim-state", (UpsertGatewaySimStateRequest req, SqliteRepository repo) =>
{
    if (ValidateGatewaySimStateRequest(req) is { } error)
    {
        return error;
    }

    repo.ReplaceGatewaySimProfiles(req.DeviceId, req.Profiles);
    return Results.Ok(new { ok = true, count = req.Profiles.Count });
});

app.MapPost("/api/gateway/sms/upload", (UploadSmsRequest req, CryptoState crypto, SqliteRepository repo, ILogger<Program> logger) =>
{
    if (ValidateUploadSmsRequest(req) is { } error)
    {
        return error;
    }

    try
    {
        var plain = crypto.DecryptWithServerPrivateKey(req.EncryptedPayloadBase64);
        var payload = JsonSerializer.Deserialize<GatewaySmsPayload>(plain, jsonOptions);
        plain = string.Empty;
        if (payload is null)
        {
            return Results.BadRequest("invalid payload");
        }

        if (ValidateGatewayPayload(payload) is { } payloadError)
        {
            return payloadError;
        }

        var normalizedDirection = NormalizeDirection(payload.Direction);
        var normalizedSimSlot = NormalizeSimSlotIndex(payload.SimSlotIndex);
        var normalizedSimPhone = NormalizeOptionalText(payload.SimPhoneNumber, 64);
        var normalizedSimCount = NormalizeSimCount(payload.SimCount);
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
    if (!string.IsNullOrWhiteSpace(phone) && !IsValidPhone(phone))
    {
        return Results.BadRequest("phone invalid");
    }

    var list = repo.QueryMessages(sinceTs, limit ?? 5000, phone);
    return Results.Ok(list);
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
    if (ValidatePinRequest(req) is { } error)
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
    if (ValidateSendRequest(req) is { } error)
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

    var outboundSimSlot = selectedSim?.SlotIndex ?? NormalizeSimSlotIndex(req.SimSlotIndex);
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
    var encrypted = EncryptByPublicKey(plain, pem);

    repo.EnqueueOutbound(req.DeviceId, encrypted);
    repo.InsertMessageIfNotExists(outbound);

    return Results.Ok(new { ok = true, message = outbound });
});

app.MapGet("/api/gateway/pull", (string deviceId, SqliteRepository repo) =>
{
    var found = repo.LeaseNextOutbound(deviceId);
    if (found is null)
    {
        return Results.NoContent();
    }

    return Results.Ok(found);
});

app.MapPost("/api/gateway/pull/ack", (AckOutboundRequest req, SqliteRepository repo) =>
{
    if (ValidateAckOutboundRequest(req) is { } error)
    {
        return error;
    }

    var acked = repo.AckOutbound(req.DeviceId, req.OutboxId, req.AckToken);
    return acked
        ? Results.Ok(new { ok = true })
        : Results.NotFound(new { ok = false, error = "pending outbound not found" });
});

app.MapPost("/api/gateway/outbound-status", (OutboundStatusUpdateRequest req, SqliteRepository repo) =>
{
    if (ValidateOutboundStatusRequest(req) is { } error)
    {
        return error;
    }

    var status = NormalizeSendStatus(req.Status);
    if (status is null)
    {
        return Results.BadRequest("status invalid");
    }

    var normalized = req with
    {
        Status = status,
        SimSlotIndex = NormalizeSimSlotIndex(req.SimSlotIndex),
        SimPhoneNumber = NormalizeOptionalText(req.SimPhoneNumber, 64),
        SimCount = NormalizeSimCount(req.SimCount),
        ErrorMessage = NormalizeOptionalText(req.ErrorMessage, 512),
        Timestamp = req.Timestamp > 0 ? req.Timestamp : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
    };

    var updated = repo.UpsertOutboundStatus(normalized);
    return Results.Ok(new { ok = true, updated });
});

app.Run();

static string NormalizeDirection(string? direction)
{
    var d = direction?.Trim().ToLowerInvariant();
    return d is "outbound" ? "outbound" : "inbound";
}

static int? NormalizeSimSlotIndex(int? simSlotIndex)
{
    return simSlotIndex is >= 0 and <= 7 ? simSlotIndex : null;
}

static int? NormalizeSimCount(int? simCount)
{
    return simCount is >= 1 and <= 8 ? simCount : null;
}

static string? NormalizeSendStatus(string? status)
{
    return status?.Trim().ToLowerInvariant() switch
    {
        "queued" => "queued",
        "dispatched" => "dispatched",
        "sent" => "sent",
        "failed" => "failed",
        _ => null
    };
}

static string? NormalizeOptionalText(string? value, int maxLength)
{
    var normalized = value?.Trim();
    if (string.IsNullOrWhiteSpace(normalized))
    {
        return null;
    }

    return normalized.Length <= maxLength ? normalized : normalized[..maxLength];
}

static string EncryptByPublicKey(string plainText, string publicPem)
{
    using var rsa = RSA.Create();
    rsa.ImportFromPem(publicPem);
    var bytes = Encoding.UTF8.GetBytes(plainText);
    var maxChunkSize = GetMaxOaepSha256PlaintextSize(rsa);
    if (bytes.Length <= maxChunkSize)
    {
        var encrypted = rsa.Encrypt(bytes, RSAEncryptionPadding.OaepSHA256);
        return Convert.ToBase64String(encrypted);
    }

    var chunks = new List<string>();
    for (var offset = 0; offset < bytes.Length; offset += maxChunkSize)
    {
        var len = Math.Min(maxChunkSize, bytes.Length - offset);
        var slice = bytes.AsSpan(offset, len).ToArray();
        var encrypted = rsa.Encrypt(slice, RSAEncryptionPadding.OaepSHA256);
        chunks.Add(Convert.ToBase64String(encrypted));
    }

    return string.Join('.', chunks);
}

static int GetMaxOaepSha256PlaintextSize(RSA rsa)
{
    var keyBytes = rsa.KeySize / 8;
    var hashBytes = 32;
    return keyBytes - (2 * hashBytes) - 2;
}

static bool PasswordMatches(string? provided, string expected)
{
    var left = Encoding.UTF8.GetBytes(provided ?? string.Empty);
    var right = Encoding.UTF8.GetBytes(expected ?? string.Empty);
    return left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);
}

static IResult? ValidateRegisterGatewayRequest(RegisterGatewayRequest req)
{
    if (string.IsNullOrWhiteSpace(req.DeviceId) || string.IsNullOrWhiteSpace(req.PublicKeyPem))
    {
        return Results.BadRequest("deviceId/publicKeyPem required");
    }

    if (req.DeviceId.Length > 128)
    {
        return Results.BadRequest("deviceId too long");
    }

    if (req.PublicKeyPem.Length is < 128 or > 16384)
    {
        return Results.BadRequest("publicKeyPem length invalid");
    }

    return null;
}

static IResult? ValidateUploadSmsRequest(UploadSmsRequest req)
{
    if (string.IsNullOrWhiteSpace(req.DeviceId) || string.IsNullOrWhiteSpace(req.EncryptedPayloadBase64))
    {
        return Results.BadRequest("deviceId/encryptedPayloadBase64 required");
    }

    if (req.DeviceId.Length > 128)
    {
        return Results.BadRequest("deviceId too long");
    }

    if (req.EncryptedPayloadBase64.Length > 262144)
    {
        return Results.BadRequest("encrypted payload too large");
    }

    return null;
}

static IResult? ValidateGatewayPayload(GatewaySmsPayload payload)
{
    if (!IsValidPhone(payload.Phone))
    {
        return Results.BadRequest("phone invalid");
    }

    if (payload.Content.Length > 8192)
    {
        return Results.BadRequest("content too large");
    }

    if (!string.IsNullOrWhiteSpace(payload.MessageId) && payload.MessageId.Length > 256)
    {
        return Results.BadRequest("messageId too long");
    }

    if (payload.SimSlotIndex.HasValue && payload.SimSlotIndex.Value is < 0 or > 7)
    {
        return Results.BadRequest("simSlotIndex invalid");
    }

    if (!string.IsNullOrWhiteSpace(payload.SimPhoneNumber) && !IsValidPhone(payload.SimPhoneNumber))
    {
        return Results.BadRequest("simPhoneNumber invalid");
    }

    if (payload.SimCount.HasValue && payload.SimCount.Value is < 1 or > 8)
    {
        return Results.BadRequest("simCount invalid");
    }

    return null;
}

static IResult? ValidateGatewaySimStateRequest(UpsertGatewaySimStateRequest req)
{
    if (string.IsNullOrWhiteSpace(req.DeviceId))
    {
        return Results.BadRequest("deviceId required");
    }

    if (req.DeviceId.Length > 128)
    {
        return Results.BadRequest("deviceId too long");
    }

    if (req.Profiles is null)
    {
        return Results.BadRequest("profiles required");
    }

    if (req.Profiles.Count > 8)
    {
        return Results.BadRequest("too many sim profiles");
    }

    if (req.Profiles.GroupBy(x => x.SlotIndex).Any(x => x.Count() > 1))
    {
        return Results.BadRequest("duplicate sim slot index");
    }

    foreach (var profile in req.Profiles)
    {
        if (ValidateGatewaySimProfile(profile) is { } error)
        {
            return error;
        }
    }

    return null;
}

static IResult? ValidateGatewaySimProfile(GatewaySimProfilePayload profile)
{
    if (profile.SlotIndex is < 0 or > 7)
    {
        return Results.BadRequest("sim slot invalid");
    }

    if (profile.SubscriptionId.HasValue && profile.SubscriptionId.Value < 0)
    {
        return Results.BadRequest("subscriptionId invalid");
    }

    if (!string.IsNullOrWhiteSpace(profile.DisplayName) && profile.DisplayName.Length > 128)
    {
        return Results.BadRequest("displayName too long");
    }

    if (!string.IsNullOrWhiteSpace(profile.PhoneNumber) && !IsValidPhone(profile.PhoneNumber))
    {
        return Results.BadRequest("phoneNumber invalid");
    }

    if (profile.SimCount.HasValue && profile.SimCount.Value is < 1 or > 8)
    {
        return Results.BadRequest("simCount invalid");
    }

    return null;
}

static IResult? ValidatePinRequest(PinConversationRequest req)
{
    return IsValidPhone(req.Phone)
        ? null
        : Results.BadRequest("phone required");
}

static IResult? ValidateSendRequest(SendSmsRequest req)
{
    if (string.IsNullOrWhiteSpace(req.DeviceId) || !IsValidPhone(req.TargetPhone) || string.IsNullOrWhiteSpace(req.Content))
    {
        return Results.BadRequest("deviceId/targetPhone/content required");
    }

    if (req.DeviceId.Length > 128)
    {
        return Results.BadRequest("deviceId too long");
    }

    if (req.Content.Length > 8192)
    {
        return Results.BadRequest("content too large");
    }

    if (req.SimSlotIndex.HasValue && req.SimSlotIndex.Value is < 0 or > 7)
    {
        return Results.BadRequest("simSlotIndex invalid");
    }

    return null;
}

static IResult? ValidateAckOutboundRequest(AckOutboundRequest req)
{
    if (string.IsNullOrWhiteSpace(req.DeviceId) || string.IsNullOrWhiteSpace(req.AckToken) || req.OutboxId <= 0)
    {
        return Results.BadRequest("deviceId/outboxId/ackToken required");
    }

    if (req.DeviceId.Length > 128)
    {
        return Results.BadRequest("deviceId too long");
    }

    if (req.AckToken.Length > 128)
    {
        return Results.BadRequest("ackToken too long");
    }

    return null;
}

static IResult? ValidateOutboundStatusRequest(OutboundStatusUpdateRequest req)
{
    if (string.IsNullOrWhiteSpace(req.DeviceId) || string.IsNullOrWhiteSpace(req.MessageId) || !IsValidPhone(req.TargetPhone))
    {
        return Results.BadRequest("deviceId/messageId/targetPhone required");
    }

    if (req.DeviceId.Length > 128)
    {
        return Results.BadRequest("deviceId too long");
    }

    if (req.MessageId.Length > 256)
    {
        return Results.BadRequest("messageId too long");
    }

    if (string.IsNullOrWhiteSpace(req.Status))
    {
        return Results.BadRequest("status required");
    }

    if (NormalizeSendStatus(req.Status) is null)
    {
        return Results.BadRequest("status invalid");
    }

    if (req.SimSlotIndex.HasValue && req.SimSlotIndex.Value is < 0 or > 7)
    {
        return Results.BadRequest("simSlotIndex invalid");
    }

    if (!string.IsNullOrWhiteSpace(req.SimPhoneNumber) && !IsValidPhone(req.SimPhoneNumber))
    {
        return Results.BadRequest("simPhoneNumber invalid");
    }

    if (req.SimCount.HasValue && req.SimCount.Value is < 1 or > 8)
    {
        return Results.BadRequest("simCount invalid");
    }

    if (req.ErrorCode.HasValue && req.ErrorCode.Value is < -999999 or > 999999)
    {
        return Results.BadRequest("errorCode invalid");
    }

    if (!string.IsNullOrWhiteSpace(req.ErrorMessage) && req.ErrorMessage.Length > 512)
    {
        return Results.BadRequest("errorMessage too long");
    }

    return null;
}

static bool IsValidPhone(string? phone)
{
    var normalized = phone?.Trim();
    return !string.IsNullOrWhiteSpace(normalized) && normalized.Length <= 64;
}

public static class RuntimeLayout
{
    public static string ExecutablePath { get; } = ResolveExecutablePath();
    public static string RuntimeDirectory { get; } = ResolveRuntimeDirectory();

    private static string ResolveExecutablePath()
    {
        var path = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(path))
        {
            return path;
        }

        path = System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
        if (!string.IsNullOrWhiteSpace(path))
        {
            return path;
        }

        return AppContext.BaseDirectory;
    }

    private static string ResolveRuntimeDirectory()
    {
        var path = ResolveExecutablePath();
        return Directory.Exists(path)
            ? path
            : Path.GetDirectoryName(path) ?? AppContext.BaseDirectory;
    }
}

public static class MessageIdentity
{
    public static string Build(string deviceId, string phone, string content, long timestamp, string direction, int? simSlotIndex = null)
    {
        using var sha = SHA256.Create();
        var raw = $"{deviceId}|{phone}|{timestamp}|{direction}|{simSlotIndex?.ToString() ?? "-1"}|{content}";
        var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(raw));
        return Convert.ToHexString(hash)[..24].ToLowerInvariant();
    }
}

public sealed class CryptoState
{
    private readonly RSA _serverRsa;
    public string ServerPublicKeyPem { get; }
    public string PrivateKeyFilePath { get; }

    private const string PrivateKeyFileName = "server-crypto-private.pem";

    public CryptoState()
    {
        PrivateKeyFilePath = Path.Combine(RuntimeLayout.RuntimeDirectory, PrivateKeyFileName);
        _serverRsa = LoadOrCreateServerRsa(PrivateKeyFilePath);
        ServerPublicKeyPem = _serverRsa.ExportSubjectPublicKeyInfoPem();
    }

    private static RSA LoadOrCreateServerRsa(string privateKeyFilePath)
    {
        var rsa = RSA.Create();

        if (File.Exists(privateKeyFilePath))
        {
            var existingPem = File.ReadAllText(privateKeyFilePath, Encoding.UTF8);
            rsa.ImportFromPem(existingPem);
            return rsa;
        }

        rsa.KeySize = 2048;
        var privatePem = rsa.ExportPkcs8PrivateKeyPem();
        File.WriteAllText(privateKeyFilePath, privatePem, new UTF8Encoding(false));
        return rsa;
    }

    public string DecryptWithServerPrivateKey(string encryptedBase64)
    {
        if (!encryptedBase64.Contains('.'))
        {
            var data = Convert.FromBase64String(encryptedBase64);
            var plain = _serverRsa.Decrypt(data, RSAEncryptionPadding.OaepSHA256);
            return Encoding.UTF8.GetString(plain);
        }

        var estimatedCapacity = encryptedBase64.Count(x => x == '.') switch
        {
            < 1 => 1024,
            var dotCount => Math.Min((dotCount + 1) * 190, 256 * 1024)
        };
        using var output = new MemoryStream(estimatedCapacity);
        foreach (var chunk in encryptedBase64.Split('.', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var data = Convert.FromBase64String(chunk);
            var plainChunk = _serverRsa.Decrypt(data, RSAEncryptionPadding.OaepSHA256);
            output.Write(plainChunk, 0, plainChunk.Length);
        }
        return Encoding.UTF8.GetString(output.ToArray());
    }
}

public sealed class GatewayRegistry
{
    private readonly Dictionary<string, string> _pubKeys = new(StringComparer.Ordinal);
    private readonly object _lock = new();

    public void Upsert(string deviceId, string publicKeyPem)
    {
        lock (_lock)
        {
            _pubKeys[deviceId] = publicKeyPem;
        }
    }

    public bool TryGetPublicKey(string deviceId, out string? pem)
    {
        lock (_lock)
        {
            return _pubKeys.TryGetValue(deviceId, out pem);
        }
    }
}

public sealed class ServerRuntimeSettings
{
    public string Password { get; }
    public int HttpsPort { get; }
    public string ServerConfigFilePath { get; }
    public string LegacyPasswordFilePath { get; }

    private const int DefaultHttpsPort = 5001;

    public ServerRuntimeSettings()
    {
        var baseDir = RuntimeLayout.RuntimeDirectory;
        ServerConfigFilePath = Path.Combine(baseDir, "server.conf");
        LegacyPasswordFilePath = Path.Combine(baseDir, "password.conf");

        var config = LoadOrCreateConfig();
        Password = config.Password;
        HttpsPort = config.HttpsPort;
    }

    private (string Password, int HttpsPort) LoadOrCreateConfig()
    {
        if (!File.Exists(ServerConfigFilePath))
        {
            var migratedPassword = TryLoadLegacyPassword();
            var generatedPassword = string.IsNullOrWhiteSpace(migratedPassword)
                ? Convert.ToBase64String(RandomNumberGenerator.GetBytes(18))
                : migratedPassword!;

            WriteServerConfig(DefaultHttpsPort, generatedPassword);
            return (generatedPassword, DefaultHttpsPort);
        }

        var values = ParseKeyValueFile(ServerConfigFilePath);
        var changed = false;

        if (!values.TryGetValue("password", out var password) || string.IsNullOrWhiteSpace(password))
        {
            password = TryLoadLegacyPassword();
            if (string.IsNullOrWhiteSpace(password))
            {
                password = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));
            }
            changed = true;
        }

        var httpsPort = DefaultHttpsPort;
        if (values.TryGetValue("https_port", out var rawPort) && int.TryParse(rawPort, out var parsedPort) && parsedPort is >= 1 and <= 65535)
        {
            httpsPort = parsedPort;
        }
        else
        {
            changed = true;
        }

        if (changed)
        {
            WriteServerConfig(httpsPort, password!);
        }

        return (password!, httpsPort);
    }

    private string? TryLoadLegacyPassword()
    {
        if (!File.Exists(LegacyPasswordFilePath))
        {
            return null;
        }

        var values = ParseKeyValueFile(LegacyPasswordFilePath);
        if (values.TryGetValue("password", out var password) && !string.IsNullOrWhiteSpace(password))
        {
            return password;
        }

        var raw = File.ReadAllLines(LegacyPasswordFilePath, Encoding.UTF8)
            .Select(x => x.Trim())
            .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x) && !x.StartsWith("#", StringComparison.Ordinal));

        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        return raw.Contains('=')
            ? raw[(raw.IndexOf('=') + 1)..].Trim()
            : raw;
    }

    private Dictionary<string, string> ParseKeyValueFile(string path)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in File.ReadAllLines(path, Encoding.UTF8))
        {
            var trimmed = line.Trim();
            if (string.IsNullOrWhiteSpace(trimmed) || trimmed.StartsWith("#", StringComparison.Ordinal) || trimmed.StartsWith(";", StringComparison.Ordinal))
            {
                continue;
            }

            var idx = trimmed.IndexOf('=');
            if (idx <= 0)
            {
                continue;
            }

            var key = trimmed[..idx].Trim();
            var value = trimmed[(idx + 1)..].Trim();
            if (!string.IsNullOrWhiteSpace(key))
            {
                result[key] = value;
            }
        }

        return result;
    }

    private void WriteServerConfig(int httpsPort, string password)
    {
        File.WriteAllText(
            ServerConfigFilePath,
            $"# RemoteMessage server.conf\n# Generated on first start. Edit values and restart the service.\nhttps_port={httpsPort}\npassword={password}\n",
            new UTF8Encoding(false)
        );
    }
}

public sealed class HttpsCertificateSettings
{
    public X509Certificate2 Certificate { get; }
    public string CerFilePath { get; }
    public string PfxFilePath { get; }

    public HttpsCertificateSettings()
    {
        var baseDir = RuntimeLayout.RuntimeDirectory;
        CerFilePath = Path.Combine(baseDir, "server-cert.cer");
        PfxFilePath = Path.Combine(baseDir, "server-cert.pfx");

        Certificate = LoadOrCreateCertificate();
    }

    private X509Certificate2 LoadOrCreateCertificate()
    {
        if (File.Exists(PfxFilePath))
        {
            var existing = new X509Certificate2(PfxFilePath, string.Empty, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);
            EnsureCertificateFile(existing);
            return existing;
        }

        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest(
            $"CN={Dns.GetHostName()}",
            rsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1
        );

        req.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, false));
        req.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, false));
        req.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(req.PublicKey, false));

        var san = new SubjectAlternativeNameBuilder();
        san.AddDnsName("localhost");
        san.AddDnsName(Dns.GetHostName());
        san.AddIpAddress(IPAddress.Loopback);
        san.AddIpAddress(IPAddress.IPv6Loopback);
        foreach (var ip in Dns.GetHostAddresses(Dns.GetHostName()).Where(x => x.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork || x.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6))
        {
            san.AddIpAddress(ip);
        }
        req.CertificateExtensions.Add(san.Build());

        var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
        var exportable = new X509Certificate2(cert.Export(X509ContentType.Pfx), string.Empty, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);
        File.WriteAllBytes(PfxFilePath, exportable.Export(X509ContentType.Pfx));
        EnsureCertificateFile(exportable);
        return exportable;
    }

    private void EnsureCertificateFile(X509Certificate2 certificate)
    {
        File.WriteAllText(CerFilePath, certificate.ExportCertificatePem(), new UTF8Encoding(false));
    }
}

public sealed class SqliteRepository
{
    private const long OutboxLeaseTimeoutMs = 60_000;
    private readonly string _connectionString;
    public string DatabaseFilePath { get; }

    public SqliteRepository()
    {
        DatabaseFilePath = Path.Combine(RuntimeLayout.RuntimeDirectory, "server.db");
        _connectionString = new SqliteConnectionStringBuilder { DataSource = DatabaseFilePath }.ToString();
        EnsureSchema();
    }

    public bool InsertMessageIfNotExists(SmsPayload payload)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT OR IGNORE INTO messages(
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
)
VALUES(
    $id,$deviceId,$phone,$content,$timestamp,$direction,$simSlotIndex,$simPhoneNumber,$simCount,
    $sendStatus,$sendErrorCode,$sendErrorMessage,$updatedAt
);";
        cmd.Parameters.AddWithValue("$id", payload.Id);
        cmd.Parameters.AddWithValue("$deviceId", payload.DeviceId);
        cmd.Parameters.AddWithValue("$phone", payload.Phone);
        cmd.Parameters.AddWithValue("$content", payload.Content);
        cmd.Parameters.AddWithValue("$timestamp", payload.Timestamp);
        cmd.Parameters.AddWithValue("$direction", payload.Direction);
        cmd.Parameters.AddWithValue("$simSlotIndex", (object?)payload.SimSlotIndex ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$simPhoneNumber", (object?)payload.SimPhoneNumber ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$simCount", (object?)payload.SimCount ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$sendStatus", (object?)NormalizeSendStatusText(payload.SendStatus) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$sendErrorCode", (object?)payload.SendErrorCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$sendErrorMessage", (object?)payload.SendErrorMessage ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$updatedAt", payload.UpdatedAt ?? payload.Timestamp);
        return cmd.ExecuteNonQuery() > 0;
    }

    public IReadOnlyList<SmsPayload> QueryMessages(long? sinceTs, int limit, string? phone)
    {
        limit = Math.Clamp(limit, 1, 10000);
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        var where = new List<string> { "1=1" };

        if (sinceTs.HasValue)
        {
            where.Add("(timestamp >= $sinceTs OR updated_at >= $sinceTs)");
            cmd.Parameters.AddWithValue("$sinceTs", sinceTs.Value);
        }

        if (!string.IsNullOrWhiteSpace(phone))
        {
            where.Add("phone = $phone");
            cmd.Parameters.AddWithValue("$phone", phone);
        }

        cmd.CommandText = $@"
SELECT
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
FROM messages
WHERE {string.Join(" AND ", where)}
ORDER BY timestamp ASC
LIMIT $limit;";
        cmd.Parameters.AddWithValue("$limit", limit);

        var list = new List<SmsPayload>(Math.Min(limit, 1024));
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new SmsPayload(
                Id: reader.GetString(0),
                DeviceId: reader.GetString(1),
                Phone: reader.GetString(2),
                Content: reader.GetString(3),
                Timestamp: reader.GetInt64(4),
                Direction: reader.GetString(5),
                SimSlotIndex: reader.IsDBNull(6) ? null : reader.GetInt32(6),
                SimPhoneNumber: reader.IsDBNull(7) ? null : reader.GetString(7),
                SimCount: reader.IsDBNull(8) ? null : reader.GetInt32(8),
                SendStatus: reader.IsDBNull(9) ? null : reader.GetString(9),
                SendErrorCode: reader.IsDBNull(10) ? null : reader.GetInt32(10),
                SendErrorMessage: reader.IsDBNull(11) ? null : reader.GetString(11),
                UpdatedAt: reader.IsDBNull(12) ? null : reader.GetInt64(12)
            ));
        }

        return list;
    }

    public void SetPinned(string phone, bool pinned)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        if (pinned)
        {
            cmd.CommandText = "INSERT OR REPLACE INTO pinned_conversations(phone, pinned_at) VALUES($phone, $ts);";
            cmd.Parameters.AddWithValue("$phone", phone);
            cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        }
        else
        {
            cmd.CommandText = "DELETE FROM pinned_conversations WHERE phone = $phone;";
            cmd.Parameters.AddWithValue("$phone", phone);
        }

        cmd.ExecuteNonQuery();
    }

    public IReadOnlyList<string> GetPinnedPhones()
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT phone FROM pinned_conversations ORDER BY pinned_at DESC;";
        var list = new List<string>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(reader.GetString(0));
        }

        return list;
    }

    public void EnqueueOutbound(string deviceId, string encryptedPayloadBase64)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT INTO outbox(device_id, encrypted_payload_base64, created_at)
VALUES($deviceId, $payload, $ts);";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        cmd.Parameters.AddWithValue("$payload", encryptedPayloadBase64);
        cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        cmd.ExecuteNonQuery();
    }

    public void UpsertGateway(string deviceId, string publicKeyPem)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT INTO gateways(device_id, public_key_pem, updated_at)
VALUES($deviceId, $pem, $ts)
ON CONFLICT(device_id) DO UPDATE SET
  public_key_pem = excluded.public_key_pem,
  updated_at = excluded.updated_at;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        cmd.Parameters.AddWithValue("$pem", publicKeyPem);
        cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        cmd.ExecuteNonQuery();
    }

    public string? GetGatewayPublicKey(string deviceId)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT public_key_pem FROM gateways WHERE device_id = $deviceId LIMIT 1;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        var v = cmd.ExecuteScalar();
        return v?.ToString();
    }

    public void ReplaceGatewaySimProfiles(string deviceId, IReadOnlyList<GatewaySimProfilePayload> profiles)
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();

        using (var del = conn.CreateCommand())
        {
            del.Transaction = tx;
            del.CommandText = "DELETE FROM gateway_sim_profiles WHERE device_id = $deviceId;";
            del.Parameters.AddWithValue("$deviceId", deviceId);
            del.ExecuteNonQuery();
        }

        foreach (var profile in profiles)
        {
            using var insert = conn.CreateCommand();
            insert.Transaction = tx;
            insert.CommandText = @"
INSERT INTO gateway_sim_profiles(device_id, slot_index, subscription_id, display_name, phone_number, sim_count, updated_at)
VALUES($deviceId, $slotIndex, $subscriptionId, $displayName, $phoneNumber, $simCount, $updatedAt);";
            insert.Parameters.AddWithValue("$deviceId", deviceId);
            insert.Parameters.AddWithValue("$slotIndex", profile.SlotIndex);
            insert.Parameters.AddWithValue("$subscriptionId", (object?)profile.SubscriptionId ?? DBNull.Value);
            insert.Parameters.AddWithValue("$displayName", (object?)NormalizeProfileText(profile.DisplayName, 128) ?? DBNull.Value);
            insert.Parameters.AddWithValue("$phoneNumber", (object?)NormalizeProfileText(profile.PhoneNumber, 64) ?? DBNull.Value);
            insert.Parameters.AddWithValue("$simCount", NormalizeProfileSimCount(profile.SimCount, profiles.Count));
            insert.Parameters.AddWithValue("$updatedAt", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            insert.ExecuteNonQuery();
        }

        tx.Commit();
    }

    public IReadOnlyList<GatewaySimProfileRecord> GetGatewaySimProfiles(string deviceId)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
SELECT device_id, slot_index, subscription_id, display_name, phone_number, sim_count, updated_at
FROM gateway_sim_profiles
WHERE device_id = $deviceId
ORDER BY slot_index ASC;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);

        var list = new List<GatewaySimProfileRecord>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new GatewaySimProfileRecord(
                DeviceId: reader.GetString(0),
                SlotIndex: reader.GetInt32(1),
                SubscriptionId: reader.IsDBNull(2) ? null : reader.GetInt32(2),
                DisplayName: reader.IsDBNull(3) ? null : reader.GetString(3),
                PhoneNumber: reader.IsDBNull(4) ? null : reader.GetString(4),
                SimCount: reader.IsDBNull(5) ? 0 : reader.GetInt32(5),
                UpdatedAt: reader.IsDBNull(6) ? 0 : reader.GetInt64(6)
            ));
        }

        return list;
    }

    public GatewaySimProfileRecord? ResolveGatewaySimProfile(string deviceId, int? simSlotIndex)
    {
        var profiles = GetGatewaySimProfiles(deviceId);
        if (profiles.Count == 0)
        {
            return null;
        }

        if (simSlotIndex.HasValue)
        {
            return profiles.FirstOrDefault(x => x.SlotIndex == simSlotIndex.Value);
        }

        return profiles.Count == 1 ? profiles[0] : null;
    }

    public void InsertApiLog(string method, string path, int statusCode, string remoteIp, long durationMs)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT INTO api_logs(method, path, status_code, remote_ip, duration_ms, created_at)
VALUES($method, $path, $status, $ip, $duration, $ts);";
        cmd.Parameters.AddWithValue("$method", method);
        cmd.Parameters.AddWithValue("$path", path);
        cmd.Parameters.AddWithValue("$status", statusCode);
        cmd.Parameters.AddWithValue("$ip", remoteIp);
        cmd.Parameters.AddWithValue("$duration", durationMs);
        cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        cmd.ExecuteNonQuery();
    }

    public PendingOutbound? LeaseNextOutbound(string deviceId)
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var leaseExpiredBefore = now - OutboxLeaseTimeoutMs;
        using var select = conn.CreateCommand();
        select.Transaction = tx;
        select.CommandText = @"
SELECT id, device_id, encrypted_payload_base64
FROM outbox
WHERE device_id = $deviceId
  AND (lease_token IS NULL OR leased_at IS NULL OR leased_at <= $leaseExpiredBefore)
ORDER BY id ASC
LIMIT 1;";
        select.Parameters.AddWithValue("$deviceId", deviceId);
        select.Parameters.AddWithValue("$leaseExpiredBefore", leaseExpiredBefore);

        using var reader = select.ExecuteReader();
        if (!reader.Read())
        {
            tx.Commit();
            return null;
        }

        var id = reader.GetInt64(0);
        var leaseToken = Guid.NewGuid().ToString("N");
        var item = new PendingOutbound
        {
            OutboxId = id,
            AckToken = leaseToken,
            DeviceId = reader.GetString(1),
            EncryptedPayloadBase64 = reader.GetString(2)
        };
        reader.Close();

        using var lease = conn.CreateCommand();
        lease.Transaction = tx;
        lease.CommandText = @"
UPDATE outbox
SET lease_token = $leaseToken, leased_at = $leasedAt
WHERE id = $id
  AND device_id = $deviceId
  AND (lease_token IS NULL OR leased_at IS NULL OR leased_at <= $leaseExpiredBefore);";
        lease.Parameters.AddWithValue("$leaseToken", leaseToken);
        lease.Parameters.AddWithValue("$leasedAt", now);
        lease.Parameters.AddWithValue("$id", id);
        lease.Parameters.AddWithValue("$deviceId", deviceId);
        lease.Parameters.AddWithValue("$leaseExpiredBefore", leaseExpiredBefore);
        var leased = lease.ExecuteNonQuery();
        if (leased <= 0)
        {
            tx.Rollback();
            return null;
        }

        tx.Commit();
        return item;
    }

    public bool AckOutbound(string deviceId, long outboxId, string ackToken)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
DELETE FROM outbox
WHERE id = $outboxId
  AND device_id = $deviceId
  AND lease_token = $ackToken;";
        cmd.Parameters.AddWithValue("$outboxId", outboxId);
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        cmd.Parameters.AddWithValue("$ackToken", ackToken);
        return cmd.ExecuteNonQuery() > 0;
    }

    public bool UpsertOutboundStatus(OutboundStatusUpdateRequest req)
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();

        using var update = conn.CreateCommand();
        update.Transaction = tx;
        update.CommandText = @"
UPDATE messages
SET send_status = $sendStatus,
    send_error_code = $sendErrorCode,
    send_error_message = $sendErrorMessage,
    updated_at = $updatedAt,
    sim_slot_index = COALESCE($simSlotIndex, sim_slot_index),
    sim_phone_number = COALESCE($simPhoneNumber, sim_phone_number),
    sim_count = COALESCE($simCount, sim_count)
WHERE id = $id;";
        update.Parameters.AddWithValue("$sendStatus", req.Status);
        update.Parameters.AddWithValue("$sendErrorCode", (object?)req.ErrorCode ?? DBNull.Value);
        update.Parameters.AddWithValue("$sendErrorMessage", (object?)req.ErrorMessage ?? DBNull.Value);
        update.Parameters.AddWithValue("$updatedAt", req.Timestamp);
        update.Parameters.AddWithValue("$simSlotIndex", (object?)req.SimSlotIndex ?? DBNull.Value);
        update.Parameters.AddWithValue("$simPhoneNumber", (object?)req.SimPhoneNumber ?? DBNull.Value);
        update.Parameters.AddWithValue("$simCount", (object?)req.SimCount ?? DBNull.Value);
        update.Parameters.AddWithValue("$id", req.MessageId);
        var affected = update.ExecuteNonQuery();

        if (affected <= 0)
        {
            using var insert = conn.CreateCommand();
            insert.Transaction = tx;
            insert.CommandText = @"
INSERT OR IGNORE INTO messages(
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
)
VALUES(
    $id, $deviceId, $phone, $content, $timestamp, 'outbound', $simSlotIndex, $simPhoneNumber, $simCount,
    $sendStatus, $sendErrorCode, $sendErrorMessage, $updatedAt
);";
            insert.Parameters.AddWithValue("$id", req.MessageId);
            insert.Parameters.AddWithValue("$deviceId", req.DeviceId);
            insert.Parameters.AddWithValue("$phone", req.TargetPhone);
            insert.Parameters.AddWithValue("$content", req.Content ?? string.Empty);
            insert.Parameters.AddWithValue("$timestamp", req.Timestamp);
            insert.Parameters.AddWithValue("$simSlotIndex", (object?)req.SimSlotIndex ?? DBNull.Value);
            insert.Parameters.AddWithValue("$simPhoneNumber", (object?)req.SimPhoneNumber ?? DBNull.Value);
            insert.Parameters.AddWithValue("$simCount", (object?)req.SimCount ?? DBNull.Value);
            insert.Parameters.AddWithValue("$sendStatus", req.Status);
            insert.Parameters.AddWithValue("$sendErrorCode", (object?)req.ErrorCode ?? DBNull.Value);
            insert.Parameters.AddWithValue("$sendErrorMessage", (object?)req.ErrorMessage ?? DBNull.Value);
            insert.Parameters.AddWithValue("$updatedAt", req.Timestamp);
            affected = insert.ExecuteNonQuery();
        }

        tx.Commit();
        return affected > 0;
    }

    private SqliteConnection Open()
    {
        var conn = OpenRaw();
        EnsureSchema(conn);
        return conn;
    }

    private SqliteConnection OpenRaw()
    {
        var conn = new SqliteConnection(_connectionString);
        conn.Open();
        return conn;
    }

    private void EnsureSchema()
    {
        using var conn = OpenRaw();
        EnsureSchema(conn);
    }

    private void EnsureSchema(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
CREATE TABLE IF NOT EXISTS messages(
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    phone TEXT NOT NULL,
    content TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    direction TEXT NOT NULL,
    sim_slot_index INTEGER,
    sim_phone_number TEXT,
    sim_count INTEGER,
    send_status TEXT,
    send_error_code INTEGER,
    send_error_message TEXT,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    encrypted_payload_base64 TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    lease_token TEXT,
    leased_at INTEGER
);

CREATE TABLE IF NOT EXISTS pinned_conversations(
    phone TEXT PRIMARY KEY,
    pinned_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS gateways(
    device_id TEXT PRIMARY KEY,
    public_key_pem TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS gateway_sim_profiles(
    device_id TEXT NOT NULL,
    slot_index INTEGER NOT NULL,
    subscription_id INTEGER,
    display_name TEXT,
    phone_number TEXT,
    sim_count INTEGER,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY(device_id, slot_index)
);

CREATE TABLE IF NOT EXISTS api_logs(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    remote_ip TEXT NOT NULL,
    duration_ms INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_phone_ts ON messages(phone, timestamp);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_messages_updated_at ON messages(updated_at);
CREATE INDEX IF NOT EXISTS idx_gateway_sim_profiles_device_id ON gateway_sim_profiles(device_id);
CREATE INDEX IF NOT EXISTS idx_outbox_device_id ON outbox(device_id);
CREATE INDEX IF NOT EXISTS idx_api_logs_created_at ON api_logs(created_at);
";
        cmd.ExecuteNonQuery();
        EnsureColumns(conn);
    }

    private void EnsureColumns(SqliteConnection conn)
    {
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN sim_slot_index INTEGER;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN sim_phone_number TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN sim_count INTEGER;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN send_status TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN send_error_code INTEGER;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN send_error_message TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN updated_at INTEGER;");
        TryExecuteNonQuery(conn, "UPDATE messages SET updated_at = timestamp WHERE updated_at IS NULL OR updated_at <= 0;");
        TryExecuteNonQuery(conn, "CREATE INDEX IF NOT EXISTS idx_messages_updated_at ON messages(updated_at);");
        TryExecuteNonQuery(conn, "ALTER TABLE outbox ADD COLUMN lease_token TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE outbox ADD COLUMN leased_at INTEGER;");
        TryExecuteNonQuery(conn, "CREATE INDEX IF NOT EXISTS idx_outbox_device_lease ON outbox(device_id, leased_at);");
    }

    private void TryExecuteNonQuery(SqliteConnection conn, string sql)
    {
        try
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            cmd.ExecuteNonQuery();
        }
        catch (SqliteException)
        {
            // ignore when the column already exists
        }
    }

    private string? NormalizeProfileText(string? value, int maxLength)
    {
        var normalized = value?.Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return null;
        }

        return normalized.Length <= maxLength ? normalized : normalized[..maxLength];
    }

    private int NormalizeProfileSimCount(int? simCount, int fallback)
    {
        if (simCount is >= 1 and <= 8)
        {
            return simCount.Value;
        }

        return Math.Clamp(fallback, 1, 8);
    }

    private string? NormalizeSendStatusText(string? status)
    {
        return status?.Trim().ToLowerInvariant() switch
        {
            "queued" => "queued",
            "dispatched" => "dispatched",
            "sent" => "sent",
            "failed" => "failed",
            _ => null
        };
    }
}

public record RegisterGatewayRequest(string DeviceId, string PublicKeyPem);
public record UploadSmsRequest(string DeviceId, string EncryptedPayloadBase64);
public record SendSmsRequest(string DeviceId, string TargetPhone, string Content, int? SimSlotIndex = null);
public record PinConversationRequest(string Phone, bool Pinned);
public record AckOutboundRequest(string DeviceId, long OutboxId, string AckToken);
public record OutboundStatusUpdateRequest(
    string DeviceId,
    string MessageId,
    string TargetPhone,
    string Status,
    long Timestamp,
    string? Content = null,
    int? SimSlotIndex = null,
    string? SimPhoneNumber = null,
    int? SimCount = null,
    int? ErrorCode = null,
    string? ErrorMessage = null
);
public record UpsertGatewaySimStateRequest(string DeviceId, IReadOnlyList<GatewaySimProfilePayload> Profiles);
public record GatewaySimProfilePayload(int SlotIndex, int? SubscriptionId = null, string? DisplayName = null, string? PhoneNumber = null, int? SimCount = null);

public record GatewaySmsPayload(
    string Phone,
    string Content,
    long Timestamp,
    string? Direction = null,
    string? MessageId = null,
    int? SimSlotIndex = null,
    string? SimPhoneNumber = null,
    int? SimCount = null
);
public record SmsPayload(
    string Id,
    string DeviceId,
    string Phone,
    string Content,
    long Timestamp,
    string Direction = "unknown",
    int? SimSlotIndex = null,
    string? SimPhoneNumber = null,
    int? SimCount = null,
    string? SendStatus = null,
    int? SendErrorCode = null,
    string? SendErrorMessage = null,
    long? UpdatedAt = null
);
public record OutboundInstruction(string MessageId, string TargetPhone, string Content, int? SimSlotIndex = null);
public record GatewaySimProfileRecord(string DeviceId, int SlotIndex, int? SubscriptionId, string? DisplayName, string? PhoneNumber, int SimCount, long UpdatedAt);

public sealed class PendingOutbound
{
    [JsonPropertyName("outboxId")]
    public long OutboxId { get; set; }

    [JsonPropertyName("ackToken")]
    public string AckToken { get; set; } = string.Empty;

    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("encryptedPayloadBase64")]
    public string EncryptedPayloadBase64 { get; set; } = string.Empty;
}

public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly string _logFilePath;
    private readonly object _writeLock = new();

    public FileLoggerProvider(string logFilePath)
    {
        _logFilePath = logFilePath;
        var directory = Path.GetDirectoryName(_logFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(_logFilePath, categoryName, _writeLock);

    public void Dispose()
    {
    }
}

public sealed class FileLogger : ILogger
{
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
    private readonly string _logFilePath;
    private readonly string _categoryName;
    private readonly object _writeLock;

    public FileLogger(string logFilePath, string categoryName, object writeLock)
    {
        _logFilePath = logFilePath;
        _categoryName = categoryName;
        _writeLock = writeLock;
    }

    public IDisposable BeginScope<TState>(TState state) where TState : notnull => NoopScope.Instance;

    public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel))
        {
            return;
        }

        var message = formatter(state, exception);
        if (string.IsNullOrWhiteSpace(message) && exception is null)
        {
            return;
        }

        var line = $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz}] {logLevel,-11} {_categoryName}: {Sanitize(message)}";
        if (exception is not null)
        {
            line += $" | {Sanitize(exception.ToString())}";
        }

        try
        {
            lock (_writeLock)
            {
                File.AppendAllText(_logFilePath, line + Environment.NewLine, Utf8NoBom);
            }
        }
        catch
        {
            // Logging must not crash the server process.
        }
    }

    private static string Sanitize(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        return value.Replace('\r', ' ').Replace('\n', ' ');
    }
}

public sealed class NoopScope : IDisposable
{
    public static readonly NoopScope Instance = new();

    private NoopScope()
    {
    }

    public void Dispose()
    {
    }
}
