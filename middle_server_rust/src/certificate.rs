use std::{
    env, fs,
    net::{IpAddr, Ipv4Addr},
    path::PathBuf,
};

use anyhow::Context;
use get_if_addrs::{IfAddr, get_if_addrs};
use rcgen::{
    BasicConstraints, Certificate, CertificateParams, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose, PKCS_RSA_SHA256, SanType,
    date_time_ymd,
};
use rsa::{RsaPrivateKey, pkcs8::EncodePrivateKey};

use crate::runtime::runtime_directory;

#[derive(Clone, Debug)]
pub struct HttpsCertificateSettings {
    pub cer_file_path: PathBuf,
    pub cert_pem_file_path: PathBuf,
    pub key_pem_file_path: PathBuf,
}

impl HttpsCertificateSettings {
    pub fn load_or_create() -> anyhow::Result<Self> {
        let base_dir = runtime_directory();
        let settings = Self {
            cer_file_path: base_dir.join("server-cert.cer"),
            cert_pem_file_path: base_dir.join("server-cert.pem"),
            key_pem_file_path: base_dir.join("server-key.pem"),
        };
        if !settings.cer_file_path.exists()
            || !settings.cert_pem_file_path.exists()
            || !settings.key_pem_file_path.exists()
        {
            settings.create_certificate_chain()?;
        }
        Ok(settings)
    }

    fn create_certificate_chain(&self) -> anyhow::Result<()> {
        if let Some(parent) = self.cer_file_path.parent() {
            fs::create_dir_all(parent)?;
        }

        let host_name = host_name();
        let mut root_dn = DistinguishedName::new();
        root_dn.push(
            DnType::CommonName,
            format!("RemoteMessage Root CA - {host_name}"),
        );
        let mut root_params = CertificateParams::default();
        root_params.alg = &PKCS_RSA_SHA256;
        root_params.key_pair = Some(generate_rsa_key_pair()?);
        root_params.distinguished_name = root_dn;
        root_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        root_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
        root_params.not_before = date_time_ymd(2026, 1, 1);
        root_params.not_after = date_time_ymd(2036, 1, 1);
        let root = Certificate::from_params(root_params).context("create root certificate")?;

        let mut server_params =
            CertificateParams::new(vec!["localhost".to_owned(), host_name.clone()]);
        server_params.alg = &PKCS_RSA_SHA256;
        server_params.key_pair = Some(generate_rsa_key_pair()?);
        server_params
            .distinguished_name
            .push(DnType::CommonName, host_name);
        server_params.is_ca = IsCa::NoCa;
        server_params.key_usages = vec![
            KeyUsagePurpose::DigitalSignature,
            KeyUsagePurpose::KeyEncipherment,
        ];
        server_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        server_params.not_before = date_time_ymd(2026, 1, 1);
        server_params.not_after = date_time_ymd(2028, 1, 1);
        for address in server_ip_addresses() {
            server_params
                .subject_alt_names
                .push(SanType::IpAddress(address));
        }
        let server =
            Certificate::from_params(server_params).context("create server certificate")?;

        let server_cert_pem = server
            .serialize_pem_with_signer(&root)
            .context("sign server certificate")?;
        let server_key_pem = server.serialize_private_key_pem();

        fs::write(&self.cert_pem_file_path, server_cert_pem.as_bytes())
            .with_context(|| format!("write {}", self.cert_pem_file_path.display()))?;
        fs::write(&self.key_pem_file_path, server_key_pem.as_bytes())
            .with_context(|| format!("write {}", self.key_pem_file_path.display()))?;
        fs::write(
            &self.cer_file_path,
            root.serialize_der()
                .context("export root certificate der")?,
        )
        .with_context(|| format!("write {}", self.cer_file_path.display()))?;
        Ok(())
    }
}

fn generate_rsa_key_pair() -> anyhow::Result<KeyPair> {
    let mut rng = rand::rngs::OsRng;
    let rsa = RsaPrivateKey::new(&mut rng, 2048)?;
    let pkcs8 = rsa.to_pkcs8_der()?;
    Ok(KeyPair::from_der_and_sign_algo(
        pkcs8.as_bytes(),
        &PKCS_RSA_SHA256,
    )?)
}

fn host_name() -> String {
    env::var("COMPUTERNAME")
        .or_else(|_| env::var("HOSTNAME"))
        .map(|value| value.trim().to_owned())
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "localhost".to_owned())
}

fn server_ip_addresses() -> Vec<IpAddr> {
    let mut addresses = vec![
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V4(Ipv4Addr::new(10, 0, 2, 2)),
        IpAddr::V6(std::net::Ipv6Addr::LOCALHOST),
    ];
    if let Ok(ifaces) = get_if_addrs() {
        for iface in ifaces {
            if iface.is_loopback() {
                continue;
            }
            let ip = match iface.addr {
                IfAddr::V4(v4) => IpAddr::V4(v4.ip),
                IfAddr::V6(v6) => IpAddr::V6(v6.ip),
            };
            if is_supported_address(ip) && !addresses.contains(&ip) {
                addresses.push(ip);
            }
        }
    }
    addresses.sort_by_key(|ip| {
        (
            if matches!(ip, IpAddr::V4(_)) { 0 } else { 1 },
            ip.to_string(),
        )
    });
    addresses
}

fn is_supported_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(v4) => !v4.is_link_local(),
        IpAddr::V6(v6) => !v6.is_multicast() && !v6.is_unicast_link_local(),
    }
}
