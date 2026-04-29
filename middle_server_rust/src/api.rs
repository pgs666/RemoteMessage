use std::{sync::Arc, time::Instant};

use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::json;
use subtle::ConstantTimeEq;

use crate::{
    config::ServerRuntimeSettings,
    crypto::{CryptoState, build_message_identity, encrypt_by_public_key},
    logger::FileLogger,
    models::{
        AckOutboundRequest, ClearServerDataRequest, GatewaySmsPayload, OutboundInstruction,
        OutboundStatusUpdateRequest, PinConversationRequest, RegisterGatewayRequest,
        SendSmsRequest, SmsPayload, UploadSmsRequest, UpsertGatewaySimStateRequest,
    },
    registry::GatewayRegistry,
    repository::SqliteRepository,
    runtime::now_millis,
};

const DEFAULT_GATEWAY_ONLINE_WINDOW_MS: i64 = 120_000;

#[derive(Clone)]
pub struct AppState {
    pub settings: Arc<ServerRuntimeSettings>,
    pub crypto: Arc<CryptoState>,
    pub repo: SqliteRepository,
    pub registry: GatewayRegistry,
    pub logger: FileLogger,
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/api/crypto/server-public-key", get(server_public_key))
        .route("/api/gateway/register", post(register_gateway))
        .route("/api/gateway/sim-state", post(upsert_gateway_sim_state))
        .route("/api/gateway/sms/upload", post(upload_sms))
        .route("/api/gateway/pull", get(pull_outbound))
        .route("/api/gateway/pull/ack", post(ack_outbound))
        .route("/api/gateway/outbound-status", post(outbound_status))
        .route("/api/client/inbox", get(client_inbox))
        .route("/api/client/gateways", get(client_gateways))
        .route(
            "/api/client/gateways/{device_id}/online",
            get(client_gateway_online),
        )
        .route("/api/client/device-sims", get(client_device_sims))
        .route("/api/client/conversations/pin", post(pin_conversation))
        .route("/api/client/conversations/pins", get(conversation_pins))
        .route("/api/client/send", post(client_send))
        .route("/api/admin/clear-server-data", post(clear_server_data))
        .layer(DefaultBodyLimit::max(256 * 1024))
        .layer(middleware::from_fn_with_state(state.clone(), auth_and_log))
        .with_state(state)
}

async fn auth_and_log(State(state): State<AppState>, req: Request<Body>, next: Next) -> Response {
    let begin = Instant::now();
    let method = req.method().as_str().to_owned();
    let path = req.uri().path().to_owned();
    let remote_ip = "unknown".to_owned();

    if !path.eq_ignore_ascii_case("/healthz") && !is_request_authorized(&req, &state.settings) {
        let response = (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "invalid credentials" })),
        )
            .into_response();
        state.repo.insert_api_log(
            &method,
            &path,
            response.status().as_u16(),
            &remote_ip,
            begin.elapsed().as_millis() as i64,
        );
        return response;
    }

    let response = next.run(req).await;
    state.repo.insert_api_log(
        &method,
        &path,
        response.status().as_u16(),
        &remote_ip,
        begin.elapsed().as_millis() as i64,
    );
    response
}

fn is_request_authorized(req: &Request<Body>, settings: &ServerRuntimeSettings) -> bool {
    let path = req.uri().path();
    let headers = req.headers();
    if starts_with_ignore_ascii_case(path, "/api/gateway/") {
        return header_matches(headers, "X-Gateway-Token", &settings.gateway_token);
    }
    if starts_with_ignore_ascii_case(path, "/api/client/") {
        return header_matches(headers, "X-Client-Token", &settings.client_token);
    }
    if starts_with_ignore_ascii_case(path, "/api/admin/") {
        return header_matches(headers, "X-Admin-Token", &settings.admin_token);
    }
    if starts_with_ignore_ascii_case(path, "/api/crypto/") {
        return header_matches(headers, "X-Gateway-Token", &settings.gateway_token)
            || header_matches(headers, "X-Client-Token", &settings.client_token)
            || header_matches(headers, "X-Admin-Token", &settings.admin_token);
    }
    false
}

fn header_matches(headers: &axum::http::HeaderMap, header_name: &str, expected: &str) -> bool {
    let provided = headers
        .get(header_name)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    provided.len() == expected.len() && provided.as_bytes().ct_eq(expected.as_bytes()).into()
}

