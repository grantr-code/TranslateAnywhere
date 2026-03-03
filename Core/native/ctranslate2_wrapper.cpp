/*
 * ctranslate2_wrapper.cpp
 *
 * C++ implementation of the CTranslate2 + SentencePiece translation wrapper.
 * Supports two local model families:
 *   - OPUS family (paired directional models)
 *   - NLLB family (single multilingual model with lang-code prefixes)
 */

#include "ctranslate2_wrapper.h"

#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

enum class ModelFamily : int {
    Unknown = 0,
    Opus = 1,
    Nllb = 2,
};

struct ModelPair {
    std::unique_ptr<ctranslate2::Translator> translator;
    std::unique_ptr<sentencepiece::SentencePieceProcessor> source_spm;
    std::unique_ptr<sentencepiece::SentencePieceProcessor> target_spm;
    bool loaded = false;
};

struct NllbModel {
    std::unique_ptr<ctranslate2::Translator> translator;
    std::unique_ptr<sentencepiece::SentencePieceProcessor> spm;
    bool loaded = false;
};

static std::mutex g_mutex;
static ModelPair g_en_ru;
static ModelPair g_ru_en;
static NllbModel g_nllb;

int resolve_threads(int threads) {
    if (threads > 0) {
        return threads;
    }
    auto hw_threads = std::thread::hardware_concurrency();
    return (hw_threads > 0) ? static_cast<int>(hw_threads) : 1;
}

void reset_model_pair(ModelPair& model) {
    model.source_spm.reset();
    model.target_spm.reset();
    model.translator.reset();
    model.loaded = false;
}

void reset_nllb_model(NllbModel& model) {
    model.spm.reset();
    model.translator.reset();
    model.loaded = false;
}

bool load_opus_model(ModelPair& model, const std::string& model_dir, int threads) {
    if (model.loaded) return true;

    namespace fs = std::filesystem;
    if (!fs::exists(model_dir)) {
        fprintf(stderr, "[ctranslate2_wrapper] OPUS model dir not found: %s\n", model_dir.c_str());
        return false;
    }

    try {
        model.source_spm = std::make_unique<sentencepiece::SentencePieceProcessor>();
        auto status = model.source_spm->Load(model_dir + "/source.spm");
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] Failed to load source.spm from %s: %s\n",
                    model_dir.c_str(), status.ToString().c_str());
            return false;
        }

        model.target_spm = std::make_unique<sentencepiece::SentencePieceProcessor>();
        status = model.target_spm->Load(model_dir + "/target.spm");
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] Failed to load target.spm from %s: %s\n",
                    model_dir.c_str(), status.ToString().c_str());
            return false;
        }

        ctranslate2::ReplicaPoolConfig pool_config;
        pool_config.num_threads_per_replica = resolve_threads(threads);

        model.translator = std::make_unique<ctranslate2::Translator>(
            model_dir,
            ctranslate2::Device::CPU,
            ctranslate2::ComputeType::DEFAULT,
            std::vector<int>{0},
            pool_config
        );

        model.loaded = true;
        fprintf(stderr, "[ctranslate2_wrapper] Loaded OPUS model: %s\n", model_dir.c_str());
        return true;

    } catch (const std::exception& e) {
        fprintf(stderr, "[ctranslate2_wrapper] Error loading OPUS model %s: %s\n",
                model_dir.c_str(), e.what());
        reset_model_pair(model);
        return false;
    }
}

bool load_nllb_model(NllbModel& model, const std::string& model_dir, int threads) {
    if (model.loaded) return true;

    namespace fs = std::filesystem;
    if (!fs::exists(model_dir)) {
        fprintf(stderr, "[ctranslate2_wrapper] NLLB model dir not found: %s\n", model_dir.c_str());
        return false;
    }

    try {
        model.spm = std::make_unique<sentencepiece::SentencePieceProcessor>();
        auto status = model.spm->Load(model_dir + "/sentencepiece.bpe.model");
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] Failed to load sentencepiece.bpe.model from %s: %s\n",
                    model_dir.c_str(), status.ToString().c_str());
            return false;
        }

        ctranslate2::ReplicaPoolConfig pool_config;
        pool_config.num_threads_per_replica = resolve_threads(threads);

        model.translator = std::make_unique<ctranslate2::Translator>(
            model_dir,
            ctranslate2::Device::CPU,
            ctranslate2::ComputeType::DEFAULT,
            std::vector<int>{0},
            pool_config
        );

        model.loaded = true;
        fprintf(stderr, "[ctranslate2_wrapper] Loaded NLLB model: %s\n", model_dir.c_str());
        return true;

    } catch (const std::exception& e) {
        fprintf(stderr, "[ctranslate2_wrapper] Error loading NLLB model %s: %s\n",
                model_dir.c_str(), e.what());
        reset_nllb_model(model);
        return false;
    }
}

