#![forbid(unsafe_code)]

mod api;
mod certificate;
mod config;
mod crypto;
mod logger;
mod models;
mod onboarding;
mod registry;
mod repository;
mod runtime;

use std::{env, net::SocketAddr, sync::Arc, time::Duration};

use api::AppState;
use axum_server::tls_rustls::RustlsConfig;
use certificate::HttpsCertificateSettings;
use config::ServerRuntimeSettings;
use crypto::CryptoState;
use logger::FileLogger;
use registry::GatewayRegistry;
use repository::SqliteRepository;
use runtime::{executable_path, runtime_directory};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let startup_options = parse_startup_options()?;
    let settings = Arc::new(ServerRuntimeSettings::load_or_create()?);
    let https_settings = HttpsCertificateSettings::load_or_create()?;
    let logger = FileLogger::new(
        runtime_directory().join("server.log"),
        settings.log_max_bytes,
        settings.log_retention_days,
    )?;
    let repo = SqliteRepository::new()?;
    let crypto = Arc::new(CryptoState::load_or_create()?);
    let default_credentials = repo.ensure_default_auth_credentials()?;
    if let Some(credential) = default_credentials.client {
        onboarding::write_credential_artifact(&settings, &credential, &logger)?;
    }
    if let Some(credential) = default_credentials.gateway {
        onboarding::write_credential_artifact(&settings, &credential, &logger)?;
    }
    if startup_options.new_client {
        let credential = repo.create_client_auth_credential(None)?;
        onboarding::write_credential_artifact(&settings, &credential, &logger)?;
    }
    if startup_options.new_gateway {
        let credential = repo.create_gateway_auth_credential(None)?;
        onboarding::write_credential_artifact(&settings, &credential, &logger)?;
    }

    logger.info(
        "Startup",
        format!(
            "RemoteMessage Rust middle server starting. Runtime directory={}; ExecutablePath={}",
            runtime_directory().display(),
            executable_path().display()
        ),
    );
    logger.info(
        "Startup",
        format!(
            "Loaded config {}; HTTPS port={}",
            settings.server_config_file_path.display(),
            settings.https_port
        ),
    );
    logger.info(
        "Startup",
        "Runtime files are created beside the executable: server.db, server.conf, server.log, server-cert.cer (root CA), server-cert.pem, server-key.pem, server-crypto-private.pem",
    );
    logger.info(
        "Startup",
        format!(
            "SQLite database path: {}",
            repo.database_file_path().display()
        ),
    );
    logger.info(
        "Startup",
        format!("Server log path: {}", logger.path().display()),
    );
    logger.info(
        "Startup",
        format!(
            "Server crypto private key path: {}",
            crypto.private_key_file_path().display()
        ),
    );
    logger.info("Startup", "Auth enabled: per-credential segmented headers (X-Gateway-Token / X-Client-Token / X-Admin-Token). Gateway tokens are bound to the first registered deviceId.");
    logger.info(
        "Startup",
        format!(
            "Maintenance policy: every {} min; log retention {} days / {} MB; api_logs {} days; messages {} days (0=keep); db max {} MB.",
            settings.maintenance_interval_minutes,
            settings.log_retention_days,
            settings.log_max_bytes / (1024 * 1024),
            settings.api_log_retention_days,
            settings.message_retention_days,
            settings.database_max_bytes / (1024 * 1024)
        ),
    );

    logger.warn("Security", "Security review result: this service is suitable for LAN/VPN or reverse-proxied deployment, but it is not sufficient for direct public internet exposure without stronger auth, rate limiting, replay protection, and monitoring.");

    let maintenance_repo = repo.clone();
    let maintenance_settings = Arc::clone(&settings);
    let maintenance_logger = logger.clone();
    tokio::spawn(async move {
        run_maintenance_loop(maintenance_repo, maintenance_settings, maintenance_logger).await;
    });

    let state = AppState {
        settings: Arc::clone(&settings),
        crypto,
        repo,
        registry: GatewayRegistry::default(),
        logger,
    };
    let router = api::build_router(state);
    let tls_config = RustlsConfig::from_pem_file(
        &https_settings.cert_pem_file_path,
        &https_settings.key_pem_file_path,
    )
    .await?;
    let addr = SocketAddr::from(([0, 0, 0, 0], settings.https_port));
    axum_server::bind_rustls(addr, tls_config)
        .serve(router.into_make_service())
        .await?;
    Ok(())
}

#[derive(Default)]
struct StartupOptions {
    new_client: bool,
    new_gateway: bool,
}

fn parse_startup_options() -> anyhow::Result<StartupOptions> {
    let mut options = StartupOptions::default();
    for arg in env::args().skip(1) {
        match arg.as_str() {
            "--new-client" => options.new_client = true,
            "--new-gateway" => options.new_gateway = true,
            "--help" | "-h" => {
                println!(
                    "RemoteMessage middle server\n\nOptions:\n  --new-client   Create a new client token and onboarding QR txt before serving\n  --new-gateway  Create a new gateway token and onboarding QR txt before serving\n  -h, --help     Show this help"
                );
                std::process::exit(0);
            }
            _ => anyhow::bail!("unknown argument: {arg}"),
        }
    }
    Ok(options)
}

async fn run_maintenance_loop(
    repo: SqliteRepository,
    settings: Arc<ServerRuntimeSettings>,
    logger: FileLogger,
) {
    let interval =
        Duration::from_secs(settings.maintenance_interval_minutes.clamp(5, 1440) as u64 * 60);
    run_maintenance_once(&repo, &settings, &logger);
    loop {
        tokio::time::sleep(interval).await;
        run_maintenance_once(&repo, &settings, &logger);
    }
}

fn run_maintenance_once(
    repo: &SqliteRepository,
    settings: &ServerRuntimeSettings,
    logger: &FileLogger,
) {
    match repo.run_maintenance(settings) {
        Ok(result) if result.has_changes() => logger.info(
            "Maintenance",
            format!(
                "Maintenance cleaned: apiLogs={}, messages={}, outbox={}, orphanPins={}, dbVacuumed={}, dbBytes={}",
                result.api_logs_deleted,
                result.messages_deleted,
                result.outbox_deleted,
                result.orphan_pins_deleted,
                result.database_vacuumed,
                result.database_bytes
            ),
        ),
        Ok(_) => {}
        Err(err) => logger.warn("Maintenance", format!("Maintenance loop failed: {err:#}")),
    }
}
