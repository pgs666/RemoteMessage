# RemoteMessage Middle Server (Rust)

This is the Rust middle server for RemoteMessage:

- HTTPS API server for gateway, client, crypto, and admin endpoints.
- Per-credential token auth through `X-Gateway-Token`, `X-Client-Token`, and `X-Admin-Token`.
- Gateway tokens are bound to the first registered `deviceId`; later gateway pull/ack/status calls must use the same `deviceId`.
- Gateway registration does not allow overwriting an existing `deviceId` with a different public key.
- SQLite persistence using the existing wire-facing schema names and columns where practical.
- RSA-OAEP-SHA256 encryption/decryption compatible with the Android gateway protocol.
- RMS2 JSON onboarding QR text files for client and gateway credentials.
- Self-signed root CA file for clients/gateways to trust.
- Maintenance loop for API log retention, message retention, orphan pin cleanup, and database size trimming.

The crate root has `#![forbid(unsafe_code)]`, so this crate cannot introduce Rust `unsafe` blocks. Third-party dependencies may still use unsafe internally, notably SQLite/TLS/crypto crates.

## Runtime Files

Runtime files are created beside the executable:

```text
server.db                         # SQLite database, including auth_credentials
server.conf                       # Server port, admin token, retention settings
server-cert.cer                   # Root CA certificate for clients/gateways to import
server-cert.pem                   # HTTPS server certificate, PEM
server-key.pem                    # HTTPS server private key, PEM
server-crypto-private.pem         # RSA private key for message payload crypto
onboarding-client-<id>.txt        # RMS2 JSON client onboarding QR text
onboarding-gateway-<id>.txt       # RMS2 JSON gateway onboarding QR text
server.log                        # File log with size rotation and retention cleanup
```

Client and gateway token plaintext is only printed/written when a credential is created. The database stores token SHA-256 hashes, not plaintext tokens.

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

By default the server listens on `https://0.0.0.0:5001`. Edit `server.conf` and restart to change the port or admin token.

On first start, if no active client or gateway credential exists, the server creates one client credential and one gateway credential and writes RMS2 onboarding text files.

Create extra credentials on startup:

```powershell
remote_message_middle_server.exe --new-client
remote_message_middle_server.exe --new-gateway
remote_message_middle_server.exe --new-client --new-gateway
```

## Onboarding Format

Client QR payload:

```json
{"format":"RMS2","role":"client","serverBaseUrl":"https://192.168.1.100:5001","clientToken":"...","credentialId":"...","displayName":"...","createdAt":0}
```

Gateway QR payload:

```json
{"format":"RMS2","role":"gateway","serverBaseUrl":"https://192.168.1.100:5001","gatewayToken":"...","credentialId":"...","displayName":"...","boundDeviceId":null,"createdAt":0}
```

A gateway credential is unbound when generated. The first successful `/api/gateway/register` binds it to that request's `deviceId`; later gateway endpoints reject a different `deviceId`.

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
