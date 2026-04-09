using Microsoft.Data.Sqlite;

public sealed class SqliteRepository
{
    private const long OutboxLeaseTimeoutMs = 60_000;
    private const int CurrentSchemaVersion = 3;
    private const int MaintenanceDeleteBatchSize = 2_000;
    private readonly string _connectionString;
    public string DatabaseFilePath { get; }

    public SqliteRepository()
    {
        DatabaseFilePath = Path.Combine(RuntimeLayout.RuntimeDirectory, "server.db");
        _connectionString = new SqliteConnectionStringBuilder { DataSource = DatabaseFilePath }.ToString();
        EnsureSchema();
    }

    public bool InsertMessageIfNotExists(SmsPayload payload)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT OR IGNORE INTO messages(
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
)
VALUES(
    $id,$deviceId,$phone,$content,$timestamp,$direction,$simSlotIndex,$simPhoneNumber,$simCount,
    $sendStatus,$sendErrorCode,$sendErrorMessage,$updatedAt
);";
        cmd.Parameters.AddWithValue("$id", payload.Id);
        cmd.Parameters.AddWithValue("$deviceId", payload.DeviceId);
        cmd.Parameters.AddWithValue("$phone", payload.Phone);
        cmd.Parameters.AddWithValue("$content", payload.Content);
        cmd.Parameters.AddWithValue("$timestamp", payload.Timestamp);
        cmd.Parameters.AddWithValue("$direction", payload.Direction);
        cmd.Parameters.AddWithValue("$simSlotIndex", (object?)payload.SimSlotIndex ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$simPhoneNumber", (object?)payload.SimPhoneNumber ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$simCount", (object?)payload.SimCount ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$sendStatus", (object?)NormalizeSendStatusText(payload.SendStatus) ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$sendErrorCode", (object?)payload.SendErrorCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$sendErrorMessage", (object?)payload.SendErrorMessage ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$updatedAt", payload.UpdatedAt ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        return cmd.ExecuteNonQuery() > 0;
    }

    public IReadOnlyList<SmsPayload> QueryMessages(long? sinceTs, int limit, string? phone)
    {
        limit = Math.Clamp(limit, 1, 10000);
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        var where = new List<string> { "1=1" };

        if (sinceTs.HasValue)
        {
            where.Add("(timestamp >= $sinceTs OR updated_at >= $sinceTs)");
            cmd.Parameters.AddWithValue("$sinceTs", sinceTs.Value);
        }

        if (!string.IsNullOrWhiteSpace(phone))
        {
            where.Add("phone = $phone");
            cmd.Parameters.AddWithValue("$phone", phone);
        }

        cmd.CommandText = $@"
SELECT
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
FROM messages
WHERE {string.Join(" AND ", where)}
ORDER BY timestamp ASC
LIMIT $limit;";
        cmd.Parameters.AddWithValue("$limit", limit);

        var list = new List<SmsPayload>(Math.Min(limit, 1024));
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new SmsPayload(
                Id: reader.GetString(0),
                DeviceId: reader.GetString(1),
                Phone: reader.GetString(2),
                Content: reader.GetString(3),
                Timestamp: reader.GetInt64(4),
                Direction: reader.GetString(5),
                SimSlotIndex: reader.IsDBNull(6) ? null : reader.GetInt32(6),
                SimPhoneNumber: reader.IsDBNull(7) ? null : reader.GetString(7),
                SimCount: reader.IsDBNull(8) ? null : reader.GetInt32(8),
                SendStatus: reader.IsDBNull(9) ? null : reader.GetString(9),
                SendErrorCode: reader.IsDBNull(10) ? null : reader.GetInt32(10),
                SendErrorMessage: reader.IsDBNull(11) ? null : reader.GetString(11),
                UpdatedAt: reader.IsDBNull(12) ? null : reader.GetInt64(12)
            ));
        }

        return list;
    }

    public void SetPinned(string phone, bool pinned)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        if (pinned)
        {
            cmd.CommandText = "INSERT OR REPLACE INTO pinned_conversations(phone, pinned_at) VALUES($phone, $ts);";
            cmd.Parameters.AddWithValue("$phone", phone);
            cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        }
        else
        {
            cmd.CommandText = "DELETE FROM pinned_conversations WHERE phone = $phone;";
            cmd.Parameters.AddWithValue("$phone", phone);
        }

        cmd.ExecuteNonQuery();
    }

    public IReadOnlyList<string> GetPinnedPhones()
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT phone FROM pinned_conversations ORDER BY pinned_at DESC;";
        var list = new List<string>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(reader.GetString(0));
        }

        return list;
    }

    public void EnqueueOutbound(string deviceId, string encryptedPayloadBase64)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT INTO outbox(device_id, encrypted_payload_base64, created_at)
