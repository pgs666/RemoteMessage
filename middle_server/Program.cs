using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
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
        var payload = System.Text.Json.JsonSerializer.Deserialize<SmsPayload>(plain);
        if (payload is null)
        {
            return Results.BadRequest("invalid payload");
        }

        store.Inbox.Enqueue(payload with { Direction = "inbound" });
        return Results.Ok(new { ok = true });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { error = ex.Message });
    }
});

app.MapGet("/api/client/inbox", (MessageStore store) => Results.Ok(store.Inbox.ToArray()));

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

    return Results.Ok(new { ok = true });
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
    public ConcurrentQueue<SmsPayload> Inbox { get; } = new();
    public ConcurrentQueue<PendingOutbound> Outbox { get; set; } = new();
}

public record RegisterGatewayRequest(string DeviceId, string PublicKeyPem);
public record UploadSmsRequest(string DeviceId, string EncryptedPayloadBase64);
public record SendSmsRequest(string DeviceId, string TargetPhone, string Content);

public record SmsPayload(string Phone, string Content, long Timestamp, string Direction = "unknown");
public record OutboundInstruction(string TargetPhone, string Content);

public sealed class PendingOutbound
{
    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("encryptedPayloadBase64")]
    public string EncryptedPayloadBase64 { get; set; } = string.Empty;
}
