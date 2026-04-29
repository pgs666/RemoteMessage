use std::{env, fs, net::Ipv4Addr, path::PathBuf};

use anyhow::Context;
use if_addrs::{IfAddr, get_if_addrs};
use qrcode::{QrCode, render::unicode};
use serde_json::json;

use crate::{
    config::ServerRuntimeSettings, logger::FileLogger, models::CreatedAuthCredential,
    runtime::runtime_directory,
};

pub fn write_credential_artifact(
    settings: &ServerRuntimeSettings,
    credential: &CreatedAuthCredential,
    logger: &FileLogger,
) -> anyhow::Result<PathBuf> {
    let payload = build_payload(settings, credential);
    let qr_text = build_ascii_qr(&payload)?;
    let file_name = format!("onboarding-{}-{}.txt", credential.role, credential.id);
    let path = runtime_directory().join(file_name);
    let output = format!(
        "RemoteMessage {} onboarding QR\n\
Format: RMS2 JSON\n\
Server: {}\n\
Credential: {} ({})\n\
Token: {}\n\
Bound device: {}\n\n\
{payload}\n\n{qr_text}\n",
        credential.role,
        resolve_server_base_url(settings.https_port),
        credential.display_name,
        credential.id,
        credential.token,
        credential
            .bound_device_id
            .as_deref()
            .unwrap_or("<first gateway registration>"),
    );
    fs::write(&path, output).with_context(|| format!("write {}", path.display()))?;

    println!(
        "Generated {} onboarding QR: {}",
        credential.role,
        path.display()
    );
    println!("{payload}");
    logger.info(
        "Onboarding",
        format!(
            "{} onboarding QR generated for credential {} at {}",
            credential.role,
            credential.id,
            path.display()
        ),
    );
    Ok(path)
}

fn build_payload(settings: &ServerRuntimeSettings, credential: &CreatedAuthCredential) -> String {
    match credential.role.as_str() {
        "gateway" => json!({
            "format": "RMS2",
            "role": "gateway",
            "serverBaseUrl": resolve_server_base_url(settings.https_port),
            "gatewayToken": credential.token,
            "credentialId": credential.id,
            "displayName": credential.display_name,
            "boundDeviceId": credential.bound_device_id,
            "createdAt": credential.created_at,
        })
        .to_string(),
        _ => json!({
            "format": "RMS2",
            "role": "client",
            "serverBaseUrl": resolve_server_base_url(settings.https_port),
            "clientToken": credential.token,
            "credentialId": credential.id,
            "displayName": credential.display_name,
            "createdAt": credential.created_at,
        })
        .to_string(),
    }
}

fn resolve_server_base_url(https_port: u16) -> String {
    if let Ok(value) = env::var("REMOTE_MESSAGE_SERVER_BASE_URL") {
        let value = value.trim().to_owned();
        if !value.is_empty() {
            return value;
        }
    }

    let chosen = candidate_ipv4_addresses()
        .into_iter()
        .max_by_key(|ip| is_private_ipv4(*ip))
        .unwrap_or(Ipv4Addr::LOCALHOST);
    format!("https://{}:{}", chosen, https_port)
}

fn candidate_ipv4_addresses() -> Vec<Ipv4Addr> {
    let mut result = Vec::new();
    if let Ok(ifaces) = get_if_addrs() {
        for iface in ifaces {
            if iface.is_loopback() {
                continue;
            }
            let IfAddr::V4(addr) = iface.addr else {
                continue;
            };
            let ip = addr.ip;
            if !ip.is_link_local() && !result.contains(&ip) {
                result.push(ip);
            }
        }
    }
    result
}

fn is_private_ipv4(ip: Ipv4Addr) -> bool {
    ip.is_private()
}

fn build_ascii_qr(payload: &str) -> anyhow::Result<String> {
    let code = QrCode::new(payload.as_bytes()).context("build onboarding qr")?;
    Ok(code.render::<unicode::Dense1x2>().quiet_zone(true).build())
}
