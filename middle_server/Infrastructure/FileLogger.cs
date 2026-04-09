using System.Text;

public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly string _logFilePath;
    private readonly object _writeLock = new();

    public FileLoggerProvider(string logFilePath)
    {
        _logFilePath = logFilePath;
        var directory = Path.GetDirectoryName(_logFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(_logFilePath, categoryName, _writeLock);

    public void Dispose()
    {
    }
}

public sealed class FileLogger : ILogger
{
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
    private readonly string _logFilePath;
    private readonly string _categoryName;
    private readonly object _writeLock;

    public FileLogger(string logFilePath, string categoryName, object writeLock)
    {
        _logFilePath = logFilePath;
        _categoryName = categoryName;
        _writeLock = writeLock;
    }

    public IDisposable BeginScope<TState>(TState state) where TState : notnull => NoopScope.Instance;

    public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel))
        {
            return;
        }

        var message = formatter(state, exception);
        if (string.IsNullOrWhiteSpace(message) && exception is null)
        {
            return;
        }

        var line = $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz}] {logLevel,-11} {_categoryName}: {Sanitize(message)}";
        if (exception is not null)
        {
            line += $" | {Sanitize(exception.ToString())}";
        }

        try
        {
            lock (_writeLock)
            {
                File.AppendAllText(_logFilePath, line + Environment.NewLine, Utf8NoBom);
            }
        }
        catch
        {
            // Logging must not crash the server process.
        }
    }

    private static string Sanitize(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        return value.Replace('\r', ' ').Replace('\n', ' ');
    }
}

public sealed class NoopScope : IDisposable
{
    public static readonly NoopScope Instance = new();

    private NoopScope()
    {
    }

    public void Dispose()
    {
    }
}