VALUES($deviceId, $payload, $ts);";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        cmd.Parameters.AddWithValue("$payload", encryptedPayloadBase64);
        cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        cmd.ExecuteNonQuery();
    }

    public void UpsertGateway(string deviceId, string publicKeyPem)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT INTO gateways(device_id, public_key_pem, updated_at, last_seen_at)
VALUES($deviceId, $pem, $ts, $ts)
ON CONFLICT(device_id) DO UPDATE SET
  public_key_pem = excluded.public_key_pem,
  updated_at = excluded.updated_at,
  last_seen_at = excluded.last_seen_at;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        cmd.Parameters.AddWithValue("$pem", publicKeyPem);
        cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        cmd.ExecuteNonQuery();
    }

    public bool TouchGatewayLastSeen(string deviceId)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
UPDATE gateways
SET last_seen_at = $ts
WHERE device_id = $deviceId;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        return cmd.ExecuteNonQuery() > 0;
    }

    public string? GetGatewayPublicKey(string deviceId)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT public_key_pem FROM gateways WHERE device_id = $deviceId LIMIT 1;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        var v = cmd.ExecuteScalar();
        return v?.ToString();
    }

    public IReadOnlyList<GatewaySummaryRecord> ListGateways(int limit, long onlineWindowMs)
    {
        limit = Math.Clamp(limit, 1, 2000);
        onlineWindowMs = Math.Clamp(onlineWindowMs, 5_000, 86_400_000);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
SELECT
    g.device_id,
    g.updated_at,
    g.last_seen_at,
    COALESCE((
        SELECT COUNT(1)
        FROM gateway_sim_profiles s
        WHERE s.device_id = g.device_id
    ), 0) AS sim_profile_count,
    COALESCE((
        SELECT COUNT(1)
        FROM outbox o
        WHERE o.device_id = g.device_id
    ), 0) AS pending_outbox_count,
    (
        SELECT MAX(m.timestamp)
        FROM messages m
        WHERE m.device_id = g.device_id
    ) AS last_message_timestamp
FROM gateways g
ORDER BY g.updated_at DESC
LIMIT $limit;";
        cmd.Parameters.AddWithValue("$limit", limit);

        var list = new List<GatewaySummaryRecord>(Math.Min(limit, 512));
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            long? lastSeenAt = reader.IsDBNull(2) ? null : reader.GetInt64(2);
            var isOnline = lastSeenAt.HasValue && now - lastSeenAt.Value <= onlineWindowMs;
            list.Add(new GatewaySummaryRecord(
                DeviceId: reader.GetString(0),
                UpdatedAt: reader.IsDBNull(1) ? 0 : reader.GetInt64(1),
                LastSeenAt: lastSeenAt,
                IsOnline: isOnline,
                SimProfileCount: reader.IsDBNull(3) ? 0 : reader.GetInt32(3),
                PendingOutboxCount: reader.IsDBNull(4) ? 0 : reader.GetInt32(4),
                LastMessageTimestamp: reader.IsDBNull(5) ? null : reader.GetInt64(5)
            ));
        }

        return list;
    }

    public GatewayOnlineStatusRecord? GetGatewayOnlineStatus(string deviceId, long onlineWindowMs)
    {
        onlineWindowMs = Math.Clamp(onlineWindowMs, 5_000, 86_400_000);
        var checkedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT last_seen_at FROM gateways WHERE device_id = $deviceId LIMIT 1;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);

        using var reader = cmd.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }

        long? lastSeenAt = reader.IsDBNull(0) ? null : reader.GetInt64(0);
        var isOnline = lastSeenAt.HasValue && checkedAt - lastSeenAt.Value <= onlineWindowMs;
        return new GatewayOnlineStatusRecord(
            DeviceId: deviceId,
            LastSeenAt: lastSeenAt,
            IsOnline: isOnline,
            OnlineWindowMs: onlineWindowMs,
            CheckedAt: checkedAt
        );
    }

    public void ReplaceGatewaySimProfiles(string deviceId, IReadOnlyList<GatewaySimProfilePayload> profiles)
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();

        using (var del = conn.CreateCommand())
        {
            del.Transaction = tx;
            del.CommandText = "DELETE FROM gateway_sim_profiles WHERE device_id = $deviceId;";
            del.Parameters.AddWithValue("$deviceId", deviceId);
            del.ExecuteNonQuery();
        }

        foreach (var profile in profiles)
        {
            using var insert = conn.CreateCommand();
            insert.Transaction = tx;
            insert.CommandText = @"
INSERT INTO gateway_sim_profiles(device_id, slot_index, subscription_id, display_name, phone_number, sim_count, updated_at)
VALUES($deviceId, $slotIndex, $subscriptionId, $displayName, $phoneNumber, $simCount, $updatedAt);";
            insert.Parameters.AddWithValue("$deviceId", deviceId);
            insert.Parameters.AddWithValue("$slotIndex", profile.SlotIndex);
            insert.Parameters.AddWithValue("$subscriptionId", (object?)profile.SubscriptionId ?? DBNull.Value);
            insert.Parameters.AddWithValue("$displayName", (object?)NormalizeProfileText(profile.DisplayName, 128) ?? DBNull.Value);
            insert.Parameters.AddWithValue("$phoneNumber", (object?)NormalizeProfileText(profile.PhoneNumber, 64) ?? DBNull.Value);
            insert.Parameters.AddWithValue("$simCount", NormalizeProfileSimCount(profile.SimCount, profiles.Count));
            insert.Parameters.AddWithValue("$updatedAt", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            insert.ExecuteNonQuery();
        }

        tx.Commit();
    }

    public IReadOnlyList<GatewaySimProfileRecord> GetGatewaySimProfiles(string deviceId)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
