//! Plugins' native code in MAP_JIT memory, the one memory `allow-jit` lets become executable under the
//! hardened runtime. A compiled module is copied in once, by the one function `jit-write-allowlist` lets
//! write there, and wasmtime runs only code that lies in such memory (`.agents/IMPLEMENTATION.md` §11).

use std::ffi::{c_int, c_void};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};
use wasmtime::{CustomCodeMemory, Result};

type WriteFn = unsafe extern "C" fn(*mut c_void) -> c_int;

unsafe extern "C" {
    fn pthread_jit_write_with_callback_np(callback: WriteFn, ctx: *mut c_void) -> c_int;
    fn sys_icache_invalidate(start: *mut c_void, len: usize);
}

/// The callbacks `pthread_jit_write_with_callback_np` may run: C's `PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP`.
#[used]
#[unsafe(link_section = "__DATA_CONST,__pth_jit_func")]
static WRITE_ALLOWLIST: [Option<WriteFn>; 2] = [Some(write_image), None];

/// The region mapped and not yet written, and its size: `write_image` writes it once and nothing else.
static PENDING: AtomicUsize = AtomicUsize::new(0);
static PENDING_SIZE: AtomicUsize = AtomicUsize::new(0);
/// One load at a time, so `PENDING` is the loader's own region.
static LOADING: Mutex<()> = Mutex::new(());
/// Every live region, start to end: the only code `Publish` lets wasmtime run.
static REGIONS: Mutex<Vec<(usize, usize)>> = Mutex::new(Vec::new());

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[repr(C)]
struct Write {
    dst: *mut u8,
    src: *const u8,
    len: usize,
}

/// Its argument may be forged — any code can call the function — so it checks the destination against
/// what the loader left in `PENDING`, which it clears.
unsafe extern "C" fn write_image(ctx: *mut c_void) -> c_int {
    let write = unsafe { &*(ctx as *const Write) };
    let size = PENDING_SIZE.load(Ordering::SeqCst);
    let start = PENDING.swap(0, Ordering::SeqCst);
    if start == 0 || start != write.dst as usize || write.len > size {
        return -1;
    }
    unsafe { std::ptr::copy_nonoverlapping(write.src, write.dst, write.len) };
    0
}

/// A compiled module (`Engine::precompile_module`, `Module::serialize`) in MAP_JIT memory, for
/// `Module::deserialize_raw`. It must outlive every module and instance made from it.
pub struct JitCode {
    base: NonNull<u8>,
    mapped: usize,
    len: usize,
}

// Written once before anyone sees it, then only read and run.
unsafe impl Send for JitCode {}
unsafe impl Sync for JitCode {}

impl JitCode {
    pub fn new(image: &[u8]) -> Result<JitCode> {
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as usize;
        let mapped = image.len().div_ceil(page).max(1) * page;
        let protection = libc::PROT_READ | libc::PROT_WRITE | libc::PROT_EXEC;
        let flags = libc::MAP_PRIVATE | libc::MAP_ANON | libc::MAP_JIT;
        let base = unsafe { libc::mmap(std::ptr::null_mut(), mapped, protection, flags, -1, 0) };
        if base == libc::MAP_FAILED {
            wasmtime::bail!("no memory for native code: {}", std::io::Error::last_os_error());
        }
        let code = JitCode { base: NonNull::new(base as *mut u8).unwrap(), mapped, len: image.len() };
        let written = {
            let _loading = lock(&LOADING);
            PENDING_SIZE.store(mapped, Ordering::SeqCst);
            PENDING.store(base as usize, Ordering::SeqCst);
            let mut write = Write { dst: base as *mut u8, src: image.as_ptr(), len: image.len() };
            unsafe { pthread_jit_write_with_callback_np(write_image, &mut write as *mut Write as *mut c_void) }
        };
        if written != 0 {
            wasmtime::bail!("the native code could not be written");
        }
        unsafe { sys_icache_invalidate(base, image.len()) };
        lock(&REGIONS).push((base as usize, base as usize + mapped));
        Ok(code)
    }

    pub fn image(&self) -> NonNull<[u8]> {
        NonNull::slice_from_raw_parts(self.base, self.len)
    }
}

impl Drop for JitCode {
    fn drop(&mut self) {
        let start = self.base.as_ptr() as usize;
        lock(&REGIONS).retain(|region| region.0 != start);
        unsafe { libc::munmap(self.base.as_ptr() as *mut c_void, self.mapped) };
    }
}

/// wasmtime's publish step: MAP_JIT memory is executable as written, so this only refuses code anywhere
/// else — a module loaded some other way fails here rather than reaching for `mprotect`.
pub struct Publish;

impl CustomCodeMemory for Publish {
    fn required_alignment(&self) -> usize {
        1
    }

    fn publish_executable(&self, ptr: *const u8, len: usize) -> Result<()> {
        let (start, end) = (ptr as usize, ptr as usize + len);
        if lock(&REGIONS).iter().any(|&(from, to)| from <= start && end <= to) {
            return Ok(());
        }
        wasmtime::bail!("native code outside MAP_JIT memory")
    }

    fn unpublish_executable(&self, _ptr: *const u8, _len: usize) -> Result<()> {
        Ok(())
    }
}
