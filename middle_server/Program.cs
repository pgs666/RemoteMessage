using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;

var httpsSettings = new HttpsCertificateSettings();
var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options =>
{
    options.Listen(IPAddress.Any, httpsSettings.HttpsPort, listen => listen.UseHttps(httpsSettings.Certificate));
});
builder.Services.AddSingleton<CryptoState>();
builder.Services.AddSingleton<GatewayRegistry>();
builder.Services.AddSingleton<SqliteRepository>();
builder.Services.AddSingleton<PasswordSecuritySettings>();
builder.Services.AddSingleton(httpsSettings);

var app = builder.Build();

app.Use(async (context, next) =>
{
    var repo = context.RequestServices.GetRequiredService<SqliteRepository>();
    var sec = context.RequestServices.GetRequiredService<PasswordSecuritySettings>();

    var path = context.Request.Path.Value ?? string.Empty;
    var requiresAuth = !path.Equals("/healthz", StringComparison.OrdinalIgnoreCase);

    var begin = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    if (requiresAuth)
    {
        var password = context.Request.Headers["X-Password"].ToString();
        if (!string.Equals(password, sec.Password, StringComparison.Ordinal))
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
    if (string.IsNullOrWhiteSpace(req.DeviceId) || string.IsNullOrWhiteSpace(req.PublicKeyPem))
    {
        return Results.BadRequest("deviceId/publicKeyPem required");
    }

    registry.Upsert(req.DeviceId, req.PublicKeyPem);
    repo.UpsertGateway(req.DeviceId, req.PublicKeyPem);
    return Results.Ok(new { ok = true, req.DeviceId });
});

app.MapPost("/api/gateway/sms/upload", (UploadSmsRequest req, CryptoState crypto, SqliteRepository repo) =>
{
    try
    {
        var plain = crypto.DecryptWithServerPrivateKey(req.EncryptedPayloadBase64);
        var payload = JsonSerializer.Deserialize<GatewaySmsPayload>(plain);
        if (payload is null)
        {
            return Results.BadRequest("invalid payload");
        }

        var normalized = new SmsPayload(
            Id: string.IsNullOrWhiteSpace(payload.MessageId)
                ? MessageIdentity.Build(req.DeviceId, payload.Phone, payload.Content, payload.Timestamp, NormalizeDirection(payload.Direction))
                : payload.MessageId!,
            DeviceId: req.DeviceId,
            Phone: payload.Phone,
            Content: payload.Content,
            Timestamp: payload.Timestamp,
            Direction: NormalizeDirection(payload.Direction)
        );

        var isNew = repo.InsertMessageIfNotExists(normalized);
        return Results.Ok(new { ok = true, deduplicated = !isNew, messageId = normalized.Id });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { error = ex.Message });
    }
});

app.MapGet("/api/client/inbox", (long? sinceTs, int? limit, string? phone, SqliteRepository repo) =>
{
    var list = repo.QueryMessages(sinceTs, limit ?? 5000, phone);
    return Results.Ok(list);
});

app.MapPost("/api/client/conversations/pin", (PinConversationRequest req, SqliteRepository repo) =>
{
    if (string.IsNullOrWhiteSpace(req.Phone))
    {
        return Results.BadRequest("phone required");
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
    if (!registry.TryGetPublicKey(req.DeviceId, out var pem) || string.IsNullOrWhiteSpace(pem))
    {
        pem = repo.GetGatewayPublicKey(req.DeviceId);
        if (string.IsNullOrWhiteSpace(pem))
        {
            return Results.NotFound("gateway not registered");
        }

        registry.Upsert(req.DeviceId, pem);
    }

    var instruction = new OutboundInstruction(req.TargetPhone, req.Content);
    var plain = JsonSerializer.Serialize(instruction);
    var encrypted = EncryptByPublicKey(plain, pem);

    var outbound = new SmsPayload(
        Id: MessageIdentity.Build(req.DeviceId, req.TargetPhone, req.Content, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), "outbound"),
        DeviceId: req.DeviceId,
        Phone: req.TargetPhone,
        Content: req.Content,
        Timestamp: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        Direction: "outbound"
    );

    repo.EnqueueOutbound(req.DeviceId, encrypted);
    repo.InsertMessageIfNotExists(outbound);

    return Results.Ok(new { ok = true, message = outbound });
});

