//! dockwasm — dock2's plugin engine: a narrow C ABI over wasmtime's Pulley interpreter. One engine per
//! process, one module per plugin build, one instance per running plugin; any call that fails poisons its
//! instance, and the host starts a fresh one (`.agents/IMPLEMENTATION.md` §11).
//!
//! # Safety
//!
//! Every `dw_` function takes what dock2's `PluginEngine` gives it: handles this crate made and has not
//! freed, buffers valid for the lengths beside them — empty ones possibly null — and out-pointers to write.
//! That one contract covers them all, so it is said here rather than on each.
#![allow(clippy::missing_safety_doc)]

use std::ffi::{CString, c_char, c_void};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use wasmtime::{
    Caller, Config, Engine, Extern, InstancePre, Linker, Memory, Module, ResourceLimiter, Result, Store, Trap,
    TypedFunc, UpdateDeadline,
};

pub const DW_OK: i32 = 0;
pub const DW_DEADLINE: i32 = 1;
pub const DW_MEMORY: i32 = 2;
pub const DW_TRAP: i32 = 3;
pub const DW_ERROR: i32 = 4;

/// The most a guest may log or ask for at once, in bytes.
const HOST_CALL_LIMIT: u32 = 64 * 1024;

pub struct DwEngine {
    engine: Engine,
    linker: Linker<HostState>,
    ticking: Arc<Ticking>,
    ticker: Option<JoinHandle<()>>,
}

/// The calls running, which the ticker ticks for: with none, it waits, and dock2 idles without a wake a
/// millisecond.
#[derive(Default)]
struct Ticking {
    /// Calls in flight, and whether the engine is going.
    state: Mutex<(usize, bool)>,
    wake: Condvar,
}

impl Ticking {
    fn state(&self) -> MutexGuard<'_, (usize, bool)> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Ticks until the guard is dropped.
    fn running(self: &Arc<Self>) -> Running {
        self.state().0 += 1;
        self.wake.notify_one();
        Running(self.clone())
    }

    /// Blocks while nothing runs; false once the engine is going.
    fn wait_for_calls(&self) -> bool {
        let mut state = self.state();
        while state.0 == 0 && !state.1 {
            state = self.wake.wait(state).unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        !state.1
    }

    fn stop(&self) {
        self.state().1 = true;
        self.wake.notify_one();
    }
}

struct Running(Arc<Ticking>);

impl Drop for Running {
    fn drop(&mut self) {
        self.0.state().0 -= 1;
    }
}

pub struct DwModule {
    pre: InstancePre<HostState>,
}

type LogFn = extern "C" fn(ctx: *mut c_void, level: i32, ptr: *const u8, len: usize);

/// Refuses a memory.grow past the cap: the guest sees -1, and a guest that cannot cope traps.
struct Limiter {
    cap: usize,
    hit_cap: bool,
}

impl ResourceLimiter for Limiter {
    fn memory_growing(&mut self, _current: usize, desired: usize, _max: Option<usize>) -> Result<bool> {
        if desired > self.cap {
            self.hit_cap = true;
            return Ok(false);
        }
        Ok(true)
    }
    fn table_growing(&mut self, _current: usize, desired: usize, _max: Option<usize>) -> Result<bool> {
        Ok(desired <= 100_000)
    }
    fn instances(&self) -> usize {
        1
    }
    fn memories(&self) -> usize {
        1
    }
    fn tables(&self) -> usize {
        4
    }
}

struct HostState {
    limiter: Limiter,
    deadline: Instant,
    log: Option<LogFn>,
    log_ctx: usize,
}

pub struct DwInstance {
    store: Store<HostState>,
    ticking: Arc<Ticking>,
    memory: Memory,
    alloc: TypedFunc<u32, u32>,
    free: TypedFunc<(u32, u32), ()>,
    handle: TypedFunc<(u32, u32), u64>,
    poisoned: bool,
}

// ---- helpers --------------------------------------------------------------------------------------

/// The bytes Swift hands over. An empty buffer's pointer may be null, which a slice may never be.
unsafe fn borrowed<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(ptr, len) } }
}

