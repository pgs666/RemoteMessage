use std::{collections::HashMap, fs, path::PathBuf};

use anyhow::Context;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use rand::{RngCore, rngs::OsRng};

use crate::runtime::runtime_directory;

const DEFAULT_HTTPS_PORT: u16 = 5001;
const DEFAULT_LOG_RETENTION_DAYS: i32 = 14;
const DEFAULT_LOG_MAX_MB: i32 = 32;
const DEFAULT_API_LOG_RETENTION_DAYS: i32 = 30;
const DEFAULT_MESSAGE_RETENTION_DAYS: i32 = 0;
const DEFAULT_DATABASE_MAX_MB: i32 = 512;
const DEFAULT_MAINTENANCE_INTERVAL_MINUTES: i32 = 60;

#[derive(Clone, Debug)]
pub struct ServerRuntimeSettings {
    pub gateway_token: String,
    pub client_token: String,
    pub admin_token: String,
    pub https_port: u16,
    pub log_retention_days: i32,
    pub log_max_bytes: i64,
    pub api_log_retention_days: i32,
    pub message_retention_days: i32,
    pub database_max_bytes: i64,
    pub maintenance_interval_minutes: i32,
    pub server_config_file_path: PathBuf,
    pub is_first_start: bool,
}

struct WritableConfig<'a> {
    https_port: u16,
    gateway_token: &'a str,
    client_token: &'a str,
    admin_token: &'a str,
    log_retention_days: i32,
    log_max_mb: i32,
    api_log_retention_days: i32,
    message_retention_days: i32,
    db_max_mb: i32,
    maintenance_interval_minutes: i32,
}

impl ServerRuntimeSettings {
    pub fn load_or_create() -> anyhow::Result<Self> {
        let base_dir = runtime_directory();
        fs::create_dir_all(&base_dir)
            .with_context(|| format!("create runtime dir {}", base_dir.display()))?;
        let server_config_file_path = base_dir.join("server.conf");

        if !server_config_file_path.exists() {
            let gateway_token = generate_secret();
            let client_token = generate_secret();
            let admin_token = generate_secret();
            write_server_config(
                &server_config_file_path,
                &WritableConfig {
                    https_port: DEFAULT_HTTPS_PORT,
                    gateway_token: &gateway_token,
                    client_token: &client_token,
                    admin_token: &admin_token,
                    log_retention_days: DEFAULT_LOG_RETENTION_DAYS,
                    log_max_mb: DEFAULT_LOG_MAX_MB,
                    api_log_retention_days: DEFAULT_API_LOG_RETENTION_DAYS,
                    message_retention_days: DEFAULT_MESSAGE_RETENTION_DAYS,
                    db_max_mb: DEFAULT_DATABASE_MAX_MB,
                    maintenance_interval_minutes: DEFAULT_MAINTENANCE_INTERVAL_MINUTES,
                },
            )?;
            return Ok(Self {
                gateway_token,
                client_token,
                admin_token,
                https_port: DEFAULT_HTTPS_PORT,
                log_retention_days: DEFAULT_LOG_RETENTION_DAYS,
                log_max_bytes: mb_to_bytes(DEFAULT_LOG_MAX_MB),
                api_log_retention_days: DEFAULT_API_LOG_RETENTION_DAYS,
                message_retention_days: DEFAULT_MESSAGE_RETENTION_DAYS,
                database_max_bytes: mb_to_bytes(DEFAULT_DATABASE_MAX_MB),
                maintenance_interval_minutes: DEFAULT_MAINTENANCE_INTERVAL_MINUTES,
                server_config_file_path,
                is_first_start: true,
            });
        }

        let values = parse_key_value_file(&server_config_file_path)?;
        let mut changed = false;
        let gateway_token = read_or_generate_secret(&values, "gateway_token", &mut changed);
        let client_token = read_or_generate_secret(&values, "client_token", &mut changed);
        let admin_token = read_or_generate_secret(&values, "admin_token", &mut changed);
        let https_port = parse_u16_in_range(
            &values,
            "https_port",
            1,
            u16::MAX,
            DEFAULT_HTTPS_PORT,
            &mut changed,
        );
        let log_retention_days = parse_i32_in_range(
            &values,
            "log_retention_days",
            1,
            3650,
            DEFAULT_LOG_RETENTION_DAYS,
            &mut changed,
        );
        let log_max_mb = parse_i32_in_range(
            &values,
            "log_max_mb",
            1,
            4096,
            DEFAULT_LOG_MAX_MB,
            &mut changed,
        );
        let api_log_retention_days = parse_i32_in_range(
            &values,
            "api_log_retention_days",
            1,
            3650,
            DEFAULT_API_LOG_RETENTION_DAYS,
            &mut changed,
        );
        let message_retention_days = parse_i32_in_range(
            &values,
            "message_retention_days",
            0,
            3650,
            DEFAULT_MESSAGE_RETENTION_DAYS,
            &mut changed,
        );
        let db_max_mb = parse_i32_alias_in_range(
            &values,
            "db_max_mb",
            "database_max_mb",
            1,
            16384,
            DEFAULT_DATABASE_MAX_MB,
            &mut changed,
        );
        let maintenance_interval_minutes = parse_i32_in_range(
            &values,
            "maintenance_interval_minutes",
            5,
            1440,
            DEFAULT_MAINTENANCE_INTERVAL_MINUTES,
            &mut changed,
        );

        if changed {
            write_server_config(
                &server_config_file_path,
                &WritableConfig {
                    https_port,
                    gateway_token: &gateway_token,
                    client_token: &client_token,
                    admin_token: &admin_token,
                    log_retention_days,
                    log_max_mb,
                    api_log_retention_days,
                    message_retention_days,
                    db_max_mb,
                    maintenance_interval_minutes,
                },
            )?;
        }

        Ok(Self {
            gateway_token,
            client_token,
            admin_token,
            https_port,
            log_retention_days,
            log_max_bytes: mb_to_bytes(log_max_mb),
            api_log_retention_days,
            message_retention_days,
            database_max_bytes: mb_to_bytes(db_max_mb),
            maintenance_interval_minutes,
            server_config_file_path,
            is_first_start: false,
        })
    }
}

