using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

public sealed class HttpsCertificateSettings
{
    private const int RootCertificateLifetimeYears = 10;
    private const int ServerCertificateLifetimeDays = 397;
    private const string ServerAuthOid = "1.3.6.1.5.5.7.3.1";

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
        if (TryLoadExistingCertificate(out var existingServerCertificate, out var existingTrustAnchor))
        {
            EnsureCertificateFile(existingTrustAnchor);
            existingTrustAnchor.Dispose();
            return existingServerCertificate;
        }

        TryDeleteFile(PfxFilePath);
        TryDeleteFile(CerFilePath);

        var generated = CreateCertificateChain();
        File.WriteAllBytes(PfxFilePath, generated.ServerCertificate.Export(X509ContentType.Pfx));
        EnsureCertificateFile(generated.TrustAnchorCertificate);
        generated.TrustAnchorCertificate.Dispose();
        return generated.ServerCertificate;
    }

    private bool TryLoadExistingCertificate(out X509Certificate2 serverCertificate, out X509Certificate2 trustAnchorCertificate)
    {
        serverCertificate = null!;
        trustAnchorCertificate = null!;

        if (!File.Exists(PfxFilePath) || !File.Exists(CerFilePath))
        {
            return false;
        }

        try
        {
            serverCertificate = LoadCertificateFromPfxBytes(File.ReadAllBytes(PfxFilePath));
            trustAnchorCertificate = LoadCertificateFromCertificateBytes(File.ReadAllBytes(CerFilePath));

            if (!IsServerCertificate(serverCertificate) || !IsTrustAnchorCertificate(trustAnchorCertificate) || !IsIssuedBy(serverCertificate, trustAnchorCertificate))
            {
                DisposeCertificates(ref serverCertificate, ref trustAnchorCertificate);
                return false;
            }

            return true;
        }
        catch (CryptographicException)
        {
            DisposeCertificates(ref serverCertificate, ref trustAnchorCertificate);
            return false;
        }
    }

    private static GeneratedCertificateChain CreateCertificateChain()
    {
        var hostName = Dns.GetHostName();
        var notBefore = DateTimeOffset.UtcNow.AddDays(-1);
        var rootNotAfter = notBefore.AddYears(RootCertificateLifetimeYears);
        var serverNotAfter = notBefore.AddDays(ServerCertificateLifetimeDays);

        using var rootRsa = RSA.Create(2048);
        var rootRequest = new CertificateRequest(
            $"CN=RemoteMessage Root CA - {hostName}",
            rootRsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1
        );
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        rootRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        rootRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(rootRequest.PublicKey, false));

        using var rootCertificate = rootRequest.CreateSelfSigned(notBefore, rootNotAfter);
        using var serverRsa = RSA.Create(2048);
        var serverRequest = new CertificateRequest(
            $"CN={hostName}",
            serverRsa,
            HashAlgorithmName.SHA256,
            RSASignaturePadding.Pkcs1
        );
        serverRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        serverRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        serverRequest.CertificateExtensions.Add(
            new X509EnhancedKeyUsageExtension(
                new OidCollection
                {
                    new(ServerAuthOid),
                },
                false
            )
        );
        serverRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(serverRequest.PublicKey, false));
        serverRequest.CertificateExtensions.Add(BuildSubjectAlternativeNameExtension(hostName));

        var serverCertificate = serverRequest
            .Create(rootCertificate, notBefore, serverNotAfter, CreateSerialNumber())
            .CopyWithPrivateKey(serverRsa);

        var exportableServerCertificate = LoadCertificateFromPfxBytes(serverCertificate.Export(X509ContentType.Pfx));
        var trustAnchorCertificate = LoadCertificateFromCertificateBytes(rootCertificate.Export(X509ContentType.Cert));
        serverCertificate.Dispose();

        return new GeneratedCertificateChain(exportableServerCertificate, trustAnchorCertificate);
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

    private static X509Certificate2 LoadCertificateFromCertificateBytes(byte[] certificateBytes) => new(certificateBytes);

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

    private static X509Extension BuildSubjectAlternativeNameExtension(string hostName)
    {
        var san = new SubjectAlternativeNameBuilder();
        san.AddDnsName("localhost");
        san.AddDnsName(hostName);

        try
        {
            var fqdn = Dns.GetHostEntry(hostName).HostName?.Trim();
            if (!string.IsNullOrWhiteSpace(fqdn) && !fqdn.Equals(hostName, StringComparison.OrdinalIgnoreCase))
            {
                san.AddDnsName(fqdn);
            }
        }
        catch (SocketException)
        {
            // FQDN resolution is best-effort only.
        }

        foreach (var address in GetServerIpAddresses())
        {
            san.AddIpAddress(address);
        }

        return san.Build();
    }

    private static IEnumerable<IPAddress> GetServerIpAddresses()
    {
        var addresses = new HashSet<IPAddress>
        {
            IPAddress.Loopback,
            IPAddress.IPv6Loopback,
        };

        try
        {
            foreach (var address in Dns.GetHostAddresses(Dns.GetHostName()))
            {
                if (IsSupportedAddress(address))
                {
                    addresses.Add(address);
                }
            }
        }
        catch (SocketException)
        {
            // Hostname DNS resolution is best-effort only.
        }

        foreach (var networkInterface in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (networkInterface.OperationalStatus != OperationalStatus.Up || networkInterface.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            foreach (var unicast in networkInterface.GetIPProperties().UnicastAddresses)
            {
                var address = unicast.Address;
                if (IsSupportedAddress(address))
                {
                    addresses.Add(address);
                }
            }
        }

        return addresses.OrderBy(x => x.AddressFamily == AddressFamily.InterNetwork ? 0 : 1).ThenBy(x => x.ToString(), StringComparer.Ordinal);
    }

    private static bool IsSupportedAddress(IPAddress address)
    {
        if (IPAddress.IsLoopback(address))
        {
            return true;
        }

        if (address.AddressFamily != AddressFamily.InterNetwork && address.AddressFamily != AddressFamily.InterNetworkV6)
        {
            return false;
        }

        if (address.IsIPv6LinkLocal || address.IsIPv6Multicast)
        {
            return false;
        }

        var text = address.ToString();
        return !text.StartsWith("169.254.", StringComparison.Ordinal);
    }

    private static byte[] CreateSerialNumber()
    {
        var serial = RandomNumberGenerator.GetBytes(16);
        serial[0] &= 0x7F;
        return serial;
    }

    private static bool IsTrustAnchorCertificate(X509Certificate2 certificate)
    {
        var basicConstraints = certificate.Extensions.OfType<X509BasicConstraintsExtension>().FirstOrDefault();
        var keyUsage = certificate.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault();
        return basicConstraints?.CertificateAuthority == true
            && keyUsage is not null
            && keyUsage.KeyUsages.HasFlag(X509KeyUsageFlags.KeyCertSign)
            && certificate.SubjectName.RawData.AsSpan().SequenceEqual(certificate.IssuerName.RawData);
    }

    private static bool IsServerCertificate(X509Certificate2 certificate)
    {
        if (!certificate.HasPrivateKey)
        {
            return false;
        }

        var basicConstraints = certificate.Extensions.OfType<X509BasicConstraintsExtension>().FirstOrDefault();
        if (basicConstraints?.CertificateAuthority == true)
        {
            return false;
        }

        var enhancedKeyUsage = certificate.Extensions.OfType<X509EnhancedKeyUsageExtension>().FirstOrDefault();
        return enhancedKeyUsage is not null
            && enhancedKeyUsage.EnhancedKeyUsages.Cast<Oid>().Any(x => x.Value == ServerAuthOid);
    }

    private static bool IsIssuedBy(X509Certificate2 certificate, X509Certificate2 issuerCertificate)
    {
        return certificate.IssuerName.RawData.AsSpan().SequenceEqual(issuerCertificate.SubjectName.RawData);
    }

    private void EnsureCertificateFile(X509Certificate2 certificate)
    {
        File.WriteAllBytes(CerFilePath, certificate.Export(X509ContentType.Cert));
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

    private static void DisposeCertificates(ref X509Certificate2 serverCertificate, ref X509Certificate2 trustAnchorCertificate)
    {
        serverCertificate?.Dispose();
        trustAnchorCertificate?.Dispose();
        serverCertificate = null!;
        trustAnchorCertificate = null!;
    }

    private sealed record GeneratedCertificateChain(
        X509Certificate2 ServerCertificate,
        X509Certificate2 TrustAnchorCertificate
    );
}
