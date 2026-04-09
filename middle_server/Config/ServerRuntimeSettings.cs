using System.Security.Cryptography;
using System.Text;

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