fn parse_key_value_file(path: &PathBuf) -> anyhow::Result<HashMap<String, String>> {
    let content = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let mut result = HashMap::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';') {
            continue;
        }
        let Some((key, value)) = trimmed.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if !key.is_empty() {
            result.insert(key.to_ascii_lowercase(), value.trim().to_owned());
        }
    }
    Ok(result)
}

fn read_or_generate_secret(
    values: &HashMap<String, String>,
    key: &str,
    changed: &mut bool,
) -> String {
    values
        .get(key)
        .filter(|value| !value.trim().is_empty())
        .cloned()
        .unwrap_or_else(|| {
            *changed = true;
            generate_secret()
        })
}

fn parse_i32_in_range(
    values: &HashMap<String, String>,
    key: &str,
    min: i32,
    max: i32,
    fallback: i32,
    changed: &mut bool,
) -> i32 {
    if let Some(value) = values.get(key).and_then(|raw| raw.parse::<i32>().ok())
        && (min..=max).contains(&value)
    {
        return value;
    }
    *changed = true;
    fallback
}

fn parse_i32_alias_in_range(
    values: &HashMap<String, String>,
    key: &str,
    alias: &str,
    min: i32,
    max: i32,
    fallback: i32,
    changed: &mut bool,
) -> i32 {
    if let Some(value) = values
        .get(key)
        .or_else(|| values.get(alias))
        .and_then(|raw| raw.parse::<i32>().ok())
        && (min..=max).contains(&value)
    {
        return value;
    }
    *changed = true;
    fallback
}

fn parse_u16_in_range(
    values: &HashMap<String, String>,
    key: &str,
    min: u16,
    max: u16,
    fallback: u16,
    changed: &mut bool,
) -> u16 {
    if let Some(value) = values.get(key).and_then(|raw| raw.parse::<u16>().ok())
        && (min..=max).contains(&value)
    {
        return value;
    }
    *changed = true;
    fallback
}

fn write_server_config(path: &PathBuf, config: &WritableConfig<'_>) -> anyhow::Result<()> {
    let https_port = config.https_port;
    let gateway_token = config.gateway_token;
    let client_token = config.client_token;
    let admin_token = config.admin_token;
    let log_retention_days = config.log_retention_days;
    let log_max_mb = config.log_max_mb;
    let api_log_retention_days = config.api_log_retention_days;
    let message_retention_days = config.message_retention_days;
    let db_max_mb = config.db_max_mb;
    let maintenance_interval_minutes = config.maintenance_interval_minutes;
    let content = format!(
        "# RemoteMessage server.conf\n\
# Generated on first start. Edit values and restart the service.\n\
https_port={https_port}\n\n\
# Segmented authentication tokens\n\
gateway_token={gateway_token}\n\
client_token={client_token}\n\
admin_token={admin_token}\n\n\
# File log retention\n\
log_retention_days={log_retention_days}\n\
log_max_mb={log_max_mb}\n\n\
# Database retention\n\
api_log_retention_days={api_log_retention_days}\n\
message_retention_days={message_retention_days}\n\
db_max_mb={db_max_mb}\n\n\
# Maintenance loop interval\n\
maintenance_interval_minutes={maintenance_interval_minutes}\n"
    );
    fs::write(path, content).with_context(|| format!("write {}", path.display()))
}

fn generate_secret() -> String {
    let mut bytes = [0_u8; 24];
    OsRng.fill_bytes(&mut bytes);
    STANDARD.encode(bytes)
}

fn mb_to_bytes(mb: i32) -> i64 {
    i64::from(mb) * 1024 * 1024
}
