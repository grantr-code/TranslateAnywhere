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
        case .local:  return "Local (OPUS-MT)"
        case .ollama: return "Ollama"
        }
    }
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
        ])
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let hotkeyTriggered       = Notification.Name("TranslateAnywhere.hotkeyTriggered")
    static let hotkeyChanged         = Notification.Name("TranslateAnywhere.hotkeyChanged")
}

// MARK: - Constants

enum AppConstants {
    static let appName          = "TranslateAnywhere"
    static let bundleIdentifier = "com.translateanywhere.app"
    static let modelSubdirEnRu  = "opus-mt-en-ru"
    static let modelSubdirRuEn  = "opus-mt-ru-en"
    static let maxInputChars    = 8000
    static let clipboardTimeout: TimeInterval = 0.5  // 500ms
    static let defaultHotkeyKeyCode: UInt32   = 17   // "t"
    static let defaultHotkeyModifiers: UInt32 = 0x0900 // Ctrl+Option
}
