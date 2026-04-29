use serde::{Deserialize, Serialize};

#[derive(Debug, Clone)]
pub struct AuthCredentialRecord {
    pub id: String,
    pub role: String,
    pub bound_device_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CreatedAuthCredential {
    pub id: String,
    pub role: String,
    pub display_name: String,
    pub token: String,
    pub bound_device_id: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Default)]
pub struct DefaultAuthCredentials {
    pub client: Option<CreatedAuthCredential>,
    pub gateway: Option<CreatedAuthCredential>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GatewayRegistrationResult {
    Created,
    AlreadyRegistered,
    PublicKeyUpdated,
    PublicKeyConflict,
    DeviceAlreadyRegistered,
    CredentialNotFound,
    CredentialDeviceConflict,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterGatewayRequest {
    pub device_id: String,
    pub public_key_pem: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadSmsRequest {
    pub device_id: String,
    pub encrypted_payload_base64: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendSmsRequest {
    pub device_id: String,
    pub target_phone: String,
    pub content: String,
    pub sim_slot_index: Option<i32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinConversationRequest {
    pub phone: String,
    pub pinned: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AckOutboundRequest {
    pub device_id: String,
    pub outbox_id: i64,
    pub ack_token: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutboundStatusUpdateRequest {
    pub device_id: String,
    pub message_id: String,
    pub target_phone: String,
    pub status: String,
    pub timestamp: i64,
    pub content: Option<String>,
    pub sim_slot_index: Option<i32>,
    pub sim_phone_number: Option<String>,
    pub sim_count: Option<i32>,
    pub error_code: Option<i32>,
    pub error_message: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpsertGatewaySimStateRequest {
    pub device_id: String,
    pub profiles: Vec<GatewaySimProfilePayload>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewaySimProfilePayload {
    pub slot_index: i32,
    pub subscription_id: Option<i32>,
    pub display_name: Option<String>,
    pub phone_number: Option<String>,
    pub sim_count: Option<i32>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClearServerDataRequest {
    pub confirm: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerDataClearResult {
    pub messages_cleared: i32,
    pub outbox_cleared: i32,
    pub pinned_conversations_cleared: i32,
    pub gateway_sim_profiles_cleared: i32,
    pub api_logs_cleared: i32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewaySmsPayload {
    pub phone: String,
    pub content: String,
    pub timestamp: i64,
    pub direction: Option<String>,
    pub message_id: Option<String>,
    pub sim_slot_index: Option<i32>,
    pub sim_phone_number: Option<String>,
    pub sim_count: Option<i32>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SmsPayload {
    pub id: String,
    pub device_id: String,
    pub phone: String,
    pub content: String,
    pub timestamp: i64,
    pub direction: String,
    pub sim_slot_index: Option<i32>,
    pub sim_phone_number: Option<String>,
    pub sim_count: Option<i32>,
    pub send_status: Option<String>,
    pub send_error_code: Option<i32>,
    pub send_error_message: Option<String>,
    pub updated_at: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutboundInstruction {
    pub message_id: String,
    pub target_phone: String,
    pub content: String,
    pub sim_slot_index: Option<i32>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewaySimProfileRecord {
    pub device_id: String,
    pub slot_index: i32,
    pub subscription_id: Option<i32>,
    pub display_name: Option<String>,
    pub phone_number: Option<String>,
    pub sim_count: i32,
    pub updated_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewaySummaryRecord {
    pub device_id: String,
    pub updated_at: i64,
    pub last_seen_at: Option<i64>,
    pub is_online: bool,
    pub sim_profile_count: i32,
    pub pending_outbox_count: i32,
    pub last_message_timestamp: Option<i64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayOnlineStatusRecord {
    pub device_id: String,
    pub last_seen_at: Option<i64>,
    pub is_online: bool,
    pub online_window_ms: i64,
    pub checked_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingOutbound {
    pub outbox_id: i64,
    pub ack_token: String,
    pub device_id: String,
    pub encrypted_payload_base64: String,
}

#[derive(Debug)]
pub struct DatabaseMaintenanceResult {
    pub api_logs_deleted: i32,
    pub messages_deleted: i32,
    pub outbox_deleted: i32,
    pub orphan_pins_deleted: i32,
    pub database_vacuumed: bool,
    pub database_bytes: i64,
}

impl DatabaseMaintenanceResult {
    pub fn has_changes(&self) -> bool {
        self.api_logs_deleted > 0
            || self.messages_deleted > 0
            || self.outbox_deleted > 0
            || self.orphan_pins_deleted > 0
            || self.database_vacuumed
    }
}
