//! Bitwarden ([first-party](../../.agents/product/plugins/first-party.md#bitwarden)): sign in, then the vault
//! as a list; every copy concealed. The master password and key are dropped once they have opened the
//! user key; the session and the opened key are secrets, the latter until the lock timeout.

pub mod api;
pub mod crypto;
pub mod vault;

use api::{SecondFactor, Server, TokenAnswer};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use crypto::{Kdf, SymmetricKey};
use dock2_plugin::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use vault::{Opening, Vault, VaultItem};

/// What lasts between runs, sealed in the Keychain: never the master password, never the master key.
#[derive(Serialize, Deserialize, Clone, Debug)]
struct Session {
    email: String,
    kdf: KdfRecord,
    access: String,
    refresh: String,
    /// When the access token runs out, in milliseconds since 1970.
    expires: i64,
    /// The user key, sealed with the stretched master key.
    protected_key: String,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct KdfRecord {
    kind: u8,
    iterations: u32,
    memory: Option<u32>,
    parallelism: Option<u32>,
}

impl From<&Kdf> for KdfRecord {
    fn from(kdf: &Kdf) -> Self {
        match kdf {
            Kdf::Pbkdf2 { iterations } => KdfRecord { kind: 0, iterations: *iterations, memory: None, parallelism: None },
            Kdf::Argon2id { iterations, memory_mib, parallelism } => {
                KdfRecord { kind: 1, iterations: *iterations, memory: Some(*memory_mib), parallelism: Some(*parallelism) }
            }
        }
    }
}

impl KdfRecord {
    fn kdf(&self) -> Kdf {
        match self.kind {
            1 => Kdf::Argon2id { iterations: self.iterations, memory_mib: self.memory.unwrap_or(64), parallelism: self.parallelism.unwrap_or(4) },
            _ => Kdf::Pbkdf2 { iterations: self.iterations },
        }
    }
}

/// The opened user key, sealed in the Keychain until the lock timeout.
#[derive(Serialize, Deserialize)]
struct Unlocked {
    key: String,
    until: i64,
}

/// Where a sign-in or an unlock is, between the events that carry it on.
#[derive(Default)]
enum Pending {
    #[default]
    None,
    /// Prelogin asked for the KDF; the password waits for it.
    Prelogin { email: String, password: String },
    /// The master key is being derived, for a sign-in or an unlock.
    Deriving { email: String, password: String, kdf: Kdf, unlocking: bool },
    /// Signed in as far as the server's answer; a second factor or a new device's code may follow.
    Granting { email: String, master_key: [u8; 32], hash: String, kdf: Kdf, factor: Option<SecondFactor> },
}

#[derive(Default)]
struct Bitwarden {
    settings: BTreeMap<String, String>,
    session: Option<Session>,
    key: Option<SymmetricKey>,
    unlocked_until: i64,
    vault: Option<Vault>,
    /// The last sync, still sealed: what opens the vault after an unlock without the network.
    sealed_vault: Option<String>,
    /// The vault being opened a slice an event, with the sync it comes from.
    opening: Option<(Opening, serde_json::Value)>,
    /// Organizations' keys opened before, by their sealed form: RSA spent once per run.
    organization_keys: HashMap<String, SymmetricKey>,
    device: Option<String>,
    pending: Pending,
    /// Which of dock2's views is open: "login", "second-factor", "new-device", "unlock", "vault".
    view: Option<String>,
    form_error: Option<String>,
    syncing: bool,
    /// What Commands was last told to list.
    commands: Option<Vec<&'static str>>,
    loaded: u8,
    /// Events that came before the secrets were read.
    waiting: Vec<Event>,
}

const LOADS: u8 = 4;

impl Bitwarden {
    fn server(&self) -> Server {
        Server::from_setting(self.settings.get("server").map(String::as_str).unwrap_or("https://vault.bitwarden.com"))
    }

    fn lock_minutes(&self) -> i64 {
        self.settings.get("lockAfter").and_then(|m| m.trim().parse::<f64>().ok()).map(|m| m.max(0.0) as i64).unwrap_or(15)
    }

    fn is_unlocked(&self) -> bool {
        self.key.is_some() && now_ms() < self.unlocked_until
    }

    /// Signed out, only Sign In; locked, no Lock.
    fn commands(&self) -> Vec<&'static str> {
        match (&self.session, self.is_unlocked()) {
            (None, _) => vec!["sign-in"],
            (Some(_), false) => vec!["search", "sign-out"],
            (Some(_), true) => vec!["search", "lock", "sign-out"],
        }
    }

    // ---- views ----------------------------------------------------------------------------------

