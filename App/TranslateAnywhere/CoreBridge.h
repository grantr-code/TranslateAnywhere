/*
 * CoreBridge.h
 * Thin inline wrappers around tc_* functions to avoid name conflicts
 * between the C TranslateDirection / TranslateStatus enums and the
 * identically named Swift enums in Contracts.swift.
 *
 * These wrappers take/return plain integer types so Swift can call them
 * without needing to reference the shadowed C enum types.
 */

#ifndef CORE_BRIDGE_H
#define CORE_BRIDGE_H

#include "translator_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Wrapper around tc_init that takes raw types.
 */
static inline int32_t bridge_tc_init(const uint8_t *model_base_dir,
                                      uint32_t dir_len,
                                      int32_t threads) {
    return tc_init(model_base_dir, dir_len, threads);
}

/*
 * Result struct using only primitive types to avoid enum name conflicts.
 */
typedef struct {
    const uint8_t *data;
    uint32_t       len;
    int32_t        status;     /* TranslateStatus raw value  */
    int32_t        detected;   /* TranslateDirection raw value */
} BridgeTranslateResult;

/*
 * Wrapper around tc_translate that returns plain integers for status/direction.
 */
static inline BridgeTranslateResult bridge_tc_translate(const uint8_t *input,
                                                         uint32_t input_len,
                                                         int32_t direction) {
    TranslateResult r = tc_translate(input, input_len, (TranslateDirection)direction);
    BridgeTranslateResult br;
    br.data     = r.data;
    br.len      = r.len;
    br.status   = (int32_t)r.status;
    br.detected = (int32_t)r.detected;
    return br;
}

/*
 * Wrapper around tc_free_buffer.
 */
static inline void bridge_tc_free_buffer(const uint8_t *ptr, uint32_t len) {
    tc_free_buffer(ptr, len);
}

/*
 * Wrapper around tc_is_russian.
 */
static inline int32_t bridge_tc_is_russian(const uint8_t *input, uint32_t input_len) {
    return tc_is_russian(input, input_len);
}

#ifdef __cplusplus
}
#endif

#endif /* CORE_BRIDGE_H */
