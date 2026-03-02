/*
 * AccessibilityHelper.swift
 * TranslateAnywhere
 *
 * Provides an Accessibility API (AX) fallback for reading the currently
 * selected text when the clipboard-based capture cannot be used (e.g.
 * secure input mode, non-standard text fields).  Also handles permission
 * checks and prompts.
 */

import AppKit
import ApplicationServices
import os.log

final class AccessibilityHelper {

    // MARK: - Logger

    private static let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "accessibility"
    )

    // MARK: - Permission Checks

    /// Returns `true` if the app already has Accessibility permission.
    /// Does NOT prompt the user.
    static func hasPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Prompts the user to grant Accessibility permission and opens
    /// System Settings to the relevant pane.
    static func requestPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Also try to open the System Settings / System Preferences pane directly.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Selected Text via AX

    /// Attempts to read the currently selected text from the focused UI element
    /// using the Accessibility API.  Returns `nil` if no text is selected, the
    /// element is a secure text field, or permission is not granted.
    static func getSelectedText() -> String? {
        guard hasPermission() else {
            logger.warning("Accessibility permission not granted")
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()

        // 1. Get the focused element.
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success, let element = focusedElement else {
            logger.warning("Could not get focused element: \(focusResult.rawValue)")
            return nil
        }

        let axElement = element as! AXUIElement

        // 2. Reject secure text fields (password fields).
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        if let role = roleValue as? String, role == "AXSecureTextField" {
            logger.warning("Focused element is a secure text field, cannot read selection")
            return nil
        }

        // 3. Read the selected text attribute.
        var selectedTextValue: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        )

        guard textResult == .success,
              let text = selectedTextValue as? String,
              !text.isEmpty else {
            logger.debug("No selected text via AX (status: \(textResult.rawValue))")
            return nil
        }

        logger.debug("Got selected text via AX: \(text.prefix(50))...")
        return text
    }

    // MARK: - Secure Text Field Detection

    /// Returns `true` if the currently focused element is a secure (password)
    /// text field, meaning we must not attempt to read its contents.
    static func isSecureTextField() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return false
        }

        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        return (roleValue as? String) == "AXSecureTextField"
    }
}