fn starts_with_ignore_ascii_case(value: &str, prefix: &str) -> bool {
    value.len() >= prefix.len() && value[..prefix.len()].eq_ignore_ascii_case(prefix)
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({ "ok": true }))
}

async fn server_public_key(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "publicKey": state.crypto.server_public_key_pem() }))
}

async fn register_gateway(
    State(state): State<AppState>,
    Json(req): Json<RegisterGatewayRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_register_gateway_request(&req)?;
    state
        .registry
        .upsert(req.device_id.clone(), req.public_key_pem.clone());
    state
        .repo
        .upsert_gateway(&req.device_id, &req.public_key_pem)
        .map_err(ApiError::internal)?;
    Ok(Json(json!({ "ok": true, "deviceId": req.device_id })))
}

async fn upsert_gateway_sim_state(
    State(state): State<AppState>,
    Json(req): Json<UpsertGatewaySimStateRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_gateway_sim_state_request(&req)?;
    state
        .repo
        .replace_gateway_sim_profiles(&req.device_id, &req.profiles)
        .map_err(ApiError::internal)?;
    state
        .repo
        .touch_gateway_last_seen(&req.device_id)
        .map_err(ApiError::internal)?;
    Ok(Json(json!({ "ok": true, "count": req.profiles.len() })))
}

async fn upload_sms(
    State(state): State<AppState>,
    Json(req): Json<UploadSmsRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_upload_sms_request(&req)?;
    state
        .repo
        .touch_gateway_last_seen(&req.device_id)
        .map_err(ApiError::internal)?;

    let plain = state
        .crypto
        .decrypt_with_server_private_key(&req.encrypted_payload_base64)
        .map_err(|err| {
            state.logger.warn(
                "GatewayUpload",
                format!(
                    "Failed to decrypt gateway upload for device {}: {err:#}",
                    req.device_id
                ),
            );
            ApiError::bad_request_json(json!({ "error": "invalid encrypted payload" }))
        })?;
    let payload: GatewaySmsPayload =
        serde_json::from_str(&plain).map_err(|_| ApiError::bad_request("invalid payload"))?;
    validate_gateway_payload(&payload)?;

    let normalized_direction = normalize_direction(payload.direction.as_deref());
    let normalized_sim_slot = normalize_sim_slot_index(payload.sim_slot_index);
    let normalized_sim_phone = normalize_optional_text(payload.sim_phone_number.as_deref(), 64);
    let normalized_sim_count = normalize_sim_count(payload.sim_count);
    let uploaded_sim_profile = state
        .repo
        .resolve_gateway_sim_profile(&req.device_id, normalized_sim_slot)
        .map_err(ApiError::internal)?;
    let message_id = payload
        .message_id
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| {
            build_message_identity(
                &req.device_id,
                &payload.phone,
                &payload.content,
                payload.timestamp,
                &normalized_direction,
                normalized_sim_slot,
            )
        });
    let normalized = SmsPayload {
        id: message_id,
        device_id: req.device_id.clone(),
        phone: payload.phone,
        content: payload.content,
        timestamp: payload.timestamp,
        direction: normalized_direction,
        sim_slot_index: normalized_sim_slot.or_else(|| {
            uploaded_sim_profile
                .as_ref()
                .map(|profile| profile.slot_index)
        }),
        sim_phone_number: normalized_sim_phone.or_else(|| {
            uploaded_sim_profile
                .as_ref()
                .and_then(|profile| profile.phone_number.clone())
        }),
        sim_count: normalized_sim_count.or_else(|| {
            uploaded_sim_profile
                .as_ref()
                .map(|profile| profile.sim_count)
        }),
        send_status: None,
        send_error_code: None,
        send_error_message: None,
        updated_at: None,
    };
    let is_new = state
        .repo
        .insert_message_if_not_exists(&normalized)
        .map_err(ApiError::internal)?;
    Ok(Json(
        json!({ "ok": true, "deduplicated": !is_new, "messageId": normalized.id }),
    ))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InboxQuery {
    since_ts: Option<i64>,
    limit: Option<i32>,
    phone: Option<String>,
}

