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
    func captureSelectedText() async -> CaptureResult? {
        logger.info("Starting text capture")

        let outputMode = resolveOutputMode()
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: UDKey.restoreClipboard)

        // ----- Secure-input fast path --------------------------------
        if IsSecureEventInputEnabled() {
            logger.warning("Secure input mode detected -- using AX fallback only")
            guard let text = AccessibilityHelper.getSelectedText(), !text.isEmpty else {
                return nil
            }
            return CaptureResult(text: text, outputMode: outputMode)
        }

        // ----- Save current clipboard --------------------------------
        let savedState = shouldRestoreClipboard ? clipboardManager.save() : nil
        let countBefore = NSPasteboard.general.changeCount

        // ----- Simulate Cmd+C ----------------------------------------
        let source = CGEventSource(stateID: .hidSystemState)

        // Virtual key 8 = "c"
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            logger.error("Failed to create CGEvents for Cmd+C")
            if let savedState {
                clipboardManager.restore(savedState)
            }
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: AppConstants.keyEventIntervalNs)
        keyUp.post(tap: .cghidEventTap)

        // ----- Poll for pasteboard change (max 500 ms) ---------------
        let timeoutNs = UInt64(AppConstants.clipboardTimeout * 1_000_000_000.0)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while NSPasteboard.general.changeCount == countBefore {
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            if elapsed >= timeoutNs {
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(AppConstants.clipboardPollInterval * 1_000_000_000.0))
        }

        // ----- Read result -------------------------------------------
        if NSPasteboard.general.changeCount != countBefore {
            let text = NSPasteboard.general.string(forType: .string)

            if let savedState {
                clipboardManager.restore(savedState)
            }

            if let text, !text.isEmpty {
                logger.info("Captured \(text.count) chars via Cmd+C")
                return CaptureResult(text: text, outputMode: outputMode)
            } else {
                logger.debug("Cmd+C succeeded but pasteboard had no string")
            }
        }

        // ----- Cmd+C did not change clipboard -- try AX fallback -----
        if let savedState {
            clipboardManager.restore(savedState)
        }
        logger.info("Clipboard capture failed, trying AX fallback")

        let axText = AccessibilityHelper.getSelectedText()
        if let axText, !axText.isEmpty {
            logger.info("AX fallback captured \(axText.count) chars")
            return CaptureResult(text: axText, outputMode: outputMode)
        } else {
            logger.debug("AX fallback returned nil")
        }
        return nil
    }

    // MARK: - Replace

    /// Replace the current selection with the given text by pasting it as
    /// plain text.  Returns `true` on success.
    @discardableResult
    func replaceSelection(with text: String) async -> Bool {
        logger.info("Replacing selection with \(text.count) chars")

        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: UDKey.restoreClipboard)
        let savedState = shouldRestoreClipboard ? clipboardManager.save() : nil

        // Put the replacement text on the clipboard as plain text.
        clipboardManager.setPlainText(text)

        // Small delay so the pasteboard write settles.
        try? await Task.sleep(nanoseconds: AppConstants.prePasteDelayNs)

        // ----- Simulate Cmd+V ----------------------------------------
        let source = CGEventSource(stateID: .hidSystemState)

        // Virtual key 9 = "v"
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            logger.error("Failed to create CGEvents for Cmd+V")
            if let savedState {
                clipboardManager.restore(savedState)
            }
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: AppConstants.keyEventIntervalNs)
        keyUp.post(tap: .cghidEventTap)

        // Wait for the target application to finish processing the paste.
        try? await Task.sleep(nanoseconds: AppConstants.postPasteWaitNs)

        // Restore the user's clipboard after a short delay so paste has settled.
        if let savedState {
            try? await Task.sleep(nanoseconds: AppConstants.clipboardRestoreAfterPasteNs)
            clipboardManager.restore(savedState)
        }

        logger.info("Selection replaced successfully")
        return true
    }

    // MARK: - Output Mode Resolution

    private func resolveOutputMode() -> TranslationOutputMode {
        guard let context = AccessibilityHelper.focusedElementContext() else {
            return .replaceSelection
        }

        if let isEditable = context.isEditableTextInput {
            logger.debug("Focused role=\(context.role ?? "unknown"), editable=\(isEditable)")
            return isEditable ? .replaceSelection : .showPopup
        }

        logger.debug("Focused role=\(context.role ?? "unknown"), editable=unknown (fallback to replace)")
        return .replaceSelection
    }
}
