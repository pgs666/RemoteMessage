use std::{path::PathBuf, time::Duration};

use anyhow::Context;
use rusqlite::{OptionalExtension, params};

use crate::{
    config::ServerRuntimeSettings,
    models::{
        DatabaseMaintenanceResult, GatewayOnlineStatusRecord, GatewaySimProfilePayload,
        GatewaySimProfileRecord, GatewaySummaryRecord, OutboundStatusUpdateRequest,
        PendingOutbound, ServerDataClearResult, SmsPayload,
    },
    runtime::{now_millis, runtime_directory},
};

const OUTBOX_LEASE_TIMEOUT_MS: i64 = 60_000;
const CURRENT_SCHEMA_VERSION: i32 = 3;
const MAINTENANCE_DELETE_BATCH_SIZE: i32 = 2_000;

#[derive(Clone)]
pub struct SqliteRepository {
    database_file_path: PathBuf,
}

impl SqliteRepository {
    pub fn new() -> anyhow::Result<Self> {
        let repo = Self {
            database_file_path: runtime_directory().join("server.db"),
        };
        repo.ensure_schema()?;
        Ok(repo)
    }

    pub fn database_file_path(&self) -> &PathBuf {
        &self.database_file_path
    }

    pub fn insert_message_if_not_exists(&self, payload: &SmsPayload) -> anyhow::Result<bool> {
        let conn = self.open()?;
        let affected = conn.execute(
            "\
INSERT OR IGNORE INTO messages(
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
)
VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13);",
            params![
                payload.id,
                payload.device_id,
                payload.phone,
                payload.content,
                payload.timestamp,
                payload.direction,
                payload.sim_slot_index,
                payload.sim_phone_number,
                payload.sim_count,
                normalize_send_status_text(payload.send_status.as_deref()),
                payload.send_error_code,
                payload.send_error_message,
                payload.updated_at.unwrap_or_else(now_millis),
            ],
        )?;
        Ok(affected > 0)
    }

    pub fn query_messages(
        &self,
        since_ts: Option<i64>,
        limit: Option<i32>,
        phone: Option<String>,
    ) -> anyhow::Result<Vec<SmsPayload>> {
        let limit = limit.unwrap_or(5000).clamp(1, 10000);
        let normalized_phone = phone.filter(|value| !value.trim().is_empty());
        let conn = self.open()?;
        let mut stmt = conn.prepare(
            "\
SELECT
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
FROM messages
WHERE (?1 IS NULL OR timestamp >= ?1 OR updated_at >= ?1)
  AND (?2 IS NULL OR phone = ?2)
ORDER BY timestamp ASC
LIMIT ?3;",
        )?;
        let rows = stmt.query_map(params![since_ts, normalized_phone, limit], read_sms_payload)?;
        collect_rows(rows)
    }

    pub fn set_pinned(&self, phone: &str, pinned: bool) -> anyhow::Result<()> {
        let conn = self.open()?;
        if pinned {
            conn.execute(
                "INSERT OR REPLACE INTO pinned_conversations(phone, pinned_at) VALUES(?1, ?2);",
                params![phone, now_millis()],
            )?;
        } else {
            conn.execute(
                "DELETE FROM pinned_conversations WHERE phone = ?1;",
                params![phone],
            )?;
        }
        Ok(())
    }

    pub fn get_pinned_phones(&self) -> anyhow::Result<Vec<String>> {
        let conn = self.open()?;
        let mut stmt =
            conn.prepare("SELECT phone FROM pinned_conversations ORDER BY pinned_at DESC;")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        collect_rows(rows)
    }

    pub fn enqueue_outbound(
        &self,
        device_id: &str,
        encrypted_payload_base64: &str,
    ) -> anyhow::Result<()> {
        let conn = self.open()?;
        conn.execute(
            "INSERT INTO outbox(device_id, encrypted_payload_base64, created_at) VALUES(?1, ?2, ?3);",
            params![device_id, encrypted_payload_base64, now_millis()],
        )?;
        Ok(())
    }

    pub fn upsert_gateway(&self, device_id: &str, public_key_pem: &str) -> anyhow::Result<()> {
        let conn = self.open()?;
        let ts = now_millis();
        conn.execute(
            "\
INSERT INTO gateways(device_id, public_key_pem, updated_at, last_seen_at)
VALUES(?1, ?2, ?3, ?3)
ON CONFLICT(device_id) DO UPDATE SET
  public_key_pem = excluded.public_key_pem,
  updated_at = excluded.updated_at,
  last_seen_at = excluded.last_seen_at;",
            params![device_id, public_key_pem, ts],
        )?;
        Ok(())
    }

    pub fn touch_gateway_last_seen(&self, device_id: &str) -> anyhow::Result<bool> {
        let conn = self.open()?;
        let affected = conn.execute(
            "UPDATE gateways SET last_seen_at = ?1 WHERE device_id = ?2;",
            params![now_millis(), device_id],
        )?;
        Ok(affected > 0)
    }

    pub fn get_gateway_public_key(&self, device_id: &str) -> anyhow::Result<Option<String>> {
        let conn = self.open()?;
        conn.query_row(
            "SELECT public_key_pem FROM gateways WHERE device_id = ?1 LIMIT 1;",
            params![device_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn list_gateways(
        &self,
        limit: Option<i32>,
        online_window_ms: i64,
    ) -> anyhow::Result<Vec<GatewaySummaryRecord>> {
        let limit = limit.unwrap_or(200).clamp(1, 2000);
        let online_window_ms = online_window_ms.clamp(5_000, 86_400_000);
        let now = now_millis();
        let conn = self.open()?;
        let mut stmt = conn.prepare(
            "\
SELECT
    g.device_id,
    g.updated_at,
    g.last_seen_at,
    COALESCE((SELECT COUNT(1) FROM gateway_sim_profiles s WHERE s.device_id = g.device_id), 0) AS sim_profile_count,
    COALESCE((SELECT COUNT(1) FROM outbox o WHERE o.device_id = g.device_id), 0) AS pending_outbox_count,
    (SELECT MAX(m.timestamp) FROM messages m WHERE m.device_id = g.device_id) AS last_message_timestamp
FROM gateways g
ORDER BY g.updated_at DESC
LIMIT ?1;",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            let last_seen_at: Option<i64> = row.get(2)?;
            Ok(GatewaySummaryRecord {
                device_id: row.get(0)?,
                updated_at: row.get::<_, Option<i64>>(1)?.unwrap_or(0),
                last_seen_at,
                is_online: last_seen_at.is_some_and(|ts| now - ts <= online_window_ms),
                sim_profile_count: row.get::<_, Option<i32>>(3)?.unwrap_or(0),
                pending_outbox_count: row.get::<_, Option<i32>>(4)?.unwrap_or(0),
                last_message_timestamp: row.get(5)?,
            })
        })?;
        collect_rows(rows)
    }

    pub fn get_gateway_online_status(
        &self,
        device_id: &str,
        online_window_ms: i64,
    ) -> anyhow::Result<Option<GatewayOnlineStatusRecord>> {
        let online_window_ms = online_window_ms.clamp(5_000, 86_400_000);
        let checked_at = now_millis();
        let conn = self.open()?;
        let last_seen_at: Option<Option<i64>> = conn
            .query_row(
                "SELECT last_seen_at FROM gateways WHERE device_id = ?1 LIMIT 1;",
                params![device_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(last_seen_at.map(|last_seen_at| GatewayOnlineStatusRecord {
            device_id: device_id.to_owned(),
            last_seen_at,
            is_online: last_seen_at.is_some_and(|ts| checked_at - ts <= online_window_ms),
            online_window_ms,
            checked_at,
        }))
    }

    pub fn replace_gateway_sim_profiles(
        &self,
        device_id: &str,
        profiles: &[GatewaySimProfilePayload],
    ) -> anyhow::Result<()> {
        let mut conn = self.open()?;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM gateway_sim_profiles WHERE device_id = ?1;",
            params![device_id],
        )?;
        for profile in profiles {
            tx.execute(
                "\
INSERT INTO gateway_sim_profiles(device_id, slot_index, subscription_id, display_name, phone_number, sim_count, updated_at)
VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7);",
                params![
                    device_id,
                    profile.slot_index,
                    profile.subscription_id,
                    normalize_profile_text(profile.display_name.as_deref(), 128),
                    normalize_profile_text(profile.phone_number.as_deref(), 64),
                    normalize_profile_sim_count(profile.sim_count, profiles.len() as i32),
                    now_millis(),
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_gateway_sim_profiles(
        &self,
        device_id: &str,
    ) -> anyhow::Result<Vec<GatewaySimProfileRecord>> {
        let conn = self.open()?;
        let mut stmt = conn.prepare(
            "\
SELECT device_id, slot_index, subscription_id, display_name, phone_number, sim_count, updated_at
FROM gateway_sim_profiles
WHERE device_id = ?1
ORDER BY slot_index ASC;",
        )?;
        let rows = stmt.query_map(params![device_id], |row| {
            Ok(GatewaySimProfileRecord {
                device_id: row.get(0)?,
                slot_index: row.get(1)?,
                subscription_id: row.get(2)?,
                display_name: row.get(3)?,
                phone_number: row.get(4)?,
                sim_count: row.get::<_, Option<i32>>(5)?.unwrap_or(0),
                updated_at: row.get::<_, Option<i64>>(6)?.unwrap_or(0),
            })
        })?;
        collect_rows(rows)
    }

    pub fn resolve_gateway_sim_profile(
        &self,
        device_id: &str,
        sim_slot_index: Option<i32>,
    ) -> anyhow::Result<Option<GatewaySimProfileRecord>> {
        let profiles = self.get_gateway_sim_profiles(device_id)?;
        if profiles.is_empty() {
            return Ok(None);
        }
        if let Some(slot) = sim_slot_index {
            return Ok(profiles
                .into_iter()
                .find(|profile| profile.slot_index == slot));
        }
        Ok((profiles.len() == 1).then(|| profiles[0].clone()))
    }

    pub fn insert_api_log(
        &self,
        method: &str,
        path: &str,
        status_code: u16,
        remote_ip: &str,
        duration_ms: i64,
    ) {
        let Ok(conn) = self.open() else {
            return;
        };
        let _ = conn.execute(
            "INSERT INTO api_logs(method, path, status_code, remote_ip, duration_ms, created_at) VALUES(?1, ?2, ?3, ?4, ?5, ?6);",
            params![method, path, i32::from(status_code), remote_ip, duration_ms, now_millis()],
        );
    }

    pub fn lease_next_outbound(&self, device_id: &str) -> anyhow::Result<Option<PendingOutbound>> {
        let mut conn = self.open()?;
        let tx = conn.transaction()?;
        let now = now_millis();
        let lease_expired_before = now - OUTBOX_LEASE_TIMEOUT_MS;
        let selected: Option<(i64, String, String)> = {
            let mut stmt = tx.prepare(
                "\
SELECT id, device_id, encrypted_payload_base64
FROM outbox
WHERE device_id = ?1
  AND (lease_token IS NULL OR leased_at IS NULL OR leased_at <= ?2)
ORDER BY id ASC
LIMIT 1;",
            )?;
            stmt.query_row(params![device_id, lease_expired_before], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .optional()?
        };

        let Some((id, selected_device_id, encrypted_payload_base64)) = selected else {
            tx.commit()?;
            return Ok(None);
        };
        let lease_token = uuid::Uuid::new_v4().simple().to_string();
        let leased = tx.execute(
            "\
UPDATE outbox
SET lease_token = ?1, leased_at = ?2
WHERE id = ?3
  AND device_id = ?4
  AND (lease_token IS NULL OR leased_at IS NULL OR leased_at <= ?5);",
            params![lease_token, now, id, device_id, lease_expired_before],
        )?;
        if leased == 0 {
            tx.rollback()?;
            return Ok(None);
        }
        tx.commit()?;
        Ok(Some(PendingOutbound {
            outbox_id: id,
            ack_token: lease_token,
            device_id: selected_device_id,
            encrypted_payload_base64,
        }))
    }

    pub fn ack_outbound(
        &self,
        device_id: &str,
        outbox_id: i64,
        ack_token: &str,
    ) -> anyhow::Result<bool> {
        let conn = self.open()?;
        let affected = conn.execute(
            "DELETE FROM outbox WHERE id = ?1 AND device_id = ?2 AND lease_token = ?3;",
            params![outbox_id, device_id, ack_token],
        )?;
        Ok(affected > 0)
    }

    pub fn upsert_outbound_status(
        &self,
        req: &OutboundStatusUpdateRequest,
    ) -> anyhow::Result<bool> {
        let mut conn = self.open()?;
        let tx = conn.transaction()?;
        let affected = tx.execute(
            "\
UPDATE messages
SET send_status = ?1,
    send_error_code = ?2,
    send_error_message = ?3,
    updated_at = ?4,
    sim_slot_index = COALESCE(?5, sim_slot_index),
    sim_phone_number = COALESCE(?6, sim_phone_number),
    sim_count = COALESCE(?7, sim_count)
WHERE id = ?8;",
            params![
                req.status,
                req.error_code,
                req.error_message,
                req.timestamp,
                req.sim_slot_index,
                req.sim_phone_number,
                req.sim_count,
                req.message_id,
            ],
        )?;
        let mut final_affected = affected;
        if final_affected == 0 {
            final_affected = tx.execute(
                "\
INSERT OR IGNORE INTO messages(
    id, device_id, phone, content, timestamp, direction, sim_slot_index, sim_phone_number, sim_count,
    send_status, send_error_code, send_error_message, updated_at
)
VALUES(?1, ?2, ?3, ?4, ?5, 'outbound', ?6, ?7, ?8, ?9, ?10, ?11, ?12);",
                params![
                    req.message_id,
                    req.device_id,
                    req.target_phone,
                    req.content.clone().unwrap_or_default(),
                    req.timestamp,
                    req.sim_slot_index,
                    req.sim_phone_number,
                    req.sim_count,
                    req.status,
                    req.error_code,
                    req.error_message,
                    req.timestamp,
                ],
            )?;
        }
        tx.commit()?;
        Ok(final_affected > 0)
    }

    pub fn clear_server_data(&self) -> anyhow::Result<ServerDataClearResult> {
        let mut conn = self.open()?;
        let tx = conn.transaction()?;
        let result = ServerDataClearResult {
            messages_cleared: delete_all_from(&tx, "messages")?,
            outbox_cleared: delete_all_from(&tx, "outbox")?,
            pinned_conversations_cleared: delete_all_from(&tx, "pinned_conversations")?,
            gateway_sim_profiles_cleared: delete_all_from(&tx, "gateway_sim_profiles")?,
            api_logs_cleared: delete_all_from(&tx, "api_logs")?,
        };
        tx.commit()?;
        Ok(result)
    }

    pub fn run_maintenance(
        &self,
        settings: &ServerRuntimeSettings,
    ) -> anyhow::Result<DatabaseMaintenanceResult> {
        let mut api_logs_deleted = 0;
        let mut messages_deleted = 0;
        let outbox_deleted = 0;
        let mut orphan_pins_deleted = 0;
        let mut database_vacuumed = false;
        let now = now_millis();

        let mut conn = self.open()?;
        {
            let tx = conn.transaction()?;
            if settings.api_log_retention_days > 0 {
                let cutoff = now - i64::from(settings.api_log_retention_days) * 24 * 60 * 60 * 1000;
                api_logs_deleted += delete_by_timestamp(&tx, "api_logs", "created_at", cutoff)?;
            }
            if settings.message_retention_days > 0 {
                let cutoff = now - i64::from(settings.message_retention_days) * 24 * 60 * 60 * 1000;
                messages_deleted += delete_messages_older_than(&tx, cutoff)?;
            }
            orphan_pins_deleted += delete_orphan_pinned_conversations_tx(&tx)?;
            tx.commit()?;
        }

        let mut db_bytes = get_database_bytes(&conn)?;
        if db_bytes > settings.database_max_bytes {
            let trim = trim_database_by_size(&conn, settings.database_max_bytes)?;
            api_logs_deleted += trim.0;
            messages_deleted += trim.1;
            orphan_pins_deleted += trim.2;
            database_vacuumed = trim.3;
            db_bytes = get_database_bytes(&conn)?;
        }

        Ok(DatabaseMaintenanceResult {
            api_logs_deleted,
            messages_deleted,
            outbox_deleted,
            orphan_pins_deleted,
            database_vacuumed,
            database_bytes: db_bytes,
        })
    }

    fn open(&self) -> anyhow::Result<rusqlite::Connection> {
        let conn = self.open_raw()?;
        self.ensure_schema_up_to_date(&conn)?;
        Ok(conn)
    }

    fn open_raw(&self) -> anyhow::Result<rusqlite::Connection> {
        if let Some(parent) = self.database_file_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = rusqlite::Connection::open(&self.database_file_path)
            .with_context(|| format!("open sqlite {}", self.database_file_path.display()))?;
        conn.busy_timeout(Duration::from_millis(5000))?;
        Ok(conn)
    }

    fn ensure_schema(&self) -> anyhow::Result<()> {
        let conn = self.open_raw()?;
        self.ensure_schema_up_to_date(&conn)
    }

    fn ensure_schema_up_to_date(&self, conn: &rusqlite::Connection) -> anyhow::Result<()> {
        let schema_version = get_schema_version(conn)?;
        if schema_version >= CURRENT_SCHEMA_VERSION
            && table_exists(conn, "messages")?
            && table_exists(conn, "outbox")?
        {
            return Ok(());
        }
        ensure_schema(conn)?;
        set_schema_version(conn, CURRENT_SCHEMA_VERSION)?;
        Ok(())
    }
}

fn read_sms_payload(row: &rusqlite::Row<'_>) -> rusqlite::Result<SmsPayload> {
    Ok(SmsPayload {
        id: row.get(0)?,
        device_id: row.get(1)?,
        phone: row.get(2)?,
        content: row.get(3)?,
        timestamp: row.get(4)?,
        direction: row.get(5)?,
        sim_slot_index: row.get(6)?,
        sim_phone_number: row.get(7)?,
        sim_count: row.get(8)?,
        send_status: row.get(9)?,
        send_error_code: row.get(10)?,
        send_error_message: row.get(11)?,
        updated_at: row.get(12)?,
    })
}

fn collect_rows<T>(
    rows: rusqlite::MappedRows<'_, impl FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<T>>,
) -> anyhow::Result<Vec<T>> {
    let mut list = Vec::new();
    for row in rows {
        list.push(row?);
    }
    Ok(list)
}

fn get_schema_version(conn: &rusqlite::Connection) -> anyhow::Result<i32> {
    conn.query_row("PRAGMA user_version;", [], |row| row.get(0))
        .map_err(Into::into)
}

fn set_schema_version(conn: &rusqlite::Connection, schema_version: i32) -> anyhow::Result<()> {
    conn.execute(&format!("PRAGMA user_version = {schema_version};"), [])?;
    Ok(())
}

fn table_exists(conn: &rusqlite::Connection, table_name: &str) -> anyhow::Result<bool> {
    let exists: Option<i32> = conn
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?1 LIMIT 1;",
            params![table_name],
            |row| row.get(0),
        )
        .optional()?;
    Ok(exists.is_some())
}

fn ensure_schema(conn: &rusqlite::Connection) -> anyhow::Result<()> {
    conn.execute_batch(
        "\
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
",
    )?;
    ensure_columns(conn)
}

fn ensure_columns(conn: &rusqlite::Connection) -> anyhow::Result<()> {
    let statements = [
        "ALTER TABLE messages ADD COLUMN sim_slot_index INTEGER;",
        "ALTER TABLE messages ADD COLUMN sim_phone_number TEXT;",
        "ALTER TABLE messages ADD COLUMN sim_count INTEGER;",
        "ALTER TABLE messages ADD COLUMN send_status TEXT;",
        "ALTER TABLE messages ADD COLUMN send_error_code INTEGER;",
        "ALTER TABLE messages ADD COLUMN send_error_message TEXT;",
        "ALTER TABLE messages ADD COLUMN updated_at INTEGER;",
        "UPDATE messages SET updated_at = timestamp WHERE updated_at IS NULL OR updated_at <= 0;",
        "CREATE INDEX IF NOT EXISTS idx_messages_updated_at ON messages(updated_at);",
        "ALTER TABLE outbox ADD COLUMN lease_token TEXT;",
        "ALTER TABLE outbox ADD COLUMN leased_at INTEGER;",
        "CREATE INDEX IF NOT EXISTS idx_outbox_device_lease ON outbox(device_id, leased_at);",
        "ALTER TABLE gateways ADD COLUMN last_seen_at INTEGER;",
        "UPDATE gateways SET last_seen_at = updated_at WHERE last_seen_at IS NULL OR last_seen_at <= 0;",
        "CREATE INDEX IF NOT EXISTS idx_gateways_last_seen_at ON gateways(last_seen_at);",
    ];
    for sql in statements {
        let _ = conn.execute(sql, []);
    }
    Ok(())
}

fn delete_all_from(tx: &rusqlite::Transaction<'_>, table_name: &str) -> anyhow::Result<i32> {
    let affected = tx.execute(&format!("DELETE FROM {table_name};"), [])?;
    Ok(affected as i32)
}

fn delete_by_timestamp(
    tx: &rusqlite::Transaction<'_>,
    table_name: &str,
    timestamp_column: &str,
    cutoff: i64,
) -> anyhow::Result<i32> {
    let affected = tx.execute(
        &format!("DELETE FROM {table_name} WHERE {timestamp_column} < ?1;"),
        params![cutoff],
    )?;
    Ok(affected as i32)
}

fn delete_messages_older_than(tx: &rusqlite::Transaction<'_>, cutoff: i64) -> anyhow::Result<i32> {
    let affected = tx.execute(
        "DELETE FROM messages WHERE COALESCE(updated_at, timestamp) < ?1;",
        params![cutoff],
    )?;
    Ok(affected as i32)
}

fn delete_orphan_pinned_conversations_tx(tx: &rusqlite::Transaction<'_>) -> anyhow::Result<i32> {
    let affected = tx.execute(
        "DELETE FROM pinned_conversations WHERE phone NOT IN (SELECT DISTINCT phone FROM messages);",
        [],
    )?;
    Ok(affected as i32)
}

fn delete_orphan_pinned_conversations(conn: &rusqlite::Connection) -> anyhow::Result<i32> {
    let affected = conn.execute(
        "DELETE FROM pinned_conversations WHERE phone NOT IN (SELECT DISTINCT phone FROM messages);",
        [],
    )?;
    Ok(affected as i32)
}

fn trim_database_by_size(
    conn: &rusqlite::Connection,
    max_bytes: i64,
) -> anyhow::Result<(i32, i32, i32, bool)> {
    let mut api_logs_deleted = 0;
    let mut messages_deleted = 0;
    let mut orphan_pins_deleted = 0;
    let mut current_bytes = get_database_bytes(conn)?;

    while current_bytes > max_bytes {
        let deleted = delete_oldest_api_logs(conn, MAINTENANCE_DELETE_BATCH_SIZE)?;
        api_logs_deleted += deleted;
        if deleted <= 0 {
            break;
        }
        current_bytes = get_database_bytes(conn)?;
    }

    while current_bytes > max_bytes {
        let deleted = delete_oldest_messages(conn, MAINTENANCE_DELETE_BATCH_SIZE)?;
        messages_deleted += deleted;
        if deleted <= 0 {
            break;
        }
        orphan_pins_deleted += delete_orphan_pinned_conversations(conn)?;
        current_bytes = get_database_bytes(conn)?;
    }

    if api_logs_deleted > 0 || messages_deleted > 0 || orphan_pins_deleted > 0 {
        conn.execute("VACUUM;", [])?;
        return Ok((
            api_logs_deleted,
            messages_deleted,
            orphan_pins_deleted,
            true,
        ));
    }
    Ok((
        api_logs_deleted,
        messages_deleted,
        orphan_pins_deleted,
        false,
    ))
}

fn delete_oldest_api_logs(conn: &rusqlite::Connection, batch_size: i32) -> anyhow::Result<i32> {
    let affected = conn.execute(
        "\
DELETE FROM api_logs
WHERE id IN (
    SELECT id FROM api_logs ORDER BY created_at ASC, id ASC LIMIT ?1
);",
        params![batch_size.max(1)],
    )?;
    Ok(affected as i32)
}

fn delete_oldest_messages(conn: &rusqlite::Connection, batch_size: i32) -> anyhow::Result<i32> {
    let affected = conn.execute(
        "\
DELETE FROM messages
WHERE id IN (
    SELECT id FROM messages ORDER BY COALESCE(updated_at, timestamp) ASC, timestamp ASC, id ASC LIMIT ?1
);",
        params![batch_size.max(1)],
    )?;
    Ok(affected as i32)
}

fn get_database_bytes(conn: &rusqlite::Connection) -> anyhow::Result<i64> {
    let page_count: i64 = conn.query_row("PRAGMA page_count;", [], |row| row.get(0))?;
    let page_size: i64 = conn.query_row("PRAGMA page_size;", [], |row| row.get(0))?;
    Ok(page_count.saturating_mul(page_size).max(0))
}

fn normalize_profile_text(value: Option<&str>, max_length: usize) -> Option<String> {
    let normalized = value?.trim();
    if normalized.is_empty() {
        return None;
    }
    Some(truncate_chars(normalized, max_length))
}

fn normalize_profile_sim_count(sim_count: Option<i32>, fallback: i32) -> i32 {
    if let Some(value @ 1..=8) = sim_count {
        return value;
    }
    fallback.clamp(1, 8)
}

fn normalize_send_status_text(status: Option<&str>) -> Option<String> {
    match status?.trim().to_ascii_lowercase().as_str() {
        "queued" => Some("queued".to_owned()),
        "dispatched" => Some("dispatched".to_owned()),
        "sent" => Some("sent".to_owned()),
        "failed" => Some("failed".to_owned()),
        _ => None,
    }
}

fn truncate_chars(value: &str, max_length: usize) -> String {
    value.chars().take(max_length).collect()
}