    fn show(&mut self, out: &mut Effects, view: &str) {
        let node: ViewNode = match view {
            "login" => self.login_form().into(),
            "second-factor" => self.code_form("second-factor").into(),
            "new-device" => self.code_form("new-device").into(),
            "unlock" => self.unlock_form().into(),
            _ => self.vault_list().into(),
        };
        if self.view.is_some() {
            out.update_view(node);
        } else {
            out.show_view(node);
        }
        self.view = Some(view.into());
    }

    fn login_form(&self) -> Form {
        Form {
            id: "login".into(),
            title: Some(format!("Sign in to {}", self.server().name)),
            fields: vec![
                Field::new("email", "Email", FieldKind::Text)
                    .value(self.session.as_ref().map(|s| s.email.as_str()).unwrap_or(""))
                    .placeholder("you@example.com"),
                Field::new("password", "Master password", FieldKind::Secure).error(self.form_error.as_deref()),
            ],
            submit: "Sign In".into(),
        }
    }

    fn code_form(&self, id: &str) -> Form {
        let (title, label) = match (id, &self.pending) {
            ("new-device", _) => ("A code went to your email", "The code from the email"),
            (_, Pending::Granting { factor: Some(SecondFactor::Email), .. }) => ("A code went to your email", "The code from the email"),
            _ => ("Your authenticator's code", "Six digits"),
        };
        Form {
            id: id.into(),
            title: Some(title.into()),
            fields: vec![Field::new("code", label, FieldKind::Text).error(self.form_error.as_deref())],
            submit: "Continue".into(),
        }
    }

    fn unlock_form(&self) -> Form {
        let email = self.session.as_ref().map(|s| s.email.clone()).unwrap_or_default();
        Form {
            id: "unlock".into(),
            title: Some(format!("Unlock {email}")),
            fields: vec![Field::new("password", "Master password", FieldKind::Secure).error(self.form_error.as_deref())],
            submit: "Unlock".into(),
        }
    }

    fn vault_list(&self) -> List {
        let items: Vec<Item> = self.vault.as_ref().map(|v| v.items.iter().map(list_item).collect()).unwrap_or_default();
        let shared = self.vault.as_ref().map(|v| v.shared).unwrap_or(0);
        let mut list = List::new("vault").title("Bitwarden").items(items).preview().filtering(Filtering::Dock2)
            .loading(self.syncing || self.opening.is_some());
        list = list.empty("Nothing in the vault", (shared > 0).then_some("Some organizations' items would not open."));
        list.actions = Some(vec![Action::new("sync", "Sync").key("cmd+shift+s"), Action::new("lock", "Lock").key("cmd+shift+l"),
                                 Action::new("sign-out", "Sign Out").destructive()]);
        list
    }

    // ---- signing in and unlocking -----------------------------------------------------------------

    fn sign_in(&mut self, values: &BTreeMap<String, String>, out: &mut Effects) {
        let email = values.get("email").cloned().unwrap_or_default().trim().to_string();
        let password = values.get("password").cloned().unwrap_or_default();
        if !email.contains('@') || password.is_empty() {
            self.form_error = Some("An email and the master password, please.".into());
            return self.show(out, "login");
        }
        self.form_error = None;
        let server = self.server();
        self.pending = Pending::Prelogin { email: email.clone(), password };
        out.http("prelogin", "POST", &format!("{}/accounts/prelogin", server.identity), &[("Content-Type", "application/json")],
                 Some(api::prelogin_body(&email)));
        out.toast("Signing in…");
    }

    fn unlock(&mut self, values: &BTreeMap<String, String>, out: &mut Effects) {
        let (Some(session), Some(password)) = (self.session.clone(), values.get("password").cloned()) else { return };
        let kdf = session.kdf.kdf();
        self.derive(&session.email, password, kdf, true, out);
    }

    /// dock2 derives the master key natively; it comes back as `Derived`.
    fn derive(&mut self, email: &str, password: String, kdf: Kdf, unlocking: bool, out: &mut Effects) {
        let salt = crypto::salt(email, &kdf);
        match &kdf {
            Kdf::Pbkdf2 { iterations } => out.derive_pbkdf2("master", &password, &salt, *iterations),
            Kdf::Argon2id { iterations, memory_mib, parallelism } => {
                out.derive_argon2id("master", &password, &salt, *iterations, memory_mib * 1024, *parallelism)
            }
        }
        self.pending = Pending::Deriving { email: email.into(), password, kdf, unlocking };
    }

