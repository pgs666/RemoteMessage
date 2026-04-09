using System.Security.Cryptography;
using System.Text;

public sealed class ServerRuntimeSettings
{
    public string Password { get; }
    public string GatewayToken { get; }
    public string ClientToken { get; }
    public string AdminToken { get; }
    public int HttpsPort { get; }
    public int LogRetentionDays { get; }
    public long LogMaxBytes { get; }
    public int ApiLogRetentionDays { get; }
    public int MessageRetentionDays { get; }
    public long DatabaseMaxBytes { get; }
    public int MaintenanceIntervalMinutes { get; }
    public string ServerConfigFilePath { get; }
    public string LegacyPasswordFilePath { get; }

    private const int DefaultHttpsPort = 5001;
    private const int DefaultLogRetentionDays = 14;
    private const int DefaultLogMaxMb = 32;
    private const int DefaultApiLogRetentionDays = 30;
    private const int DefaultMessageRetentionDays = 0;
    private const int DefaultDatabaseMaxMb = 512;
    private const int DefaultMaintenanceIntervalMinutes = 60;

    public ServerRuntimeSettings()
    {
        var baseDir = RuntimeLayout.RuntimeDirectory;
        ServerConfigFilePath = Path.Combine(baseDir, "server.conf");
        LegacyPasswordFilePath = Path.Combine(baseDir, "password.conf");

        var config = LoadOrCreateConfig();
        Password = config.Password;
        GatewayToken = config.GatewayToken;
        ClientToken = config.ClientToken;
        AdminToken = config.AdminToken;
        HttpsPort = config.HttpsPort;
        LogRetentionDays = config.LogRetentionDays;
        LogMaxBytes = config.LogMaxBytes;
        ApiLogRetentionDays = config.ApiLogRetentionDays;
        MessageRetentionDays = config.MessageRetentionDays;
        DatabaseMaxBytes = config.DatabaseMaxBytes;
        MaintenanceIntervalMinutes = config.MaintenanceIntervalMinutes;
    }