async fn client_inbox(
    State(state): State<AppState>,
    Query(query): Query<InboxQuery>,
) -> Result<Json<Vec<SmsPayload>>, ApiError> {
    if query
        .phone
        .as_deref()
        .is_some_and(|phone| !is_valid_phone(Some(phone)))
    {
        return Err(ApiError::bad_request("phone invalid"));
    }
    let list = state
        .repo
        .query_messages(query.since_ts, query.limit, query.phone)
        .map_err(ApiError::internal)?;
    Ok(Json(list))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GatewaysQuery {
    limit: Option<i32>,
    online_window_ms: Option<i64>,
}

async fn client_gateways(
    State(state): State<AppState>,
    Query(query): Query<GatewaysQuery>,
) -> Result<Json<Vec<crate::models::GatewaySummaryRecord>>, ApiError> {
    let normalized_window_ms = query
        .online_window_ms
        .unwrap_or(DEFAULT_GATEWAY_ONLINE_WINDOW_MS)
        .clamp(5_000, 86_400_000);
    let list = state
        .repo
        .list_gateways(query.limit, normalized_window_ms)
        .map_err(ApiError::internal)?;
    Ok(Json(list))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OnlineQuery {
    online_window_ms: Option<i64>,
}

async fn client_gateway_online(
    State(state): State<AppState>,
    Path(device_id): Path<String>,
    Query(query): Query<OnlineQuery>,
) -> Result<Response, ApiError> {
    if device_id.trim().is_empty() || device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId required"));
    }
    let normalized_window_ms = query
        .online_window_ms
        .unwrap_or(DEFAULT_GATEWAY_ONLINE_WINDOW_MS)
        .clamp(5_000, 86_400_000);
    let status = state
        .repo
        .get_gateway_online_status(&device_id, normalized_window_ms)
        .map_err(ApiError::internal)?;
    Ok(match status {
        Some(status) => Json(status).into_response(),
        None => (StatusCode::NOT_FOUND, "gateway not found").into_response(),
    })
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceSimsQuery {
    device_id: String,
}

async fn client_device_sims(
    State(state): State<AppState>,
    Query(query): Query<DeviceSimsQuery>,
) -> Result<Response, ApiError> {
    if query.device_id.trim().is_empty() || query.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId required"));
    }
    let list = state
        .repo
        .get_gateway_sim_profiles(&query.device_id)
        .map_err(ApiError::internal)?;
    Ok(Json(list).into_response())
}

async fn pin_conversation(
    State(state): State<AppState>,
    Json(req): Json<PinConversationRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_pin_request(&req)?;
    state
        .repo
        .set_pinned(&req.phone, req.pinned)
        .map_err(ApiError::internal)?;
    Ok(Json(json!({ "ok": true })))
}

async fn conversation_pins(State(state): State<AppState>) -> Result<Json<Vec<String>>, ApiError> {
    Ok(Json(
        state.repo.get_pinned_phones().map_err(ApiError::internal)?,
    ))
}

async fn client_send(
    State(state): State<AppState>,
    Json(req): Json<SendSmsRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_send_request(&req)?;

    let mut pem = state.registry.get(&req.device_id);
    if pem.as_deref().is_none_or(|value| value.trim().is_empty()) {
        pem = state
            .repo
            .get_gateway_public_key(&req.device_id)
            .map_err(ApiError::internal)?;
        if let Some(pem_value) = pem.clone().filter(|value| !value.trim().is_empty()) {
            state.registry.upsert(req.device_id.clone(), pem_value);
        } else {
            return Err(ApiError::not_found("gateway not registered"));
        }
    }
    let pem = pem.unwrap_or_default();

    let gateway_sims = state
        .repo
        .get_gateway_sim_profiles(&req.device_id)
        .map_err(ApiError::internal)?;
    let selected_sim = if let Some(slot) = req.sim_slot_index {
        let found = gateway_sims
            .iter()
            .find(|profile| profile.slot_index == slot)
            .cloned();
        if !gateway_sims.is_empty() && found.is_none() {
            return Err(ApiError::bad_request("simSlotIndex invalid"));
        }
        found
    } else {
        gateway_sims.first().cloned()
    };

    let outbound_sim_slot = selected_sim
        .as_ref()
        .map(|profile| profile.slot_index)
        .or_else(|| normalize_sim_slot_index(req.sim_slot_index));
    let now = now_millis();
    let outbound = SmsPayload {
        id: build_message_identity(
            &req.device_id,
            &req.target_phone,
            &req.content,
            now,
            "outbound",
            outbound_sim_slot,
        ),
        device_id: req.device_id.clone(),
        phone: req.target_phone.clone(),
        content: req.content.clone(),
        timestamp: now,
        direction: "outbound".to_owned(),
        sim_slot_index: outbound_sim_slot,
        sim_phone_number: selected_sim
            .as_ref()
            .and_then(|profile| profile.phone_number.clone()),
        sim_count: selected_sim
            .as_ref()
            .map(|profile| profile.sim_count)
            .or_else(|| gateway_sims.iter().map(|profile| profile.sim_count).max()),
        send_status: Some("queued".to_owned()),
        send_error_code: None,
        send_error_message: None,
        updated_at: Some(now),
    };
    let instruction = OutboundInstruction {
        message_id: outbound.id.clone(),
        target_phone: req.target_phone,
        content: req.content,
        sim_slot_index: outbound_sim_slot,
    };
    let plain = serde_json::to_string(&instruction).map_err(ApiError::internal)?;
    let encrypted = encrypt_by_public_key(&plain, &pem)
        .map_err(|_| ApiError::bad_request("gateway public key invalid"))?;

    state
        .repo
        .enqueue_outbound(&req.device_id, &encrypted)
        .map_err(ApiError::internal)?;
    state
        .repo
        .insert_message_if_not_exists(&outbound)
        .map_err(ApiError::internal)?;
    Ok(Json(json!({ "ok": true, "message": outbound })))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GatewayPullQuery {
    device_id: String,
}

async fn pull_outbound(
    State(state): State<AppState>,
    Query(query): Query<GatewayPullQuery>,
) -> Result<Response, ApiError> {
    if query.device_id.trim().is_empty() || query.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId required"));
    }
    state
        .repo
        .touch_gateway_last_seen(&query.device_id)
        .map_err(ApiError::internal)?;
    let found = state
        .repo
        .lease_next_outbound(&query.device_id)
        .map_err(ApiError::internal)?;
    Ok(match found {
        Some(item) => Json(item).into_response(),
        None => StatusCode::NO_CONTENT.into_response(),
    })
}

async fn ack_outbound(
    State(state): State<AppState>,
    Json(req): Json<AckOutboundRequest>,
) -> Result<Response, ApiError> {
    validate_ack_outbound_request(&req)?;
    state
        .repo
        .touch_gateway_last_seen(&req.device_id)
        .map_err(ApiError::internal)?;
    let acked = state
        .repo
        .ack_outbound(&req.device_id, req.outbox_id, &req.ack_token)
        .map_err(ApiError::internal)?;
    Ok(if acked {
        Json(json!({ "ok": true })).into_response()
    } else {
        (
            StatusCode::NOT_FOUND,
            Json(json!({ "ok": false, "error": "pending outbound not found" })),
        )
            .into_response()
    })
}

async fn outbound_status(
    State(state): State<AppState>,
    Json(req): Json<OutboundStatusUpdateRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_outbound_status_request(&req)?;
    state
        .repo
        .touch_gateway_last_seen(&req.device_id)
        .map_err(ApiError::internal)?;
    let Some(status) = normalize_send_status(Some(&req.status)) else {
        return Err(ApiError::bad_request("status invalid"));
    };
    let normalized = OutboundStatusUpdateRequest {
        status,
        sim_slot_index: normalize_sim_slot_index(req.sim_slot_index),
        sim_phone_number: normalize_optional_text(req.sim_phone_number.as_deref(), 64),
        sim_count: normalize_sim_count(req.sim_count),
        error_message: normalize_optional_text(req.error_message.as_deref(), 512),
        timestamp: if req.timestamp > 0 {
            req.timestamp
        } else {
            now_millis()
        },
        ..req
    };
    let updated = state
        .repo
        .upsert_outbound_status(&normalized)
        .map_err(ApiError::internal)?;
    Ok(Json(json!({ "ok": true, "updated": updated })))
}

async fn clear_server_data(
    State(state): State<AppState>,
    Json(req): Json<ClearServerDataRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate_clear_server_data_request(&req)?;
    let result = state.repo.clear_server_data().map_err(ApiError::internal)?;
    state.logger.warn(
        "Admin",
        format!(
            "Server data cleared via admin API. Messages={}, Outbox={}, Pinned={}, SimProfiles={}, ApiLogs={}",
            result.messages_cleared,
            result.outbox_cleared,
            result.pinned_conversations_cleared,
            result.gateway_sim_profiles_cleared,
            result.api_logs_cleared
        ),
    );
    Ok(Json(json!({ "ok": true, "result": result })))
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    body: ErrorBody,
}

#[derive(Debug)]
enum ErrorBody {
    Text(String),
    Json(serde_json::Value),
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            body: ErrorBody::Text(message.into()),
        }
    }

    fn bad_request_json(value: serde_json::Value) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            body: ErrorBody::Json(value),
        }
    }

    fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            body: ErrorBody::Text(message.into()),
        }
    }

    fn internal(error: impl std::fmt::Display) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            body: ErrorBody::Text(format!("internal server error: {error}")),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        match self.body {
            ErrorBody::Text(message) => (self.status, message).into_response(),
            ErrorBody::Json(value) => (self.status, Json(value)).into_response(),
        }
    }
}

