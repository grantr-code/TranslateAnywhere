/*
 * SelectionCapture.swift
 * TranslateAnywhere
 *
 * Captures the currently selected text in the frontmost application via
 * simulated Cmd+C and replaces the selection with translated text via Cmd+V.
 * Falls back to the
 * Accessibility API when clipboard capture is impossible (secure input
 * mode, apps that block Cmd+C, etc.).
 *
 * The user's clipboard contents are saved before and restored after every
 * capture/replace cycle (when the "restoreClipboard" preference is on).
 */

import AppKit
import Carbon
import os.log

final class SelectionCapture {

    // MARK: - Properties

    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "capture"
    )
    private let clipboardManager = ClipboardManager()

    // MARK: - Capture

    /// Capture the currently selected text in the frontmost application.
    ///
    /// Strategy:
    /// 1. If macOS secure-input mode is active, go straight to AX fallback.
    /// 2. Otherwise simulate Cmd+C, wait for the pasteboard to change,
    ///    read the text, and (optionally) restore the original clipboard.
    /// 3. If Cmd+C did not change the pasteboard, try the AX fallback.
    func captureSelectedText() async -> String? {
        logger.info("Starting text capture")

        // ----- Secure-input fast path --------------------------------
        if IsSecureEventInputEnabled() {
            logger.warning("Secure input mode detected -- using AX fallback only")
            return AccessibilityHelper.getSelectedText()
        }

        // ----- Save current clipboard --------------------------------
        let saved = clipboardManager.save()
        let countBefore = NSPasteboard.general.changeCount

        // ----- Simulate Cmd+C ----------------------------------------
        let source = CGEventSource(stateID: .hidSystemState)

        // Virtual key 8 = "c"
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            logger.error("Failed to create CGEvents for Cmd+C")
            clipboardManager.restore(saved)
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms between down & up
        keyUp.post(tap: .cghidEventTap)

        // ----- Poll for pasteboard change (max 500 ms) ---------------
        let deadline = Date().addingTimeInterval(AppConstants.clipboardTimeout)
        while NSPasteboard.general.changeCount == countBefore && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }

        // ----- Read result -------------------------------------------
        if NSPasteboard.general.changeCount != countBefore {
            let text = NSPasteboard.general.string(forType: .string)

            // Restore the user's clipboard if the preference is enabled.
            if UserDefaults.standard.bool(forKey: UDKey.restoreClipboard) {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
                clipboardManager.restore(saved)
            }

            if let text, !text.isEmpty {
                logger.info("Captured \(text.count) chars via Cmd+C")
            } else {
                logger.debug("Cmd+C succeeded but pasteboard had no string")
            }
            return text
        }

        // ----- Cmd+C did not change clipboard -- try AX fallback -----
        clipboardManager.restore(saved)
        logger.info("Clipboard capture failed, trying AX fallback")

        let axText = AccessibilityHelper.getSelectedText()
        if let axText {
            logger.info("AX fallback captured \(axText.count) chars")
        } else {
            logger.debug("AX fallback returned nil")
        }
        return axText
    }

    // MARK: - Replace

    /// Replace the current selection with the given text by pasting it as
    /// plain text.  Returns `true` on success.
    @discardableResult
    func replaceSelection(with text: String) async -> Bool {
        logger.info("Replacing selection with \(text.count) chars")

        // Save the user's clipboard so we can restore it later.
        let saved = clipboardManager.save()

        // Put the replacement text on the clipboard as plain text.
        clipboardManager.setPlainText(text)

        // Small delay so the pasteboard write settles.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // ----- Simulate Cmd+V ----------------------------------------
        let source = CGEventSource(stateID: .hidSystemState)

        // Virtual key 9 = "v"
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms between down & up

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        // Wait for the target application to finish processing the paste.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // Restore the user's original clipboard if preference is on.
        if UserDefaults.standard.bool(forKey: UDKey.restoreClipboard) {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms extra
            clipboardManager.restore(saved)
        }

        logger.info("Selection replaced successfully")
        return true
    }
}
