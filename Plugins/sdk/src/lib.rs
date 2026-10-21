//! dock2-plugin: write a dock2 plugin.
//!
//! A plugin is an actor: dock2 delivers one [`Event`] at a time, the plugin answers with [`Effects`], and
//! nothing it does blocks — I/O is an effect, its result a later event. Implement [`Plugin`] and export it:
//!
//! ```ignore
//! #[derive(Default)]
//! struct Hello;
//! impl dock2_plugin::Plugin for Hello {
//!     fn handle(&mut self, event: Event, out: &mut Effects) {
//!         if let Event::Command { .. } = event { out.toast("Hello") }
//!     }
//! }
//! dock2_plugin::export!(Hello);
//! ```
//!
//! The types here are the JSON dock2's `PluginProtocol.swift` and `ViewNode.swift` speak.

pub mod view;

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub use view::*;

/// The interface version this SDK targets: a manifest's `api`.
pub const API: u32 = 1;

// ---- events ---------------------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    Started { settings: BTreeMap<String, String> },
    Stopped,
    Settings { settings: BTreeMap<String, String> },
    Command { id: String },
    /// What is typed in search: answer with [`Effects::results`] under the same `id`.
    Query { id: u64, text: String },
    Action {
        action: String,
        item: Option<String>,
        view: Option<String>,
        result: Option<String>,
        tile: Option<String>,
    },
    Submit { view: String, values: BTreeMap<String, String> },
    /// A list's field, for an owner that filters it; answer with `answer_filter`, naming `id`.
    Filter {
        view: String,
        text: String,
        #[serde(default)]
        id: u64,
    },
    Tile { id: String },
    Timer { id: String },
    Http {
        request: String,
        status: Option<u16>,
        #[serde(default)]
        headers: BTreeMap<String, String>,
        #[serde(default, with = "base64_option")]
        body: Option<Vec<u8>>,
        error: Option<String>,
    },
    Storage { request: String, key: String, value: Option<String> },
    Secret { request: String, key: String, value: Option<String> },
    NowPlaying { info: Option<NowPlayingInfo> },
    /// The key a [`Effects::derive`] asked for.
    Derived {
        request: String,
        #[serde(with = "base64_bytes")]
        key: Vec<u8>,
    },
    ViewClosed { view: String },
    /// An effect dock2 refused or could not perform.
    Error { request: Option<String>, message: String },
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Default)]
pub struct NowPlayingInfo {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub playing: bool,
    pub duration: Option<f64>,
    pub elapsed: Option<f64>,
    /// When `elapsed` was true, in milliseconds since 1970.
    pub timestamp: Option<f64>,
    #[serde(default, with = "base64_option")]
    pub artwork: Option<Vec<u8>>,
    pub app: Option<String>,
}

impl NowPlayingInfo {
    /// Where the track is now, `elapsed` run on since `timestamp` while playing.
    pub fn position(&self, now_ms: i64) -> Option<f64> {
        let elapsed = self.elapsed?;
        match (self.playing, self.timestamp) {
            (true, Some(at)) => Some((elapsed + (now_ms as f64 - at) / 1000.0).max(0.0)),
            _ => Some(elapsed),
        }
    }
}

// ---- effects --------------------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Effect {
    ShowView { view: ViewNode },
    UpdateView {
        view: ViewNode,
        #[serde(skip_serializing_if = "Option::is_none")]
        answering: Option<u64>,
    },
    PopView,
    CloseView,
    Dismiss,
    Results { query: u64, items: Vec<ResultItem> },
    SetTile { id: String, tile: Tile },
    RemoveTile { id: String },
    Http {
        request: String,
        method: String,
        url: String,
        headers: BTreeMap<String, String>,
        #[serde(skip_serializing_if = "Option::is_none", with = "base64_option")]
        body: Option<Vec<u8>>,
    },
    StorageGet { request: String, key: String },
    StorageSet { key: String, value: String },
    StorageDelete { key: String },
    SecretGet { request: String, key: String },
    SecretSet { key: String, value: String },
    SecretDelete { key: String },
    Copy { text: String, concealed: bool },
    Paste { text: String, concealed: bool },
    Open { url: String },
    Toast { text: String },
    Timer {
        id: String,
        ms: u64,
        #[serde(rename = "repeat")]
        repeats: bool,
    },
    CancelTimer { id: String },
    Subscribe { event: String },
    NowPlaying {
        command: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        seconds: Option<f64>,
    },
    Derive {
        request: String,
        function: String,
        password: String,
        #[serde(with = "base64_bytes")]
        salt: Vec<u8>,
        iterations: u32,
        #[serde(skip_serializing_if = "Option::is_none")]
        memory: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        parallelism: Option<u32>,
        length: u32,
    },
}

/// A row in search, in the plugin's own section.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ResultItem {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<Action>,
}

/// A live tile on the dock.
#[derive(Debug, Clone, Serialize, PartialEq, Default)]
pub struct Tile {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<Icon>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub caption: Option<String>,
    /// The hover label.
    pub label: String,
}