    fn derived(&mut self, master_key: Vec<u8>, out: &mut Effects) {
        let Pending::Deriving { email, password, kdf, unlocking } = std::mem::take(&mut self.pending) else { return };
        let Ok(master_key) = <[u8; 32]>::try_from(master_key.as_slice()) else { return };
        if unlocking {
            let Some(session) = self.session.clone() else { return };
            match crypto::user_key(&session.protected_key, &master_key) {
                Ok(key) => {
                    self.form_error = None;
                    self.opened(key, out);
                }
                Err(_) => {
                    self.form_error = Some("That is not the master password.".into());
                    self.show(out, "unlock");
                }
            }
            return;
        }
        let hash = crypto::master_password_hash(&master_key, &password);
        self.pending = Pending::Granting { email, master_key, hash, kdf, factor: None };
        self.grant(None, None, out);
    }

    /// The password grant, with what the server asked for last time, if anything.
    fn grant(&mut self, factor: Option<(SecondFactor, &str)>, new_device: Option<&str>, out: &mut Effects) {
        let Pending::Granting { email, hash, .. } = &self.pending else { return };
        let (email, hash) = (email.clone(), hash.clone());
        let device = match self.device.clone() {
            Some(device) => device,
            None => self.new_device(out),
        };
        let headers = api::token_headers(&email);
        let headers: Vec<(&str, &str)> = headers.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        out.http("token", "POST", &format!("{}/connect/token", self.server().identity), &headers,
                 Some(api::token_body(&email, &hash, &device, factor, new_device)));
    }