unsafe fn borrowed_mut<'a>(ptr: *mut u8, len: usize) -> &'a mut [u8] {
    if ptr.is_null() || len == 0 { &mut [] } else { unsafe { std::slice::from_raw_parts_mut(ptr, len) } }
}

unsafe fn set_err(err: *mut *mut c_char, msg: String) {
    if !err.is_null() {
        let c = CString::new(msg.replace('\0', " ")).unwrap();
        unsafe { *err = c.into_raw() };
    }
}

unsafe fn put_bytes(out: *mut *mut u8, out_len: *mut usize, bytes: Vec<u8>) {
    let b = bytes.into_boxed_slice();
    unsafe {
        *out_len = b.len();
        *out = Box::into_raw(b) as *mut u8;
    }
}

fn guest_range(len: usize, ptr: u32, size: u32) -> Result<std::ops::Range<usize>> {
    let (p, l) = (ptr as usize, size as usize);
    let end = p.checked_add(l).ok_or_else(|| wasmtime::format_err!("guest range overflows"))?;
    if end > len {
        wasmtime::bail!("guest range {p}+{l} is out of bounds");
    }
    Ok(p..end)
}

fn memory(caller: &mut Caller<'_, HostState>) -> Result<Memory> {
    match caller.get_export("memory") {
        Some(Extern::Memory(memory)) => Ok(memory),
        _ => wasmtime::bail!("the guest exports no memory"),
    }
}

/// The three calls a plugin makes, module `dock2`, all immediate: nothing hands bytes back into the guest
/// mid-call, since the results of I/O arrive as later events.
fn build_linker(engine: &Engine) -> Result<Linker<HostState>> {
    let mut linker = Linker::new(engine);
    linker.func_wrap("dock2", "log", |mut caller: Caller<'_, HostState>, level: i32, ptr: u32, len: u32| -> Result<()> {
        let memory = memory(&mut caller)?;
        let (data, state) = memory.data_and_store_mut(&mut caller);
        let range = guest_range(data.len(), ptr, len.min(HOST_CALL_LIMIT))?;
        if let Some(log) = state.log {
            log(state.log_ctx as *mut c_void, level, data[range.clone()].as_ptr(), range.len());
        }
        Ok(())
    })?;
    linker.func_wrap("dock2", "now_ms", || -> i64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
    })?;
    linker.func_wrap("dock2", "random", |mut caller: Caller<'_, HostState>, ptr: u32, len: u32| -> Result<()> {
        let memory = memory(&mut caller)?;
        let data = memory.data_mut(&mut caller);
        let range = guest_range(data.len(), ptr, len.min(HOST_CALL_LIMIT))?;
        unsafe extern "C" {
            fn arc4random_buf(buf: *mut c_void, nbytes: usize);
        }
        let buffer = &mut data[range];
        unsafe { arc4random_buf(buffer.as_mut_ptr() as *mut c_void, buffer.len()) };
        Ok(())
    })?;
    Ok(linker)
}

