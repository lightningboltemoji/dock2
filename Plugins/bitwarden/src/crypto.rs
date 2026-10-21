//! Bitwarden's client-side cryptography, as its clients do it: the master key derived from the master
//! password, the hash the server checks, the stretched key that opens the user key, and the encrypted
//! strings everything in a vault is kept as.

use aes::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

type HmacSha256 = Hmac<Sha256>;
type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;

#[derive(Debug, PartialEq)]
pub enum CryptoError {
    /// Not an encrypted string, or one of a type this client cannot open.
    Malformed,
    /// The MAC did not match: the wrong key, or tampered bytes.
    WrongKey,
    Padding,
    Kdf,
}

/// How the master key is derived, as `prelogin` says.
#[derive(Debug, Clone, PartialEq)]
pub enum Kdf {
    Pbkdf2 { iterations: u32 },
    Argon2id { iterations: u32, memory_mib: u32, parallelism: u32 },
}

/// A 256-bit encryption key and a 256-bit MAC key.
#[derive(Clone, PartialEq)]
pub struct SymmetricKey {
    pub enc: [u8; 32],
    pub mac: [u8; 32],
}

impl std::fmt::Debug for SymmetricKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SymmetricKey(…)")
    }
}

impl SymmetricKey {
    /// 64 bytes: the encryption key, then the MAC key.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, CryptoError> {
        if bytes.len() != 64 {
            return Err(CryptoError::Malformed);
        }
        let (mut enc, mut mac) = ([0u8; 32], [0u8; 32]);
        enc.copy_from_slice(&bytes[..32]);
        mac.copy_from_slice(&bytes[32..]);
        Ok(SymmetricKey { enc, mac })
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        [self.enc.as_slice(), self.mac.as_slice()].concat()
    }
}

/// What the master key is derived with: the lowercased email for PBKDF2, its SHA-256 for Argon2id. dock2
/// derives the key itself, natively — PBKDF2's 600,000 rounds and Argon2's 64 MiB are past what a
/// plugin's call may spend.
pub fn salt(email: &str, kdf: &Kdf) -> Vec<u8> {
    let email = email.trim().to_lowercase();
    match kdf {
        Kdf::Pbkdf2 { .. } => email.into_bytes(),
        Kdf::Argon2id { .. } => Sha256::digest(email.as_bytes()).to_vec(),
    }
}

/// The master key, derived here: for the tests, which check the salt against an independent derivation.
#[cfg(test)]
pub fn master_key(password: &str, email: &str, kdf: &Kdf) -> Result<[u8; 32], CryptoError> {
    let salt = salt(email, kdf);
    let mut key = [0u8; 32];
    match kdf {
        Kdf::Pbkdf2 { iterations } => pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, *iterations, &mut key),
        Kdf::Argon2id { iterations, memory_mib, parallelism } => {
            let params = argon2::Params::new(memory_mib * 1024, *iterations, *parallelism, Some(32)).map_err(|_| CryptoError::Kdf)?;
            argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params)
                .hash_password_into(password.as_bytes(), &salt, &mut key)
                .map_err(|_| CryptoError::Kdf)?;
        }
    }
    Ok(key)
}

/// What the server checks in place of the password: one more PBKDF2 round of the master key, salted with
/// the password.
pub fn master_password_hash(master_key: &[u8; 32], password: &str) -> String {
    let mut hash = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(master_key, password.as_bytes(), 1, &mut hash);
    BASE64.encode(hash)
}

/// HKDF-Expand alone (the master key is already uniform), info "enc" and "mac".
pub fn stretch(master_key: &[u8; 32]) -> SymmetricKey {
    let hkdf = hkdf::Hkdf::<Sha256>::from_prk(master_key).expect("32 bytes is a PRK");
    let (mut enc, mut mac) = ([0u8; 32], [0u8; 32]);
    hkdf.expand(b"enc", &mut enc).expect("32 bytes");
    hkdf.expand(b"mac", &mut mac).expect("32 bytes");
    SymmetricKey { enc, mac }
}

