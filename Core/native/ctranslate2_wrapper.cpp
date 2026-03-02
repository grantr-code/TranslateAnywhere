/*
 * ctranslate2_wrapper.cpp
 *
 * C++ implementation of the CTranslate2 + SentencePiece translation wrapper.
 * Models are lazily loaded on first use per direction. Thread safety is
 * enforced via a global mutex (the Rust side also serializes calls, but we
 * protect the C++ globals independently for safety).
 */

#include "ctranslate2_wrapper.h"

#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

// ── Per-direction model state ──

struct ModelPair {
    std::unique_ptr<ctranslate2::Translator> translator;
    std::unique_ptr<sentencepiece::SentencePieceProcessor> source_spm;
    std::unique_ptr<sentencepiece::SentencePieceProcessor> target_spm;
    bool loaded = false;
};

static std::mutex g_mutex;
static ModelPair g_en_ru;  // direction == 1: English -> Russian
static ModelPair g_ru_en;  // direction == 2: Russian -> English

// ── Lazy model loader ──

bool load_model(ModelPair& model, const std::string& model_dir, int threads) {
    if (model.loaded) return true;

    namespace fs = std::filesystem;

    if (!fs::exists(model_dir)) {
        fprintf(stderr, "[ctranslate2_wrapper] Model dir not found: %s\n", model_dir.c_str());
        return false;
    }

    try {
        // Load source SentencePiece model
        model.source_spm = std::make_unique<sentencepiece::SentencePieceProcessor>();
        auto status = model.source_spm->Load(model_dir + "/source.spm");
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] Failed to load source.spm from %s: %s\n",
                    model_dir.c_str(), status.ToString().c_str());
            return false;
        }

        // Load target SentencePiece model
        model.target_spm = std::make_unique<sentencepiece::SentencePieceProcessor>();
        status = model.target_spm->Load(model_dir + "/target.spm");
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] Failed to load target.spm from %s: %s\n",
                    model_dir.c_str(), status.ToString().c_str());
            return false;
        }

        // Load CTranslate2 model
        int intra_threads = (threads > 0) ? threads : 4;
        ctranslate2::ReplicaPoolConfig pool_config;
        pool_config.num_threads_per_replica = intra_threads;

        model.translator = std::make_unique<ctranslate2::Translator>(
            model_dir,
            ctranslate2::Device::CPU,
            ctranslate2::ComputeType::INT8,
            std::vector<int>{0},  // device indices
            pool_config
        );

        model.loaded = true;
        fprintf(stderr, "[ctranslate2_wrapper] Loaded model: %s (threads=%d)\n",
                model_dir.c_str(), intra_threads);
        return true;

    } catch (const std::exception& e) {
        fprintf(stderr, "[ctranslate2_wrapper] Error loading model %s: %s\n",
                model_dir.c_str(), e.what());
        model.source_spm.reset();
        model.target_spm.reset();
        model.translator.reset();
        model.loaded = false;
        return false;
    }
}

// ── OPUS-MT special token filter ──

// Filters tokens that are OPUS-MT artifacts: anything in angle brackets
// (e.g., <s>, </s>, <pad>, <unk>, language tags like >>ru<<),
// and lone SentencePiece whitespace markers.
bool is_special_token(const std::string& token) {
    if (token.empty()) return false;

    // Angle-bracket tokens: <s>, </s>, <pad>, <unk>, etc.
    if (token.front() == '<' && token.back() == '>') return true;

    // OPUS-MT language direction tokens: >>ru<<, >>en<<, etc.
    if (token.size() >= 4 && token[0] == '>' && token[1] == '>' &&
        token[token.size() - 2] == '<' && token[token.size() - 1] == '<') {
        return true;
    }

    // Lone SentencePiece whitespace marker (U+2581 = 0xE2 0x96 0x81 in UTF-8)
    if (token == "\xe2\x96\x81") return true;

    return false;
}

// ── Core translation logic ──

std::string translate_impl(const char* input_text, const char* model_base_dir,
                           int direction, int threads) {
    std::string base_dir(model_base_dir);
    std::string model_subdir;
    ModelPair* model_pair = nullptr;

    if (direction == 1) {  // en->ru
        model_subdir = base_dir + "/opus-mt-en-ru";
        model_pair = &g_en_ru;
    } else if (direction == 2) {  // ru->en
        model_subdir = base_dir + "/opus-mt-ru-en";
        model_pair = &g_ru_en;
    } else {
        fprintf(stderr, "[ctranslate2_wrapper] Invalid direction: %d\n", direction);
        return "";
    }

    // Lazy-load the model for this direction
    if (!load_model(*model_pair, model_subdir, threads)) {
        return "";
    }

    std::string input(input_text);

    // Tokenize with source SentencePiece
    std::vector<std::string> tokens;
    auto status = model_pair->source_spm->Encode(input, &tokens);
    if (!status.ok()) {
        fprintf(stderr, "[ctranslate2_wrapper] SentencePiece encode error: %s\n",
                status.ToString().c_str());
        return "";
    }

    if (tokens.empty()) {
        fprintf(stderr, "[ctranslate2_wrapper] SentencePiece produced zero tokens\n");
        return "";
    }

    // Translate via CTranslate2
    ctranslate2::TranslationOptions options;
    options.beam_size = 4;
    options.max_decoding_length = 512;

    std::vector<std::vector<std::string>> batch = {tokens};

    try {
        auto results = model_pair->translator->translate_batch(batch, options);

        if (results.empty() || results[0].hypotheses.empty()) {
            fprintf(stderr, "[ctranslate2_wrapper] No translation result\n");
            return "";
        }

        // Take the best hypothesis (index 0)
        auto& output_tokens = results[0].hypotheses[0];

        // Filter OPUS-MT special tokens
        std::vector<std::string> filtered;
        filtered.reserve(output_tokens.size());
        for (const auto& tok : output_tokens) {
            if (!is_special_token(tok)) {
                filtered.push_back(tok);
            }
        }

        // Detokenize with target SentencePiece
        std::string decoded;
        status = model_pair->target_spm->Decode(filtered, &decoded);
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] SentencePiece decode error: %s\n",
                    status.ToString().c_str());
            return "";
        }

        return decoded;

    } catch (const std::exception& e) {
        fprintf(stderr, "[ctranslate2_wrapper] Translation error: %s\n", e.what());
        return "";
    }
}

}  // anonymous namespace

// ── C ABI exports ──

extern "C" {

char* cpp_translate(const char* input_text, const char* model_base_dir,
                    int direction, int threads) {
    if (!input_text || !model_base_dir) return nullptr;

    std::lock_guard<std::mutex> lock(g_mutex);

    std::string result = translate_impl(input_text, model_base_dir, direction, threads);
    if (result.empty()) return nullptr;

    // Heap-allocate the result as a null-terminated C string
    char* output = static_cast<char*>(malloc(result.size() + 1));
    if (!output) return nullptr;
    memcpy(output, result.c_str(), result.size() + 1);
    return output;
}

void cpp_free_string(char* ptr) {
    free(ptr);
}

}  // extern "C"
