/*
 * ctranslate2_wrapper.h
 *
 * C-callable wrapper around CTranslate2 + SentencePiece for OPUS-MT translation.
 * Called from Rust FFI in translator_core.
 */

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Translate text using CTranslate2 + SentencePiece.
 *
 * input_text:      null-terminated UTF-8 input string.
 * model_base_dir:  null-terminated UTF-8 path to directory containing model subdirectories
 *                  (opus-mt-en-ru/ and opus-mt-ru-en/).
 * direction:       1 = en->ru, 2 = ru->en.
 * threads:         number of intra-op threads for CTranslate2.
 *
 * Returns a heap-allocated null-terminated C string with the translation.
 * Caller must free with cpp_free_string().
 * Returns NULL on error.
 */
char* cpp_translate(const char* input_text, const char* model_base_dir,
                    int direction, int threads);

/*
 * Free a string returned by cpp_translate.
 * Safe to call with NULL.
 */
void cpp_free_string(char* ptr);

#ifdef __cplusplus
}
#endif