SELECT device_id, slot_index, subscription_id, display_name, phone_number, sim_count, updated_at
FROM gateway_sim_profiles
WHERE device_id = $deviceId
ORDER BY slot_index ASC;";
        cmd.Parameters.AddWithValue("$deviceId", deviceId);

        var list = new List<GatewaySimProfileRecord>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new GatewaySimProfileRecord(
                DeviceId: reader.GetString(0),
                SlotIndex: reader.GetInt32(1),
                SubscriptionId: reader.IsDBNull(2) ? null : reader.GetInt32(2),
                DisplayName: reader.IsDBNull(3) ? null : reader.GetString(3),
                PhoneNumber: reader.IsDBNull(4) ? null : reader.GetString(4),
                SimCount: reader.IsDBNull(5) ? 0 : reader.GetInt32(5),
                UpdatedAt: reader.IsDBNull(6) ? 0 : reader.GetInt64(6)
            ));
        }

        return list;
    }

    public GatewaySimProfileRecord? ResolveGatewaySimProfile(string deviceId, int? simSlotIndex)
    {
        var profiles = GetGatewaySimProfiles(deviceId);
        if (profiles.Count == 0)
        {
            return null;
        }

        if (simSlotIndex.HasValue)
        {
            return profiles.FirstOrDefault(x => x.SlotIndex == simSlotIndex.Value);
        }

        return profiles.Count == 1 ? profiles[0] : null;
    }

    public void InsertApiLog(string method, string path, int statusCode, string remoteIp, long durationMs)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
