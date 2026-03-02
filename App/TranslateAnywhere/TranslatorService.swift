/*
 * TranslatorService.swift
 * Bridges Swift to the C ABI exposed by translator_core (Rust/CTranslate2).
 * Also supports an Ollama HTTP backend for cloud-based translation.
 *
 * The C functions are called through CoreBridge.h wrappers (bridge_tc_*)
 * to avoid name conflicts between the C TranslateDirection / TranslateStatus
 * enums and the identically named Swift enums defined in Contracts.swift.
 * The bridge wrappers use plain Int32 for enum values.
 */

import Foundation
import os.log

// MARK: - TranslationResult (Swift-side)

struct TranslationResult: Sendable {
    let text: String
    let status: TranslateStatus
    let detectedDirection: TranslateDirection
}

// MARK: - TranslatorService

final class TranslatorService: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "Translator")
    private var isInitialized = false
    private let queue = DispatchQueue(label: "com.translateanywhere.translator", qos: .userInitiated)

    // MARK: - Lifecycle

    /// Initializes the local translation engine with models from the app bundle.
    /// Returns true on success.
    func initialize() -> Bool {
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.error("Bundle.main.resourcePath is nil")
            return false
        }

        logger.info("Initializing translator core with model path: \(resourcePath)")

        let utf8 = Array(resourcePath.utf8)
        let result: Int32 = utf8.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return Int32(-1) }
            return bridge_tc_init(base, UInt32(buf.count), 0)
        }

        if result == 0 {
            isInitialized = true
            logger.info("Translator core initialized successfully")
        } else {
            logger.error("Translator core init failed with code \(result)")
        }
        return result == 0
    }

    // MARK: - Translation

    /// Translates text using the configured backend.
    func translate(text: String, direction: TranslateDirection) async -> TranslationResult {
        let settings = await SettingsManager.shared
        let backend = await settings.backend

        switch backend {
        case .local:
            return await translateLocal(text: text, direction: direction)
        case .ollama:
            let endpoint = await settings.ollamaEndpoint
            let model = await settings.ollamaModel
            return await translateOllama(text: text, direction: direction,
                                         endpoint: endpoint, model: model)
        }
    }

    /// Detects whether the given text is predominantly Russian/Cyrillic.
    func isRussian(_ text: String) -> Bool {
        let utf8 = Array(text.utf8)
        let result = utf8.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return bridge_tc_is_russian(base, UInt32(buf.count))
        }
        let detected = result == 1
        logger.debug("isRussian check: \(detected)")
        return detected
    }

    // MARK: - Local Backend

    private func translateLocal(text: String, direction: TranslateDirection) async -> TranslationResult {
        logger.info("Translating locally: direction=\(direction.label), len=\(text.count)")

        guard isInitialized else {
            logger.error("Translator core not initialized")
            return TranslationResult(text: "", status: .notInitialized, detectedDirection: direction)
        }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: TranslationResult(
                        text: "", status: .notInitialized, detectedDirection: direction))
                    return
                }

                let utf8 = Array(text.utf8)
                let bridgeResult: BridgeTranslateResult = utf8.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else {
                        return BridgeTranslateResult(data: nil, len: 0,
                                                     status: TranslateStatus.invalidInput.rawValue,
                                                     detected: TranslateDirection.autoDetect.rawValue)
                    }
                    return bridge_tc_translate(base, UInt32(buf.count), direction.rawValue)
                }

                // Map raw Int32 values back to Swift enums
                let status = TranslateStatus(rawValue: bridgeResult.status) ?? .translationFail
                let detected = TranslateDirection(rawValue: bridgeResult.detected) ?? .autoDetect

                var translatedText = ""
                if let data = bridgeResult.data, bridgeResult.len > 0 {
                    let buffer = UnsafeBufferPointer(start: data, count: Int(bridgeResult.len))
                    translatedText = String(bytes: buffer, encoding: .utf8) ?? ""
                }

                // Free the buffer returned by the C library
                if let data = bridgeResult.data {
                    bridge_tc_free_buffer(data, bridgeResult.len)
                }

                self.logger.info("Local translation complete: status=\(status.rawValue), detected=\(detected.label), outputLen=\(translatedText.count)")

                continuation.resume(returning: TranslationResult(
                    text: translatedText, status: status, detectedDirection: detected))
            }
        }
    }

    // MARK: - Ollama Backend

    private func translateOllama(text: String, direction: TranslateDirection,
                                  endpoint: String, model: String) async -> TranslationResult {
        logger.info("Translating via Ollama: direction=\(direction.label), model=\(model)")

        let directionPrompt: String
        let detectedDir: TranslateDirection

        switch direction {
        case .autoDetect:
            let russian = isRussian(text)
            if russian {
                directionPrompt = "Translate the following Russian text to English. Output ONLY the translation, nothing else."
                detectedDir = .ruToEn
            } else {
                directionPrompt = "Translate the following English text to Russian. Output ONLY the translation, nothing else."
                detectedDir = .enToRu
            }
        case .enToRu:
            directionPrompt = "Translate the following English text to Russian. Output ONLY the translation, nothing else."
            detectedDir = .enToRu
        case .ruToEn:
            directionPrompt = "Translate the following Russian text to English. Output ONLY the translation, nothing else."
            detectedDir = .ruToEn
        }

        let prompt = "\(directionPrompt)\n\n\(text)"

        guard let url = URL(string: "\(endpoint)/api/generate") else {
            logger.error("Invalid Ollama endpoint URL: \(endpoint)")
            return TranslationResult(text: "", status: .translationFail, detectedDirection: detectedDir)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Failed to serialize Ollama request body: \(error.localizedDescription)")
            return TranslationResult(text: "", status: .translationFail, detectedDirection: detectedDir)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Ollama response is not HTTP")
                return TranslationResult(text: "", status: .translationFail, detectedDirection: detectedDir)
            }

            guard httpResponse.statusCode == 200 else {
                logger.error("Ollama returned HTTP \(httpResponse.statusCode)")
                return TranslationResult(text: "", status: .translationFail, detectedDirection: detectedDir)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                logger.error("Failed to parse Ollama response JSON")
                return TranslationResult(text: "", status: .translationFail, detectedDirection: detectedDir)
            }

            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("Ollama translation complete: outputLen=\(trimmed.count)")
            return TranslationResult(text: trimmed, status: .ok, detectedDirection: detectedDir)

        } catch {
            logger.error("Ollama request failed: \(error.localizedDescription)")
            return TranslationResult(text: "", status: .translationFail, detectedDirection: detectedDir)
        }
    }
}
