/*
 * MenuManager.swift
 * Builds and manages the NSMenu for the status bar item.
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

        NotificationCenter.default.addObserver(self, selector: #selector(onHotkeyChanged),
                                               name: .hotkeyChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onModelUpdate),
                                               name: .modelSelectionChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onModelUpdate),
                                               name: .modelInstallStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onModelUpdate),
                                               name: .modelDownloadProgressChanged, object: nil)

        buildMenu()
        logger.info("MenuManager initialized")
    }

    // MARK: - Build Menu

    func buildMenu() {
        Task { [weak self] in
            await self?.buildMenuAsync()
        }
    }

    private func buildMenuAsync() async {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let settings = SettingsManager.shared
        let modelStatuses = await ModelStoreManager.shared.allStatuses()

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

        // ── Models submenu ──
        let modelsItem = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
        let modelsSubmenu = NSMenu()

        let activeModelItem = NSMenuItem(title: "Active Model", action: nil, keyEquivalent: "")
        let activeModelSubmenu = NSMenu()
        for model in LocalModelID.allCases {
            let status = modelStatuses[model] ?? LocalModelStatus(state: .notInstalled, progress: 0, lastError: nil)
            let title = "\(model.label) \(statusBadge(for: status))"
            let item = NSMenuItem(title: title, action: #selector(setActiveModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            item.state = (settings.localModelId == model) ? .on : .off
            activeModelSubmenu.addItem(item)
        }
        activeModelItem.submenu = activeModelSubmenu
        modelsSubmenu.addItem(activeModelItem)

        modelsSubmenu.addItem(.separator())

        let downloadsItem = NSMenuItem(title: "Downloads", action: nil, keyEquivalent: "")
        let downloadsSubmenu = NSMenu()

        for model in LocalModelID.allCases {
            let status = modelStatuses[model] ?? LocalModelStatus(state: .notInstalled, progress: 0, lastError: nil)
            let title = downloadTitle(for: model, status: status)
            let item = NSMenuItem(title: title, action: #selector(downloadModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            item.isEnabled = status.state != .downloading
            downloadsSubmenu.addItem(item)
        }

        downloadsSubmenu.addItem(.separator())

        let downloadAll = NSMenuItem(title: "Download All Models",
                                     action: #selector(downloadAllModels),
                                     keyEquivalent: "")
        downloadAll.target = self
        downloadsSubmenu.addItem(downloadAll)

        downloadsItem.submenu = downloadsSubmenu
        modelsSubmenu.addItem(downloadsItem)

        modelsItem.submenu = modelsSubmenu
        menu.addItem(modelsItem)

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
    }

    private func statusBadge(for status: LocalModelStatus) -> String {
        switch status.state {
        case .installed:
            return "(Installed)"
        case .downloading:
            let p = Int((status.progress * 100).rounded())
            return "(\(p)%)"
        case .failed:
            return "(Failed)"
        case .notInstalled:
            return "(Not installed)"
        }
    }

    private func downloadTitle(for model: LocalModelID, status: LocalModelStatus) -> String {
        switch status.state {
        case .installed:
            return "\(model.label): Installed"
        case .downloading:
            let p = Int((status.progress * 100).rounded())
            return "\(model.label): Downloading \(p)%"
        case .failed:
            return "Retry \(model.label) (Failed)"
        case .notInstalled:
            return "Download \(model.label)"
        }
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

    @objc private func setActiveModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let model = LocalModelID(rawValue: raw) else { return }

        SettingsManager.shared.localModelId = model
        NotificationCenter.default.post(name: .modelSelectionChanged, object: nil)

        Task {
            if !(await ModelStoreManager.shared.isInstalled(model)) {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Model Not Installed"
                    alert.informativeText = "\(model.label) is selected but not installed. Download now?"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Cancel")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        Task {
                            await ModelStoreManager.shared.installModel(model)
                        }
                    }
                }
            }
        }

        logger.info("Menu: Active local model set to \(model.rawValue, privacy: .public)")
        buildMenu()
    }

    @objc private func downloadModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let model = LocalModelID(rawValue: raw) else { return }

        Task {
            await ModelStoreManager.shared.installModel(model)
        }

        logger.info("Menu: Download requested for model \(model.rawValue, privacy: .public)")
        buildMenu()
    }

    @objc private func downloadAllModels() {
        Task {
            await ModelStoreManager.shared.installAllModels()
        }
        logger.info("Menu: Download all models requested")
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

    @objc private func onModelUpdate() {
        buildMenu()
    }
}