INSERT INTO api_logs(method, path, status_code, remote_ip, duration_ms, created_at)
VALUES($method, $path, $status, $ip, $duration, $ts);";
        cmd.Parameters.AddWithValue("$method", method);
        cmd.Parameters.AddWithValue("$path", path);
        cmd.Parameters.AddWithValue("$status", statusCode);
        cmd.Parameters.AddWithValue("$ip", remoteIp);
        cmd.Parameters.AddWithValue("$duration", durationMs);
        cmd.Parameters.AddWithValue("$ts", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        cmd.ExecuteNonQuery();
    }

    public PendingOutbound? LeaseNextOutbound(string deviceId)
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var leaseExpiredBefore = now - OutboxLeaseTimeoutMs;
        using var select = conn.CreateCommand();
        select.Transaction = tx;
        select.CommandText = @"
SELECT id, device_id, encrypted_payload_base64
FROM outbox
WHERE device_id = $deviceId
  AND (lease_token IS NULL OR leased_at IS NULL OR leased_at <= $leaseExpiredBefore)
ORDER BY id ASC
LIMIT 1;";
        select.Parameters.AddWithValue("$deviceId", deviceId);
        select.Parameters.AddWithValue("$leaseExpiredBefore", leaseExpiredBefore);

        using var reader = select.ExecuteReader();
        if (!reader.Read())
        {
            tx.Commit();
            return null;
        }

        var id = reader.GetInt64(0);
        var leaseToken = Guid.NewGuid().ToString("N");
        var item = new PendingOutbound
        {
            OutboxId = id,
            AckToken = leaseToken,
            DeviceId = reader.GetString(1),
            EncryptedPayloadBase64 = reader.GetString(2)
        };
        reader.Close();

        using var lease = conn.CreateCommand();
        lease.Transaction = tx;
        lease.CommandText = @"
UPDATE outbox
SET lease_token = $leaseToken, leased_at = $leasedAt
WHERE id = $id
  AND device_id = $deviceId
  AND (lease_token IS NULL OR leased_at IS NULL OR leased_at <= $leaseExpiredBefore);";
        lease.Parameters.AddWithValue("$leaseToken", leaseToken);
        lease.Parameters.AddWithValue("$leasedAt", now);
        lease.Parameters.AddWithValue("$id", id);
        lease.Parameters.AddWithValue("$deviceId", deviceId);
        lease.Parameters.AddWithValue("$leaseExpiredBefore", leaseExpiredBefore);
        var leased = lease.ExecuteNonQuery();
        if (leased <= 0)
        {
            tx.Rollback();
            return null;
        }

        tx.Commit();
        return item;
    }

    public bool AckOutbound(string deviceId, long outboxId, string ackToken)
    {
        using var conn = Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
DELETE FROM outbox
WHERE id = $outboxId
  AND device_id = $deviceId
  AND lease_token = $ackToken;";
        cmd.Parameters.AddWithValue("$outboxId", outboxId);
        cmd.Parameters.AddWithValue("$deviceId", deviceId);
        cmd.Parameters.AddWithValue("$ackToken", ackToken);
        return cmd.ExecuteNonQuery() > 0;
    }

    public bool UpsertOutboundStatus(OutboundStatusUpdateRequest req)
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();

        using var update = conn.CreateCommand();
        update.Transaction = tx;
        update.CommandText = @"
UPDATE messages
SET send_status = $sendStatus,
    send_error_code = $sendErrorCode,
    send_error_message = $sendErrorMessage,
    updated_at = $updatedAt,
    sim_slot_index = COALESCE($simSlotIndex, sim_slot_index),
    sim_phone_number = COALESCE($simPhoneNumber, sim_phone_number),
    sim_count = COALESCE($simCount, sim_count)