app.MapGet("/api/gateway/pull", (string deviceId, SqliteRepository repo) =>
{
    var found = repo.DequeueOutbound(deviceId);
    if (found is null)
    {
        return Results.NoContent();
    }

    return Results.Ok(found);
});

app.Run();

static string NormalizeDirection(string? direction)
{
    var d = direction?.Trim().ToLowerInvariant();
    return d is "outbound" ? "outbound" : "inbound";
}

static string EncryptByPublicKey(string plainText, string publicPem)
{
    using var rsa = RSA.Create();
    rsa.ImportFromPem(publicPem);
    var bytes = Encoding.UTF8.GetBytes(plainText);
    var encrypted = rsa.Encrypt(bytes, RSAEncryptionPadding.OaepSHA256);
    return Convert.ToBase64String(encrypted);
}

public static class MessageIdentity
{
    public static string Build(string deviceId, string phone, string content, long timestamp, string direction)
    {
        using var sha = SHA256.Create();
        var raw = $"{deviceId}|{phone}|{timestamp}|{direction}|{content}";
        var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(raw));
        return Convert.ToHexString(hash)[..24].ToLowerInvariant();
    }
}

public sealed class CryptoState
{
    private readonly RSA _serverRsa = RSA.Create(2048);
    public string ServerPublicKeyPem { get; }

    public CryptoState()
    {
        ServerPublicKeyPem = _serverRsa.ExportRSAPublicKeyPem();
    }

    public string DecryptWithServerPrivateKey(string encryptedBase64)
    {
        var data = Convert.FromBase64String(encryptedBase64);
        var plain = _serverRsa.Decrypt(data, RSAEncryptionPadding.OaepSHA256);
        return Encoding.UTF8.GetString(plain);
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

public sealed class PasswordSecuritySettings
{
    public string Password { get; }
    public string PasswordFilePath { get; }

    public PasswordSecuritySettings()
    {
        PasswordFilePath = Path.Combine(AppContext.BaseDirectory, "password.conf");
        if (!File.Exists(PasswordFilePath))
        {
            var generated = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));
            File.WriteAllText(
                PasswordFilePath,
                "# RemoteMessage password.conf\n# Edit the password value below\npassword=" + generated + "\n",
                Encoding.UTF8
            );
            Password = generated;
            return;
        }

        var lines = File.ReadAllLines(PasswordFilePath, Encoding.UTF8);
        var raw = lines
            .Select(x => x.Trim())
            .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x) && !x.StartsWith("#", StringComparison.Ordinal));

        if (string.IsNullOrWhiteSpace(raw))
        {
            Password = "change-me";
            return;
        }

        Password = raw.Contains('=')
            ? raw[(raw.IndexOf('=') + 1)..].Trim()
            : raw;

        if (string.IsNullOrWhiteSpace(Password))
        {
            Password = "change-me";
        }
    }
}

public sealed class HttpsCertificateSettings
{
    public X509Certificate2 Certificate { get; }
    public string CerFilePath { get; }
    public string PfxFilePath { get; }
    public int HttpsPort { get; }

