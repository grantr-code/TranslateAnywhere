/*
 * Integration tests for translator_core C ABI.
 *
 * Language detection tests (tc_is_russian) run without models.
 * Translation tests require models and are marked #[ignore].
 * Run ignored tests with: MODELS_DIR=/path/to/models cargo test -- --ignored
 */

extern "C" {
    fn tc_is_russian(input: *const u8, input_len: u32) -> i32;
    fn tc_init(model_base_dir: *const u8, dir_len: u32, threads: i32) -> i32;
    fn tc_translate(input: *const u8, input_len: u32, direction: i32) -> TranslateResult;
    fn tc_free_buffer(ptr: *const u8, len: u32);
}

#[repr(C)]
struct TranslateResult {
    data: *const u8,
    len: u32,
    status: i32,
    detected: i32,
}

// ── Language Detection Tests (no models needed) ────────────────────

#[test]
fn test_russian_detection_cyrillic() {
    let text = "Привет, как дела?";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 1, "Should detect Russian text");
}

#[test]
fn test_russian_detection_english() {
    let text = "Hello, how are you?";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 0, "Should detect English text");
}

#[test]
fn test_russian_detection_mixed_mostly_english() {
    let text = "Hello world with a few Привет words in English text";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 0, "Mixed text mostly English should return 0");
}

#[test]
fn test_russian_detection_mixed_mostly_russian() {
    let text = "Привет мир это тест hello";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 1, "Mixed text mostly Russian should return 1");
}

#[test]
fn test_russian_detection_empty() {
    let text = "";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 0, "Empty text should return 0");
}

#[test]
fn test_russian_detection_numbers_only() {
    let text = "12345 67890";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 0, "Numbers only should return 0");
}

#[test]
fn test_russian_detection_single_word_ru() {
    let text = "Привет";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 1, "Single Russian word should return 1");
}

#[test]
fn test_russian_detection_single_word_en() {
    let text = "Hello";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 0, "Single English word should return 0");
}

#[test]
fn test_russian_detection_extended_cyrillic() {
    // Uses characters from Cyrillic Supplement block (U+0500..U+052F)
    let text = "ԐԑԒԓ"; // Komi letters
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 1, "Extended Cyrillic should be detected");
}

#[test]
fn test_russian_detection_punctuation_only() {
    let text = "!!! ??? ... ---";
    let bytes = text.as_bytes();
    let result = unsafe { tc_is_russian(bytes.as_ptr(), bytes.len() as u32) };
    assert_eq!(result, 0, "Punctuation only should return 0");
}

// ── Buffer Management Tests ────────────────────────────────────────

#[test]
fn test_free_buffer_null_safe() {
    // Freeing a null pointer must not crash
    unsafe { tc_free_buffer(std::ptr::null(), 0) };
}

#[test]
fn test_free_buffer_zero_len() {
    unsafe { tc_free_buffer(std::ptr::null(), 0) };
}

// ── Translation Without Init Tests ─────────────────────────────────

#[test]
fn test_translate_not_initialized() {
    let text = "Hello";
    let bytes = text.as_bytes();
    let result = unsafe { tc_translate(bytes.as_ptr(), bytes.len() as u32, 0) };
    assert_eq!(result.status, 1, "Should return NotInitialized (status 1)");
    if !result.data.is_null() {
        unsafe { tc_free_buffer(result.data, result.len) };
    }
}

#[test]
fn test_translate_empty_input() {
    let text = "";
    let bytes = text.as_bytes();
    let result = unsafe { tc_translate(bytes.as_ptr(), bytes.len() as u32, 1) };
    // Either NotInitialized or InvalidInput is acceptable
    assert!(
        result.status == 1 || result.status == 5,
        "Should return NotInitialized or InvalidInput, got {}",
        result.status
    );
    if !result.data.is_null() {
        unsafe { tc_free_buffer(result.data, result.len) };
    }
}

// ── Full Translation Tests (require models) ────────────────────────
// Run with: MODELS_DIR=/path/to/models cargo test -- --ignored