WHERE id = $id;";
        update.Parameters.AddWithValue("$sendStatus", req.Status);
        update.Parameters.AddWithValue("$sendErrorCode", (object?)req.ErrorCode ?? DBNull.Value);
        update.Parameters.AddWithValue("$sendErrorMessage", (object?)req.ErrorMessage ?? DBNull.Value);
        update.Parameters.AddWithValue("$updatedAt", req.Timestamp);
        update.Parameters.AddWithValue("$simSlotIndex", (object?)req.SimSlotIndex ?? DBNull.Value);
        update.Parameters.AddWithValue("$simPhoneNumber", (object?)req.SimPhoneNumber ?? DBNull.Value);
        update.Parameters.AddWithValue("$simCount", (object?)req.SimCount ?? DBNull.Value);
        update.Parameters.AddWithValue("$id", req.MessageId);
        var affected = update.ExecuteNonQuery();

        if (affected <= 0)
        {
            using var insert = conn.CreateCommand();
            insert.Transaction = tx;
            insert.CommandText = @"
INSERT OR IGNORE INTO messages(
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
)
VALUES(
    $id, $deviceId, $phone, $content, $timestamp, 'outbound', $simSlotIndex, $simPhoneNumber, $simCount,
    $sendStatus, $sendErrorCode, $sendErrorMessage, $updatedAt
);";
            insert.Parameters.AddWithValue("$id", req.MessageId);
            insert.Parameters.AddWithValue("$deviceId", req.DeviceId);
            insert.Parameters.AddWithValue("$phone", req.TargetPhone);
            insert.Parameters.AddWithValue("$content", req.Content ?? string.Empty);
            insert.Parameters.AddWithValue("$timestamp", req.Timestamp);
            insert.Parameters.AddWithValue("$simSlotIndex", (object?)req.SimSlotIndex ?? DBNull.Value);
            insert.Parameters.AddWithValue("$simPhoneNumber", (object?)req.SimPhoneNumber ?? DBNull.Value);
            insert.Parameters.AddWithValue("$simCount", (object?)req.SimCount ?? DBNull.Value);
            insert.Parameters.AddWithValue("$sendStatus", req.Status);
            insert.Parameters.AddWithValue("$sendErrorCode", (object?)req.ErrorCode ?? DBNull.Value);
            insert.Parameters.AddWithValue("$sendErrorMessage", (object?)req.ErrorMessage ?? DBNull.Value);
            insert.Parameters.AddWithValue("$updatedAt", req.Timestamp);
            affected = insert.ExecuteNonQuery();
        }

        tx.Commit();
        return affected > 0;
    }

    public ServerDataClearResult ClearServerData()
    {
        using var conn = Open();
        using var tx = conn.BeginTransaction();

        var messagesCleared = DeleteAllFrom(conn, tx, "messages");
        var outboxCleared = DeleteAllFrom(conn, tx, "outbox");
        var pinnedConversationsCleared = DeleteAllFrom(conn, tx, "pinned_conversations");
        var gatewaySimProfilesCleared = DeleteAllFrom(conn, tx, "gateway_sim_profiles");
        var apiLogsCleared = DeleteAllFrom(conn, tx, "api_logs");

        tx.Commit();
        return new ServerDataClearResult(
            MessagesCleared: messagesCleared,
            OutboxCleared: outboxCleared,
            PinnedConversationsCleared: pinnedConversationsCleared,
            GatewaySimProfilesCleared: gatewaySimProfilesCleared,
            ApiLogsCleared: apiLogsCleared
        );
    }

    public DatabaseMaintenanceResult RunMaintenance(ServerRuntimeSettings settings)
    {
        var apiLogsDeleted = 0;
        var messagesDeleted = 0;
        var outboxDeleted = 0;
        var orphanPinsDeleted = 0;
        var vacuumed = false;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        using var conn = Open();
        using (var tx = conn.BeginTransaction())
        {
            if (settings.ApiLogRetentionDays > 0)
            {
                var cutoff = now - TimeSpan.FromDays(settings.ApiLogRetentionDays).TotalMilliseconds;
                apiLogsDeleted += DeleteByTimestamp(conn, tx, "api_logs", "created_at", (long)cutoff);
            }

            if (settings.MessageRetentionDays > 0)
            {
                var cutoff = now - TimeSpan.FromDays(settings.MessageRetentionDays).TotalMilliseconds;
                messagesDeleted += DeleteMessagesOlderThan(conn, tx, (long)cutoff);
            }

            orphanPinsDeleted += DeleteOrphanPinnedConversations(conn, tx);
            tx.Commit();
        }

        var dbBytesBeforeTrim = GetDatabaseBytes(conn);
        if (dbBytesBeforeTrim > settings.DatabaseMaxBytes)
        {
            var trim = TrimDatabaseBySize(conn, settings.DatabaseMaxBytes);
            apiLogsDeleted += trim.ApiLogsDeleted;
            messagesDeleted += trim.MessagesDeleted;
            outboxDeleted += trim.OutboxDeleted;
            orphanPinsDeleted += trim.OrphanPinsDeleted;
            vacuumed = trim.DatabaseVacuumed;
        }

        return new DatabaseMaintenanceResult(
            ApiLogsDeleted: apiLogsDeleted,
            MessagesDeleted: messagesDeleted,
            OutboxDeleted: outboxDeleted,
            OrphanPinsDeleted: orphanPinsDeleted,
            DatabaseVacuumed: vacuumed,
            DatabaseBytes: GetDatabaseBytes(conn)
        );
    }

    private SqliteConnection Open()
    {
        var conn = OpenRaw();
        EnsureSchemaUpToDate(conn);
        return conn;
    }

    private SqliteConnection OpenRaw()
    {
        var conn = new SqliteConnection(_connectionString);
        conn.Open();
        using var pragma = conn.CreateCommand();
        pragma.CommandText = "PRAGMA busy_timeout = 5000;";
        pragma.ExecuteNonQuery();
        return conn;
    }

    private void EnsureSchema()
    {
        using var conn = OpenRaw();
        EnsureSchemaUpToDate(conn);
    }

    private void EnsureSchemaUpToDate(SqliteConnection conn)
    {
        var schemaVersion = GetSchemaVersion(conn);
        if (schemaVersion >= CurrentSchemaVersion && TableExists(conn, "messages") && TableExists(conn, "outbox"))
        {
            return;
        }

        EnsureSchema(conn);
        SetSchemaVersion(conn, CurrentSchemaVersion);
    }

    private int GetSchemaVersion(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA user_version;";
        var scalar = cmd.ExecuteScalar();
        return Convert.ToInt32(scalar ?? 0);
    }

    private void SetSchemaVersion(SqliteConnection conn, int schemaVersion)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"PRAGMA user_version = {schemaVersion};";
        cmd.ExecuteNonQuery();
    }

    private bool TableExists(SqliteConnection conn, string tableName)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT 1 FROM sqlite_master WHERE type='table' AND name = $name LIMIT 1;";
        cmd.Parameters.AddWithValue("$name", tableName);
        return cmd.ExecuteScalar() is not null;
    }

    private void EnsureSchema(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
CREATE TABLE IF NOT EXISTS messages(
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    phone TEXT NOT NULL,
    content TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    direction TEXT NOT NULL,
    sim_slot_index INTEGER,
    sim_phone_number TEXT,
    sim_count INTEGER,
    send_status TEXT,
    send_error_code INTEGER,
    send_error_message TEXT,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    encrypted_payload_base64 TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    lease_token TEXT,
    leased_at INTEGER
);

CREATE TABLE IF NOT EXISTS pinned_conversations(
    phone TEXT PRIMARY KEY,
    pinned_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS gateways(
    device_id TEXT PRIMARY KEY,
    public_key_pem TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    last_seen_at INTEGER
);

CREATE TABLE IF NOT EXISTS gateway_sim_profiles(
    device_id TEXT NOT NULL,
    slot_index INTEGER NOT NULL,
    subscription_id INTEGER,
    display_name TEXT,
    phone_number TEXT,
    sim_count INTEGER,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY(device_id, slot_index)
);

CREATE TABLE IF NOT EXISTS api_logs(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    remote_ip TEXT NOT NULL,
    duration_ms INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_phone_ts ON messages(phone, timestamp);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_gateway_sim_profiles_device_id ON gateway_sim_profiles(device_id);
CREATE INDEX IF NOT EXISTS idx_outbox_device_id ON outbox(device_id);
CREATE INDEX IF NOT EXISTS idx_api_logs_created_at ON api_logs(created_at);
";
        cmd.ExecuteNonQuery();
        EnsureColumns(conn);
    }

    private void EnsureColumns(SqliteConnection conn)
    {
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN sim_slot_index INTEGER;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN sim_phone_number TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN sim_count INTEGER;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN send_status TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN send_error_code INTEGER;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN send_error_message TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE messages ADD COLUMN updated_at INTEGER;");
        TryExecuteNonQuery(conn, "UPDATE messages SET updated_at = timestamp WHERE updated_at IS NULL OR updated_at <= 0;");
        TryExecuteNonQuery(conn, "CREATE INDEX IF NOT EXISTS idx_messages_updated_at ON messages(updated_at);");
        TryExecuteNonQuery(conn, "ALTER TABLE outbox ADD COLUMN lease_token TEXT;");
        TryExecuteNonQuery(conn, "ALTER TABLE outbox ADD COLUMN leased_at INTEGER;");
        TryExecuteNonQuery(conn, "CREATE INDEX IF NOT EXISTS idx_outbox_device_lease ON outbox(device_id, leased_at);");
        TryExecuteNonQuery(conn, "ALTER TABLE gateways ADD COLUMN last_seen_at INTEGER;");
        TryExecuteNonQuery(conn, "UPDATE gateways SET last_seen_at = updated_at WHERE last_seen_at IS NULL OR last_seen_at <= 0;");
        TryExecuteNonQuery(conn, "CREATE INDEX IF NOT EXISTS idx_gateways_last_seen_at ON gateways(last_seen_at);");
    }

    private void TryExecuteNonQuery(SqliteConnection conn, string sql)
    {
        try
        {
            using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            cmd.ExecuteNonQuery();
        }
        catch (SqliteException)
        {
            // ignore when the column already exists
        }
    }

    private int DeleteAllFrom(SqliteConnection conn, SqliteTransaction tx, string tableName)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = $"DELETE FROM {tableName};";
        return cmd.ExecuteNonQuery();
    }

    private string? NormalizeProfileText(string? value, int maxLength)
    {
        var normalized = value?.Trim();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return null;
        }

        return normalized.Length <= maxLength ? normalized : normalized[..maxLength];
    }

    private int NormalizeProfileSimCount(int? simCount, int fallback)
    {
        if (simCount is >= 1 and <= 8)
        {
            return simCount.Value;
        }

        return Math.Clamp(fallback, 1, 8);
    }

    private string? NormalizeSendStatusText(string? status)
    {
        return status?.Trim().ToLowerInvariant() switch
        {
            "queued" => "queued",
            "dispatched" => "dispatched",
            "sent" => "sent",
            "failed" => "failed",
            _ => null
        };
    }

    private int DeleteByTimestamp(SqliteConnection conn, SqliteTransaction tx, string tableName, string timestampColumn, long cutoff)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = $"DELETE FROM {tableName} WHERE {timestampColumn} < $cutoff;";
        cmd.Parameters.AddWithValue("$cutoff", cutoff);
        return cmd.ExecuteNonQuery();
    }

    private int DeleteMessagesOlderThan(SqliteConnection conn, SqliteTransaction tx, long cutoff)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
