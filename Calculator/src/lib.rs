//! dock2's calculator: fend behind the C ABI in `include/dockcalc.h`, driven by `Sources/Dock2Calc`.

use std::ffi::{CStr, CString, c_char};
use std::ptr;
use std::thread;
use std::time::{Duration, Instant};

/// Longer than any question typed, and short enough that fend's deepest nesting fits `STACK` many times over.
const MAX_QUESTION: usize = 256;
/// fend parses by recursion, about 4.3 KB a character at worst: a dispatch queue's 512 KiB overflows.
const STACK: usize = 8 << 20;

struct Deadline(Instant);

impl fend_core::Interrupt for Deadline {
    fn should_interrupt(&self) -> bool {
        Instant::now() >= self.0
    }
}

fn answer(question: String, budget: Duration, comma_decimals: bool) -> Option<String> {
    let deadline = Deadline(Instant::now() + budget);
    let worker = thread::Builder::new().name("dockcalc".into()).stack_size(STACK).spawn(move || {
        let mut context = fend_core::Context::new();
        if comma_decimals {
            context.set_decimal_separator_style(fend_core::DecimalSeparatorStyle::Comma);
        }
        // The preview drops what a live answer should not show: errors, the question restated, a unit
        // type, more than a line.
        fend_core::evaluate_preview_with_interrupt(&question, &context, &deadline).get_main_result().to_owned()
    });
    // A panic ends only the worker, and comes back as an error from join.
    let answer = worker.ok()?.join().ok()?;
    (!answer.is_empty()).then_some(answer)
}

/// fend's live answer to `question`, or null. Free it with `dc_string_free`.
///
/// # Safety
/// `question` is null or a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_answer(question: *const c_char, budget_ms: u32, comma_decimals: bool) -> *mut c_char {
    if question.is_null() {
        return ptr::null_mut();
    }
    let Ok(question) = unsafe { CStr::from_ptr(question) }.to_str() else { return ptr::null_mut() };
    if question.len() > MAX_QUESTION {
        return ptr::null_mut();
    }
    answer(question.to_owned(), Duration::from_millis(budget_ms.into()), comma_decimals)
        .and_then(|answer| CString::new(answer).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// `s` is null or a string `dc_answer` returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dc_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dc_version() -> *const c_char {
    c"fend 1.5.9".as_ptr()
}
