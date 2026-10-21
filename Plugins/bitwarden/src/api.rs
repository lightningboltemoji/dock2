//! Bitwarden's server API, as its clients call it: prelogin for the KDF, the token endpoint for a session,
//! sync for the vault. Answers come in either case — the cloud's camelCase or an older PascalCase — so
//! fields are looked up without it.

use crate::crypto::Kdf;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;

/// Where a server's identity and API endpoints are.
#[derive(Debug, Clone, PartialEq)]
pub struct Server {
    pub identity: String,
    pub api: String,
    /// For the sign-in form: "bitwarden.com", "vault.example.org".
    pub name: String,
}

impl Server {
    /// The cloud's two regions by their vault's address; anything else is self-hosted, its endpoints under it.
    pub fn from_setting(url: &str) -> Server {
        let url = url.trim().trim_end_matches('/');
        let url = if url.contains("://") { url.to_string() } else { format!("https://{url}") };
        let host = url.split("://").nth(1).unwrap_or("").split('/').next().unwrap_or("").to_lowercase();
        match host.as_str() {
            "" | "bitwarden.com" | "vault.bitwarden.com" => Server {
                identity: "https://identity.bitwarden.com".into(),
                api: "https://api.bitwarden.com".into(),
                name: "bitwarden.com".into(),
            },
            "bitwarden.eu" | "vault.bitwarden.eu" => Server {
                identity: "https://identity.bitwarden.eu".into(),
                api: "https://api.bitwarden.eu".into(),
                name: "bitwarden.eu".into(),
            },
            _ => Server { identity: format!("{url}/identity"), api: format!("{url}/api"), name: host },
        }
    }
}

/// A field, whatever its case.
pub fn field<'a>(value: &'a Value, name: &str) -> Option<&'a Value> {
    value.as_object()?.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, v)| v)
}

pub fn text(value: &Value, name: &str) -> Option<String> {
    field(value, name)?.as_str().map(Into::into)
}

pub fn number(value: &Value, name: &str) -> Option<u64> {
    field(value, name)?.as_u64()
}

pub fn prelogin_body(email: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({ "email": email.trim() })).unwrap_or_default()
}

/// The KDF an account uses.
pub fn parse_prelogin(body: &[u8]) -> Option<Kdf> {
    let value: Value = serde_json::from_slice(body).ok()?;
    let iterations = number(&value, "kdfIterations")? as u32;
    match number(&value, "kdf")? {
        0 => Some(Kdf::Pbkdf2 { iterations }),
        1 => Some(Kdf::Argon2id {
            iterations,
            memory_mib: number(&value, "kdfMemory")? as u32,
            parallelism: number(&value, "kdfParallelism")? as u32,
        }),
        _ => None,
    }
}

/// What a second factor is, by Bitwarden's number for it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SecondFactor {
    Authenticator = 0,
    Email = 1,
}

/// What the password grant answers.
#[derive(Debug, PartialEq)]
pub enum TokenAnswer {
    Session { access: String, refresh: String, expires_in: u64, protected_key: String },
    /// A second factor first, the ones dock2 can ask for in the account's order.
    SecondFactor(Vec<SecondFactor>),
    /// A sign-in from a device the account has not seen: a code went to its email.
    NewDevice,
    Refused(String),
}

pub fn parse_token(status: Option<u16>, body: &[u8]) -> TokenAnswer {
    let Ok(value) = serde_json::from_slice::<Value>(body) else {
        return TokenAnswer::Refused(format!("The server answered {}.", status.map(|s| s.to_string()).unwrap_or_else(|| "nothing".into())));
    };
    if let (Some(access), Some(refresh)) = (text(&value, "access_token"), text(&value, "refresh_token")) {
        let protected_key = text(&value, "Key").unwrap_or_default();
        return TokenAnswer::Session { access, refresh, expires_in: number(&value, "expires_in").unwrap_or(3600), protected_key };
    }
    if let Some(providers) = field(&value, "TwoFactorProviders").and_then(Value::as_array) {
        let offered: Vec<SecondFactor> = providers
            .iter()
            .filter_map(|p| p.as_u64().or_else(|| p.as_str().and_then(|s| s.parse().ok())))
            .filter_map(|p| match p {
                0 => Some(SecondFactor::Authenticator),
                1 => Some(SecondFactor::Email),
                _ => None,
            })
            .collect();
        if offered.is_empty() {
            return TokenAnswer::Refused("This account's second factor is one dock2 cannot ask for yet: sign in with an authenticator or email code.".into());
        }
        return TokenAnswer::SecondFactor(offered);
    }
    let description = text(&value, "error_description").unwrap_or_default();
    if description.to_lowercase().contains("new device") {
        return TokenAnswer::NewDevice;
    }
    let message = field(&value, "ErrorModel").and_then(|m| text(m, "Message")).unwrap_or(description);
    TokenAnswer::Refused(if message.is_empty() { "The email or master password is wrong.".into() } else { message })
}