fn validate_register_gateway_request(req: &RegisterGatewayRequest) -> Result<(), ApiError> {
    if req.device_id.trim().is_empty() || req.public_key_pem.trim().is_empty() {
        return Err(ApiError::bad_request("deviceId/publicKeyPem required"));
    }
    if req.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId too long"));
    }
    let public_key_len = req.public_key_pem.len();
    if !(128..=16384).contains(&public_key_len) {
        return Err(ApiError::bad_request("publicKeyPem length invalid"));
    }
    Ok(())
}

fn validate_upload_sms_request(req: &UploadSmsRequest) -> Result<(), ApiError> {
    if req.device_id.trim().is_empty() || req.encrypted_payload_base64.trim().is_empty() {
        return Err(ApiError::bad_request(
            "deviceId/encryptedPayloadBase64 required",
        ));
    }
    if req.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId too long"));
    }
    if req.encrypted_payload_base64.len() > 262_144 {
        return Err(ApiError::bad_request("encrypted payload too large"));
    }
    Ok(())
}

fn validate_gateway_payload(payload: &GatewaySmsPayload) -> Result<(), ApiError> {
    if !is_valid_phone(Some(&payload.phone)) {
        return Err(ApiError::bad_request("phone invalid"));
    }
    if payload.content.chars().count() > 8192 {
        return Err(ApiError::bad_request("content too large"));
    }
    if payload
        .message_id
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty() && value.chars().count() > 256)
    {
        return Err(ApiError::bad_request("messageId too long"));
    }
    if payload
        .sim_slot_index
        .is_some_and(|value| !(0..=7).contains(&value))
    {
        return Err(ApiError::bad_request("simSlotIndex invalid"));
    }
    if payload
        .sim_phone_number
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty() && !is_valid_phone(Some(value)))
    {
        return Err(ApiError::bad_request("simPhoneNumber invalid"));
    }
    if payload
        .sim_count
        .is_some_and(|value| !(1..=8).contains(&value))
    {
        return Err(ApiError::bad_request("simCount invalid"));
    }
    Ok(())
}

