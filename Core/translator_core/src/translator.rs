// translator_core/src/translator.rs
//
// Internal module managing CTranslate2 translation via C++ FFI.

use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::{c_char, c_int};
use std::path::{Path, PathBuf};

const FAMILY_OPUS: i32 = 1;
const FAMILY_NLLB: i32 = 2;

extern "C" {
    fn cpp_translate(
        input_text: *const c_char,
        model_base_dir: *const c_char,
        direction: c_int,
        model_family: c_int,
        threads: c_int,
    ) -> *mut c_char;

    fn cpp_free_string(ptr: *mut c_char);

    fn cpp_reset_cache();
}

#[derive(Debug)]
pub enum TranslateError {
    ModelNotFound,
    EncodingError,
    TranslationFailed(String),
    InvalidInput,
}

#[derive(Debug, Clone, Copy)]
enum ModelFamily {
    Opus,
    Nllb,
}

impl ModelFamily {
    fn as_ffi(self) -> i32 {
        match self {
            ModelFamily::Opus => FAMILY_OPUS,
            ModelFamily::Nllb => FAMILY_NLLB,
        }
    }
}

pub struct Translator {
    model_base_dir_cstr: CString,
    model_family: ModelFamily,
    threads: i32,
}

impl Translator {
    pub fn new(model_base_dir: &str, threads: i32) -> Result<Self, TranslateError> {
        let path = PathBuf::from(model_base_dir);
        let model_base_dir_cstr = CString::new(model_base_dir).map_err(|e| {
            eprintln!(
                "[translator_core] Failed to create CString from model_base_dir: {}",
                e
            );
            TranslateError::EncodingError
        })?;

        let family = detect_model_family(&path).ok_or_else(|| {
            eprintln!(
                "[translator_core] Could not detect model family at {:?}",
                path
            );
            TranslateError::ModelNotFound
        })?;

        match family {
            ModelFamily::Opus => verify_opus_layout(&path)?,
            ModelFamily::Nllb => verify_nllb_layout(&path)?,
        }

        eprintln!(
            "[translator_core] Translator initialized with model dir: {:?}, family: {:?}, threads: {}",
            path, family, threads
        );

        Ok(Translator {
            model_base_dir_cstr,
            model_family: family,
            threads,
        })
    }

    pub fn reset_native_cache() {
        unsafe { cpp_reset_cache() };
    }

    pub fn translate(&self, text: &str, direction: i32) -> Result<String, TranslateError> {
        if text.is_empty() {
            return Err(TranslateError::InvalidInput);
        }

        if direction != 1 && direction != 2 {
            return Err(TranslateError::TranslationFailed(format!(
                "Invalid direction: {}",
                direction
            )));
        }

        let input_cstr = CString::new(text).map_err(|e| {
            eprintln!("[translator_core] Failed to create CString from input: {}", e);
            TranslateError::EncodingError
        })?;

        let result_ptr = unsafe {
            cpp_translate(
                input_cstr.as_ptr(),
                self.model_base_dir_cstr.as_ptr(),
                direction as c_int,
                self.model_family.as_ffi() as c_int,
                self.threads as c_int,
            )
        };

        if result_ptr.is_null() {
            return Err(TranslateError::TranslationFailed(
                "C++ cpp_translate returned null".to_string(),
            ));
        }

        let result = unsafe { CStr::from_ptr(result_ptr) }
            .to_str()
            .map_err(|e| {
                eprintln!("[translator_core] C++ returned invalid UTF-8: {}", e);
                unsafe { cpp_free_string(result_ptr) };
                TranslateError::EncodingError
            })?
            .to_string();

        unsafe { cpp_free_string(result_ptr) };

        if result.is_empty() {
            return Err(TranslateError::TranslationFailed(
                "C++ returned empty string".to_string(),
            ));
        }

        Ok(result)
    }
}

fn detect_model_family(path: &Path) -> Option<ModelFamily> {
    let profile_path = path.join("model_profile.json");
    if let Ok(raw) = fs::read_to_string(&profile_path) {
        let lc = raw.to_lowercase();
        if lc.contains("\"model_family\"") || lc.contains("\"family\"") {
            if lc.contains("nllb") {
                return Some(ModelFamily::Nllb);
            }
            if lc.contains("opus") {
                return Some(ModelFamily::Opus);
            }
        }
    }

    if has_opus_dirs(path) {
        return Some(ModelFamily::Opus);
    }

    let has_nllb = path.join("model.bin").exists() && path.join("sentencepiece.bpe.model").exists();
    if has_nllb {
        return Some(ModelFamily::Nllb);
    }

    None
}

fn has_opus_dirs(path: &Path) -> bool {
    let has_base = path.join("opus-mt-en-ru").exists() && path.join("opus-mt-ru-en").exists();
    let has_big = path.join("opus-mt-en-zle").exists() && path.join("opus-mt-zle-en").exists();
    has_base || has_big
}

fn verify_opus_layout(path: &Path) -> Result<(), TranslateError> {
    if has_opus_dirs(path) {
        return Ok(());
    }

    eprintln!(
        "[translator_core] OPUS model directory missing expected pair subdirectories at {:?}",
        path
    );
    Err(TranslateError::ModelNotFound)
}

fn verify_nllb_layout(path: &Path) -> Result<(), TranslateError> {
    let model_bin = path.join("model.bin");
    let spm = path.join("sentencepiece.bpe.model");

    if !model_bin.exists() {
        eprintln!("[translator_core] NLLB model.bin not found at {:?}", model_bin);
        return Err(TranslateError::ModelNotFound);
    }

    if !spm.exists() {
        eprintln!(
            "[translator_core] NLLB sentencepiece.bpe.model not found at {:?}",
            spm
        );
        return Err(TranslateError::ModelNotFound);
    }

    Ok(())
}
