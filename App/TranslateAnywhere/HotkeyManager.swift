/*
 * HotkeyManager.swift
 * Registers a system-wide hotkey using Carbon's RegisterEventHotKey API.
 * Also provides HotkeyCapturePanel for the user to set a new hotkey combination.
 *
 * The manager validates that modifier combos always include Control or Cmd.
 * On registration failure it falls back to Ctrl+Option+T.
 */

import AppKit
import Carbon.HIToolbox
import os.log

// MARK: - Global Carbon event handler

/// Unique hotkey ID tag used for registration.
private let kHotkeyID = EventHotKeyID(signature: OSType(0x5441), // "TA"
                                       id: 1)

/// Global C-compatible function pointer for the Carbon hot key event handler.
/// This is installed via InstallEventHandler on the application event target.
private var hotkeyEventHandlerRef: EventHandlerRef?

private func carbonHotkeyHandler(nextHandler: EventHandlerCallRef?,
                                  event: EventRef?,
                                  userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return status }

    if hotKeyID.signature == kHotkeyID.signature && hotKeyID.id == kHotkeyID.id {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .hotkeyTriggered, object: nil)
        }
    }
    return noErr
}

// MARK: - HotkeyManager

@MainActor
final class HotkeyManager {

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "Hotkey")
    private var hotkeyRef: EventHotKeyRef?
    private var isHandlerInstalled = false

    /// The key code and Carbon modifiers for the currently registered hotkey.
    private(set) var currentKeyCode: UInt32 = 0
    private(set) var currentModifiers: UInt32 = 0

    init() {
        installCarbonHandler()
    }

    deinit {
        // Note: deinit on MainActor
    }

    // MARK: - Carbon handler installation

    private func installCarbonHandler() {
        guard !isHandlerInstalled else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         carbonHotkeyHandler,
                                         1,
                                         &eventSpec,
                                         nil,
                                         &hotkeyEventHandlerRef)
        if status == noErr {
            isHandlerInstalled = true
            logger.info("Carbon event handler installed")
        } else {
            logger.error("Failed to install Carbon event handler: \(status)")
        }
    }

    // MARK: - Registration

    /// Registers a global hotkey with the given Carbon key code and modifier mask.
    /// Returns true on success.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        // Validate modifiers: must include controlKey (0x1000) or cmdKey (0x0100)
        guard validateModifiers(modifiers) else {
            logger.warning("Invalid modifiers 0x\(String(modifiers, radix: 16)): must include Control or Cmd")
            return false
        }

        // Unregister any existing hotkey first
        unregister()

        var hotKeyRef: EventHotKeyRef?
        var hotKeyID = kHotkeyID

        let status = RegisterEventHotKey(keyCode,
                                          modifiers,
                                          hotKeyID,
                                          GetApplicationEventTarget(),
                                          0,
                                          &hotKeyRef)

        if status == noErr, let ref = hotKeyRef {
            self.hotkeyRef = ref
            self.currentKeyCode = keyCode
            self.currentModifiers = modifiers
            logger.info("Hotkey registered: keyCode=\(keyCode), mods=0x\(String(modifiers, radix: 16))")
            return true
        } else {
            logger.error("RegisterEventHotKey failed: \(status)")
            return false
        }
    }

    /// Registers from saved settings, with fallback to default.
    func registerFromSettings() {
        let settings = SettingsManager.shared
        let keyCode = settings.hotkeyKeyCode
        let modifiers = settings.hotkeyModifiers

        if keyCode == 0 && modifiers == 0 {
            logger.info("No hotkey configured, skipping registration")
            return
        }

        if !register(keyCode: keyCode, modifiers: modifiers) {
            logger.warning("Failed to register saved hotkey, falling back to Ctrl+Option+T")
            fallbackToDefault()
        }
    }

    /// Unregisters the current hotkey.
    func unregister() {
        if let ref = hotkeyRef {
            let status = UnregisterEventHotKey(ref)
            if status == noErr {
                logger.info("Hotkey unregistered")
            } else {
                logger.error("UnregisterEventHotKey failed: \(status)")
            }
            hotkeyRef = nil
        }
        currentKeyCode = 0
        currentModifiers = 0
    }

    /// Clears the hotkey from settings and unregisters.
    func clearHotkey() {
        unregister()
        let settings = SettingsManager.shared
        settings.hotkeyKeyCode = 0
        settings.hotkeyModifiers = 0
        logger.info("Hotkey cleared from settings")
    }

    // MARK: - Validation

    /// Validates that the modifier mask includes Control (0x1000) or Cmd (0x0100).
    /// Rejects Option-only, Shift-only, or Option+Shift-only combos.
    func validateModifiers(_ mods: UInt32) -> Bool {
        let hasControl = (mods & UInt32(controlKey)) != 0
        let hasCmd = (mods & UInt32(cmdKey)) != 0
        return hasControl || hasCmd
    }

    // MARK: - Fallback

    private func fallbackToDefault() {
        let keyCode = AppConstants.defaultHotkeyKeyCode
        let modifiers = AppConstants.defaultHotkeyModifiers

        if register(keyCode: keyCode, modifiers: modifiers) {
            let settings = SettingsManager.shared
            settings.hotkeyKeyCode = keyCode
            settings.hotkeyModifiers = modifiers
            logger.info("Registered fallback hotkey: Ctrl+Option+T")

            // Show a transient banner via notification
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Hotkey Registration"
                alert.informativeText = "The configured hotkey could not be registered. Falling back to \u{2303}\u{2325}T (Ctrl+Option+T)."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } else {
            logger.error("Even fallback hotkey registration failed")
        }
    }
}

