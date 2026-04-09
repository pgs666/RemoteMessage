using System.Text.Json.Serialization;

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
public record ClearServerDataRequest(string? Confirm);
public record ServerDataClearResult(
    int MessagesCleared,
    int OutboxCleared,
    int PinnedConversationsCleared,
    int GatewaySimProfilesCleared,
    int ApiLogsCleared
);

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
public record GatewaySummaryRecord(
    string DeviceId,
    long UpdatedAt,
    long? LastSeenAt,
    bool IsOnline,
    int SimProfileCount,
    int PendingOutboxCount,
    long? LastMessageTimestamp
);
public record GatewayOnlineStatusRecord(
    string DeviceId,
    long? LastSeenAt,
    bool IsOnline,
    long OnlineWindowMs,
    long CheckedAt
);

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
