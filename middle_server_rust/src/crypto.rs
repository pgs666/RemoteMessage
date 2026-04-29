use std::{fs, path::PathBuf, sync::Mutex};

use anyhow::{Context, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use rsa::{
    Oaep, RsaPrivateKey, RsaPublicKey,
    pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey, EncodePublicKey, LineEnding},
    traits::PublicKeyParts,
};
use sha2::{Digest, Sha256};

use crate::runtime::runtime_directory;

const PRIVATE_KEY_FILE_NAME: &str = "server-crypto-private.pem";

pub struct CryptoState {
    server_rsa: Mutex<RsaPrivateKey>,
    server_public_key_pem: String,
    private_key_file_path: PathBuf,
}

impl CryptoState {
    pub fn load_or_create() -> anyhow::Result<Self> {
        let private_key_file_path = runtime_directory().join(PRIVATE_KEY_FILE_NAME);
        let server_rsa = load_or_create_server_rsa(&private_key_file_path)?;
        let server_public_key_pem = RsaPublicKey::from(&server_rsa)
            .to_public_key_pem(LineEnding::LF)
            .context("export server public key")?;
        Ok(Self {
            server_rsa: Mutex::new(server_rsa),
            server_public_key_pem,
            private_key_file_path,
        })
    }

    pub fn server_public_key_pem(&self) -> &str {
        &self.server_public_key_pem
    }

    pub fn private_key_file_path(&self) -> &PathBuf {
        &self.private_key_file_path
    }

    pub fn decrypt_with_server_private_key(
        &self,
        encrypted_base64: &str,
    ) -> anyhow::Result<String> {
        if !encrypted_base64.contains('.') {
            let data = STANDARD
                .decode(encrypted_base64.trim())
                .context("decode encrypted payload")?;
            let plain = self.decrypt_chunk(&data)?;
            return String::from_utf8(plain).context("payload is not utf-8");
        }

        let mut output =
            Vec::with_capacity(encrypted_base64.matches('.').count().saturating_add(1) * 190);
        for chunk in encrypted_base64
            .split('.')
            .map(str::trim)
            .filter(|chunk| !chunk.is_empty())
        {
            if chunk.len() > 4096 {
                return Err(anyhow!("encrypted chunk too large"));
            }
            let data = STANDARD
                .decode(chunk)
                .context("decode encrypted payload chunk")?;
            let plain = self.decrypt_chunk(&data)?;
            output.extend_from_slice(&plain);
        }
        String::from_utf8(output).context("payload is not utf-8")
    }

    fn decrypt_chunk(&self, encrypted: &[u8]) -> anyhow::Result<Vec<u8>> {
        let key = self
            .server_rsa
            .lock()
            .map_err(|_| anyhow!("server rsa lock poisoned"))?;
        key.decrypt(Oaep::new::<Sha256>(), encrypted)
            .context("rsa decrypt failed")
    }
}

fn load_or_create_server_rsa(private_key_file_path: &PathBuf) -> anyhow::Result<RsaPrivateKey> {
    if private_key_file_path.exists() {
        let existing_pem = fs::read_to_string(private_key_file_path)
            .with_context(|| format!("read {}", private_key_file_path.display()))?;
        return RsaPrivateKey::from_pkcs8_pem(&existing_pem).context("import server private key");
    }

    if let Some(parent) = private_key_file_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut rng = rand::rngs::OsRng;
    let rsa = RsaPrivateKey::new(&mut rng, 2048).context("generate server rsa key")?;
    let private_pem = rsa
        .to_pkcs8_pem(LineEnding::LF)
        .context("export server private key")?;
    fs::write(private_key_file_path, private_pem.as_bytes())
        .with_context(|| format!("write {}", private_key_file_path.display()))?;
    Ok(rsa)
}

pub fn encrypt_by_public_key(plain_text: &str, public_pem: &str) -> anyhow::Result<String> {
    let public_key =
        RsaPublicKey::from_public_key_pem(public_pem).context("import gateway public key")?;
    let bytes = plain_text.as_bytes();
    let max_chunk_size = max_oaep_sha256_plaintext_size(&public_key)?;
    let mut rng = rand::rngs::OsRng;

    if bytes.len() <= max_chunk_size {
        let encrypted = public_key
            .encrypt(&mut rng, Oaep::new::<Sha256>(), bytes)
            .context("rsa encrypt failed")?;
        return Ok(STANDARD.encode(encrypted));
    }

    let mut chunks = Vec::new();
    for chunk in bytes.chunks(max_chunk_size) {
        let encrypted = public_key
            .encrypt(&mut rng, Oaep::new::<Sha256>(), chunk)
            .context("rsa encrypt chunk failed")?;
        chunks.push(STANDARD.encode(encrypted));
    }
    Ok(chunks.join("."))
}

fn max_oaep_sha256_plaintext_size(public_key: &RsaPublicKey) -> anyhow::Result<usize> {
    let key_bytes = public_key.size();
    let hash_bytes = 32;
    key_bytes
        .checked_sub(2 * hash_bytes + 2)
        .filter(|value| *value > 0)
        .ok_or_else(|| anyhow!("rsa key too small"))
}

pub fn build_message_identity(
    device_id: &str,
    phone: &str,
    content: &str,
    timestamp: i64,
    direction: &str,
    sim_slot_index: Option<i32>,
) -> String {
    let raw = format!(
        "{}|{}|{}|{}|{}|{}",
        device_id,
        phone,
        timestamp,
        direction,
        sim_slot_index.unwrap_or(-1),
        content
    );
    let hash = Sha256::digest(raw.as_bytes());
    to_lower_hex(&hash[..12])
}

fn to_lower_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}