// MARK: - HotkeyCapturePanel

/// A small modal-ish panel that captures a key combination from the user.
@MainActor
final class HotkeyCapturePanel {

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "HotkeyCapture")
    private var panel: NSPanel?
    private var monitor: Any?
    private var instructionLabel: NSTextField?
    private var errorLabel: NSTextField?

    private var onComplete: ((UInt32, UInt32) -> Void)?
    private var onCancel: (() -> Void)?

    /// Shows the capture panel. Calls `onComplete(keyCode, modifiers)` when a valid combo is pressed,
    /// or `onCancel()` when Esc is pressed.
    func show(onComplete: @escaping (UInt32, UInt32) -> Void,
              onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        // Create the panel
        let panelRect = NSRect(x: 0, y: 0, width: 300, height: 120)
        let p = NSPanel(contentRect: panelRect,
                        styleMask: [.titled, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.title = "Set Hotkey"
        p.level = .floating
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.center()
        self.panel = p

        // Content view
        let contentView = NSView(frame: panelRect)
        p.contentView = contentView

        // Instruction label
        let instruction = NSTextField(labelWithString: "Press new hotkey combination...")
        instruction.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        instruction.alignment = .center
        instruction.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(instruction)
        self.instructionLabel = instruction

        // Error label
        let error = NSTextField(labelWithString: "")
        error.font = NSFont.systemFont(ofSize: 12)
        error.textColor = .systemRed
        error.alignment = .center
        error.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(error)
        self.errorLabel = error

        // Hint label
        let hint = NSTextField(labelWithString: "Press Esc to cancel")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hint)

        NSLayoutConstraint.activate([
            instruction.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            instruction.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            instruction.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            instruction.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            error.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            error.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 12),
            error.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            error.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            hint.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        // Install local key monitor
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil // consume all key events
        }

        // Make the panel key and order it front
        p.makeKeyAndOrderFront(nil)
        // We need to make the app active temporarily to receive key events
        NSApp.activate(ignoringOtherApps: true)

        logger.info("Hotkey capture panel shown")
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)

        // Esc cancels
        if keyCode == 53 { // Escape key
            dismiss()
            onCancel?()
            return
        }

        // Convert NSEvent modifier flags to Carbon modifiers
        let carbonMods = nsModifiersToCarbonModifiers(event.modifierFlags)

        // Validate
        let hasControl = (carbonMods & UInt32(controlKey)) != 0
        let hasCmd = (carbonMods & UInt32(cmdKey)) != 0

        if !hasControl && !hasCmd {
            errorLabel?.stringValue = "Must include \u{2303} or \u{2318}"
            logger.debug("Rejected hotkey: missing Control or Cmd modifier")
            return
        }

        // Valid combination
        errorLabel?.stringValue = ""
        logger.info("Captured hotkey: keyCode=\(keyCode), mods=0x\(String(carbonMods, radix: 16))")

        dismiss()
        onComplete?(keyCode, carbonMods)
    }

    /// Converts NSEvent.ModifierFlags to Carbon modifier mask.
    private func nsModifiersToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    private func dismiss() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        instructionLabel = nil
        errorLabel = nil
        logger.info("Hotkey capture panel dismissed")
    }
}