/// `2.<iv>|<ciphertext>|<mac>`: AES-256-CBC with an HMAC-SHA256 over the IV and the ciphertext. Type 0,
/// without the MAC, is refused: nothing a current account holds.
pub fn decrypt(encrypted: &str, key: &SymmetricKey) -> Result<Vec<u8>, CryptoError> {
    let (kind, rest) = encrypted.split_once('.').ok_or(CryptoError::Malformed)?;
    if kind != "2" {
        return Err(CryptoError::Malformed);
    }
    let parts: Vec<&str> = rest.split('|').collect();
    let [iv, data, mac] = parts.as_slice() else { return Err(CryptoError::Malformed) };
    let (iv, data, mac) = (
        BASE64.decode(iv).map_err(|_| CryptoError::Malformed)?,
        BASE64.decode(data).map_err(|_| CryptoError::Malformed)?,
        BASE64.decode(mac).map_err(|_| CryptoError::Malformed)?,
    );
    if iv.len() != 16 {
        return Err(CryptoError::Malformed);
    }
    let mut check = HmacSha256::new_from_slice(&key.mac).expect("any key size");
    check.update(&iv);
    check.update(&data);
    if !bool::from(check.finalize().into_bytes().as_slice().ct_eq(&mac)) {
        return Err(CryptoError::WrongKey);
    }
    Aes256CbcDec::new(&key.enc.into(), iv.as_slice().into())
        .decrypt_padded_vec_mut::<Pkcs7>(&data)
        .map_err(|_| CryptoError::Padding)
}

pub fn decrypt_string(encrypted: &str, key: &SymmetricKey) -> Result<String, CryptoError> {
    String::from_utf8(decrypt(encrypted, key)?).map_err(|_| CryptoError::Malformed)
}

/// The account's RSA private key: PKCS#8 bytes sealed with the user key.
pub fn private_key(sealed: &str, user_key: &SymmetricKey) -> Result<rsa::RsaPrivateKey, CryptoError> {
    use rsa::pkcs8::DecodePrivateKey;
    rsa::RsaPrivateKey::from_pkcs8_der(&decrypt(sealed, user_key)?).map_err(|_| CryptoError::Malformed)
}

/// `3.<data>` and `4.<data>`: RSA-OAEP with SHA-256 or SHA-1, as an organization's key is sealed for each of
/// its members. The older types that add a MAC are refused.
pub fn decrypt_rsa(encrypted: &str, key: &rsa::RsaPrivateKey) -> Result<Vec<u8>, CryptoError> {
    let (kind, data) = encrypted.split_once('.').ok_or(CryptoError::Malformed)?;
    let data = BASE64.decode(data).map_err(|_| CryptoError::Malformed)?;
    match kind {
        "3" => key.decrypt(rsa::Oaep::new::<Sha256>(), &data),
        "4" => key.decrypt(rsa::Oaep::new::<sha1::Sha1>(), &data),
        _ => return Err(CryptoError::Malformed),
    }
    .map_err(|_| CryptoError::WrongKey)
}

/// The user key, which the account keeps encrypted with the stretched master key.
pub fn user_key(protected: &str, master_key: &[u8; 32]) -> Result<SymmetricKey, CryptoError> {
    SymmetricKey::from_bytes(&decrypt(protected, &stretch(master_key))?)
}

// ---- TOTP ---------------------------------------------------------------------------------------

/// A TOTP code now, from a base32 secret or an `otpauth://` URI, with how many seconds it has left.
pub fn totp(spec: &str, now_ms: i64) -> Option<(String, u64)> {
    let (secret, period, digits, algorithm) = parse_totp(spec)?;
    let seconds = (now_ms / 1000) as u64;
    let counter = seconds / period;
    let code = hotp(&secret, counter, digits, &algorithm)?;
    Some((code, period - seconds % period))
}

fn parse_totp(spec: &str) -> Option<(Vec<u8>, u64, u32, String)> {
    let spec = spec.trim();
    if let Some(query) = spec.strip_prefix("otpauth://totp/").and_then(|rest| rest.split_once('?').map(|(_, q)| q)) {
        let mut secret = None;
        let (mut period, mut digits, mut algorithm) = (30, 6, "SHA1".to_string());
        for pair in query.split('&') {
            let (name, value) = pair.split_once('=')?;
            match name.to_ascii_lowercase().as_str() {
                "secret" => secret = base32(value),
                "period" => period = value.parse().ok()?,
                "digits" => digits = value.parse().ok()?,
                "algorithm" => algorithm = value.to_ascii_uppercase(),
                _ => {}
            }
        }
        return Some((secret?, period, digits, algorithm));
    }
    Some((base32(spec)?, 30, 6, "SHA1".into()))
}

