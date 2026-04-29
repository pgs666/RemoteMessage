use std::{env, fs, net::Ipv4Addr, path::Path};

use anyhow::Context;
use get_if_addrs::{IfAddr, get_if_addrs};
use qrcode::{QrCode, render::unicode};

use crate::{config::ServerRuntimeSettings, logger::FileLogger, runtime::runtime_directory};

const ONBOARDING_TEXT_FILE_NAME: &str = "onboarding-qr.txt";
const ONBOARDING_SCRIPT_PS1: &str = "qrcode.ps1";
const ONBOARDING_SCRIPT_BAT: &str = "qrcode.bat";
const ONBOARDING_SCRIPT_SH: &str = "qrcode.sh";

pub fn write_first_start_artifacts(
    settings: &ServerRuntimeSettings,
    logger: &FileLogger,
) -> anyhow::Result<()> {
    let runtime_dir = runtime_directory();
    let payload = build_onboarding_payload(settings);
    let qr_text = build_ascii_qr(&payload)?;
    let output = format!(
        "RemoteMessage onboarding QR\n\
Format: RMS1|serverBaseUrl|clientToken|gatewayToken\n\n\
{payload}\n\n{qr_text}\n"
    );

    let onboarding_text_path = runtime_dir.join(ONBOARDING_TEXT_FILE_NAME);
    fs::write(&onboarding_text_path, output)
        .with_context(|| format!("write {}", onboarding_text_path.display()))?;
    write_helper_scripts(&runtime_dir, &payload)?;

    println!();
    println!("==== RemoteMessage First-Start Onboarding QR ====");
    println!("Scan this QR from client/gateway to auto-fill server and token:");
    println!();
    println!("{qr_text}");
    println!("{payload}");
    println!("Saved: {}", onboarding_text_path.display());
    println!("==================================================");
    println!();

    logger.info(
        "Onboarding",
        format!(
            "First-start onboarding QR generated at {}",
            onboarding_text_path.display()
        ),
    );
    Ok(())
}

fn build_onboarding_payload(settings: &ServerRuntimeSettings) -> String {
    let server_base_url = resolve_server_base_url(settings.https_port);
    format!(
        "RMS1|{}|{}|{}",
        server_base_url, settings.client_token, settings.gateway_token
    )
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

fn write_helper_scripts(runtime_dir: &Path, payload: &str) -> anyhow::Result<()> {
    let safe_payload_for_ps1 = payload.replace('\'', "''");
    let safe_payload_for_sh = payload.replace('\'', "'\"'\"'");

    let ps1 = format!(
        "$payload = '{safe_payload_for_ps1}'\n\
Write-Host \"RemoteMessage onboarding payload:\"\n\
Write-Host $payload\n\
Write-Host \"\"\n\
Write-Host \"If your terminal cannot render onboarding-qr.txt well,\"\n\
Write-Host \"copy the payload above into any QR generator.\"\n"
    );
    let bat = format!(
        "@echo off\n\
set PAYLOAD={payload}\n\
echo RemoteMessage onboarding payload:\n\
echo %PAYLOAD%\n\
echo.\n\
echo If your terminal cannot render onboarding-qr.txt well,\n\
echo copy the payload above into any QR generator.\n"
    );
    let sh = format!(
        "#!/usr/bin/env sh\n\
PAYLOAD='{safe_payload_for_sh}'\n\
echo \"RemoteMessage onboarding payload:\"\n\
echo \"$PAYLOAD\"\n\
echo \"\"\n\
echo \"If your terminal cannot render onboarding-qr.txt well,\"\n\
echo \"copy the payload above into any QR generator.\"\n"
    );

    fs::write(runtime_dir.join(ONBOARDING_SCRIPT_PS1), ps1)?;
    fs::write(runtime_dir.join(ONBOARDING_SCRIPT_BAT), bat)?;
    fs::write(runtime_dir.join(ONBOARDING_SCRIPT_SH), sh)?;
    Ok(())
}