fn validate_gateway_sim_state_request(req: &UpsertGatewaySimStateRequest) -> Result<(), ApiError> {
    if req.device_id.trim().is_empty() {
        return Err(ApiError::bad_request("deviceId required"));
    }
    if req.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId too long"));
    }
    if req.profiles.len() > 8 {
        return Err(ApiError::bad_request("too many sim profiles"));
    }
    for (index, profile) in req.profiles.iter().enumerate() {
        if req
            .profiles
            .iter()
            .skip(index + 1)
            .any(|other| other.slot_index == profile.slot_index)
        {
            return Err(ApiError::bad_request("duplicate sim slot index"));
        }
        validate_gateway_sim_profile(profile)?;
    }
    Ok(())
}

fn validate_gateway_sim_profile(
    profile: &crate::models::GatewaySimProfilePayload,
) -> Result<(), ApiError> {
    if !(0..=7).contains(&profile.slot_index) {
        return Err(ApiError::bad_request("sim slot invalid"));
    }
    if profile.subscription_id.is_some_and(|value| value < 0) {
        return Err(ApiError::bad_request("subscriptionId invalid"));
    }
    if profile
        .display_name
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty() && value.chars().count() > 128)
    {
        return Err(ApiError::bad_request("displayName too long"));
    }
    if profile
        .phone_number
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty() && !is_valid_phone(Some(value)))
    {
        return Err(ApiError::bad_request("phoneNumber invalid"));
    }
    if profile
        .sim_count
        .is_some_and(|value| !(1..=8).contains(&value))
    {
        return Err(ApiError::bad_request("simCount invalid"));
    }
    Ok(())
}

fn validate_pin_request(req: &PinConversationRequest) -> Result<(), ApiError> {
    if is_valid_phone(Some(&req.phone)) {
        Ok(())
    } else {
        Err(ApiError::bad_request("phone required"))
    }
}