/// `application/x-www-form-urlencoded`.
pub fn form(pairs: &[(&str, &str)]) -> Vec<u8> {
    pairs.iter().map(|(name, value)| format!("{}={}", encode(name), encode(value))).collect::<Vec<_>>().join("&").into_bytes()
}

fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            b' ' => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The device dock2 signs in as: the desktop client's id, macOS desktop's type.
pub const CLIENT_ID: &str = "desktop";
pub const DEVICE_TYPE: &str = "7";

/// The headers the token endpoint wants besides the body.
pub fn token_headers(email: &str) -> Vec<(String, String)> {
    vec![
        ("Content-Type".into(), "application/x-www-form-urlencoded; charset=utf-8".into()),
        ("Accept".into(), "application/json".into()),
        ("Auth-Email".into(), URL_SAFE_NO_PAD.encode(email.trim())),
        ("Device-Type".into(), DEVICE_TYPE.into()),
        ("Bitwarden-Client-Name".into(), CLIENT_ID.into()),
        ("Bitwarden-Client-Version".into(), "2025.10.0".into()),
    ]
}

/// The password grant, with a second factor or a new device's code when one was asked for.
pub fn token_body(email: &str, hash: &str, device: &str, second: Option<(SecondFactor, &str)>, new_device_code: Option<&str>) -> Vec<u8> {
    let mut pairs = vec![
        ("grant_type", "password".to_string()),
        ("username", email.trim().to_string()),
        ("password", hash.to_string()),
        ("scope", "api offline_access".to_string()),
        ("client_id", CLIENT_ID.to_string()),
        ("deviceType", DEVICE_TYPE.to_string()),
        ("deviceIdentifier", device.to_string()),
        ("deviceName", "dock2".to_string()),
    ];
    if let Some((factor, code)) = second {
        pairs.push(("twoFactorToken", code.trim().to_string()));
        pairs.push(("twoFactorProvider", (factor as u8).to_string()));
        pairs.push(("twoFactorRemember", "0".to_string()));
    }
    if let Some(code) = new_device_code {
        pairs.push(("newDeviceOtp", code.trim().to_string()));
    }
    let borrowed: Vec<(&str, &str)> = pairs.iter().map(|(k, v)| (*k, v.as_str())).collect();
    form(&borrowed)
}

pub fn refresh_body(refresh: &str) -> Vec<u8> {
    form(&[("grant_type", "refresh_token"), ("client_id", CLIENT_ID), ("refresh_token", refresh)])
}

/// Asks the server to email a sign-in code.
pub fn send_email_body(email: &str, hash: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({ "email": email.trim(), "masterPasswordHash": hash })).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn servers_by_their_vaults_address() {
        assert_eq!(Server::from_setting("https://vault.bitwarden.com").api, "https://api.bitwarden.com");
        assert_eq!(Server::from_setting("vault.bitwarden.eu/").identity, "https://identity.bitwarden.eu");
        let own = Server::from_setting("https://pw.example.org/");
        assert_eq!((own.identity.as_str(), own.api.as_str(), own.name.as_str()), ("https://pw.example.org/identity", "https://pw.example.org/api", "pw.example.org"));
    }

    #[test]
    fn answers_are_read_in_either_case() {
        assert_eq!(parse_prelogin(br#"{"kdf":0,"kdfIterations":600000}"#), Some(Kdf::Pbkdf2 { iterations: 600000 }));
        assert_eq!(parse_prelogin(br#"{"Kdf":1,"KdfIterations":3,"KdfMemory":64,"KdfParallelism":4}"#),
                   Some(Kdf::Argon2id { iterations: 3, memory_mib: 64, parallelism: 4 }));
        let session = parse_token(Some(200), br#"{"access_token":"a","refresh_token":"r","expires_in":3600,"Key":"2.x|y|z"}"#);
        assert_eq!(session, TokenAnswer::Session { access: "a".into(), refresh: "r".into(), expires_in: 3600, protected_key: "2.x|y|z".into() });
        assert_eq!(parse_token(Some(400), br#"{"error":"invalid_grant","TwoFactorProviders":["1","0"]}"#),
                   TokenAnswer::SecondFactor(vec![SecondFactor::Email, SecondFactor::Authenticator]));
        assert_eq!(parse_token(Some(400), br#"{"error":"invalid_grant","error_description":"New device verification required."}"#), TokenAnswer::NewDevice);
        assert_eq!(parse_token(Some(400), br#"{"error":"invalid_grant","ErrorModel":{"Message":"Username or password is incorrect. Try again."}}"#),
                   TokenAnswer::Refused("Username or password is incorrect. Try again.".into()));
    }

    #[test]
    fn the_grant_is_form_encoded() {
        let body = String::from_utf8(token_body("A@b.co", "h+/=", "dev", Some((SecondFactor::Authenticator, " 123456 ")), None)).unwrap();
        assert!(body.contains("username=A%40b.co") && body.contains("password=h%2B%2F%3D") && body.contains("scope=api+offline_access"));
        assert!(body.contains("twoFactorToken=123456&twoFactorProvider=0"));
    }
}
