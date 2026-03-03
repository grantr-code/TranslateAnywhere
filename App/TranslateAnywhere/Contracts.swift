/*
 * Contracts.swift
 * Shared types, enums, and UserDefaults keys for TranslateAnywhere.
 *
 * Every component imports this file. Do not add implementation details here.
 */

import Foundation

// MARK: - Direction

/// Translation direction matching the C enum TranslateDirection.
enum TranslateDirection: Int32, CaseIterable {
    case autoDetect = 0
    case enToRu     = 1
    case ruToEn     = 2

    var label: String {
        switch self {
        case .autoDetect: return "Auto Detect"
        case .enToRu:     return "EN → RU"
        case .ruToEn:     return "RU → EN"
        }
    }

    var badge: String {
        switch self {
        case .autoDetect: return "AUTO"
        case .enToRu:     return "EN→RU"
        case .ruToEn:     return "RU→EN"
        }
    }
}

// MARK: - Backend

enum TranslationBackend: String, CaseIterable {
    case local  = "local"
    case ollama = "ollama"

    var label: String {
        switch self {
        case .local:  return "Local"
        case .ollama: return "Ollama"
        }
    }
}

// MARK: - Local Model Selection

enum LocalModelFamily: String, CaseIterable, Codable, Sendable {
    case opus
    case nllb
}

enum LocalModelID: String, CaseIterable, Codable, Sendable {
    case opusBase = "opus_base"
    case opusBig  = "opus_big"
    case nllb13b  = "nllb_1_3b"
    case nllb33b  = "nllb_3_3b"

    var label: String {
        switch self {
        case .opusBase: return "OPUS Base"
        case .opusBig:  return "OPUS Big"
        case .nllb13b:  return "NLLB 1.3B"
        case .nllb33b:  return "NLLB 3.3B"
        }
    }

    var family: LocalModelFamily {
        switch self {
        case .opusBase, .opusBig:
            return .opus
        case .nllb13b, .nllb33b:
            return .nllb
        }
    }

    var approximateSizeLabel: String {
        switch self {
        case .opusBase: return "~600 MB"
        case .opusBig:  return "~1.3 GB"
        case .nllb13b:  return "~2.7 GB"
        case .nllb33b:  return "~6.8 GB"
        }
    }

    var licenseLabel: String {
        switch self {
        case .opusBase, .opusBig:
            return "CC-BY-4.0"
        case .nllb13b, .nllb33b:
            return "CC-BY-NC-4.0"
        }
    }
}

enum ModelInstallState: String, Sendable {
    case notInstalled
    case downloading
    case installed
    case failed
}

// MARK: - Translate Status (mirrors C enum)

enum TranslateStatus: Int32 {
    case ok              = 0
    case notInitialized  = 1
    case modelNotFound   = 2
    case encodingError   = 3
    case translationFail = 4
    case invalidInput    = 5
}

// MARK: - Capture Result

enum TranslationOutputMode: Sendable {
    case replaceSelection
    case showPopup
}

struct CaptureResult: Sendable {
    let text: String
    let outputMode: TranslationOutputMode
}

// MARK: - UserDefaults Keys

enum UDKey {
    static let hotkeyKeyCode       = "hotkeyKeyCode"        // UInt32
    static let hotkeyModifiers     = "hotkeyModifiers"      // UInt32 (Carbon modifier mask)
    static let direction            = "direction"             // Int (TranslateDirection.rawValue)
    static let backend              = "backend"               // String (TranslationBackend.rawValue)
    static let restoreClipboard     = "restoreClipboard"     // Bool (default: true)
    static let maxInputChars        = "maxInputChars"        // Int  (default: 8000)
    static let ollamaEndpoint       = "ollamaEndpoint"       // String
    static let ollamaModel          = "ollamaModel"          // String
    static let localModelId         = "localModelId"         // String (LocalModelID.rawValue)

    /// Register defaults on app launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            hotkeyKeyCode:       UInt32(17),    // "t" key
            hotkeyModifiers:     UInt32(0x0900), // controlKey | optionKey (Carbon)
            direction:           TranslateDirection.autoDetect.rawValue,
            backend:             TranslationBackend.local.rawValue,
            restoreClipboard:    true,
            maxInputChars:       8000,
            ollamaEndpoint:      "http://localhost:11434",
            ollamaModel:         "llama3",
            localModelId:        LocalModelID.nllb13b.rawValue,
        ])
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let hotkeyTriggered       = Notification.Name("TranslateAnywhere.hotkeyTriggered")
    static let hotkeyChanged         = Notification.Name("TranslateAnywhere.hotkeyChanged")
    static let modelSelectionChanged = Notification.Name("TranslateAnywhere.modelSelectionChanged")
    static let modelInstallStateChanged = Notification.Name("TranslateAnywhere.modelInstallStateChanged")
    static let modelDownloadProgressChanged = Notification.Name("TranslateAnywhere.modelDownloadProgressChanged")
}

// MARK: - Constants

enum AppConstants {
    static let appName          = "TranslateAnywhere"
    static let bundleIdentifier = "com.translateanywhere.app"
    static let modelSubdirEnRu  = "opus-mt-en-ru"
    static let modelSubdirRuEn  = "opus-mt-ru-en"
    static let maxInputChars    = 8000
    static let clipboardTimeout: TimeInterval = 0.5  // 500ms
    static let clipboardPollInterval: TimeInterval = 0.008 // 8ms
    static let keyEventIntervalNs: UInt64 = 12_000_000
    static let prePasteDelayNs: UInt64 = 15_000_000
    static let postPasteWaitNs: UInt64 = 90_000_000
    static let clipboardRestoreAfterPasteNs: UInt64 = 140_000_000
    static let popupAutoHideSeconds: TimeInterval = 4.0
    static let defaultHotkeyKeyCode: UInt32   = 17   // "t"
    static let defaultHotkeyModifiers: UInt32 = 0x0900 // Ctrl+Option
    static let modelsManifestURL = "https://huggingface.co/grantr-code/translateanywhere-models/resolve/main/manifest-v1.json"
    static let modelsArtifactsBaseURL = "https://huggingface.co/grantr-code/translateanywhere-models/resolve/main"
}
