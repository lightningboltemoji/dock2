//! The vault as sync returns it, decrypted: each item's fields opened with its own key when it has one,
//! else its organization's — opened with the account's private key — or the user key.

use crate::api::{field, text};
use crate::crypto::{SymmetricKey, decrypt, decrypt_rsa, decrypt_string, private_key};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub struct VaultItem {
    pub id: String,
    pub name: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub totp: Option<String>,
    pub uris: Vec<String>,
    pub notes: Option<String>,
    pub favorite: bool,
    /// Held by an organization, not the account alone.
    pub shared: bool,
}

#[derive(Debug, Default, PartialEq)]
pub struct Vault {
    pub items: Vec<VaultItem>,
    /// Items of an organization whose key would not open, left closed.
    pub shared: usize,
    /// Items that would not open: a field sealed with a key this account does not have.
    pub unreadable: usize,
}

/// The vault opened a slice at a time: the organizations' keys in one step — RSA in the interpreter is a
/// fifth of a second each — then `SLICE` items a step, so no event outruns its budget however large the
/// vault. A plugin carries on with a timer between steps.
pub struct Opening {
    ciphers: Vec<Value>,
    next: usize,
    organizations: Option<HashMap<String, SymmetricKey>>,
    pub vault: Vault,
}

/// Items a step opens: about 0.4 ms each in the interpreter, against a 1 s budget.
pub const SLICE: usize = 300;

impl Opening {
    pub fn new(sync: &Value) -> Opening {
        let ciphers = field(sync, "ciphers").and_then(Value::as_array).cloned().unwrap_or_default();
        let organizations = field(sync, "profile").filter(|p| !p.is_null()).is_none().then(HashMap::new);
        Opening { ciphers, next: 0, organizations, vault: Vault::default() }
    }

    /// One step; true when the vault is open, its items in order. `known` holds organizations' keys opened
    /// before, by their sealed form, so a later sync or unlock spends no RSA on them.
    pub fn step(&mut self, sync: &Value, user_key: &SymmetricKey, known: &mut HashMap<String, SymmetricKey>) -> bool {
        let Some(organizations) = &self.organizations else {
            self.organizations = Some(organization_keys(sync, user_key, known));
            return false;
        };
        let end = (self.next + SLICE).min(self.ciphers.len());
        for cipher in &self.ciphers[self.next..end] {
            if field(cipher, "deletedDate").is_some_and(|d| !d.is_null()) {
                continue;
            }
            let key = match field(cipher, "organizationId").and_then(Value::as_str) {
                Some(organization) => match organizations.get(organization) {
                    Some(key) => key,
                    None => {
                        self.vault.shared += 1;
                        continue;
                    }
                },
                None => user_key,
            };
            match item(cipher, key) {
                Some(item) => self.vault.items.push(item),
                None => self.vault.unreadable += 1,
            }
        }
        self.next = end;
        let done = self.next >= self.ciphers.len();
        if done {
            self.vault.items.sort_by_key(|item| (!item.favorite, item.name.to_lowercase()));
        }
        done
    }
}

/// Logins and secure notes, by name; deleted ones left out: every step at once, for the tests.
pub fn open(sync: &Value, user_key: &SymmetricKey) -> Vault {
    let mut opening = Opening::new(sync);
    let mut known = HashMap::new();
    while !opening.step(sync, user_key, &mut known) {}
    opening.vault
}

/// Each organization's key, by id: sealed for this member with RSA, opened with the account's private key —
/// unless opened before.
fn organization_keys(sync: &Value, user_key: &SymmetricKey, known: &mut HashMap<String, SymmetricKey>) -> HashMap<String, SymmetricKey> {
    let Some(profile) = field(sync, "profile") else { return HashMap::new() };
    let organizations = field(profile, "organizations").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut private = None;
    organizations
        .iter()
        .filter_map(|organization| {
            let (id, sealed) = (text(organization, "id")?, text(organization, "key")?);
            if let Some(key) = known.get(&sealed) {
                return Some((id, key.clone()));
            }
            if private.is_none() {
                private = Some(text(profile, "privateKey").and_then(|p| private_key(&p, user_key).ok())?);
            }
            let key = SymmetricKey::from_bytes(&decrypt_rsa(&sealed, private.as_ref()?).ok()?).ok()?;
            known.insert(sealed, key.clone());
            Some((id, key))
        })
        .collect()
}

