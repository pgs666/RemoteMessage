# RemoteMessage Middle Server (Rust)

This is a Rust reimplementation of `middle_server` with the same wire-facing responsibilities:

- HTTPS API server for gateway, client, crypto, and admin endpoints.
- Segmented token auth through `X-Gateway-Token`, `X-Client-Token`, and `X-Admin-Token`.
- SQLite persistence using the existing schema names and columns.
- RSA-OAEP-SHA256 encryption/decryption compatible with the Android gateway protocol.
- First-start onboarding payload and QR output in `RMS1|serverBaseUrl|clientToken|gatewayToken` format.
- Self-signed root CA file for clients/gateways to trust.
- Maintenance loop for API log retention, message retention, orphan pin cleanup, and database size trimming.

The crate root has `#![forbid(unsafe_code)]`, so this crate cannot introduce Rust `unsafe` blocks. Third-party dependencies may still use unsafe internally, notably SQLite/TLS/crypto crates.

## Runtime Files

Runtime files are created beside the executable, matching the original server layout where practical:

```text
server.db                    # SQLite database
server.conf                  # Server config and tokens
server-cert.cer              # Root CA certificate for clients/gateways to import
server-cert.pem              # HTTPS server certificate, PEM
server-key.pem               # HTTPS server private key, PEM
server-crypto-private.pem    # RSA private key for message payload crypto
onboarding-qr.txt            # First-start onboarding text/QR
qrcode.ps1 / qrcode.bat / qrcode.sh
server.log                   # File log with size rotation and retention cleanup
```

The Rust server uses `server-cert.pem` + `server-key.pem` for TLS instead of the .NET `server-cert.pfx` file. Clients still import `server-cert.cer`.

## Build

On Windows without Visual Studio Build Tools, use the GNU toolchain:

```powershell
rustup toolchain install stable-x86_64-pc-windows-gnu
rustup target add x86_64-pc-windows-gnu
cargo +stable-x86_64-pc-windows-gnu build --release --manifest-path middle_server_rust/Cargo.toml
```

With a normal Rust/MSVC setup, this should also work:

```powershell
cargo build --release --manifest-path middle_server_rust/Cargo.toml
```

## Run

```powershell
cargo +stable-x86_64-pc-windows-gnu run --release --manifest-path middle_server_rust/Cargo.toml
```

By default the server listens on `https://0.0.0.0:5001`. Edit `server.conf` and restart to change the port or tokens.

## Verification Commands

```powershell
cargo +stable-x86_64-pc-windows-gnu fmt --manifest-path middle_server_rust/Cargo.toml -- --check
cargo +stable-x86_64-pc-windows-gnu check --manifest-path middle_server_rust/Cargo.toml
cargo +stable-x86_64-pc-windows-gnu clippy --manifest-path middle_server_rust/Cargo.toml -- -D warnings
```

A smoke test can use `curl -k` against `/healthz` after the server starts:

```powershell
curl.exe -k https://127.0.0.1:5001/healthz
```

Expected response:

```json
{"ok":true}
```

## API Compatibility

Implemented endpoints:

```text
GET  /healthz
GET  /api/crypto/server-public-key
POST /api/gateway/register
POST /api/gateway/sim-state
POST /api/gateway/sms/upload
GET  /api/gateway/pull
POST /api/gateway/pull/ack
POST /api/gateway/outbound-status
GET  /api/client/inbox
GET  /api/client/gateways
GET  /api/client/gateways/{deviceId}/online
GET  /api/client/device-sims
POST /api/client/conversations/pin
GET  /api/client/conversations/pins
POST /api/client/send
POST /api/admin/clear-server-data
```

Validation limits and response shapes intentionally follow the current C# implementation closely.
