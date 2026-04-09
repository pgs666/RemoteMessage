using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

public sealed class HttpsCertificateSettings
{
    public X509Certificate2 Certificate { get; }
    public string CerFilePath { get; }
    public string PfxFilePath { get; }

    public HttpsCertificateSettings()
    {
        var baseDir = RuntimeLayout.RuntimeDirectory;
        CerFilePath = Path.Combine(baseDir, "server-cert.cer");
        PfxFilePath = Path.Combine(baseDir, "server-cert.pfx");

        Certificate = LoadOrCreateCertificate();
    }

    private X509Certificate2 LoadOrCreateCertificate()
    {
        if (File.Exists(PfxFilePath))
        {
            try
            {
                var existingBytes = File.ReadAllBytes(PfxFilePath);
                var existing = LoadCertificateFromPfxBytes(existingBytes);
                EnsureCertificateFile(existing);
                return existing;
            }
            catch (CryptographicException)
            {
                // If the current account cannot access previously persisted key material,
                // regenerate cert files in place to keep startup self-healing.
                TryDeleteFile(PfxFilePath);
            }
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
        var exportable = LoadCertificateFromPfxBytes(cert.Export(X509ContentType.Pfx));
        File.WriteAllBytes(PfxFilePath, exportable.Export(X509ContentType.Pfx));
        EnsureCertificateFile(exportable);
        return exportable;
    }

    private static X509Certificate2 LoadCertificateFromPfxBytes(byte[] pfxBytes)
    {
        CryptographicException? lastError = null;
        foreach (var flags in PreferredKeyStorageFlags())
        {
            try
            {
                return new X509Certificate2(pfxBytes, string.Empty, flags);
            }
            catch (CryptographicException ex)
            {
                lastError = ex;
            }
        }

        throw lastError ?? new CryptographicException("Unable to load PFX certificate.");
    }

    private static IEnumerable<X509KeyStorageFlags> PreferredKeyStorageFlags()
    {
        if (OperatingSystem.IsWindows())
        {
            yield return X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet | X509KeyStorageFlags.PersistKeySet;
            yield return X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet;
            yield return X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet;
            yield return X509KeyStorageFlags.EphemeralKeySet;
            yield break;
        }

        yield return X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet;
        yield return X509KeyStorageFlags.EphemeralKeySet;
        yield return X509KeyStorageFlags.Exportable;
    }

    private void EnsureCertificateFile(X509Certificate2 certificate)
    {
        File.WriteAllText(CerFilePath, certificate.ExportCertificatePem(), new UTF8Encoding(false));
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Ignore cleanup failure; follow-up creation will surface any real write issues.
        }
    }
}