fn init_with_models() -> bool {
    let model_dir = match std::env::var("MODELS_DIR") {
        Ok(d) => d,
        Err(_) => {
            eprintln!("MODELS_DIR not set, skipping");
            return false;
        }
    };
    let dir_bytes = model_dir.as_bytes();
    let result = unsafe { tc_init(dir_bytes.as_ptr(), dir_bytes.len() as u32, 0) };
    result == 0
}

#[test]
#[ignore]
fn test_translate_en_to_ru() {
    assert!(init_with_models(), "Failed to init");

    let text = "Hello, how are you?";
    let bytes = text.as_bytes();
    let result = unsafe { tc_translate(bytes.as_ptr(), bytes.len() as u32, 1) };
    assert_eq!(result.status, 0, "Translation should succeed");
    assert!(!result.data.is_null(), "Result data should not be null");
    assert!(result.len > 0, "Result should not be empty");

    let translated = unsafe {
        let slice = std::slice::from_raw_parts(result.data, result.len as usize);
        String::from_utf8_lossy(slice).to_string()
    };
    eprintln!("EN->RU: '{}' -> '{}'", text, translated);

    // Should contain Cyrillic characters
    assert!(
        translated.chars().any(|c| ('\u{0400}'..='\u{04FF}').contains(&c)),
        "Translation should contain Cyrillic: {}",
        translated
    );

    unsafe { tc_free_buffer(result.data, result.len) };
}

#[test]
#[ignore]
fn test_translate_ru_to_en() {
    assert!(init_with_models(), "Failed to init");

    let text = "Привет, как дела?";
    let bytes = text.as_bytes();
    let result = unsafe { tc_translate(bytes.as_ptr(), bytes.len() as u32, 2) };
    assert_eq!(result.status, 0, "Translation should succeed");
    assert!(!result.data.is_null(), "Result data should not be null");
    assert!(result.len > 0, "Result should not be empty");

    let translated = unsafe {
        let slice = std::slice::from_raw_parts(result.data, result.len as usize);
        String::from_utf8_lossy(slice).to_string()
    };
    eprintln!("RU->EN: '{}' -> '{}'", text, translated);

    // Should contain ASCII alphabetic
    assert!(
        translated.chars().any(|c| c.is_ascii_alphabetic()),
        "Translation should contain Latin chars: {}",
        translated
    );

    unsafe { tc_free_buffer(result.data, result.len) };
}

#[test]
#[ignore]
fn test_translate_auto_detect_english() {
    assert!(init_with_models(), "Failed to init");

    let text = "Good morning";
    let bytes = text.as_bytes();
    let result = unsafe { tc_translate(bytes.as_ptr(), bytes.len() as u32, 0) };
    assert_eq!(result.status, 0, "Translation should succeed");
    assert_eq!(result.detected, 1, "Should detect EN->RU direction");

    if !result.data.is_null() {
        unsafe { tc_free_buffer(result.data, result.len) };
    }
}

#[test]
#[ignore]
fn test_translate_auto_detect_russian() {
    assert!(init_with_models(), "Failed to init");

    let text = "Доброе утро";
    let bytes = text.as_bytes();
    let result = unsafe { tc_translate(bytes.as_ptr(), bytes.len() as u32, 0) };
    assert_eq!(result.status, 0, "Translation should succeed");
    assert_eq!(result.detected, 2, "Should detect RU->EN direction");

    if !result.data.is_null() {
        unsafe { tc_free_buffer(result.data, result.len) };
    }
}

#[test]
#[ignore]
fn test_translate_long_text() {
    assert!(init_with_models(), "Failed to init");

    let text = "This is a longer sentence that tests the translation engine's ability to handle more complex input with multiple clauses and various grammatical structures.";
    let bytes = text.as_bytes();
    let result = unsafe { tc_translate(bytes.as_ptr(), bytes.len() as u32, 1) };
    assert_eq!(result.status, 0, "Long text translation should succeed");
    assert!(result.len > 0, "Result should not be empty");

    if !result.data.is_null() {
        unsafe { tc_free_buffer(result.data, result.len) };
    }
}