bool is_special_token(const std::string& token) {
    if (token.empty()) return false;

    if (token.front() == '<' && token.back() == '>') return true;

    if (token.size() >= 4 && token[0] == '>' && token[1] == '>' &&
        token[token.size() - 2] == '<' && token[token.size() - 1] == '<') {
        return true;
    }

    if (token == "\xe2\x96\x81") return true;

    return false;
}

std::string translate_opus(const char* input_text,
                           const std::string& base_dir,
                           int direction,
                           int threads) {
    namespace fs = std::filesystem;

    std::string model_subdir;
    ModelPair* model_pair = nullptr;
    bool prepend_rus_tag = false;

    if (direction == 1) {  // en->ru
        const std::string en_zle = base_dir + "/opus-mt-en-zle";
        const std::string en_ru = base_dir + "/opus-mt-en-ru";
        if (fs::exists(en_zle)) {
            model_subdir = en_zle;
            prepend_rus_tag = true;
        } else {
            model_subdir = en_ru;
        }
        model_pair = &g_en_ru;
    } else if (direction == 2) {  // ru->en
        const std::string zle_en = base_dir + "/opus-mt-zle-en";
        const std::string ru_en = base_dir + "/opus-mt-ru-en";
        if (fs::exists(zle_en)) {
            model_subdir = zle_en;
        } else {
            model_subdir = ru_en;
        }
        model_pair = &g_ru_en;
    } else {
        fprintf(stderr, "[ctranslate2_wrapper] Invalid direction for OPUS: %d\n", direction);
        return "";
    }

    if (!load_opus_model(*model_pair, model_subdir, threads)) {
        return "";
    }

    std::string input(input_text);
    if (prepend_rus_tag) {
        input = ">>rus<< " + input;
    }

    std::vector<std::string> tokens;
    auto status = model_pair->source_spm->Encode(input, &tokens);
    if (!status.ok()) {
        fprintf(stderr, "[ctranslate2_wrapper] OPUS SentencePiece encode error: %s\n",
                status.ToString().c_str());
        return "";
    }

    if (tokens.empty()) {
        fprintf(stderr, "[ctranslate2_wrapper] OPUS SentencePiece produced zero tokens\n");
        return "";
    }

    tokens.push_back("</s>");

    ctranslate2::TranslationOptions options;
    options.beam_size = 4;
    options.max_decoding_length = 256;
    options.repetition_penalty = 1.2f;
    options.no_repeat_ngram_size = 3;

    std::vector<std::vector<std::string>> batch = {tokens};

    try {
        auto results = model_pair->translator->translate_batch(batch, options);
        if (results.empty() || results[0].hypotheses.empty()) {
            fprintf(stderr, "[ctranslate2_wrapper] OPUS no translation result\n");
            return "";
        }

        auto& output_tokens = results[0].hypotheses[0];
        std::vector<std::string> filtered;
        filtered.reserve(output_tokens.size());
        for (const auto& tok : output_tokens) {
            if (!is_special_token(tok)) {
                filtered.push_back(tok);
            }
        }

        std::string decoded;
        status = model_pair->target_spm->Decode(filtered, &decoded);
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] OPUS SentencePiece decode error: %s\n",
                    status.ToString().c_str());
            return "";
        }

        return decoded;

    } catch (const std::exception& e) {
        fprintf(stderr, "[ctranslate2_wrapper] OPUS translation error: %s\n", e.what());
        return "";
    }
}

