/*
 * MenuManager.swift
 * Builds and manages the NSMenu for the status bar item.
 *
 * Layout:
 *   Translate Selection Now
 *   ──────────────────────
 *   Hotkey: ^T           (disabled label, updates dynamically)
 *   Set Hotkey...
 *   Clear Hotkey
 *   ──────────────────────
 *   Direction >           (submenu)
 *   ──────────────────────
 *   Restore clipboard after capture  (toggle)
 *   ──────────────────────
 *   Backend >             (submenu)
 *   ──────────────────────
 *   Quit
 */

import AppKit
import os.log

@MainActor
final class MenuManager: NSObject {

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "Menu")

    private let statusItem: NSStatusItem
    private let hotkeyManager: HotkeyManager
    private let capturePanel = HotkeyCapturePanel()

    private var hotkeyLabelItem: NSMenuItem?

    init(statusItem: NSStatusItem, hotkeyManager: HotkeyManager) {
        self.statusItem = statusItem
        self.hotkeyManager = hotkeyManager
        super.init()

        // Observe hotkey changes to refresh the menu
        NotificationCenter.default.addObserver(self, selector: #selector(onHotkeyChanged),
                                               name: .hotkeyChanged, object: nil)

        buildMenu()
        logger.info("MenuManager initialized")
    }

    // MARK: - Build Menu

    func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settings = SettingsManager.shared

        // ── Translate Selection Now ──
        let translateItem = NSMenuItem(title: "Translate Selection Now",
                                       action: #selector(translateNow),
                                       keyEquivalent: "")
        translateItem.target = self
        menu.addItem(translateItem)

        menu.addItem(.separator())

        // ── Hotkey display ──
        let hotkeyDisplay: String
        if settings.hotkeyKeyCode == 0 && settings.hotkeyModifiers == 0 {
            hotkeyDisplay = "Hotkey: (none)"
        } else {
            hotkeyDisplay = "Hotkey: \(settings.hotkeyDisplayString)"
        }
        let hotkeyLabel = NSMenuItem(title: hotkeyDisplay, action: nil, keyEquivalent: "")
        hotkeyLabel.isEnabled = false
        menu.addItem(hotkeyLabel)
        self.hotkeyLabelItem = hotkeyLabel

        let setHotkey = NSMenuItem(title: "Set Hotkey\u{2026}",
                                   action: #selector(setHotkeyAction),
                                   keyEquivalent: "")
        setHotkey.target = self
        menu.addItem(setHotkey)

        let clearHotkey = NSMenuItem(title: "Clear Hotkey",
                                     action: #selector(clearHotkeyAction),
                                     keyEquivalent: "")
        clearHotkey.target = self
        menu.addItem(clearHotkey)

        menu.addItem(.separator())

        // ── Direction submenu ──
        let directionItem = NSMenuItem(title: "Direction", action: nil, keyEquivalent: "")
        let directionSubmenu = NSMenu()
        for dir in TranslateDirection.allCases {
            let item = NSMenuItem(title: dir.label,
                                  action: #selector(setDirection(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = Int(dir.rawValue)
            item.state = (settings.direction == dir) ? .on : .off
            directionSubmenu.addItem(item)
        }
        directionItem.submenu = directionSubmenu
        menu.addItem(directionItem)

        menu.addItem(.separator())

        // ── Toggle items ──
        let restoreClip = NSMenuItem(title: "Restore clipboard after capture",
                                     action: #selector(toggleRestoreClipboard(_:)),
                                     keyEquivalent: "")
        restoreClip.target = self
        restoreClip.state = settings.restoreClipboard ? .on : .off
        menu.addItem(restoreClip)

        menu.addItem(.separator())

        // ── Backend submenu ──
        let backendItem = NSMenuItem(title: "Backend", action: nil, keyEquivalent: "")
        let backendSubmenu = NSMenu()
        for b in TranslationBackend.allCases {
            let item = NSMenuItem(title: b.label,
                                  action: #selector(setBackend(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = b.rawValue
            item.state = (settings.backend == b) ? .on : .off
            backendSubmenu.addItem(item)
        }
        backendItem.submenu = backendSubmenu
        menu.addItem(backendItem)

        menu.addItem(.separator())

        // ── Quit ──
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(quitApp),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        logger.info("Menu built")
    }

    // MARK: - Actions

    @objc private func translateNow() {
        logger.info("Menu: Translate Selection Now")
        NotificationCenter.default.post(name: .hotkeyTriggered, object: nil)
    }

    @objc private func setHotkeyAction() {
        logger.info("Menu: Set Hotkey...")
        capturePanel.show(
            onComplete: { [weak self] keyCode, modifiers in
                guard let self else { return }
                let settings = SettingsManager.shared
                settings.hotkeyKeyCode = keyCode
                settings.hotkeyModifiers = modifiers
                self.hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                self.logger.info("Hotkey set to keyCode=\(keyCode), mods=0x\(String(modifiers, radix: 16))")
            },
            onCancel: { [weak self] in
                self?.logger.info("Hotkey capture cancelled")
            }
        )
    }

    @objc private func clearHotkeyAction() {
        logger.info("Menu: Clear Hotkey")
        hotkeyManager.clearHotkey()
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        buildMenu()
    }

    @objc private func setDirection(_ sender: NSMenuItem) {
        guard let dir = TranslateDirection(rawValue: Int32(sender.tag)) else { return }
        logger.info("Menu: Direction set to \(dir.label)")
        SettingsManager.shared.direction = dir
        buildMenu()
    }

    @objc private func toggleRestoreClipboard(_ sender: NSMenuItem) {
        let settings = SettingsManager.shared
        settings.restoreClipboard = !settings.restoreClipboard
        logger.info("Menu: Restore clipboard = \(settings.restoreClipboard)")
        buildMenu()
    }

    @objc private func setBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let backend = TranslationBackend(rawValue: raw) else { return }
        logger.info("Menu: Backend set to \(backend.label)")
        SettingsManager.shared.backend = backend
        buildMenu()
    }

    @objc private func quitApp() {
        logger.info("Menu: Quit")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Observers

    @objc private func onHotkeyChanged() {
        buildMenu()
    }
}
