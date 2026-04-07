using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<CryptoState>();
builder.Services.AddSingleton<GatewayRegistry>();
builder.Services.AddSingleton<MessageStore>();

var app = builder.Build();

app.MapGet("/api/crypto/server-public-key", (CryptoState crypto) =>
{
    return Results.Ok(new { publicKey = crypto.ServerPublicKeyPem });
});

app.MapPost("/api/gateway/register", (RegisterGatewayRequest req, GatewayRegistry registry) =>
{
    if (string.IsNullOrWhiteSpace(req.DeviceId) || string.IsNullOrWhiteSpace(req.PublicKeyPem))
    {
        return Results.BadRequest("deviceId/publicKeyPem required");
    }

    registry.Upsert(req.DeviceId, req.PublicKeyPem);
    return Results.Ok(new { ok = true, req.DeviceId });
});

app.MapPost("/api/gateway/sms/upload", (UploadSmsRequest req, CryptoState crypto, MessageStore store) =>
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
                ? MessageStore.BuildMessageId(req.DeviceId, payload.Phone, payload.Content, payload.Timestamp, NormalizeDirection(payload.Direction))
                : payload.MessageId!,
            DeviceId: req.DeviceId,
            Phone: payload.Phone,
            Content: payload.Content,
            Timestamp: payload.Timestamp,
            Direction: NormalizeDirection(payload.Direction)
        );

        var isNew = store.TryAddMessage(normalized);
        return Results.Ok(new { ok = true, deduplicated = !isNew, messageId = normalized.Id });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { error = ex.Message });
    }
});

app.MapGet("/api/client/inbox", (long? sinceTs, int? limit, string? phone, MessageStore store) =>
{
    var list = store.QueryMessages(sinceTs, limit ?? 5000, phone);
    return Results.Ok(list);
});

app.MapPost("/api/client/send", (SendSmsRequest req, GatewayRegistry registry, MessageStore store) =>
{
    if (!registry.TryGetPublicKey(req.DeviceId, out var pem) || string.IsNullOrWhiteSpace(pem))
    {
        return Results.NotFound("gateway not registered");
    }

    var instruction = new OutboundInstruction(req.TargetPhone, req.Content);
    var plain = System.Text.Json.JsonSerializer.Serialize(instruction);
    var encrypted = EncryptByPublicKey(plain, pem);

    store.Outbox.Enqueue(new PendingOutbound
    {
        DeviceId = req.DeviceId,
        EncryptedPayloadBase64 = encrypted
    });

    var outbound = new SmsPayload(
        Id: MessageStore.BuildMessageId(req.DeviceId, req.TargetPhone, req.Content, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), "outbound"),
        DeviceId: req.DeviceId,
        Phone: req.TargetPhone,
        Content: req.Content,
        Timestamp: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        Direction: "outbound"
    );
    store.TryAddMessage(outbound);

    return Results.Ok(new { ok = true, message = outbound });
});

app.MapGet("/api/gateway/pull", (string deviceId, MessageStore store) =>
{
    var found = store.Outbox.FirstOrDefault(x => x.DeviceId == deviceId);
    if (found is null)
    {
        return Results.NoContent();
    }

    var all = store.Outbox.ToList();
    all.Remove(found);
    store.Outbox = new ConcurrentQueue<PendingOutbound>(all);
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
    private readonly ConcurrentDictionary<string, string> _pubKeys = new();
    public void Upsert(string deviceId, string publicKeyPem) => _pubKeys[deviceId] = publicKeyPem;
    public bool TryGetPublicKey(string deviceId, out string? pem) => _pubKeys.TryGetValue(deviceId, out pem);
}

public sealed class MessageStore
{
    private readonly object _lock = new();
    private readonly List<SmsPayload> _messages = new();
    private readonly HashSet<string> _messageIds = new(StringComparer.Ordinal);

    public ConcurrentQueue<PendingOutbound> Outbox { get; set; } = new();

    public bool TryAddMessage(SmsPayload payload)
    {
        lock (_lock)
        {
            if (_messageIds.Contains(payload.Id))
            {
                return false;
            }

            _messageIds.Add(payload.Id);
            _messages.Add(payload);
            return true;
        }
    }

    public IReadOnlyList<SmsPayload> QueryMessages(long? sinceTs, int limit, string? phone)
    {
        limit = Math.Clamp(limit, 1, 10000);
        lock (_lock)
        {
            IEnumerable<SmsPayload> query = _messages;
            if (sinceTs.HasValue)
            {
                query = query.Where(x => x.Timestamp >= sinceTs.Value);
            }

            if (!string.IsNullOrWhiteSpace(phone))
            {
                query = query.Where(x => string.Equals(x.Phone, phone, StringComparison.OrdinalIgnoreCase));
            }

            return query
                .OrderBy(x => x.Timestamp)
                .TakeLast(limit)
                .ToList();
        }
    }

    public static string BuildMessageId(string deviceId, string phone, string content, long timestamp, string direction)
    {
        using var sha = SHA256.Create();
        var raw = $"{deviceId}|{phone}|{timestamp}|{direction}|{content}";
        var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(raw));
        return Convert.ToHexString(hash)[..24].ToLowerInvariant();
    }
}

public record RegisterGatewayRequest(string DeviceId, string PublicKeyPem);
public record UploadSmsRequest(string DeviceId, string EncryptedPayloadBase64);
public record SendSmsRequest(string DeviceId, string TargetPhone, string Content);

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