/// What a plugin answers one event with. Every method queues an effect; dock2 performs them in order.
#[derive(Debug, Default)]
pub struct Effects {
    pub list: Vec<Effect>,
}

impl Effects {
    pub fn push(&mut self, effect: Effect) {
        self.list.push(effect);
    }
    pub fn show_view(&mut self, view: impl Into<ViewNode>) {
        self.push(Effect::ShowView { view: view.into() })
    }
    /// The view redrawn as the answer to filter `id`: dock2 keeps no answer older than one it has shown.
    pub fn answer_filter(&mut self, view: impl Into<ViewNode>, id: u64) {
        self.push(Effect::UpdateView { view: view.into(), answering: Some(id) })
    }
    pub fn update_view(&mut self, view: impl Into<ViewNode>) {
        self.push(Effect::UpdateView { view: view.into(), answering: None })
    }
    pub fn pop_view(&mut self) {
        self.push(Effect::PopView)
    }
    pub fn close_view(&mut self) {
        self.push(Effect::CloseView)
    }
    /// dock2 lets go — after a copy, say, as its own actions do.
    pub fn dismiss(&mut self) {
        self.push(Effect::Dismiss)
    }
    pub fn results(&mut self, query: u64, items: Vec<ResultItem>) {
        self.push(Effect::Results { query, items })
    }
    pub fn set_tile(&mut self, id: &str, tile: Tile) {
        self.push(Effect::SetTile { id: id.into(), tile })
    }
    pub fn remove_tile(&mut self, id: &str) {
        self.push(Effect::RemoveTile { id: id.into() })
    }
    /// An HTTP request to a host the manifest names; the answer comes as [`Event::Http`] under `request`.
    pub fn http(&mut self, request: &str, method: &str, url: &str, headers: &[(&str, &str)], body: Option<Vec<u8>>) {
        self.push(Effect::Http {
            request: request.into(),
            method: method.into(),
            url: url.into(),
            headers: headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            body,
        })
    }
    pub fn storage_get(&mut self, request: &str, key: &str) {
        self.push(Effect::StorageGet { request: request.into(), key: key.into() })
    }
    pub fn storage_set(&mut self, key: &str, value: &str) {
        self.push(Effect::StorageSet { key: key.into(), value: value.into() })
    }
    pub fn storage_delete(&mut self, key: &str) {
        self.push(Effect::StorageDelete { key: key.into() })
    }
    pub fn secret_get(&mut self, request: &str, key: &str) {
        self.push(Effect::SecretGet { request: request.into(), key: key.into() })
    }
    pub fn secret_set(&mut self, key: &str, value: &str) {
        self.push(Effect::SecretSet { key: key.into(), value: value.into() })
    }
    pub fn secret_delete(&mut self, key: &str) {
        self.push(Effect::SecretDelete { key: key.into() })
    }
    /// A concealed copy is never kept by clipboard history, nor by any manager that follows the convention.
    pub fn copy(&mut self, text: &str, concealed: bool) {
        self.push(Effect::Copy { text: text.into(), concealed })
    }
    /// Into the app in front, through the clipboard: concealed, as a copy can be.
    pub fn paste(&mut self, text: &str, concealed: bool) {
        self.push(Effect::Paste { text: text.into(), concealed })
    }
    /// Only in answer to something the user did: a command, an action, a form, a tile.
    pub fn open(&mut self, url: &str) {
        self.push(Effect::Open { url: url.into() })
    }
    pub fn toast(&mut self, text: &str) {
        self.push(Effect::Toast { text: text.into() })
    }
    pub fn timer(&mut self, id: &str, ms: u64, repeats: bool) {
        self.push(Effect::Timer { id: id.into(), ms, repeats })
    }
    pub fn cancel_timer(&mut self, id: &str) {
        self.push(Effect::CancelTimer { id: id.into() })
    }
    pub fn subscribe(&mut self, event: &str) {
        self.push(Effect::Subscribe { event: event.into() })
    }
    /// play, pause, toggle, next, previous, or seek with `seconds`.
    pub fn now_playing(&mut self, command: &str, seconds: Option<f64>) {
        self.push(Effect::NowPlaying { command: command.into(), seconds })
    }
    /// A 32-byte PBKDF2-HMAC-SHA256 key, derived by dock2 natively; it comes as [`Event::Derived`].
    pub fn derive_pbkdf2(&mut self, request: &str, password: &str, salt: &[u8], iterations: u32) {
        self.push(Effect::Derive {
            request: request.into(),
            function: "pbkdf2-sha256".into(),
            password: password.into(),
            salt: salt.to_vec(),
            iterations,
            memory: None,
            parallelism: None,
            length: 32,
        })
    }
    /// A 32-byte Argon2id key, `memory_kib` of memory, derived by dock2 natively.
    pub fn derive_argon2id(&mut self, request: &str, password: &str, salt: &[u8], iterations: u32, memory_kib: u32, parallelism: u32) {
        self.push(Effect::Derive {
            request: request.into(),
            function: "argon2id".into(),
            password: password.into(),
            salt: salt.to_vec(),
            iterations,
            memory: Some(memory_kib),
            parallelism: Some(parallelism),
            length: 32,
        })
    }
}

