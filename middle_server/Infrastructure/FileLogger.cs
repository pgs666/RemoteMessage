using System.Text;

public sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly string _logFilePath;
    private readonly long _maxBytes;
    private readonly TimeSpan _retention;
    private readonly object _writeLock = new();

    public FileLoggerProvider(string logFilePath, long maxBytes, int retentionDays)
    {
        _logFilePath = logFilePath;
        _maxBytes = Math.Max(1L, maxBytes);
        _retention = TimeSpan.FromDays(Math.Max(1, retentionDays));
        var directory = Path.GetDirectoryName(_logFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(_logFilePath, categoryName, _maxBytes, _retention, _writeLock);

    public void Dispose()
    {
    }
}

public sealed class FileLogger : ILogger
{
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
    private readonly string _logFilePath;
    private readonly string _logDirectory;
    private readonly string _logFileBaseName;
    private readonly string _logFileExtension;
    private readonly string _categoryName;
    private readonly long _maxBytes;
    private readonly TimeSpan _retention;
    private readonly object _writeLock;
    private DateTimeOffset _lastCleanupAtUtc = DateTimeOffset.MinValue;

    public FileLogger(string logFilePath, string categoryName, long maxBytes, TimeSpan retention, object writeLock)
    {
        _logFilePath = logFilePath;
        _logDirectory = Path.GetDirectoryName(logFilePath) ?? Directory.GetCurrentDirectory();
        _logFileBaseName = Path.GetFileNameWithoutExtension(logFilePath);
        _logFileExtension = Path.GetExtension(logFilePath);
        _categoryName = categoryName;
        _maxBytes = Math.Max(1L, maxBytes);
        _retention = retention <= TimeSpan.Zero ? TimeSpan.FromDays(1) : retention;
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
                RotateIfNeededLocked();
                File.AppendAllText(_logFilePath, line + Environment.NewLine, Utf8NoBom);
                CleanupArchivesLocked();
            }
        }
        catch
        {
            // Logging must not crash the server process.
        }
    }

    private void RotateIfNeededLocked()
    {
        try
        {
            var info = new FileInfo(_logFilePath);
            if (!info.Exists || info.Length < _maxBytes)
            {
                return;
            }

            Directory.CreateDirectory(_logDirectory);
            var timestamp = DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmssfff");
            var baseArchiveName = string.IsNullOrWhiteSpace(_logFileExtension)
                ? $"{_logFileBaseName}-{timestamp}"
                : $"{_logFileBaseName}-{timestamp}{_logFileExtension}";
            var archivePath = Path.Combine(_logDirectory, baseArchiveName);
            var suffix = 1;
            while (File.Exists(archivePath))
            {
                var candidateName = string.IsNullOrWhiteSpace(_logFileExtension)
                    ? $"{_logFileBaseName}-{timestamp}-{suffix:00}"
                    : $"{_logFileBaseName}-{timestamp}-{suffix:00}{_logFileExtension}";
                archivePath = Path.Combine(_logDirectory, candidateName);
                suffix++;
            }

            File.Move(_logFilePath, archivePath);
        }
        catch
        {
            // Rotation errors should never fail normal log write.
        }
    }

    private void CleanupArchivesLocked()
    {
        try
        {
            var now = DateTimeOffset.UtcNow;
            if (now - _lastCleanupAtUtc < TimeSpan.FromMinutes(1))
            {
                return;
            }

            _lastCleanupAtUtc = now;
            Directory.CreateDirectory(_logDirectory);
            var archivePattern = string.IsNullOrWhiteSpace(_logFileExtension)
                ? $"{_logFileBaseName}-*"
                : $"{_logFileBaseName}-*{_logFileExtension}";
            var cutoffUtc = now - _retention;
            foreach (var path in Directory.EnumerateFiles(_logDirectory, archivePattern, SearchOption.TopDirectoryOnly))
            {
                var fileName = Path.GetFileName(path);
                if (!fileName.StartsWith(_logFileBaseName + "-", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var lastWriteUtc = File.GetLastWriteTimeUtc(path);
                if (lastWriteUtc <= cutoffUtc.UtcDateTime)
                {
                    File.Delete(path);
                }
            }
        }
        catch
        {
            // Cleanup should be best effort only.
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
