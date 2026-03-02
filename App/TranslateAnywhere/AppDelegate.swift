/*
 * AppDelegate.swift
 * Main entry point for TranslateAnywhere — a macOS menu-bar translation app.
 *
 * LSUIElement behavior (no dock icon) is configured via Info.plist.
 * The app runs entirely from a status bar item with an SF Symbol icon.
 *
 * State machine for hotkey triggers:
 *   - Panel NOT showing: capture text -> detect direction -> translate
 *       - If EN->RU and autoReplaceEnToRu ON: auto-replace, no panel
 *       - If RU->EN and autoReplaceRuToEn ON: auto-replace, no panel
 *       - Otherwise: show panel with translation
 *   - Panel IS showing and hotkey pressed: primary action
 *       - If not yet replaced: replace selection
 *       - If already replaced: undo replacement
 */

import AppKit
import os.log

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "AppDelegate")

    // MARK: - Components

    private var statusItem: NSStatusItem!
    private var menuManager: MenuManager!
    private var hotkeyManager: HotkeyManager!
    private var translatorService: TranslatorService!
    private var translationPanel: TranslationPanel!
    private var selectionCapture: SelectionCapture!

    // MARK: - State

    /// The original text that was captured (before translation/replacement).
    private var capturedOriginalText: String?
    /// The translated text currently shown or applied.
    private var currentTranslation: String?
    /// The direction that was detected/used for the current translation.
    private var currentDetectedDirection: TranslateDirection = .autoDetect
    /// Whether the panel has already replaced the selection.
    private var hasReplacedSelection = false
    /// Whether a translation is currently in flight.
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
        translationPanel = TranslationPanel()
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

        nc.addObserver(self, selector: #selector(onReplaceSelection(_:)),
                       name: .replaceSelection, object: nil)

        nc.addObserver(self, selector: #selector(onUndoReplace),
                       name: .undoReplace, object: nil)

        nc.addObserver(self, selector: #selector(onFlipDirection),
                       name: .flipDirection, object: nil)

        nc.addObserver(self, selector: #selector(onHotkeyChanged),
                       name: .hotkeyChanged, object: nil)
    }

    // MARK: - Hotkey Triggered

    @objc private func onHotkeyTriggered() {
        logger.info("Hotkey triggered")

        // State machine: panel visible?
        if translationPanel.isVisible {
            logger.info("Panel is visible -> primary action")
            handlePanelPrimaryAction()
            return
        }

        // Panel not visible -> capture and translate
        guard !isTranslating else {
            logger.info("Translation already in progress, ignoring")
            return
        }

        captureAndTranslate()
    }

    // MARK: - Capture & Translate

    private func captureAndTranslate() {
        logger.info("Capturing selection...")
        isTranslating = true

        Task {
            // Capture selected text using SelectionCapture (async)
            guard let text = await selectionCapture.captureSelectedText(), !text.isEmpty else {
                logger.warning("No text captured")
                isTranslating = false
                return
            }

            logger.info("Captured \(text.count) characters")

            // Truncate if needed
            let settings = SettingsManager.shared
            var inputText = text
            if inputText.count > settings.maxInputChars {
                logger.warning("Input truncated from \(inputText.count) to \(settings.maxInputChars) chars")
                inputText = String(inputText.prefix(settings.maxInputChars))
            }

            capturedOriginalText = inputText
            hasReplacedSelection = false
            selectionCapture.resetUndoState()

            // Determine direction
            let configuredDirection = settings.direction

            // Translate
            let result = await translatorService.translate(
                text: inputText, direction: configuredDirection)

            isTranslating = false

            guard result.status == .ok else {
                logger.error("Translation failed: status=\(result.status.rawValue)")
                // Show panel with error
                translationPanel.show(
                    original: inputText,
                    translation: "Translation error (\(result.status.rawValue))",
                    direction: configuredDirection,
                    detectedDirection: result.detectedDirection)
                return
            }

            currentTranslation = result.text
            currentDetectedDirection = result.detectedDirection

            logger.info("Translation complete: direction=\(result.detectedDirection.label)")

            // Check auto-replace conditions
            let detectedDir = result.detectedDirection
            if detectedDir == .enToRu && settings.autoReplaceEnToRu {
                logger.info("Auto-replacing EN->RU translation")
                await autoReplace(with: result.text)
                return
            }
            if detectedDir == .ruToEn && settings.autoReplaceRuToEn {
                logger.info("Auto-replacing RU->EN translation")
                await autoReplace(with: result.text)
                return
            }

            // Show panel
            translationPanel.show(
                original: inputText,
                translation: result.text,
                direction: configuredDirection,
                detectedDirection: result.detectedDirection)
        }
    }

    // MARK: - Auto Replace

    private func autoReplace(with text: String) async {
        let success = await selectionCapture.replaceSelection(with: text)
        if success {
            hasReplacedSelection = true
            logger.info("Auto-replace successful")
        } else {
            logger.error("Auto-replace failed, showing panel instead")
            translationPanel.show(
                original: capturedOriginalText ?? "",
                translation: text,
                direction: currentDetectedDirection,
                detectedDirection: currentDetectedDirection)
        }
    }

    // MARK: - Panel Primary Action

    private func handlePanelPrimaryAction() {
        Task {
            if !hasReplacedSelection {
                // Replace
                guard let translation = currentTranslation else {
                    logger.warning("No translation available for replace")
                    return
                }
                logger.info("Panel primary action -> replace selection")
                let success = await selectionCapture.replaceSelection(with: translation)
                if success {
                    hasReplacedSelection = true
                    logger.info("Selection replaced successfully")
                } else {
                    logger.error("Failed to replace selection")
                }
                translationPanel.dismiss()
            } else {
                // Already replaced -> undo
                logger.info("Panel primary action -> undo")
                await performUndo()
            }
        }
    }

    // MARK: - Replace / Undo Notifications

    @objc private func onReplaceSelection(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else {
            logger.warning("replaceSelection notification missing text")
            return
        }
        logger.info("Replace selection with \(text.count) chars")

        Task {
            let success = await selectionCapture.replaceSelection(with: text)
            if success {
                hasReplacedSelection = true
                logger.info("Selection replaced via panel action")
            } else {
                logger.error("Failed to replace selection via panel action")
            }
            translationPanel.dismiss()
        }
    }

    @objc private func onUndoReplace() {
        logger.info("Undo replace requested")
        Task {
            await performUndo()
        }
    }

    private func performUndo() async {
        await selectionCapture.undoLastReplacement()
        hasReplacedSelection = false
        logger.info("Undo complete")
        translationPanel.dismiss()
    }

    // MARK: - Flip Direction

    @objc private func onFlipDirection() {
        logger.info("Flip direction requested")

        guard let originalText = capturedOriginalText else {
            logger.warning("No original text to re-translate")
            return
        }

        // Flip the direction
        let newDirection: TranslateDirection
        switch currentDetectedDirection {
        case .enToRu:
            newDirection = .ruToEn
        case .ruToEn:
            newDirection = .enToRu
        case .autoDetect:
            newDirection = .enToRu // default flip from auto
        }

        logger.info("Flipping direction to \(newDirection.label)")
        translationPanel.updateStatus("Translating...")
        isTranslating = true

        Task {
            let result = await translatorService.translate(text: originalText, direction: newDirection)
            isTranslating = false

            guard result.status == .ok else {
                logger.error("Flip translation failed: status=\(result.status.rawValue)")
                translationPanel.updateStatus("Translation failed")
                return
            }

            currentTranslation = result.text
            currentDetectedDirection = result.detectedDirection
            hasReplacedSelection = false
            selectionCapture.resetUndoState()

            translationPanel.show(
                original: originalText,
                translation: result.text,
                direction: newDirection,
                detectedDirection: result.detectedDirection)
        }
    }

    // MARK: - Hotkey Changed

    @objc private func onHotkeyChanged() {
        logger.info("Hotkey changed notification received")
        // Menu manager handles its own rebuild; nothing else needed here
    }
}
