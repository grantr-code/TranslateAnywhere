/*
 * translator_core.h
 * C ABI for TranslateAnywhere offline translation engine.
 *
 * Rust staticlib (translator_core) exposes these symbols.
 * The C++ layer (CTranslate2 + SentencePiece) is linked internally.
 *
 * Thread safety: all functions are safe to call from any thread.
 * init() must be called once before translate_utf8().
 */

#ifndef TRANSLATOR_CORE_H
#define TRANSLATOR_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Direction enum ─────────────────────────────────────────────── */

typedef enum {
    TranslateDirectionAutoDetect = 0,
    TranslateDirectionEnToRu     = 1,
    TranslateDirectionRuToEn     = 2,
} TranslateDirection;

/* ── Status codes ───────────────────────────────────────────────── */

typedef enum {
    TranslateStatusOk              = 0,
    TranslateStatusNotInitialized  = 1,
    TranslateStatusModelNotFound   = 2,
    TranslateStatusEncodingError   = 3,
    TranslateStatusTranslationFail = 4,
    TranslateStatusInvalidInput    = 5,
} TranslateStatus;

/* ── Result struct ──────────────────────────────────────────────── */

typedef struct {
    const uint8_t    *data;       /* UTF-8 bytes (caller must free via tc_free_buffer) */
    uint32_t          len;        /* byte length                                       */
    TranslateStatus   status;     /* 0 = ok                                            */
    TranslateDirection detected;  /* direction actually used (useful when AutoDetect)   */
} TranslateResult;

/* ── Lifecycle ──────────────────────────────────────────────────── */

/*
 * Initialize the translation engine.
 *
 * model_base_dir: UTF-8 path to directory containing model subdirectories:
 *     <model_base_dir>/opus-mt-en-ru/
 *     <model_base_dir>/opus-mt-ru-en/
 * Each subdirectory must contain the CTranslate2 model files and
 * source.spm / target.spm SentencePiece models.
 *
 * threads: number of intra-op threads for CTranslate2 (0 = auto).
 *
 * Returns 0 on success, non-zero on failure.
 */
int32_t tc_init(const uint8_t *model_base_dir, uint32_t dir_len, int32_t threads);

/* ── Translation ────────────────────────────────────────────────── */

/*
 * Translate a UTF-8 string.
 *
 * input: pointer to UTF-8 bytes (need not be null-terminated).
 * input_len: byte length of input.
 * direction: desired direction (AutoDetect inspects the input).
 *
 * Returns a TranslateResult. Caller MUST call tc_free_buffer on
 * result.data / result.len when done (even if status != Ok, data may be non-NULL).
 */
TranslateResult tc_translate(const uint8_t *input, uint32_t input_len,
                             TranslateDirection direction);

/* ── Memory management ──────────────────────────────────────────── */

/*
 * Free a buffer previously returned by tc_translate.
 */
void tc_free_buffer(const uint8_t *ptr, uint32_t len);

/* ── Utilities ──────────────────────────────────────────────────── */

/*
 * Detect whether text is predominantly Russian (Cyrillic).
 * Returns 1 if Russian, 0 if English / other.
 */
int32_t tc_is_russian(const uint8_t *input, uint32_t input_len);

#ifdef __cplusplus
}
#endif

#endif /* TRANSLATOR_CORE_H */
