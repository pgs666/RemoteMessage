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
            var existing = new X509Certificate2(PfxFilePath, string.Empty, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);
            EnsureCertificateFile(existing);
            return existing;
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
        var exportable = new X509Certificate2(cert.Export(X509ContentType.Pfx), string.Empty, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.MachineKeySet);
        File.WriteAllBytes(PfxFilePath, exportable.Export(X509ContentType.Pfx));
        EnsureCertificateFile(exportable);
        return exportable;
    }

    private void EnsureCertificateFile(X509Certificate2 certificate)
    {
        File.WriteAllText(CerFilePath, certificate.ExportCertificatePem(), new UTF8Encoding(false));
    }
}