fn item(cipher: &Value, owner: &SymmetricKey) -> Option<VaultItem> {
    // An item may carry its own key, sealed with its owner's: the user's or its organization's.
    let key = match text(cipher, "key") {
        Some(sealed) => SymmetricKey::from_bytes(&decrypt(&sealed, owner).ok()?).ok()?,
        None => owner.clone(),
    };
    let open = |value: Option<String>| -> Option<String> { value.and_then(|sealed| decrypt_string(&sealed, &key).ok()) };
    let login = field(cipher, "login").filter(|l| !l.is_null());
    let uris = login
        .and_then(|l| field(l, "uris"))
        .and_then(Value::as_array)
        .map(|uris| uris.iter().filter_map(|u| open(text(u, "uri"))).collect())
        .unwrap_or_default();
    Some(VaultItem {
        id: text(cipher, "id")?,
        name: open(text(cipher, "name"))?,
        username: open(login.and_then(|l| text(l, "username"))),
        password: open(login.and_then(|l| text(l, "password"))),
        totp: open(login.and_then(|l| text(l, "totp"))),
        uris,
        notes: open(text(cipher, "notes")),
        favorite: field(cipher, "favorite").and_then(Value::as_bool).unwrap_or(false),
        shared: field(cipher, "organizationId").is_some_and(|o| !o.is_null()),
    })
}

impl VaultItem {
    /// What search and the list match besides the name: the username and the sites' hosts.
    pub fn keywords(&self) -> Vec<String> {
        let mut words: Vec<String> = self.username.iter().cloned().collect();
        words.extend(self.uris.iter().map(|uri| host(uri)));
        words
    }

    pub fn site(&self) -> Option<String> {
        self.uris.first().map(|uri| if uri.contains("://") { uri.clone() } else { format!("https://{uri}") })
    }
}

/// "github.com" from "https://github.com/login".
pub fn host(uri: &str) -> String {
    uri.split("://").last().unwrap_or(uri).split(['/', '?', '#']).next().unwrap_or(uri).trim_start_matches("www.").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sync answer sealed with the same openssl-made key the crypto tests use.
    #[test]
    fn opens_personal_items_and_counts_the_rest() {
        let hex = include_str!("../vectors/key.hex").trim();
        let bytes: Vec<u8> = (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect();
        let key = SymmetricKey::from_bytes(&bytes).unwrap();
        let sealed = include_str!("../vectors/sealed.txt").trim();
        let sync = serde_json::json!({
            "Profile": {"PrivateKey": include_str!("../vectors/org_private.txt").trim(),
                        "Organizations": [{"Id": "org", "Key": include_str!("../vectors/org_key.txt").trim()}]},
            "Ciphers": [
                {"Id": "1", "Name": sealed, "Login": {"Username": sealed, "Uris": [{"Uri": sealed}]}, "Favorite": true},
                {"id": "2", "name": include_str!("../vectors/org_item.txt").trim(), "organizationId": "org"},
                {"id": "5", "name": sealed, "organizationId": "another"},
                {"id": "3", "name": sealed, "deletedDate": "2026-01-01T00:00:00Z"},
                {"id": "4", "name": "2.AAAAAAAAAAAAAAAAAAAAAA==|AAAA|AAAA"},
            ]
        });
        let vault = open(&sync, &key);
        assert_eq!(vault.items.iter().map(|i| i.name.as_str()).collect::<Vec<_>>(), ["hunter2 is not a password", "Shared login"]);
        assert_eq!(vault.items[0].username.as_deref(), Some("hunter2 is not a password"));
        assert_eq!((vault.shared, vault.unreadable), (1, 1));
        assert_eq!(host("https://www.github.com/login?x"), "github.com");
    }
}