    fn new_device(&mut self, out: &mut Effects) -> String {
        let mut bytes = [0u8; 16];
        random(&mut bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        let id = format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..]);
        out.storage_set("device", &id);
        self.device = Some(id.clone());
        id
    }

    fn token_answered(&mut self, status: Option<u16>, body: &[u8], out: &mut Effects) {
        match api::parse_token(status, body) {
            TokenAnswer::Session { access, refresh, expires_in, protected_key } => {
                let Pending::Granting { email, master_key, kdf, .. } = std::mem::take(&mut self.pending) else { return };
                let Ok(key) = crypto::user_key(&protected_key, &master_key) else {
                    self.form_error = Some("The account's key would not open.".into());
                    return self.show(out, "login");
                };
                let session = Session { email, kdf: (&kdf).into(), access, refresh, expires: now_ms() + expires_in as i64 * 1000, protected_key };
                out.secret_set("session", &serde_json::to_string(&session).unwrap_or_default());
                self.session = Some(session);
                self.form_error = None;
                self.opened(key, out);
            }
            TokenAnswer::SecondFactor(offered) => {
                let factor = if offered.contains(&SecondFactor::Authenticator) { SecondFactor::Authenticator } else { SecondFactor::Email };
                let api = self.server().api;
                if let Pending::Granting { factor: current, email, hash, .. } = &mut self.pending {
                    *current = Some(factor);
                    if factor == SecondFactor::Email {
                        out.http("send-email", "POST", &format!("{api}/two-factor/send-email-login"),
                                 &[("Content-Type", "application/json")], Some(api::send_email_body(email, hash)));
                    }
                }
                self.show(out, "second-factor");
            }
            TokenAnswer::NewDevice => self.show(out, "new-device"),
            TokenAnswer::Refused(message) => {
                let view = match self.view.as_deref() {
                    Some(view @ ("second-factor" | "new-device")) => view.to_string(),
                    _ => {
                        self.pending = Pending::None;
                        "login".to_string()
                    }
                };
                self.form_error = Some(message);
                self.show(out, &view);
            }
        }
    }

    /// The user key in hand: kept, sealed, until the lock timeout; the vault opened from the last sync,
    /// and synced again.
    fn opened(&mut self, key: SymmetricKey, out: &mut Effects) {
        self.unlocked_until = now_ms() + self.lock_minutes() * 60_000;
        out.secret_set("key", &serde_json::to_string(&Unlocked { key: BASE64.encode(key.to_bytes()), until: self.unlocked_until }).unwrap_or_default());
        self.key = Some(key);
        self.open_sealed(out);
        self.sync(out);
        self.show(out, "vault");
    }

    /// Opens the last sync with the key in hand, a slice an event.
    fn open_sealed(&mut self, out: &mut Effects) {
        let (Some(_), Some(sealed)) = (&self.key, &self.sealed_vault) else { return };
        let Ok(sync) = serde_json::from_str::<serde_json::Value>(sealed) else { return };
        self.opening = Some((Opening::new(&sync), sync));
        // The first step after this event: reading the sync is work enough for one.
        out.timer("open", 100, false);
    }

    /// One slice; the next after a timer, until the vault is open.
    fn open_more(&mut self, out: &mut Effects) {
        let (Some(key), Some((opening, sync))) = (&self.key, &mut self.opening) else { return };
        if !opening.step(sync, key, &mut self.organization_keys) {
            out.timer("open", 100, false);
            return;
        }
        let Some((opening, _)) = self.opening.take() else { return };
        self.vault = Some(opening.vault);
        if self.view.as_deref() == Some("vault") {
            self.show(out, "vault");
        }
    }

    fn lock(&mut self, out: &mut Effects) {
        self.key = None;
        self.vault = None;
        self.opening = None;
        self.unlocked_until = 0;
        out.secret_delete("key");
        if self.view.is_some() {
            self.show(out, "unlock");
        }
    }

    fn sign_out(&mut self, out: &mut Effects) {
        self.lock(out);
        self.session = None;
        self.sealed_vault = None;
        out.secret_delete("session");
        out.storage_delete("vault");
        if self.view.is_some() {
            self.show(out, "login");
        }
    }

    // ---- sync ---------------------------------------------------------------------------------------

    fn sync(&mut self, out: &mut Effects) {
        let Some(session) = &self.session else { return };
        if now_ms() > session.expires - 60_000 {
            return self.refresh(out);
        }
        self.syncing = true;
        let bearer = format!("Bearer {}", session.access);
        out.http("sync", "GET", &format!("{}/sync?excludeDomains=true", self.server().api), &[("Authorization", &bearer), ("Accept", "application/json")], None);
    }

    fn refresh(&mut self, out: &mut Effects) {
        let Some(session) = &self.session else { return };
        self.syncing = true;
        out.http("refresh", "POST", &format!("{}/connect/token", self.server().identity),
                 &[("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")], Some(api::refresh_body(&session.refresh)));
    }

    fn synced(&mut self, status: Option<u16>, body: Option<Vec<u8>>, out: &mut Effects) {
        self.syncing = false;
        match (status, body) {
            (Some(200), Some(body)) => {
                let text = String::from_utf8_lossy(&body).to_string();
                out.storage_set("vault", &text);
                self.sealed_vault = Some(text);
                self.open_sealed(out);
            }
            (Some(401), _) => return self.refresh(out),
            (status, _) => out.toast(&format!("Bitwarden would not sync ({})", status.map(|s| s.to_string()).unwrap_or_else(|| "offline".into()))),
        }
        if self.view.as_deref() == Some("vault") {
            self.show(out, "vault");
        }
    }

    fn refreshed(&mut self, status: Option<u16>, body: Option<Vec<u8>>, out: &mut Effects) {
        let answer = body.as_deref().and_then(|b| serde_json::from_slice::<serde_json::Value>(b).ok());
        match (status, answer.as_ref().and_then(|a| api::text(a, "access_token"))) {
            (Some(200), Some(access)) => {
                let Some(session) = &mut self.session else { return };
                session.access = access;
                session.expires = now_ms() + answer.as_ref().and_then(|a| api::number(a, "expires_in")).unwrap_or(3600) as i64 * 1000;
                if let Some(refresh) = answer.as_ref().and_then(|a| api::text(a, "refresh_token")) {
                    session.refresh = refresh;
                }
                out.secret_set("session", &serde_json::to_string(session).unwrap_or_default());
                self.sync(out);
            }
            // The server refused the refresh token: the session is over, sign in again.
            (Some(400 | 401), _) => {
                self.syncing = false;
                self.sign_out(out);
            }
            // Offline, or the server failing: the session and the last sync stay, for the next try.
            (status, _) => {
                self.syncing = false;
                out.toast(&format!("Bitwarden would not sync ({})", status.map(|s| s.to_string()).unwrap_or_else(|| "offline".into())));
                if self.view.as_deref() == Some("vault") {
                    self.show(out, "vault");
                }
            }
        }
    }

    // ---- actions --------------------------------------------------------------------------------

    fn act(&mut self, action: &str, item: Option<&str>, out: &mut Effects) {
        match action {
            "sync" => {
                self.sync(out);
                if self.view.is_some() {
                    self.show(out, "vault");
                }
                return;
            }
            "lock" => return self.lock(out),
            "sign-out" => return self.sign_out(out),
            _ => {}
        }
        let Some(item) = item.and_then(|id| self.vault.as_ref()?.items.iter().find(|i| i.id == id)).cloned() else { return };
        // Each use pushes the lock back.
        self.unlocked_until = now_ms() + self.lock_minutes() * 60_000;
        let (copied, what) = match action {
            "copy-password" => (item.password.clone(), "Password"),
            "copy-username" => (item.username.clone(), "Username"),
            "copy-code" => (item.totp.as_deref().and_then(|spec| crypto::totp(spec, now_ms())).map(|(code, _)| code), "Code"),
            "copy-url" => (item.uris.first().cloned(), "URL"),
            "open-site" => {
                if let Some(site) = item.site() {
                    out.open(&site);
                    out.dismiss();
                }
                return;
            }
            _ => return,
        };
        match copied {
            Some(text) => {
                out.copy(&text, true);
                out.dismiss();
                out.toast(&format!("{what} copied"));
            }
            None => out.toast(&format!("No {} for {}", what.to_lowercase(), item.name)),
        }
    }

    fn results(&self, id: u64, text: &str, out: &mut Effects) {
        let query = text.to_lowercase();
        let items = match (&self.vault, self.is_unlocked()) {
            (Some(vault), true) => vault
                .items
                .iter()
                .filter(|i| i.name.to_lowercase().contains(&query) || i.keywords().iter().any(|k| k.to_lowercase().contains(&query)))
                .take(10)
                .map(|i| ResultItem {
                    id: i.id.clone(),
                    title: i.name.clone(),
                    subtitle: i.username.clone(),
                    icon: Some(Icon::symbol("key")),
                    actions: item_actions(i),
                })
                .collect(),
            _ => vec![],
        };
        out.results(id, items);
    }

    // ---- the event loop -------------------------------------------------------------------------

    fn handle_loaded(&mut self, event: Event, out: &mut Effects) {
        match event {
            Event::Command { id } => match id.as_str() {
                "search" | "sign-in" => {
                    let view = match (&self.session, self.is_unlocked()) {
                        (None, _) => "login",
                        (Some(_), false) => "unlock",
                        (Some(_), true) => {
                            self.sync(out);
                            "vault"
                        }
                    };
                    self.view = None;
                    self.show(out, view);
                }
                "lock" => self.lock(out),
                "sign-out" => self.sign_out(out),
                _ => {}
            },
            Event::Submit { view, values } => match view.as_str() {
                "login" => self.sign_in(&values, out),
                "unlock" => self.unlock(&values, out),
                "second-factor" => {
                    let factor = match &self.pending {
                        Pending::Granting { factor: Some(factor), .. } => *factor,
                        _ => SecondFactor::Authenticator,
                    };
                    let code = values.get("code").cloned().unwrap_or_default();
                    self.grant(Some((factor, &code)), None, out);
                }
                "new-device" => {
                    let code = values.get("code").cloned().unwrap_or_default();
                    self.grant(None, Some(&code), out);
                }
                _ => {}
            },
            Event::Action { action, item, result, .. } => {
                let target = item.or(result);
                self.act(&action, target.as_deref(), out);
            }
            Event::Query { id, text } => self.results(id, &text, out),
            _ => {}
        }
    }
}