std::string translate_nllb(const char* input_text,
                           const std::string& model_dir,
                           int direction,
                           int threads) {
    if (direction != 1 && direction != 2) {
        fprintf(stderr, "[ctranslate2_wrapper] Invalid direction for NLLB: %d\n", direction);
        return "";
    }

    if (!load_nllb_model(g_nllb, model_dir, threads)) {
        return "";
    }

    const std::string src_lang = (direction == 1) ? "eng_Latn" : "rus_Cyrl";
    const std::string tgt_lang = (direction == 1) ? "rus_Cyrl" : "eng_Latn";

    std::string input(input_text);

    std::vector<std::string> spm_tokens;
    auto status = g_nllb.spm->Encode(input, &spm_tokens);
    if (!status.ok()) {
        fprintf(stderr, "[ctranslate2_wrapper] NLLB SentencePiece encode error: %s\n",
                status.ToString().c_str());
        return "";
    }
    if (spm_tokens.empty()) {
        fprintf(stderr, "[ctranslate2_wrapper] NLLB SentencePiece produced zero tokens\n");
        return "";
    }

    // NLLB source format: <spm tokens> </s> <src_lang>
    spm_tokens.push_back("</s>");
    spm_tokens.push_back(src_lang);

    std::vector<std::vector<std::string>> batch = {spm_tokens};
    std::vector<std::vector<std::string>> target_prefix = {{tgt_lang}};

    ctranslate2::TranslationOptions options;
    options.beam_size = 4;
    options.max_decoding_length = 256;
    options.repetition_penalty = 1.2f;
    options.no_repeat_ngram_size = 3;

    try {
        auto results = g_nllb.translator->translate_batch(batch, target_prefix, options);

        if (results.empty() || results[0].hypotheses.empty()) {
            fprintf(stderr, "[ctranslate2_wrapper] NLLB no translation result\n");
            return "";
        }

        auto& output_tokens = results[0].hypotheses[0];
        std::vector<std::string> filtered;
        filtered.reserve(output_tokens.size());
        for (const auto& tok : output_tokens) {
            if (tok == src_lang || tok == tgt_lang) {
                continue;
            }
            if (is_special_token(tok)) {
                continue;
            }
            filtered.push_back(tok);
        }

        if (filtered.empty()) {
            fprintf(stderr, "[ctranslate2_wrapper] NLLB output tokens empty after filtering\n");
            return "";
        }

        std::string decoded;
        status = g_nllb.spm->Decode(filtered, &decoded);
        if (!status.ok()) {
            fprintf(stderr, "[ctranslate2_wrapper] NLLB SentencePiece decode error: %s\n",
                    status.ToString().c_str());
            return "";
        }

        return decoded;

    } catch (const std::exception& e) {
        fprintf(stderr, "[ctranslate2_wrapper] NLLB translation error: %s\n", e.what());
        return "";
    }
}

std::string translate_impl(const char* input_text,
                           const char* model_base_dir,
                           int direction,
                           int model_family,
                           int threads) {
    std::string base_dir(model_base_dir);

    const auto family = static_cast<ModelFamily>(model_family);
    switch (family) {
    case ModelFamily::Nllb:
        return translate_nllb(input_text, base_dir, direction, threads);
    case ModelFamily::Opus:
    case ModelFamily::Unknown:
    default:
        return translate_opus(input_text, base_dir, direction, threads);
    }
}

}  // namespace

extern "C" {

char* cpp_translate(const char* input_text,
                    const char* model_base_dir,
                    int direction,
                    int model_family,
                    int threads) {
    if (!input_text || !model_base_dir) return nullptr;

    std::lock_guard<std::mutex> lock(g_mutex);

    std::string result = translate_impl(input_text, model_base_dir, direction, model_family, threads);
    if (result.empty()) return nullptr;

    char* output = static_cast<char*>(malloc(result.size() + 1));
    if (!output) return nullptr;
    memcpy(output, result.c_str(), result.size() + 1);
    return output;
}

void cpp_free_string(char* ptr) {
    free(ptr);
}

void cpp_reset_cache(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    reset_model_pair(g_en_ru);
    reset_model_pair(g_ru_en);
    reset_nllb_model(g_nllb);
}

}  // extern "C"