fn hotp(secret: &[u8], counter: u64, digits: u32, algorithm: &str) -> Option<String> {
    let message = counter.to_be_bytes();
    let digest: Vec<u8> = match algorithm {
        "SHA256" => {
            let mut mac = Hmac::<Sha256>::new_from_slice(secret).ok()?;
            mac.update(&message);
            mac.finalize().into_bytes().to_vec()
        }
        "SHA1" => {
            let mut mac = Hmac::<sha1::Sha1>::new_from_slice(secret).ok()?;
            mac.update(&message);
            mac.finalize().into_bytes().to_vec()
        }
        _ => return None,
    };
    let offset = (digest[digest.len() - 1] & 0x0f) as usize;
    let value = u32::from_be_bytes([digest[offset] & 0x7f, digest[offset + 1], digest[offset + 2], digest[offset + 3]]);
    Some(format!("{:0width$}", value % 10u32.pow(digits), width = digits as usize))
}

/// RFC 4648 base32, case and spaces ignored, padding optional.
fn base32(text: &str) -> Option<Vec<u8>> {
    let mut bits: u64 = 0;
    let mut count = 0;
    let mut out = Vec::new();
    for c in text.chars().filter(|c| !c.is_whitespace() && *c != '=' && *c != '-') {
        let value = match c.to_ascii_uppercase() {
            c @ 'A'..='Z' => c as u64 - 'A' as u64,
            c @ '2'..='7' => c as u64 - '2' as u64 + 26,
            _ => return None,
        };
        bits = (bits << 5) | value;
        count += 5;
        if count >= 8 {
            count -= 8;
            out.push((bits >> count) as u8);
            bits &= (1 << count) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
    }

    /// PBKDF2 and HKDF against Python's hashlib and hmac (scratchpad/bw-vectors.py), not this crate.
    #[test]
    fn keys_derive_as_an_independent_implementation_derives_them() {
        let key = master_key("correct horse", " Someone@Example.com ", &Kdf::Pbkdf2 { iterations: 5000 }).unwrap();
        assert_eq!(key.to_vec(), hex(include_str!("../vectors/master_key.hex").trim()));
        assert_eq!(master_password_hash(&key, "correct horse"), include_str!("../vectors/hash.b64").trim());
        let stretched = stretch(&key);
        assert_eq!(stretched.to_bytes(), hex(include_str!("../vectors/stretched.hex").trim()));
    }

    /// An encrypted string openssl and Python made.
    #[test]
    fn opens_what_openssl_sealed_and_refuses_the_wrong_key() {
        let key = SymmetricKey::from_bytes(&hex(include_str!("../vectors/key.hex").trim())).unwrap();
        let sealed = include_str!("../vectors/sealed.txt").trim();
        assert_eq!(decrypt_string(sealed, &key).unwrap(), "hunter2 is not a password");
        let mut wrong = key.clone();
        wrong.mac[0] ^= 1;
        assert_eq!(decrypt_string(sealed, &wrong), Err(CryptoError::WrongKey));
        assert_eq!(decrypt_string("0.abc|def", &key), Err(CryptoError::Malformed));
        assert_eq!(decrypt_string(&sealed.replacen("2.", "2.A", 1), &key), Err(CryptoError::Malformed));
    }

    /// An organization's key, wrapped by openssl with OAEP for a private key openssl made and the user key sealed.
    #[test]
    fn opens_an_organizations_key_with_the_accounts_private_key() {
        let user = SymmetricKey::from_bytes(&hex(include_str!("../vectors/key.hex").trim())).unwrap();
        let private = private_key(include_str!("../vectors/org_private.txt").trim(), &user).unwrap();
        let org = SymmetricKey::from_bytes(&decrypt_rsa(include_str!("../vectors/org_key.txt").trim(), &private).unwrap()).unwrap();
        assert_eq!(decrypt_string(include_str!("../vectors/org_item.txt").trim(), &org).unwrap(), "Shared login");
        assert_eq!(decrypt_rsa("6.abc|def", &private), Err(CryptoError::Malformed));
    }

    /// RFC 6238's vectors, SHA-1 and SHA-256, cut to six digits.
    #[test]
    fn totp_codes_match_the_rfc() {
        let sha1 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
        assert_eq!(totp(sha1, 59_000).unwrap().0, "287082");
        assert_eq!(totp(sha1, 1_111_111_109_000).unwrap().0, "081804");
        let sha256 = "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA&algorithm=SHA256&digits=8";
        assert_eq!(totp(sha256, 59_000).unwrap().0, "46119246");
        assert_eq!(totp(sha1, 61_000).unwrap().1, 29);
        assert!(totp("not base32!", 0).is_none());
    }
}