fn validate_send_request(req: &SendSmsRequest) -> Result<(), ApiError> {
    if req.device_id.trim().is_empty()
        || !is_valid_phone(Some(&req.target_phone))
        || req.content.trim().is_empty()
    {
        return Err(ApiError::bad_request(
            "deviceId/targetPhone/content required",
        ));
    }
    if req.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId too long"));
    }
    if req.content.chars().count() > 8192 {
        return Err(ApiError::bad_request("content too large"));
    }
    if req
        .sim_slot_index
        .is_some_and(|value| !(0..=7).contains(&value))
    {
        return Err(ApiError::bad_request("simSlotIndex invalid"));
    }
    Ok(())
}

fn validate_ack_outbound_request(req: &AckOutboundRequest) -> Result<(), ApiError> {
    if req.device_id.trim().is_empty() || req.ack_token.trim().is_empty() || req.outbox_id <= 0 {
        return Err(ApiError::bad_request("deviceId/outboxId/ackToken required"));
    }
    if req.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId too long"));
    }
    if req.ack_token.chars().count() > 128 {
        return Err(ApiError::bad_request("ackToken too long"));
    }
    Ok(())
}

fn validate_outbound_status_request(req: &OutboundStatusUpdateRequest) -> Result<(), ApiError> {
    if req.device_id.trim().is_empty()
        || req.message_id.trim().is_empty()
        || !is_valid_phone(Some(&req.target_phone))
    {
        return Err(ApiError::bad_request(
            "deviceId/messageId/targetPhone required",
        ));
    }
    if req.device_id.chars().count() > 128 {
        return Err(ApiError::bad_request("deviceId too long"));
    }
    if req.message_id.chars().count() > 256 {
        return Err(ApiError::bad_request("messageId too long"));
    }
    if req.status.trim().is_empty() {
        return Err(ApiError::bad_request("status required"));
    }
    if normalize_send_status(Some(&req.status)).is_none() {
        return Err(ApiError::bad_request("status invalid"));
    }
    if req
        .sim_slot_index
        .is_some_and(|value| !(0..=7).contains(&value))
    {
        return Err(ApiError::bad_request("simSlotIndex invalid"));
    }
    if req
        .sim_phone_number
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty() && !is_valid_phone(Some(value)))
    {
        return Err(ApiError::bad_request("simPhoneNumber invalid"));
    }
    if req.sim_count.is_some_and(|value| !(1..=8).contains(&value)) {
        return Err(ApiError::bad_request("simCount invalid"));
    }
    if req
        .error_code
        .is_some_and(|value| !(-999_999..=999_999).contains(&value))
    {
        return Err(ApiError::bad_request("errorCode invalid"));
    }
    if req
        .error_message
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty() && value.chars().count() > 512)
    {
        return Err(ApiError::bad_request("errorMessage too long"));
    }
    Ok(())
}

fn validate_clear_server_data_request(req: &ClearServerDataRequest) -> Result<(), ApiError> {
    if req.confirm.as_deref().map(str::trim) == Some("CLEAR_SERVER_DATA") {
        Ok(())
    } else {
        Err(ApiError::bad_request("confirm invalid"))
    }
}

fn normalize_direction(direction: Option<&str>) -> String {
    match direction
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("outbound") => "outbound".to_owned(),
        _ => "inbound".to_owned(),
    }
}

fn normalize_sim_slot_index(sim_slot_index: Option<i32>) -> Option<i32> {
    sim_slot_index.filter(|value| (0..=7).contains(value))
}

fn normalize_sim_count(sim_count: Option<i32>) -> Option<i32> {
    sim_count.filter(|value| (1..=8).contains(value))
}

fn normalize_send_status(status: Option<&str>) -> Option<String> {
    match status?.trim().to_ascii_lowercase().as_str() {
        "queued" => Some("queued".to_owned()),
        "dispatched" => Some("dispatched".to_owned()),
        "sent" => Some("sent".to_owned()),
        "failed" => Some("failed".to_owned()),
        _ => None,
    }
}

fn normalize_optional_text(value: Option<&str>, max_length: usize) -> Option<String> {
    let normalized = value?.trim();
    if normalized.is_empty() {
        return None;
    }
    Some(normalized.chars().take(max_length).collect())
}

fn is_valid_phone(phone: Option<&str>) -> bool {
    let Some(normalized) = phone.map(str::trim).filter(|value| !value.is_empty()) else {
        return false;
    };
    normalized.chars().count() <= 64
}