fn item_actions(item: &VaultItem) -> Vec<Action> {
    let mut actions = vec![Action::new("copy-password", "Copy Password"), Action::new("copy-username", "Copy Username")];
    if item.totp.is_some() {
        actions.push(Action::new("copy-code", "Copy Verification Code").key("cmd+shift+c"));
    }
    if item.site().is_some() {
        actions.push(Action::new("copy-url", "Copy URL"));
        actions.push(Action::new("open-site", "Open Site").key("cmd+shift+o"));
    }
    actions
}

fn list_item(item: &VaultItem) -> Item {
    let mut detail = Detail::new(&item.id);
    if let Some(username) = &item.username {
        detail = detail.row("Username", username);
    }
    if item.password.is_some() {
        detail = detail.row("Password", "••••••••");
    }
    if item.totp.is_some() {
        detail = detail.row("Verification code", "⌘⇧C copies it");
    }
    for uri in &item.uris {
        detail = detail.row("Site", uri);
    }
    if let Some(notes) = &item.notes {
        detail = detail.row("Notes", notes);
    }
    let mut row = Item::new(&item.id, &item.name).icon(Icon::symbol(if item.password.is_some() { "key" } else { "note.text" }))
        .keywords(item.keywords()).actions(item_actions(item)).detail(detail);
    if let Some(username) = &item.username {
        row = row.subtitle(username);
    }
    if item.shared {
        row = row.tag(Tag::new("Shared").tint(Tint::Blue));
    } else if item.totp.is_some() {
        row = row.tag(Tag::new("2FA").tint(Tint::Green));
    }
    row
}

impl Plugin for Bitwarden {
    /// Each event, then Commands told what the state it left shows, if that changed.
    fn handle(&mut self, event: Event, out: &mut Effects) {
        self.step(event, out);
        let commands = self.commands();
        if self.loaded == LOADS && self.commands.as_ref() != Some(&commands) {
            out.set_commands(&commands);
            self.commands = Some(commands);
        }
    }
}

