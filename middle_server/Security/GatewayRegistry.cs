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