    public HttpsCertificateSettings()
    {
        var baseDir = AppContext.BaseDirectory;
        CerFilePath = Path.Combine(baseDir, "server-cert.cer");
        PfxFilePath = Path.Combine(baseDir, "server-cert.pfx");
        HttpsPort = int.TryParse(Environment.GetEnvironmentVariable("REMOTE_MESSAGE_HTTPS_PORT"), out var p) && p is >= 1 and <= 65535
            ? p
            : 5001;

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
    private readonly string _connectionString;

    public SqliteRepository()
    {
        var dbPath = Path.Combine(AppContext.BaseDirectory, "server.db");
        _connectionString = new SqliteConnectionStringBuilder { DataSource = dbPath }.ToString();
        EnsureSchema();
    }

    public bool InsertMessageIfNotExists(SmsPayload payload)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT OR IGNORE INTO messages(id, device_id, phone, content, timestamp, direction)
VALUES($id,$deviceId,$phone,$content,$timestamp,$direction);";
        cmd.Parameters.AddWithValue("$id", payload.Id);
        cmd.Parameters.AddWithValue("$deviceId", payload.DeviceId);
        cmd.Parameters.AddWithValue("$phone", payload.Phone);
        cmd.Parameters.AddWithValue("$content", payload.Content);
        cmd.Parameters.AddWithValue("$timestamp", payload.Timestamp);
        cmd.Parameters.AddWithValue("$direction", payload.Direction);
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
            where.Add("timestamp >= $sinceTs");
            cmd.Parameters.AddWithValue("$sinceTs", sinceTs.Value);
        }

        if (!string.IsNullOrWhiteSpace(phone))
        {
            where.Add("phone = $phone");
            cmd.Parameters.AddWithValue("$phone", phone);
        }

        cmd.CommandText = $@"
SELECT id, device_id, phone, content, timestamp, direction
FROM messages
WHERE {string.Join(" AND ", where)}
ORDER BY timestamp ASC
LIMIT $limit;";
        cmd.Parameters.AddWithValue("$limit", limit);

        var list = new List<SmsPayload>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new SmsPayload(
                Id: reader.GetString(0),
                DeviceId: reader.GetString(1),
                Phone: reader.GetString(2),
                Content: reader.GetString(3),
                Timestamp: reader.GetInt64(4),
                Direction: reader.GetString(5)
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

    public PendingOutbound? DequeueOutbound(string deviceId)
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();
        using var select = conn.CreateCommand();
        select.Transaction = tx;
        select.CommandText = @"
SELECT id, device_id, encrypted_payload_base64
FROM outbox
WHERE device_id = $deviceId
ORDER BY id ASC
LIMIT 1;";
        select.Parameters.AddWithValue("$deviceId", deviceId);

        using var reader = select.ExecuteReader();
        if (!reader.Read())
        {
            tx.Commit();
            return null;
        }

        var id = reader.GetInt64(0);
        var item = new PendingOutbound
        {
            DeviceId = reader.GetString(1),
            EncryptedPayloadBase64 = reader.GetString(2)
        };
        reader.Close();

        using var del = conn.CreateCommand();
        del.Transaction = tx;
        del.CommandText = "DELETE FROM outbox WHERE id = $id;";
        del.Parameters.AddWithValue("$id", id);
        del.ExecuteNonQuery();
        tx.Commit();
        return item;
    }

    private SqliteConnection Open()
    {
        var conn = new SqliteConnection(_connectionString);
        conn.Open();
        return conn;
    }

    private void EnsureSchema()
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
CREATE TABLE IF NOT EXISTS messages(
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    phone TEXT NOT NULL,
    content TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    direction TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    encrypted_payload_base64 TEXT NOT NULL,
    created_at INTEGER NOT NULL
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
CREATE INDEX IF NOT EXISTS idx_outbox_device_id ON outbox(device_id);
CREATE INDEX IF NOT EXISTS idx_api_logs_created_at ON api_logs(created_at);
";
        cmd.ExecuteNonQuery();
    }
}

public record RegisterGatewayRequest(string DeviceId, string PublicKeyPem);
public record UploadSmsRequest(string DeviceId, string EncryptedPayloadBase64);
public record SendSmsRequest(string DeviceId, string TargetPhone, string Content);
public record PinConversationRequest(string Phone, bool Pinned);

public record GatewaySmsPayload(string Phone, string Content, long Timestamp, string? Direction = null, string? MessageId = null);
public record SmsPayload(string Id, string DeviceId, string Phone, string Content, long Timestamp, string Direction = "unknown");
public record OutboundInstruction(string TargetPhone, string Content);

public sealed class PendingOutbound
{
    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("encryptedPayloadBase64")]
    public string EncryptedPayloadBase64 { get; set; } = string.Empty;
}