impl Bitwarden {
    fn step(&mut self, event: Event, out: &mut Effects) {
        match event {
            Event::Started { settings } => {
                self.settings = settings;
                out.secret_get("load-session", "session");
                out.secret_get("load-key", "key");
                out.storage_get("load-device", "device");
                out.storage_get("load-vault", "vault");
                // The lock timeout is watched once a minute.
                out.timer("lock", 60_000, true);
            }
            Event::Settings { settings } => self.settings = settings,
            Event::Secret { request, value, .. } | Event::Storage { request, value, .. } if request.starts_with("load-") => {
                match request.as_str() {
                    "load-session" => self.session = value.and_then(|v| serde_json::from_str(&v).ok()),
                    "load-key" => match value.and_then(|v| serde_json::from_str::<Unlocked>(&v).ok()) {
                        // Unlocked before dock2 last quit, and still within the timeout.
                        Some(unlocked) if unlocked.until > now_ms() => {
                            self.key = BASE64.decode(unlocked.key).ok().and_then(|bytes| SymmetricKey::from_bytes(&bytes).ok());
                            self.unlocked_until = unlocked.until;
                        }
                        // The timeout passed while nothing ran to lock it: the key goes now.
                        Some(_) => out.secret_delete("key"),
                        None => {}
                    },
                    "load-device" => self.device = value,
                    _ => self.sealed_vault = value,
                }
                self.loaded += 1;
                if self.loaded == LOADS {
                    self.open_sealed(out);
                    for event in std::mem::take(&mut self.waiting) {
                        self.handle_loaded(event, out);
                    }
                }
            }
            Event::Timer { id } if id == "open" => self.open_more(out),
            Event::Timer { id } if id == "lock" => {
                if self.key.is_some() && now_ms() >= self.unlocked_until {
                    self.lock(out);
                }
            }
            Event::Http { request, status, body, error, .. } => match request.as_str() {
                "prelogin" => {
                    let Pending::Prelogin { email, password } = std::mem::take(&mut self.pending) else { return };
                    match body.as_deref().filter(|_| status == Some(200)).and_then(api::parse_prelogin) {
                        Some(kdf) => self.derive(&email, password, kdf, false, out),
                        None => {
                            self.form_error = Some(error.unwrap_or_else(|| format!("{} could not be reached.", self.server().name)));
                            self.show(out, "login");
                        }
                    }
                }
                "token" => self.token_answered(status, body.as_deref().unwrap_or_default(), out),
                "sync" => self.synced(status, body, out),
                "refresh" => self.refreshed(status, body, out),
                _ => {}
            },
            Event::Derived { key, .. } => self.derived(key, out),
            Event::Error { request, message } => {
                log(Level::Warning, &format!("{request:?}: {message}"));
                self.syncing = false;
                if matches!(request.as_deref(), Some("prelogin" | "token" | "master")) {
                    self.pending = Pending::None;
                    self.form_error = Some(message);
                    self.show(out, "login");
                }
            }
            Event::ViewClosed { .. } => {
                self.view = None;
                // A sign-in given up leaves nothing behind.
                if !matches!(self.pending, Pending::None) {
                    self.pending = Pending::None;
                }
            }
            event if self.loaded < LOADS => self.waiting.push(event),
            event => self.handle_loaded(event, out),
        }
    }
}

export!(Bitwarden);

/// The whole sign-in, driven through events as dock2 would deliver them, against a server whose answers
/// are sealed here with real keys: prelogin, the derived key, the grant, sync, a copy.
#[cfg(test)]
mod flow {
    use super::*;
    use aes::cipher::{BlockEncryptMut, KeyIvInit, block_padding::Pkcs7};
    use hmac::{Hmac, Mac};

    fn seal(plain: &[u8], key: &SymmetricKey) -> String {
        let iv = [7u8; 16];
        let data = cbc::Encryptor::<aes::Aes256>::new(&key.enc.into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain);
        let mut mac = Hmac::<sha2::Sha256>::new_from_slice(&key.mac).unwrap();
        mac.update(&iv);
        mac.update(&data);
        format!("2.{}|{}|{}", BASE64.encode(iv), BASE64.encode(&data), BASE64.encode(mac.finalize().into_bytes()))
    }

    fn deliver(plugin: &mut Bitwarden, event: Event) -> Vec<Effect> {
        let mut out = Effects::default();
        plugin.handle(event, &mut out);
        out.list
    }

    fn http(request: &str, status: u16, body: Vec<u8>) -> Event {
        Event::Http { request: request.into(), status: Some(status), headers: Default::default(), body: Some(body), error: None }
    }

    fn commands(ids: &[&str]) -> Effect {
        Effect::SetCommands { shown: ids.iter().map(|id| id.to_string()).collect() }
    }

