using System.Security.Cryptography;
using System.Text;

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
