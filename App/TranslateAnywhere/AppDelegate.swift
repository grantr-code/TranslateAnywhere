/*
 * AppDelegate.swift
 * Main entry point for TranslateAnywhere — a macOS menu-bar translation app.
 *
 * LSUIElement behavior (no dock icon) is configured via Info.plist.
 * The app runs entirely from a status bar item with an SF Symbol icon.
 *
 * Hotkey flow: capture selected text -> translate -> replace selection in-place.
 * If translation fails or no text is selected, play a system beep.
 */

import AppKit
import os.log

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "AppDelegate")

    // MARK: - Components

    private var statusItem: NSStatusItem!
    private var menuManager: MenuManager!
    private var hotkeyManager: HotkeyManager!
    private var translatorService: TranslatorService!
    private var selectionCapture: SelectionCapture!

    nonisolated override init() {
        super.init()
    }

    // MARK: - State

    /// Whether a translation is currently in flight (debounce guard).
    private var isTranslating = false

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("TranslateAnywhere launching")

        // Register defaults
        UDKey.registerDefaults()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "TranslateAnywhere")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }

        // Initialize components
        hotkeyManager = HotkeyManager()
        translatorService = TranslatorService()
        selectionCapture = SelectionCapture()
        menuManager = MenuManager(statusItem: statusItem, hotkeyManager: hotkeyManager)

        // Register hotkey from settings
        hotkeyManager.registerFromSettings()

        // Initialize translation engine (non-blocking)
        Task {
            let success = translatorService.initialize()
            if success {
                logger.info("Translation engine ready")
            } else {
                logger.warning("Translation engine failed to initialize; Ollama backend may still work")
            }
        }

        // Subscribe to notifications
        subscribeToNotifications()

        logger.info("TranslateAnywhere launch complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("TranslateAnywhere terminating")
        hotkeyManager.unregister()
    }

    // MARK: - Notification Subscriptions

    private func subscribeToNotifications() {
        let nc = NotificationCenter.default

        nc.addObserver(self, selector: #selector(onHotkeyTriggered),
                       name: .hotkeyTriggered, object: nil)

        nc.addObserver(self, selector: #selector(onHotkeyChanged),
                       name: .hotkeyChanged, object: nil)
    }

    // MARK: - Hotkey Triggered

    @objc private func onHotkeyTriggered() {
        logger.info("Hotkey triggered")

        guard !isTranslating else {
            logger.info("Translation already in progress, ignoring")
            return
        }

        captureAndTranslate()
    }

    // MARK: - Capture, Translate, Replace

    private func captureAndTranslate() {
        isTranslating = true

        Task {
            defer { isTranslating = false }

            // 1. Capture selected text
            guard let text = await selectionCapture.captureSelectedText(), !text.isEmpty else {
                logger.warning("No text captured")
                NSSound.beep()
                return
            }

            logger.info("Captured \(text.count) characters")

            // 2. Truncate if needed
            let settings = SettingsManager.shared
            var inputText = text
            if inputText.count > settings.maxInputChars {
                logger.warning("Input truncated from \(inputText.count) to \(settings.maxInputChars) chars")
                inputText = String(inputText.prefix(settings.maxInputChars))
            }

            // 3. Translate
            let result = await translatorService.translate(
                text: inputText, direction: settings.direction)

            guard result.status == .ok else {
                logger.error("Translation failed: status=\(result.status.rawValue)")
                NSSound.beep()
                return
            }

            logger.info("Translation complete: direction=\(result.detectedDirection.label)")

            // 4. Replace selection in-place
            let success = await selectionCapture.replaceSelection(with: result.text)
            if success {
                logger.info("Selection replaced successfully")
            } else {
                logger.error("Failed to replace selection")
                NSSound.beep()
            }
        }
    }

    // MARK: - Hotkey Changed

    @objc private func onHotkeyChanged() {
        logger.info("Hotkey changed notification received")
    }
}