// ---- the plugin -----------------------------------------------------------------------------------

/// A plugin: one value for the instance's life, handed every event.
pub trait Plugin: Default {
    fn handle(&mut self, event: Event, out: &mut Effects);
}

// ---- the host's three calls -----------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
#[link(wasm_import_module = "dock2")]
unsafe extern "C" {
    #[link_name = "log"]
    fn host_log(level: i32, ptr: *const u8, len: usize);
    #[link_name = "now_ms"]
    fn host_now_ms() -> i64;
    #[link_name = "random"]
    fn host_random(ptr: *mut u8, len: usize);
}

#[derive(Clone, Copy)]
pub enum Level {
    Debug = 0,
    Info = 1,
    Warning = 2,
    Error = 3,
}

/// Into dock2's log, under the plugin's id.
pub fn log(level: Level, message: &str) {
    #[cfg(target_arch = "wasm32")]
    unsafe {
        host_log(level as i32, message.as_ptr(), message.len())
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = (level as i32, message);
    }
}

/// The wall clock, in milliseconds since 1970.
pub fn now_ms() -> i64 {
    #[cfg(target_arch = "wasm32")]
    unsafe {
        host_now_ms()
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
    }
}

/// Secure random bytes.
pub fn random(buffer: &mut [u8]) {
    #[cfg(target_arch = "wasm32")]
    for chunk in buffer.chunks_mut(4096) {
        unsafe { host_random(chunk.as_mut_ptr(), chunk.len()) }
    }
    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = buffer;
        unimplemented!("random bytes come from dock2")
    }
}

// ---- the ABI --------------------------------------------------------------------------------------

#[doc(hidden)]
pub mod abi {
    use super::*;

    pub fn alloc(len: u32) -> u32 {
        let mut buffer = Vec::<u8>::with_capacity(len as usize);
        let ptr = buffer.as_mut_ptr();
        std::mem::forget(buffer);
        ptr as u32
    }

    /// # Safety
    /// `ptr` and `len` must be a buffer `alloc` or `handle` gave out.
    pub unsafe fn free(ptr: u32, len: u32) {
        drop(unsafe { Vec::from_raw_parts(ptr as *mut u8, 0, len as usize) });
    }

    /// One event in; effects out as `ptr << 32 | len`, 0 for none; an event that does not parse, nothing.
    /// # Safety
    /// `ptr` and `len` must be the event the host wrote into an `alloc`ed buffer.
    pub unsafe fn handle<P: Plugin>(state: &mut Option<P>, ptr: u32, len: u32) -> u64 {
        let bytes = unsafe { std::slice::from_raw_parts(ptr as *const u8, len as usize) };
        let event: Event = match serde_json::from_slice(bytes) {
            Ok(event) => event,
            Err(error) => {
                log(Level::Warning, &format!("an event dock2-plugin cannot read: {error}"));
                return 0;
            }
        };
        let mut out = Effects::default();
        state.get_or_insert_with(P::default).handle(event, &mut out);
        if out.list.is_empty() {
            return 0;
        }
        // A boxed slice is exactly its length, as `free` will take it back.
        let json = serde_json::to_vec(&out.list).unwrap_or_default().into_boxed_slice();
        let len = json.len() as u64;
        let ptr = Box::leak(json).as_ptr() as u64;
        (ptr << 32) | len
    }
}

/// Exports `dock2_alloc`, `dock2_free` and `dock2_handle` for a [`Plugin`].
#[macro_export]
macro_rules! export {
    ($plugin:ty) => {
        static mut DOCK2_PLUGIN: Option<$plugin> = None;

        #[unsafe(no_mangle)]
        pub extern "C" fn dock2_alloc(len: u32) -> u32 {
            $crate::abi::alloc(len)
        }

        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn dock2_free(ptr: u32, len: u32) {
            unsafe { $crate::abi::free(ptr, len) }
        }

        #[unsafe(no_mangle)]
        #[allow(static_mut_refs)]
        pub unsafe extern "C" fn dock2_handle(ptr: u32, len: u32) -> u64 {
            // One event at a time, on one thread: dock2 never calls in while a call runs.
            unsafe { $crate::abi::handle(&mut DOCK2_PLUGIN, ptr, len) }
        }
    };
}

// ---- base64 for bytes in JSON, as Swift's JSONEncoder writes Data --------------------------------

pub(crate) mod base64_option {
    use super::*;
    use serde::{Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(bytes) => serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error> {
        let text: Option<String> = Option::deserialize(deserializer)?;
        text.map(|t| base64::engine::general_purpose::STANDARD.decode(t).map_err(serde::de::Error::custom)).transpose()
    }
}

/// Bytes as base64, not optional: an icon's PNG, a derived key.
pub(crate) mod base64_bytes {
    use super::*;
    use serde::{Deserializer, Serializer};

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        base64::engine::general_purpose::STANDARD.decode(text).map_err(serde::de::Error::custom)
    }
}