DELETE FROM messages
WHERE COALESCE(updated_at, timestamp) < $cutoff;";
        cmd.Parameters.AddWithValue("$cutoff", cutoff);
        return cmd.ExecuteNonQuery();
    }

    private int DeleteOrphanPinnedConversations(SqliteConnection conn, SqliteTransaction tx)
    {
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
DELETE FROM pinned_conversations
WHERE phone NOT IN (SELECT DISTINCT phone FROM messages);";
        return cmd.ExecuteNonQuery();
    }

    private (int ApiLogsDeleted, int MessagesDeleted, int OutboxDeleted, int OrphanPinsDeleted, bool DatabaseVacuumed) TrimDatabaseBySize(SqliteConnection conn, long maxBytes)
    {
        var apiLogsDeleted = 0;
        var messagesDeleted = 0;
        var outboxDeleted = 0;
        var orphanPinsDeleted = 0;

        var currentBytes = GetDatabaseBytes(conn);
        while (currentBytes > maxBytes)
        {
            var deleted = DeleteOldestApiLogs(conn, MaintenanceDeleteBatchSize);
            apiLogsDeleted += deleted;
            if (deleted <= 0)
            {
                break;
            }

            currentBytes = GetDatabaseBytes(conn);
        }

        while (currentBytes > maxBytes)
        {
            var deleted = DeleteOldestMessages(conn, MaintenanceDeleteBatchSize);
            messagesDeleted += deleted;
            if (deleted <= 0)
            {
                break;
            }

            orphanPinsDeleted += DeleteOrphanPinnedConversations(conn);
            currentBytes = GetDatabaseBytes(conn);
        }

        if (apiLogsDeleted > 0 || messagesDeleted > 0 || orphanPinsDeleted > 0)
        {
            Vacuum(conn);
            return (
                ApiLogsDeleted: apiLogsDeleted,
                MessagesDeleted: messagesDeleted,
                OutboxDeleted: outboxDeleted,
                OrphanPinsDeleted: orphanPinsDeleted,
                DatabaseVacuumed: true
            );
        }

        return (
            ApiLogsDeleted: apiLogsDeleted,
            MessagesDeleted: messagesDeleted,
            OutboxDeleted: outboxDeleted,
            OrphanPinsDeleted: orphanPinsDeleted,
            DatabaseVacuumed: false
        );
    }

    private int DeleteOldestApiLogs(SqliteConnection conn, int batchSize)
    {
        using var tx = conn.BeginTransaction();
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
DELETE FROM api_logs
WHERE id IN (
    SELECT id
    FROM api_logs
    ORDER BY created_at ASC, id ASC
    LIMIT $limit
);";
        cmd.Parameters.AddWithValue("$limit", Math.Max(1, batchSize));
        var deleted = cmd.ExecuteNonQuery();
        tx.Commit();
        return deleted;
    }

    private int DeleteOldestMessages(SqliteConnection conn, int batchSize)
    {
        using var tx = conn.BeginTransaction();
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
DELETE FROM messages
WHERE id IN (
    SELECT id
    FROM messages
    ORDER BY COALESCE(updated_at, timestamp) ASC, timestamp ASC, id ASC
    LIMIT $limit
);";
        cmd.Parameters.AddWithValue("$limit", Math.Max(1, batchSize));
        var deleted = cmd.ExecuteNonQuery();
        tx.Commit();
        return deleted;
    }

    private int DeleteOrphanPinnedConversations(SqliteConnection conn)
    {
        using var tx = conn.BeginTransaction();
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
DELETE FROM pinned_conversations
WHERE phone NOT IN (SELECT DISTINCT phone FROM messages);";
        var deleted = cmd.ExecuteNonQuery();
        tx.Commit();
        return deleted;
    }

    private long GetDatabaseBytes(SqliteConnection conn)
    {
        using var pageCountCmd = conn.CreateCommand();
        pageCountCmd.CommandText = "PRAGMA page_count;";
        var pageCount = Convert.ToInt64(pageCountCmd.ExecuteScalar() ?? 0L);

        using var pageSizeCmd = conn.CreateCommand();
        pageSizeCmd.CommandText = "PRAGMA page_size;";
        var pageSize = Convert.ToInt64(pageSizeCmd.ExecuteScalar() ?? 0L);

        return Math.Max(0L, pageCount * pageSize);
    }

    private void Vacuum(SqliteConnection conn)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "VACUUM;";
        cmd.ExecuteNonQuery();
    }
}

public sealed record DatabaseMaintenanceResult(
    int ApiLogsDeleted,
    int MessagesDeleted,
    int OutboxDeleted,
    int OrphanPinsDeleted,
    bool DatabaseVacuumed,
    long DatabaseBytes
)
{
    public bool HasChanges =>
        ApiLogsDeleted > 0
        || MessagesDeleted > 0
        || OutboxDeleted > 0
        || OrphanPinsDeleted > 0
        || DatabaseVacuumed;
}