    #[test]
    fn signs_in_syncs_and_copies_concealed() {
        let mut plugin = Bitwarden::default();
        deliver(&mut plugin, Event::Started { settings: [("server".to_string(), "https://vault.bitwarden.com".to_string())].into() });
        let mut effects = vec![];
        for (request, value) in [("load-session", None), ("load-key", None), ("load-device", Some("device-1")), ("load-vault", None)] {
            let event = if request.ends_with("session") || request.ends_with("key") {
                Event::Secret { request: request.into(), key: String::new(), value: value.map(Into::into) }
            } else {
                Event::Storage { request: request.into(), key: String::new(), value: value.map(Into::into) }
            };
            effects = deliver(&mut plugin, event);
        }
        // Signed out, Commands lists only Sign In.
        assert!(effects.contains(&commands(&["sign-in"])));

        // Signed out: the command shows the sign-in form.
        let effects = deliver(&mut plugin, Event::Command { id: "search".into() });
        assert!(matches!(&effects[..], [Effect::ShowView { view: ViewNode::Form(form) }] if form.id == "login"));

        // The form's values: prelogin first.
        let values = [("email".to_string(), "Someone@Example.com".to_string()), ("password".to_string(), "correct horse".to_string())].into();
        let effects = deliver(&mut plugin, Event::Submit { view: "login".into(), values });
        assert!(effects.iter().any(|e| matches!(e, Effect::Http { request, url, .. } if request == "prelogin" && url == "https://identity.bitwarden.com/accounts/prelogin")));

        // The KDF answered: dock2 asked to derive, with the lowercased email for salt.
        let effects = deliver(&mut plugin, http("prelogin", 200, br#"{"kdf":0,"kdfIterations":5000}"#.to_vec()));
        let [Effect::Derive { function, salt, iterations, .. }] = &effects[..] else { panic!("{effects:?}") };
        assert_eq!((function.as_str(), salt.as_slice(), *iterations), ("pbkdf2-sha256", b"someone@example.com".as_slice(), 5000));

        // dock2's derivation, here the test's own; the grant goes out with the hash, never the password.
        let master = crypto::master_key("correct horse", "someone@example.com", &Kdf::Pbkdf2 { iterations: 5000 }).unwrap();
        let effects = deliver(&mut plugin, Event::Derived { request: "master".into(), key: master.to_vec() });
        let [Effect::Http { request, body: Some(body), .. }] = &effects[..] else { panic!("{effects:?}") };
        let body = String::from_utf8(body.clone()).unwrap();
        assert!(request == "token" && !body.contains("correct") && body.contains("deviceIdentifier=device-1"));

        // The account's user key, sealed with the stretched master key, and a session.
        let user_key = SymmetricKey::from_bytes(&[9u8; 64]).unwrap();
        let protected = seal(&user_key.to_bytes(), &crypto::stretch(&master));
        let token = serde_json::json!({"access_token": "A", "refresh_token": "R", "expires_in": 3600, "Key": protected});
        let effects = deliver(&mut plugin, http("token", 200, serde_json::to_vec(&token).unwrap()));
        assert!(effects.iter().any(|e| matches!(e, Effect::SecretSet { key, value } if key == "session" && !value.contains("correct"))));
        assert!(effects.iter().any(|e| matches!(e, Effect::Http { request, .. } if request == "sync")));
        assert!(effects.contains(&commands(&["search", "lock", "sign-out"])));

        // The vault, sealed with the user key: an item with its own key, and one without.
        let item_key = SymmetricKey::from_bytes(&[3u8; 64]).unwrap();
        let sync = serde_json::json!({"ciphers": [
            {"id": "a", "name": seal(b"GitHub", &user_key), "login": {"username": seal(b"octocat", &user_key), "password": seal(b"s3cret", &user_key),
             "uris": [{"uri": seal(b"https://github.com/login", &user_key)}]}},
            {"id": "b", "key": seal(&item_key.to_bytes(), &user_key), "name": seal(b"Bank", &item_key), "login": {"password": seal(b"9999", &item_key)}},
        ]});
        let mut effects = deliver(&mut plugin, http("sync", 200, serde_json::to_vec(&sync).unwrap()));
        while plugin.opening.is_some() {
            effects = deliver(&mut plugin, Event::Timer { id: "open".into() });
        }
        let shown = effects.iter().find_map(|e| match e { Effect::UpdateView { view: ViewNode::List(list), .. } => Some(list.clone()), _ => None }).unwrap();
        assert_eq!(shown.sections[0].items.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(), ["Bank", "GitHub"]);

        // ↩ on GitHub: the password copied, concealed, and dock2 let go.
        let effects = deliver(&mut plugin, Event::Action { action: "copy-password".into(), item: Some("a".into()), view: Some("vault".into()), result: None, tile: None });
        assert!(effects.contains(&Effect::Copy { text: "s3cret".into(), concealed: true }) && effects.contains(&Effect::Dismiss));

        // Search finds it by its site too.
        let effects = deliver(&mut plugin, Event::Query { id: 3, text: "github.com".into() });
        assert!(matches!(&effects[..], [Effect::Results { query: 3, items }] if items.len() == 1 && items[0].title == "GitHub"));

        // Locked: the vault goes, and the master password opens it again from the last sync.
        let effects = deliver(&mut plugin, Event::Command { id: "lock".into() });
        assert!(plugin.vault.is_none() && effects.contains(&commands(&["search", "sign-out"])));
        let effects = deliver(&mut plugin, Event::Submit { view: "unlock".into(), values: [("password".to_string(), "wrong".to_string())].into() });
        assert!(matches!(&effects[..], [Effect::Derive { .. }]));
        let wrong = crypto::master_key("wrong", "someone@example.com", &Kdf::Pbkdf2 { iterations: 5000 }).unwrap();
        deliver(&mut plugin, Event::Derived { request: "master".into(), key: wrong.to_vec() });
        assert_eq!(plugin.form_error.as_deref(), Some("That is not the master password."));
        deliver(&mut plugin, Event::Submit { view: "unlock".into(), values: [("password".to_string(), "correct horse".to_string())].into() });
        deliver(&mut plugin, Event::Derived { request: "master".into(), key: master.to_vec() });
        // The vault opens a slice an event, each asking for the next with a timer.
        while plugin.opening.is_some() {
            deliver(&mut plugin, Event::Timer { id: "open".into() });
        }
        assert_eq!(plugin.vault.as_ref().map(|v| v.items.len()), Some(2));
    }

    /// Only a refused refresh token signs out; offline, the session and the sealed vault stay. A key whose
    /// timeout passed while dock2 was not running is deleted as the plugin starts.
    #[test]
    fn offline_keeps_the_session_and_an_expired_key_goes() {
        let session = Session { email: "a@b.co".into(), kdf: (&Kdf::Pbkdf2 { iterations: 1 }).into(), access: "A".into(), refresh: "R".into(),
                                expires: 0, protected_key: String::new() };
        let mut plugin = Bitwarden { loaded: LOADS, session: Some(session), sealed_vault: Some("{}".into()), ..Default::default() };
        let effects = deliver(&mut plugin, Event::Http { request: "refresh".into(), status: None, headers: Default::default(), body: None, error: Some("offline".into()) });
        assert!(plugin.session.is_some() && plugin.sealed_vault.is_some());
        assert!(effects.iter().all(|e| !matches!(e, Effect::SecretDelete { .. } | Effect::StorageDelete { .. })));
        deliver(&mut plugin, http("refresh", 503, b"{}".to_vec()));
        assert!(plugin.session.is_some());
        let effects = deliver(&mut plugin, http("refresh", 400, br#"{"error":"invalid_grant"}"#.to_vec()));
        assert!(plugin.session.is_none() && effects.contains(&Effect::SecretDelete { key: "session".into() }));
        assert!(effects.contains(&commands(&["sign-in"])));

        let mut plugin = Bitwarden::default();
        let expired = serde_json::to_string(&Unlocked { key: BASE64.encode([9u8; 64]), until: now_ms() - 1 }).unwrap();
        let effects = deliver(&mut plugin, Event::Secret { request: "load-key".into(), key: "key".into(), value: Some(expired) });
        assert!(plugin.key.is_none() && effects.contains(&Effect::SecretDelete { key: "key".into() }));
    }

    #[test]
    fn asks_for_a_second_factor_and_a_new_devices_code() {
        let mut plugin = Bitwarden { loaded: LOADS, device: Some("d".into()), ..Default::default() };
        plugin.pending = Pending::Granting { email: "a@b.co".into(), master_key: [1; 32], hash: "h".into(), kdf: Kdf::Pbkdf2 { iterations: 1 }, factor: None };
        let effects = deliver(&mut plugin, http("token", 400, br#"{"TwoFactorProviders": [0]}"#.to_vec()));
        assert!(matches!(&effects[..], [Effect::ShowView { view: ViewNode::Form(form) }, Effect::SetCommands { .. }] if form.id == "second-factor"));
        let effects = deliver(&mut plugin, Event::Submit { view: "second-factor".into(), values: [("code".to_string(), "123456".to_string())].into() });
        let [Effect::Http { body: Some(body), .. }] = &effects[..] else { panic!() };
        assert!(String::from_utf8_lossy(body).contains("twoFactorToken=123456&twoFactorProvider=0"));
        let effects = deliver(&mut plugin, http("token", 400, br#"{"error_description": "New device verification required."}"#.to_vec()));
        assert!(matches!(&effects[..], [Effect::UpdateView { view: ViewNode::Form(form), .. }] if form.id == "new-device"));
    }
}
