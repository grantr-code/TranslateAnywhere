// translator_core/src/lib.rs
//
// Rust staticlib exporting C ABI for TranslateAnywhere offline translation.
// Matches the contract defined in translator_core.h exactly.

use std::sync::Mutex;

use once_cell::sync::OnceCell;

mod translator;
use translator::{TranslateError, Translator};

// ── Direction constants (must match TranslateDirection in C header) ──

const DIRECTION_AUTO_DETECT: i32 = 0;
const DIRECTION_EN_TO_RU: i32 = 1;
const DIRECTION_RU_TO_EN: i32 = 2;

// ── Status constants (must match TranslateStatus in C header) ──

const STATUS_OK: i32 = 0;
const STATUS_NOT_INITIALIZED: i32 = 1;
const STATUS_MODEL_NOT_FOUND: i32 = 2;
const STATUS_ENCODING_ERROR: i32 = 3;
const STATUS_TRANSLATION_FAIL: i32 = 4;
const STATUS_INVALID_INPUT: i32 = 5;

// ── Result struct (must match TranslateResult in C header) ──

#[repr(C)]
pub struct TranslateResult {
    pub data: *const u8,
    pub len: u32,
    pub status: i32,   // TranslateStatus
    pub detected: i32, // TranslateDirection
}

impl TranslateResult {
    fn ok(text: String, detected: i32) -> Self {
        let bytes = text.into_bytes();
        let len = bytes.len() as u32;
        let ptr = bytes.as_ptr();
        std::mem::forget(bytes);
        TranslateResult {
            data: ptr,
            len,
            status: STATUS_OK,
            detected,
        }
    }

    fn error(status: i32) -> Self {
        TranslateResult {
            data: std::ptr::null(),
            len: 0,
            status,
            detected: DIRECTION_AUTO_DETECT,
        }
    }
}

// ── Global translator instance ──

static TRANSLATOR: OnceCell<Mutex<Translator>> = OnceCell::new();

// ── Exported C ABI functions ──

/// Initialize the translation engine.
///
/// model_base_dir: UTF-8 bytes pointing to directory with model subdirectories.
/// dir_len: byte length of model_base_dir.
/// threads: number of intra-op threads for CTranslate2 (0 = auto).
///
/// Returns 0 on success, non-zero on failure.
#[no_mangle]
pub extern "C" fn tc_init(model_base_dir: *const u8, dir_len: u32, threads: i32) -> i32 {
    if model_base_dir.is_null() || dir_len == 0 {
        eprintln!("[translator_core] tc_init: null or empty model_base_dir");
        return STATUS_INVALID_INPUT;
    }

    let bytes = unsafe { std::slice::from_raw_parts(model_base_dir, dir_len as usize) };
    let dir_str = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[translator_core] tc_init: invalid UTF-8 in model_base_dir: {}", e);
            return STATUS_ENCODING_ERROR;
        }
    };

    let thread_count = if threads <= 0 { 4 } else { threads };

    match Translator::new(dir_str, thread_count) {
        Ok(t) => {
            if TRANSLATOR.set(Mutex::new(t)).is_err() {
                eprintln!("[translator_core] tc_init: already initialized");
                // Not an error — re-initialization is a no-op.
                return STATUS_OK;
            }
            eprintln!("[translator_core] tc_init: success");
            STATUS_OK
        }
        Err(TranslateError::ModelNotFound) => {
            eprintln!("[translator_core] tc_init: model not found");
            STATUS_MODEL_NOT_FOUND
        }
        Err(e) => {
            eprintln!("[translator_core] tc_init: failed: {:?}", e);
            STATUS_TRANSLATION_FAIL
        }
    }
}

/// Translate a UTF-8 string.
///
/// input: pointer to UTF-8 bytes (need not be null-terminated).
/// input_len: byte length of input.
/// direction: desired direction (AutoDetect inspects the input).
///
/// Returns a TranslateResult. Caller MUST call tc_free_buffer on
/// result.data / result.len when done.
#[no_mangle]
pub extern "C" fn tc_translate(input: *const u8, input_len: u32, direction: i32) -> TranslateResult {
    // Validate input pointer
    if input.is_null() || input_len == 0 {
        return TranslateResult::error(STATUS_INVALID_INPUT);
    }

    // Convert input bytes to &str
    let bytes = unsafe { std::slice::from_raw_parts(input, input_len as usize) };
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return TranslateResult::error(STATUS_ENCODING_ERROR),
    };

    // Resolve direction if AutoDetect
    let resolved_direction = if direction == DIRECTION_AUTO_DETECT {
        if tc_is_russian(input, input_len) == 1 {
            DIRECTION_RU_TO_EN
        } else {
            DIRECTION_EN_TO_RU
        }
    } else {
        direction
    };

    // Check that translator is initialized
    let translator_mutex = match TRANSLATOR.get() {
        Some(m) => m,
        None => {
            eprintln!("[translator_core] tc_translate: not initialized");
            return TranslateResult::error(STATUS_NOT_INITIALIZED);
        }
    };

    // Lock and translate
    let translator = match translator_mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            eprintln!("[translator_core] tc_translate: mutex poisoned, recovering");
            poisoned.into_inner()
        }
    };

    match translator.translate(text, resolved_direction) {
        Ok(result) => TranslateResult::ok(result, resolved_direction),
        Err(TranslateError::NotInitialized) => TranslateResult::error(STATUS_NOT_INITIALIZED),
        Err(TranslateError::ModelNotFound) => TranslateResult::error(STATUS_MODEL_NOT_FOUND),
        Err(TranslateError::EncodingError) => TranslateResult::error(STATUS_ENCODING_ERROR),
        Err(TranslateError::InvalidInput) => TranslateResult::error(STATUS_INVALID_INPUT),
        Err(TranslateError::TranslationFailed(msg)) => {
            eprintln!("[translator_core] tc_translate: translation failed: {}", msg);
            TranslateResult::error(STATUS_TRANSLATION_FAIL)
        }
    }
}

/// Free a buffer previously returned by tc_translate.
///
/// ptr: pointer to the buffer (may be null).
/// len: byte length of the buffer.
#[no_mangle]
pub extern "C" fn tc_free_buffer(ptr: *const u8, len: u32) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = Vec::from_raw_parts(ptr as *mut u8, len as usize, len as usize);
    }
}

/// Detect whether text is predominantly Russian (Cyrillic).
///
/// Returns 1 if Russian, 0 if English / other.
/// Works without models being loaded.
#[no_mangle]
pub extern "C" fn tc_is_russian(input: *const u8, input_len: u32) -> i32 {
    if input.is_null() || input_len == 0 {
        return 0;
    }

    let bytes = unsafe { std::slice::from_raw_parts(input, input_len as usize) };
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let mut cyrillic_count: u32 = 0;
    let mut alpha_count: u32 = 0;

    for ch in text.chars() {
        if ch.is_alphabetic() {
            alpha_count += 1;
            // Cyrillic Unicode ranges:
            //   U+0400..U+04FF  Cyrillic (basic)
            //   U+0500..U+052F  Cyrillic Supplement
            let cp = ch as u32;
            if (0x0400..=0x04FF).contains(&cp) || (0x0500..=0x052F).contains(&cp) {
                cyrillic_count += 1;
            }
        }
    }

    if alpha_count == 0 {
        return 0;
    }

    // If more than half of alphabetic characters are Cyrillic, classify as Russian
    if cyrillic_count * 2 > alpha_count {
        1
    } else {
        0
    }
}
