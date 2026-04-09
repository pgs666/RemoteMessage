using System.Security.Cryptography;
using System.Text;

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