    private (
        string Password,
        string GatewayToken,
        string ClientToken,
        string AdminToken,
        int HttpsPort,
        int LogRetentionDays,
        long LogMaxBytes,
        int ApiLogRetentionDays,
        int MessageRetentionDays,
        long DatabaseMaxBytes,
        int MaintenanceIntervalMinutes
    ) LoadOrCreateConfig()
    {
        if (!File.Exists(ServerConfigFilePath))
        {
            var legacyPassword = TryLoadLegacyPassword();
            var generatedPassword = string.IsNullOrWhiteSpace(legacyPassword)
                ? GenerateSecret()
                : legacyPassword!;
            var generatedGatewayToken = GenerateSecret();
            var generatedClientToken = GenerateSecret();
            var generatedAdminToken = GenerateSecret();
            WriteServerConfig(
                httpsPort: DefaultHttpsPort,
                password: generatedPassword,
                gatewayToken: generatedGatewayToken,
                clientToken: generatedClientToken,
                adminToken: generatedAdminToken,
                logRetentionDays: DefaultLogRetentionDays,
                logMaxMb: DefaultLogMaxMb,
                apiLogRetentionDays: DefaultApiLogRetentionDays,
                messageRetentionDays: DefaultMessageRetentionDays,
                dbMaxMb: DefaultDatabaseMaxMb,
                maintenanceIntervalMinutes: DefaultMaintenanceIntervalMinutes
            );
            return (
                generatedPassword,
                generatedGatewayToken,
                generatedClientToken,
                generatedAdminToken,
                DefaultHttpsPort,
                DefaultLogRetentionDays,
                MbToBytes(DefaultLogMaxMb),
                DefaultApiLogRetentionDays,
                DefaultMessageRetentionDays,
                MbToBytes(DefaultDatabaseMaxMb),
                DefaultMaintenanceIntervalMinutes
            );
        }

        var values = ParseKeyValueFile(ServerConfigFilePath);
        var changed = false;

        var password = ReadOrGenerateSecret(values, "password", ref changed);
        if (string.IsNullOrWhiteSpace(password))
        {
            var legacy = TryLoadLegacyPassword();
            password = string.IsNullOrWhiteSpace(legacy) ? GenerateSecret() : legacy!;
            changed = true;
        }

        var gatewayToken = ReadOrGenerateSecret(values, "gateway_token", ref changed);
        var clientToken = ReadOrGenerateSecret(values, "client_token", ref changed);
        var adminToken = ReadOrGenerateSecret(values, "admin_token", ref changed);

        var httpsPort = ParseIntInRange(values, "https_port", 1, 65535, DefaultHttpsPort, ref changed);
        var logRetentionDays = ParseIntInRange(values, "log_retention_days", 1, 3650, DefaultLogRetentionDays, ref changed);
        var logMaxMb = ParseIntInRange(values, "log_max_mb", 1, 4096, DefaultLogMaxMb, ref changed);
        var apiLogRetentionDays = ParseIntInRange(values, "api_log_retention_days", 1, 3650, DefaultApiLogRetentionDays, ref changed);
        var messageRetentionDays = ParseIntInRange(values, "message_retention_days", 0, 3650, DefaultMessageRetentionDays, ref changed);
        var dbMaxMb = ParseIntInRange(values, "db_max_mb", 1, 16384, DefaultDatabaseMaxMb, ref changed);
        var maintenanceIntervalMinutes = ParseIntInRange(values, "maintenance_interval_minutes", 5, 1440, DefaultMaintenanceIntervalMinutes, ref changed);

        if (changed)
        {
            WriteServerConfig(
                httpsPort: httpsPort,
                password: password,
                gatewayToken: gatewayToken,
                clientToken: clientToken,
                adminToken: adminToken,
                logRetentionDays: logRetentionDays,
                logMaxMb: logMaxMb,
                apiLogRetentionDays: apiLogRetentionDays,
                messageRetentionDays: messageRetentionDays,
                dbMaxMb: dbMaxMb,
                maintenanceIntervalMinutes: maintenanceIntervalMinutes
            );
        }

        return (
            password,
            gatewayToken,
            clientToken,
            adminToken,
            httpsPort,
            logRetentionDays,
            MbToBytes(logMaxMb),
            apiLogRetentionDays,
            messageRetentionDays,
            MbToBytes(dbMaxMb),
            maintenanceIntervalMinutes
        );
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

    private static Dictionary<string, string> ParseKeyValueFile(string path)
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

    private static string ReadOrGenerateSecret(Dictionary<string, string> values, string key, ref bool changed)
    {
        if (values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
        {
            return value;
        }

        changed = true;
        return GenerateSecret();
    }

    private static int ParseIntInRange(
        Dictionary<string, string> values,
        string key,
        int min,
        int max,
        int fallback,
        ref bool changed
    )
    {
        if (values.TryGetValue(key, out var raw) && int.TryParse(raw, out var parsed) && parsed >= min && parsed <= max)
        {
            return parsed;
        }

        changed = true;
        return fallback;
    }

    private void WriteServerConfig(
        int httpsPort,
        string password,
        string gatewayToken,
        string clientToken,
        string adminToken,
        int logRetentionDays,
        int logMaxMb,
        int apiLogRetentionDays,
        int messageRetentionDays,
        int dbMaxMb,
        int maintenanceIntervalMinutes
    )
    {
        var content = $"""
# RemoteMessage server.conf
# Generated on first start. Edit values and restart the service.
https_port={httpsPort}

# Legacy shared password fallback (kept for compatibility)
password={password}

# New segmented authentication tokens
gateway_token={gatewayToken}
client_token={clientToken}
admin_token={adminToken}

# File log retention
log_retention_days={logRetentionDays}
log_max_mb={logMaxMb}

# Database retention
api_log_retention_days={apiLogRetentionDays}
message_retention_days={messageRetentionDays}
db_max_mb={dbMaxMb}

# Maintenance loop interval
maintenance_interval_minutes={maintenanceIntervalMinutes}
""";

        File.WriteAllText(ServerConfigFilePath, content + "\n", new UTF8Encoding(false));
    }

    private static string GenerateSecret()
    {
        return Convert.ToBase64String(RandomNumberGenerator.GetBytes(24));
    }

    private static long MbToBytes(int mb)
    {
        return mb * 1024L * 1024L;
    }
}