// ---- engine ---------------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn dw_version() -> *const c_char {
    c"wasmtime 49.0.4, pulley64".as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_engine_new(err: *mut *mut c_char) -> *mut DwEngine {
    let made = (|| -> Result<DwEngine> {
        let mut config = Config::new();
        config.target("pulley64")?;
        config.epoch_interruption(true);
        let engine = Engine::new(&config)?;
        let linker = build_linker(&engine)?;
        let ticking = Arc::new(Ticking::default());
        // A tick a millisecond while a call runs: its deadline callback checks the wall clock at every
        // tick, so a budget ends within a tick of when it should whatever the ticker's jitter.
        let (epochs, calls) = (engine.clone(), ticking.clone());
        let ticker = std::thread::Builder::new()
            .name("dockwasm-epoch".into())
            .spawn(move || {
                while calls.wait_for_calls() {
                    std::thread::sleep(Duration::from_millis(1));
                    epochs.increment_epoch();
                }
            })?;
        Ok(DwEngine { engine, linker, ticking, ticker: Some(ticker) })
    })();
    match made {
        Ok(engine) => Box::into_raw(Box::new(engine)),
        Err(error) => {
            unsafe { set_err(err, format!("{error:?}")) };
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_engine_free(engine: *mut DwEngine) {
    if engine.is_null() {
        return;
    }
    let mut engine = unsafe { Box::from_raw(engine) };
    engine.ticking.stop();
    if let Some(ticker) = engine.ticker.take() {
        let _ = ticker.join();
    }
}

// ---- module ---------------------------------------------------------------------------------------

unsafe fn finish_module(engine: &DwEngine, module: Result<Module>, err: *mut *mut c_char) -> *mut DwModule {
    match module.and_then(|module| engine.linker.instantiate_pre(&module)) {
        Ok(pre) => Box::into_raw(Box::new(DwModule { pre })),
        Err(error) => {
            unsafe { set_err(err, format!("{error:?}")) };
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_module_compile(engine: *const DwEngine, wasm: *const u8, len: usize, err: *mut *mut c_char) -> *mut DwModule {
    let engine = unsafe { &*engine };
    let bytes = unsafe { borrowed(wasm, len) };
    unsafe { finish_module(engine, Module::new(&engine.engine, bytes), err) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_module_serialize(module: *const DwModule, out: *mut *mut u8, out_len: *mut usize, err: *mut *mut c_char) -> i32 {
    match unsafe { &*module }.pre.module().serialize() {
        Ok(bytes) => {
            unsafe { put_bytes(out, out_len, bytes) };
            DW_OK
        }
        Err(error) => {
            unsafe { set_err(err, format!("{error:?}")) };
            DW_ERROR
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_module_deserialize(engine: *const DwEngine, bytes: *const u8, len: usize, err: *mut *mut c_char) -> *mut DwModule {
    let engine = unsafe { &*engine };
    let bytes = unsafe { borrowed(bytes, len) };
    // Safety: the bytes come from dw_module_serialize on this engine's build — dock2's own cache.
    let module = unsafe { Module::deserialize(&engine.engine, bytes) };
    unsafe { finish_module(engine, module, err) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_module_free(module: *mut DwModule) {
    if !module.is_null() {
        drop(unsafe { Box::from_raw(module) });
    }
}

// ---- instance -------------------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_instance_new(
    engine: *const DwEngine,
    module: *const DwModule,
    memory_cap: u64,
    log: Option<LogFn>,
    log_ctx: *mut c_void,
    err: *mut *mut c_char,
) -> *mut DwInstance {
    let (engine, module) = unsafe { (&*engine, &*module) };
    let made = (|| -> Result<DwInstance> {
        let state = HostState {
            limiter: Limiter { cap: memory_cap as usize, hit_cap: false },
            deadline: Instant::now() + Duration::from_secs(1),
            log,
            log_ctx: log_ctx as usize,
        };
        let mut store = Store::new(&engine.engine, state);
        store.limiter(|state| &mut state.limiter);
        store.set_epoch_deadline(1);
        store.epoch_deadline_callback(|context| {
            Ok(if Instant::now() >= context.data().deadline { UpdateDeadline::Interrupt } else { UpdateDeadline::Continue(1) })
        });
        // A module's start function is a call like any other, under the same second.
        let _running = engine.ticking.running();
        let instance = module.pre.instantiate(&mut store)?;
        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| wasmtime::format_err!("the guest exports no memory"))?;
        let alloc = instance.get_typed_func::<u32, u32>(&mut store, "dock2_alloc")?;
        let free = instance.get_typed_func::<(u32, u32), ()>(&mut store, "dock2_free")?;
        let handle = instance.get_typed_func::<(u32, u32), u64>(&mut store, "dock2_handle")?;
        Ok(DwInstance { store, ticking: engine.ticking.clone(), memory, alloc, free, handle, poisoned: false })
    })();
    match made {
        Ok(instance) => Box::into_raw(Box::new(instance)),
        Err(error) => {
            unsafe { set_err(err, format!("{error:?}")) };
            std::ptr::null_mut()
        }
    }
}

fn call_inner(instance: &mut DwInstance, event: &[u8]) -> Result<Vec<u8>> {
    let len = u32::try_from(event.len())?;
    let ptr = instance.alloc.call(&mut instance.store, len)?;
    instance.memory.write(&mut instance.store, ptr as usize, event)?;
    let packed = instance.handle.call(&mut instance.store, (ptr, len))?;
    instance.free.call(&mut instance.store, (ptr, len))?;
    // Zero: no effects.
    if packed == 0 {
        return Ok(b"[]".to_vec());
    }
    let (out_ptr, out_len) = ((packed >> 32) as u32, packed as u32);
    let range = guest_range(instance.memory.data_size(&instance.store), out_ptr, out_len)?;
    let out = instance.memory.data(&instance.store)[range].to_vec();
    instance.free.call(&mut instance.store, (out_ptr, out_len))?;
    Ok(out)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_instance_call(
    instance: *mut DwInstance,
    event: *const u8,
    len: usize,
    budget_ms: u32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let instance = unsafe { &mut *instance };
    if instance.poisoned {
        unsafe { put_bytes(out, out_len, b"the instance failed earlier: start a new one".to_vec()) };
        return DW_ERROR;
    }
    let event = unsafe { borrowed(event, len) };
    instance.store.data_mut().deadline = Instant::now() + Duration::from_millis(budget_ms as u64);
    instance.store.data_mut().limiter.hit_cap = false;
    instance.store.set_epoch_deadline(1);
    let running = instance.ticking.running();
    let result = call_inner(instance, event);
    drop(running);
    match result {
        Ok(bytes) => {
            unsafe { put_bytes(out, out_len, bytes) };
            DW_OK
        }
        Err(error) => {
            instance.poisoned = true;
            let status = match error.downcast_ref::<Trap>() {
                Some(Trap::Interrupt) => DW_DEADLINE,
                _ if instance.store.data().limiter.hit_cap => DW_MEMORY,
                Some(_) => DW_TRAP,
                None => DW_ERROR,
            };
            unsafe { put_bytes(out, out_len, format!("{error:?}").into_bytes()) };
            status
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_instance_free(instance: *mut DwInstance) {
    if !instance.is_null() {
        drop(unsafe { Box::from_raw(instance) });
    }
}

// ---- key derivation ---------------------------------------------------------------------------------

/// PBKDF2-HMAC-SHA256 into `out`. 0 on success.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_pbkdf2_sha256(
    password: *const u8,
    password_len: usize,
    salt: *const u8,
    salt_len: usize,
    iterations: u32,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    if iterations == 0 {
        return -1;
    }
    let (password, salt) = unsafe { (borrowed(password, password_len), borrowed(salt, salt_len)) };
    let out = unsafe { borrowed_mut(out, out_len) };
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password, salt, iterations, out);
    0
}

/// Argon2id, version 0x13, `memory_kib` of memory, into `out`. 0 on success.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_argon2id(
    password: *const u8,
    password_len: usize,
    salt: *const u8,
    salt_len: usize,
    iterations: u32,
    memory_kib: u32,
    parallelism: u32,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    let (password, salt) = unsafe { (borrowed(password, password_len), borrowed(salt, salt_len)) };
    let out = unsafe { borrowed_mut(out, out_len) };
    let Ok(params) = argon2::Params::new(memory_kib, iterations, parallelism, Some(out_len)) else { return -1 };
    match argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params).hash_password_into(password, salt, out) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dw_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
