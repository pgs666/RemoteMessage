public static class RuntimeLayout
{
    public static string ExecutablePath { get; } = ResolveExecutablePath();
    public static string RuntimeDirectory { get; } = ResolveRuntimeDirectory();

    private static string ResolveExecutablePath()
    {
        var path = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(path))
        {
            return path;
        }

        path = System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
        if (!string.IsNullOrWhiteSpace(path))
        {
            return path;
        }

        return AppContext.BaseDirectory;
    }

    private static string ResolveRuntimeDirectory()
    {
        var path = ResolveExecutablePath();
        return Directory.Exists(path)
            ? path
            : Path.GetDirectoryName(path) ?? AppContext.BaseDirectory;
    }
}
