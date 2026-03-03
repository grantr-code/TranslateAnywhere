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

    struct FocusedElementContext {
        let isSecure: Bool
        let isEditableTextInput: Bool?
        let role: String?
    }

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

    /// Returns metadata about the currently focused element. If Accessibility
    /// permission is missing, returns nil.
    static func focusedElementContext() -> FocusedElementContext? {
        guard hasPermission() else {
            logger.warning("Accessibility permission not granted")
            return nil
        }

        guard let axElement = focusedElement() else {
            return nil
        }
        return context(for: axElement)
    }

    /// Attempts to read the currently selected text from the focused UI element
    /// using the Accessibility API.  Returns `nil` if no text is selected, the
    /// element is a secure text field, or permission is not granted.
    static func getSelectedText() -> String? {
        guard hasPermission() else {
            logger.warning("Accessibility permission not granted")
            return nil
        }

        guard let axElement = focusedElement() else {
            return nil
        }

        let context = context(for: axElement)
        if context.isSecure {
            logger.warning("Focused element is a secure text field, cannot read selection")
            return nil
        }

        // Read the selected text attribute.
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

    // MARK: - Internals

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard status == .success, let focused = focusedElementValue else {
            logger.warning("Could not get focused element: \(status.rawValue)")
            return nil
        }
        return (focused as! AXUIElement)
    }

    private static func context(for element: AXUIElement) -> FocusedElementContext {
        let role = attributeString(kAXRoleAttribute as CFString, from: element)
        let isSecure = (role == "AXSecureTextField")

        let editableFromAX = attributeBool("AXEditable" as CFString, from: element)
        let editableByRole: Bool? = {
            guard let role else { return nil }
            let editableRoles: Set<String> = [
                "AXTextField",
                "AXTextArea",
                "AXSearchField",
                "AXTextView",
                "AXComboBox",
            ]
            return editableRoles.contains(role)
        }()

        return FocusedElementContext(
            isSecure: isSecure,
            isEditableTextInput: editableFromAX ?? editableByRole,
            role: role
        )
    }

    private static func attributeString(_ name: CFString, from element: AXUIElement) -> String? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        guard status == .success else {
            return nil
        }
        return value as? String
    }

    private static func attributeBool(_ name: CFString, from element: AXUIElement) -> Bool? {
        var value: AnyObject?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        guard status == .success else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}
