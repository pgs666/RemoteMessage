using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using QRCoder;

public static class OnboardingQrBootstrap
{
    private const string OnboardingTextFileName = "onboarding-qr.txt";
    private const string OnboardingScriptPs1 = "qrcode.ps1";
    private const string OnboardingScriptBat = "qrcode.bat";
    private const string OnboardingScriptSh = "qrcode.sh";

    public static void WriteFirstStartArtifacts(ServerRuntimeSettings settings, ILogger logger)
    {
        var runtimeDir = RuntimeLayout.RuntimeDirectory;
        var payload = BuildOnboardingPayload(settings);
        var qrText = BuildAsciiQr(payload);

        var output = new StringBuilder()
            .AppendLine("RemoteMessage onboarding QR")
            .AppendLine("Format: RMS1|serverBaseUrl|clientToken|gatewayToken")
            .AppendLine()
            .AppendLine(payload)
            .AppendLine()
            .AppendLine(qrText)
            .ToString();

        var onboardingTextPath = Path.Combine(runtimeDir, OnboardingTextFileName);
        File.WriteAllText(onboardingTextPath, output, new UTF8Encoding(false));
        WriteHelperScripts(runtimeDir, payload);

        Console.WriteLine();
        Console.WriteLine("==== RemoteMessage First-Start Onboarding QR ====");
        Console.WriteLine("Scan this QR from client/gateway to auto-fill server and token:");
        Console.WriteLine();
        Console.WriteLine(qrText);
        Console.WriteLine(payload);
        Console.WriteLine($"Saved: {onboardingTextPath}");
        Console.WriteLine("==================================================");
        Console.WriteLine();

        logger.LogInformation("First-start onboarding QR generated at {Path}", onboardingTextPath);
    }

    private static string BuildOnboardingPayload(ServerRuntimeSettings settings)
    {
        var serverBaseUrl = ResolveServerBaseUrl(settings.HttpsPort);
        return $"RMS1|{serverBaseUrl}|{settings.ClientToken}|{settings.GatewayToken}";
    }

    private static string ResolveServerBaseUrl(int httpsPort)
    {
        var overrideValue = Environment.GetEnvironmentVariable("REMOTE_MESSAGE_SERVER_BASE_URL")?.Trim();
        if (!string.IsNullOrWhiteSpace(overrideValue))
        {
            return overrideValue!;
        }

        var candidates = NetworkInterface.GetAllNetworkInterfaces()
            .Where(x => x.OperationalStatus == OperationalStatus.Up && x.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(x => x.GetIPProperties().UnicastAddresses)
            .Select(x => x.Address)
            .Where(x =>
                x.AddressFamily == AddressFamily.InterNetwork
                && !IPAddress.IsLoopback(x)
                && !x.ToString().StartsWith("169.254.", StringComparison.Ordinal))
            .Distinct()
            .OrderByDescending(IsPrivateIpv4)
            .ToList();

        var chosenAddress = candidates.FirstOrDefault() ?? IPAddress.Loopback;
        return $"https://{chosenAddress}:{httpsPort}";
    }

    private static bool IsPrivateIpv4(IPAddress ip)
    {
        var bytes = ip.GetAddressBytes();
        return bytes.Length == 4 && (
            bytes[0] == 10
            || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)
            || (bytes[0] == 192 && bytes[1] == 168));
    }

    private static string BuildAsciiQr(string payload)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
        var asciiQr = new AsciiQRCode(data);
        return asciiQr.GetGraphic(1, "##", "  ", true);
    }

    private static void WriteHelperScripts(string runtimeDir, string payload)
    {
        var safePayloadForPs1 = payload.Replace("'", "''", StringComparison.Ordinal);
        var safePayloadForSh = payload.Replace("'", "'\"'\"'", StringComparison.Ordinal);

        var ps1 = $"""
$payload = '{safePayloadForPs1}'
Write-Host "RemoteMessage onboarding payload:"
Write-Host $payload
Write-Host ""
Write-Host "If your terminal cannot render onboarding-qr.txt well,"
Write-Host "copy the payload above into any QR generator."
""";

        var bat = $"""
@echo off
set PAYLOAD={payload}
echo RemoteMessage onboarding payload:
echo %PAYLOAD%
echo.
echo If your terminal cannot render onboarding-qr.txt well,
echo copy the payload above into any QR generator.
""";

        var sh = $"""
#!/usr/bin/env sh
PAYLOAD='{safePayloadForSh}'
echo "RemoteMessage onboarding payload:"
echo "$PAYLOAD"
echo ""
echo "If your terminal cannot render onboarding-qr.txt well,"
echo "copy the payload above into any QR generator."
""";

        File.WriteAllText(Path.Combine(runtimeDir, OnboardingScriptPs1), ps1 + "\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(runtimeDir, OnboardingScriptBat), bat + "\n", new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(runtimeDir, OnboardingScriptSh), sh + "\n", new UTF8Encoding(false));
    }
}
