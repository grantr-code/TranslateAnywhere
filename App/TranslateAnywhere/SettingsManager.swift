/*
 * SettingsManager.swift
 * Singleton wrapper around UserDefaults for all TranslateAnywhere settings.
 *
 * Provides typed properties for every UDKey and helpers for converting
 * Carbon hotkey codes and modifiers into human-readable symbol strings.
 */

import Foundation
import Carbon.HIToolbox
import os.log

@MainActor
final class SettingsManager {

    // MARK: - Singleton

    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "Settings")

    private init() {
        logger.info("SettingsManager initialized")
    }

    // MARK: - Hotkey

    var hotkeyKeyCode: UInt32 {
        get { UInt32(defaults.integer(forKey: UDKey.hotkeyKeyCode)) }
        set { defaults.set(Int(newValue), forKey: UDKey.hotkeyKeyCode) }
    }

    var hotkeyModifiers: UInt32 {
        get { UInt32(defaults.integer(forKey: UDKey.hotkeyModifiers)) }
        set { defaults.set(Int(newValue), forKey: UDKey.hotkeyModifiers) }
    }

    // MARK: - Direction

    var direction: TranslateDirection {
        get {
            let raw = Int32(defaults.integer(forKey: UDKey.direction))
            return TranslateDirection(rawValue: raw) ?? .autoDetect
        }
        set { defaults.set(Int(newValue.rawValue), forKey: UDKey.direction) }
    }

    // MARK: - Backend

    var backend: TranslationBackend {
        get {
            let raw = defaults.string(forKey: UDKey.backend) ?? TranslationBackend.local.rawValue
            return TranslationBackend(rawValue: raw) ?? .local
        }
        set { defaults.set(newValue.rawValue, forKey: UDKey.backend) }
    }

    // MARK: - Toggles

    var autoCopyToClipboard: Bool {
        get { defaults.bool(forKey: UDKey.autoCopyToClipboard) }
        set { defaults.set(newValue, forKey: UDKey.autoCopyToClipboard) }
    }

    var restoreClipboard: Bool {
        get { defaults.bool(forKey: UDKey.restoreClipboard) }
        set { defaults.set(newValue, forKey: UDKey.restoreClipboard) }
    }

    var autoReplaceEnToRu: Bool {
        get { defaults.bool(forKey: UDKey.autoReplaceEnToRu) }
        set { defaults.set(newValue, forKey: UDKey.autoReplaceEnToRu) }
    }

    var autoReplaceRuToEn: Bool {
        get { defaults.bool(forKey: UDKey.autoReplaceRuToEn) }
        set { defaults.set(newValue, forKey: UDKey.autoReplaceRuToEn) }
    }

    var maxInputChars: Int {
        get {
            let v = defaults.integer(forKey: UDKey.maxInputChars)
            return v > 0 ? v : AppConstants.maxInputChars
        }
        set { defaults.set(newValue, forKey: UDKey.maxInputChars) }
    }

    // MARK: - Ollama

    var ollamaEndpoint: String {
        get { defaults.string(forKey: UDKey.ollamaEndpoint) ?? "http://localhost:11434" }
        set { defaults.set(newValue, forKey: UDKey.ollamaEndpoint) }
    }

    var ollamaModel: String {
        get { defaults.string(forKey: UDKey.ollamaModel) ?? "llama3" }
        set { defaults.set(newValue, forKey: UDKey.ollamaModel) }
    }

    // MARK: - Hotkey Display

    /// Returns a human-readable string such as "^T" for the current hotkey.
    var hotkeyDisplayString: String {
        let symbols = carbonModifiersToSymbols(hotkeyModifiers)
        let key = keyCodeToString(hotkeyKeyCode)
        return "\(symbols)\(key)"
    }

    /// Converts a Carbon modifier mask to modifier symbols (e.g. "^" "^").
    /// Matches Carbon constants: cmdKey=0x0100, shiftKey=0x0200, optionKey=0x0800, controlKey=0x1000.
    func carbonModifiersToSymbols(_ mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "\u{2303}" }  // ^
        if mods & UInt32(optionKey)  != 0 { s += "\u{2325}" }  // option symbol
        if mods & UInt32(shiftKey)   != 0 { s += "\u{21E7}" }  // shift symbol
        if mods & UInt32(cmdKey)     != 0 { s += "\u{2318}" }  // cmd symbol
        return s
    }

    /// Converts a Carbon virtual key code to a string character.
    func keyCodeToString(_ keyCode: UInt32) -> String {
        // Common key code mappings (macOS virtual key codes)
        let keyMap: [UInt32: String] = [
            0:  "A",   1:  "S",   2:  "D",   3:  "F",   4:  "H",
            5:  "G",   6:  "Z",   7:  "X",   8:  "C",   9:  "V",
            11: "B",  12: "Q",  13: "W",  14: "E",  15: "R",
            16: "Y",  17: "T",  18: "1",  19: "2",  20: "3",
            21: "4",  22: "6",  23: "5",  24: "=",  25: "9",
            26: "7",  27: "-",  28: "8",  29: "0",  30: "]",
            31: "O",  32: "U",  33: "[",  34: "I",  35: "P",
            37: "L",  38: "J",  39: "'",  40: "K",  41: ";",
            42: "\\", 43: ",",  44: "/",  45: "N",  46: "M",
            47: ".",
            36: "\u{21A9}",  // Return
            48: "\u{21E5}",  // Tab
            49: "\u{2423}",  // Space
            51: "\u{232B}",  // Delete
            53: "\u{238B}",  // Escape
            96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11",
            105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 114: "Help",
            115: "Home", 116: "PgUp", 117: "\u{2326}", // Forward Delete
            118: "F4", 119: "End", 120: "F2",
            121: "PgDn", 122: "F1", 123: "\u{2190}", // Left
            124: "\u{2192}", // Right
            125: "\u{2193}", // Down
            126: "\u{2191}", // Up
        ]
        return keyMap[keyCode] ?? "?"
    }
}
