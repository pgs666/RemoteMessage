using System.Security.Cryptography;
using System.Text;

public static class ApiSupport
{
    public static string NormalizeDirection(string? direction)
    {
        var d = direction?.Trim().ToLowerInvariant();
        return d is "outbound" ? "outbound" : "inbound";
    }

    public static int? NormalizeSimSlotIndex(int? simSlotIndex)
    {
        return simSlotIndex is >= 0 and <= 7 ? simSlotIndex : null;
    }

    public static int? NormalizeSimCount(int? simCount)
    {
        return simCount is >= 1 and <= 8 ? simCount : null;
    }

    public static string? NormalizeSendStatus(string? status)
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

    public static string? NormalizeOptionalText(string? value, int maxLength)
    {
        var normalized = value?.Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return null;
        }

        return normalized.Length <= maxLength ? normalized : normalized[..maxLength];
    }

    public static string EncryptByPublicKey(string plainText, string publicPem)
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

    public static bool PasswordMatches(string? provided, string expected)
    {
        var left = Encoding.UTF8.GetBytes(provided ?? string.Empty);
        var right = Encoding.UTF8.GetBytes(expected ?? string.Empty);
        return left.Length == right.Length && CryptographicOperations.FixedTimeEquals(left, right);
    }

    public static IResult? ValidateRegisterGatewayRequest(RegisterGatewayRequest req)
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

    public static IResult? ValidateUploadSmsRequest(UploadSmsRequest req)
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

    public static IResult? ValidateGatewayPayload(GatewaySmsPayload payload)
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

    public static IResult? ValidateGatewaySimStateRequest(UpsertGatewaySimStateRequest req)
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

    public static IResult? ValidateGatewaySimProfile(GatewaySimProfilePayload profile)
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

    public static IResult? ValidatePinRequest(PinConversationRequest req)
    {
        return IsValidPhone(req.Phone)
            ? null
            : Results.BadRequest("phone required");
    }

    public static IResult? ValidateSendRequest(SendSmsRequest req)
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

    public static IResult? ValidateAckOutboundRequest(AckOutboundRequest req)
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

    public static IResult? ValidateOutboundStatusRequest(OutboundStatusUpdateRequest req)
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

    public static IResult? ValidateClearServerDataRequest(ClearServerDataRequest req)
    {
        return string.Equals(req.Confirm?.Trim(), "CLEAR_SERVER_DATA", StringComparison.Ordinal)
            ? null
            : Results.BadRequest("confirm invalid");
    }

    public static bool IsValidPhone(string? phone)
    {
        var normalized = phone?.Trim();
        return !string.IsNullOrWhiteSpace(normalized) && normalized.Length <= 64;
    }

    private static int GetMaxOaepSha256PlaintextSize(RSA rsa)
    {
        var keyBytes = rsa.KeySize / 8;
        var hashBytes = 32;
        return keyBytes - (2 * hashBytes) - 2;
    }
}
