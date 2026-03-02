// translator_core/src/translator.rs
//
// Internal module managing CTranslate2 translation via C++ FFI.
// Models are lazily loaded on the C++ side (first translate call per direction).

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;

// FFI declarations for the C++ wrapper (ctranslate2_wrapper.cpp)
extern "C" {
    fn cpp_translate(
        input_text: *const c_char,
        model_base_dir: *const c_char,
        direction: c_int,
        threads: c_int,
    ) -> *mut c_char;

    fn cpp_free_string(ptr: *mut c_char);
}

/// Errors that can occur during translation.
#[derive(Debug)]
pub enum TranslateError {
    NotInitialized,
    ModelNotFound,
    EncodingError,
    TranslationFailed(String),
    InvalidInput,
}

/// Manages model directory paths and thread configuration.
/// The actual CTranslate2 models are loaded lazily on the C++ side.
pub struct Translator {
    model_base_dir: PathBuf,
    threads: i32,
}

impl Translator {
    /// Create a new Translator instance.
    ///
    /// Verifies that the expected model subdirectories exist on disk.
    /// Does not load models — that happens lazily on first translation.
    pub fn new(model_base_dir: &str, threads: i32) -> Result<Self, TranslateError> {
        let path = PathBuf::from(model_base_dir);

        // Verify model directories exist
        let en_ru = path.join("opus-mt-en-ru");
        let ru_en = path.join("opus-mt-ru-en");

        if !en_ru.exists() {
            eprintln!(
                "[translator_core] Model directory not found: {:?}",
                en_ru
            );
            return Err(TranslateError::ModelNotFound);
        }

        if !ru_en.exists() {
            eprintln!(
                "[translator_core] Model directory not found: {:?}",
                ru_en
            );
            return Err(TranslateError::ModelNotFound);
        }

        eprintln!(
            "[translator_core] Translator initialized with model dir: {:?}, threads: {}",
            path, threads
        );

        Ok(Translator {
            model_base_dir: path,
            threads,
        })
    }

    /// Translate text in the given direction.
    ///
    /// direction: 1 = en->ru, 2 = ru->en.
    /// The caller (lib.rs) has already resolved AutoDetect before calling this.
    pub fn translate(&self, text: &str, direction: i32) -> Result<String, TranslateError> {
        if text.is_empty() {
            return Err(TranslateError::InvalidInput);
        }

        // Validate direction
        if direction != 1 && direction != 2 {
            return Err(TranslateError::TranslationFailed(format!(
                "Invalid direction: {}",
                direction
            )));
        }

        // Convert Rust strings to C strings for FFI
        let input_cstr = CString::new(text).map_err(|e| {
            eprintln!(
                "[translator_core] Failed to create CString from input: {}",
                e
            );
            TranslateError::EncodingError
        })?;

        let dir_str = self
            .model_base_dir
            .to_str()
            .ok_or_else(|| {
                eprintln!("[translator_core] model_base_dir is not valid UTF-8");
                TranslateError::EncodingError
            })?;

        let dir_cstr = CString::new(dir_str).map_err(|e| {
            eprintln!(
                "[translator_core] Failed to create CString from model_base_dir: {}",
                e
            );
            TranslateError::EncodingError
        })?;

        // Call into C++ wrapper
        let result_ptr = unsafe {
            cpp_translate(
                input_cstr.as_ptr(),
                dir_cstr.as_ptr(),
                direction as c_int,
                self.threads as c_int,
            )
        };

        if result_ptr.is_null() {
            return Err(TranslateError::TranslationFailed(
                "C++ cpp_translate returned null".to_string(),
            ));
        }

        // Convert C string result back to Rust String
        let result = unsafe { CStr::from_ptr(result_ptr) }
            .to_str()
            .map_err(|e| {
                eprintln!(
                    "[translator_core] C++ returned invalid UTF-8: {}",
                    e
                );
                // Still need to free the C++ string even on error
                unsafe { cpp_free_string(result_ptr) };
                TranslateError::EncodingError
            })?
            .to_string();

        // Free the C++ allocated string
        unsafe { cpp_free_string(result_ptr) };

        if result.is_empty() {
            return Err(TranslateError::TranslationFailed(
                "C++ returned empty string".to_string(),
            ));
        }

        Ok(result)
    }
}
