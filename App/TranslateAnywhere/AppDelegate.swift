/*
 * AppDelegate.swift
 * Main entry point for TranslateAnywhere — a macOS menu-bar translation app.
 *
 * LSUIElement behavior (no dock icon) is configured via Info.plist.
 * The app runs entirely from a status bar item with an SF Symbol icon.
 *
 * Hotkey flow: capture selected text -> translate -> replace or show popup.
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
    private var popupManager: TranslationPopupManager!

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
        popupManager = TranslationPopupManager()
        menuManager = MenuManager(statusItem: statusItem, hotkeyManager: hotkeyManager)

        // Register hotkey from settings
        hotkeyManager.registerFromSettings()

        // Initialize translation engine (non-blocking)
        Task {
            let success = translatorService.initialize()
            if success {
                logger.info("Translation engine ready")
                await translatorService.warmupLocalModels()
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
        popupManager.dismiss()
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
            let pipelineStart = DispatchTime.now().uptimeNanoseconds

            // 1. Capture selected text
            guard let captureResult = await selectionCapture.captureSelectedText(), !captureResult.text.isEmpty else {
                logger.warning("No text captured")
                NSSound.beep()
                return
            }
            let captureMs = Double(DispatchTime.now().uptimeNanoseconds - pipelineStart) / 1_000_000.0

            logger.info("Captured \(captureResult.text.count) characters")

            // 2. Truncate if needed
            let settings = SettingsManager.shared
            var inputText = captureResult.text
            if inputText.count > settings.maxInputChars {
                logger.warning("Input truncated from \(inputText.count) to \(settings.maxInputChars) chars")
                inputText = String(inputText.prefix(settings.maxInputChars))
            }

            // 3. Translate
            let translateStart = DispatchTime.now().uptimeNanoseconds
            let result = await translatorService.translate(
                text: inputText, direction: settings.direction)
            let translateMs = Double(DispatchTime.now().uptimeNanoseconds - translateStart) / 1_000_000.0

            guard result.status == .ok else {
                logger.error("Translation failed: status=\(result.status.rawValue)")
                NSSound.beep()
                return
            }

            logger.info("Translation complete: direction=\(result.detectedDirection.label)")

            // 4. Emit output based on context.
            let outputStart = DispatchTime.now().uptimeNanoseconds
            switch captureResult.outputMode {
            case .replaceSelection:
                let success = await selectionCapture.replaceSelection(with: result.text)
                if success {
                    logger.info("Selection replaced successfully")
                } else {
                    logger.error("Failed to replace selection")
                    NSSound.beep()
                }
            case .showPopup:
                popupManager.show(text: result.text)
                logger.info("Displayed translation popup")
            }
            let outputMs = Double(DispatchTime.now().uptimeNanoseconds - outputStart) / 1_000_000.0
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - pipelineStart) / 1_000_000.0

            logger.info("Pipeline timings ms: capture=\(captureMs, format: .fixed(precision: 1)), translate=\(translateMs, format: .fixed(precision: 1)), output=\(outputMs, format: .fixed(precision: 1)), total=\(totalMs, format: .fixed(precision: 1))")
        }
    }

    // MARK: - Hotkey Changed

    @objc private func onHotkeyChanged() {
        logger.info("Hotkey changed notification received")
    }
}

@MainActor
final class TranslationPopupManager {
    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "TranslationPopup")

    private var panel: NSPanel?
    private var textLabel: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    func show(text: String) {
        if panel == nil {
            buildPanel()
        }
        guard let panel, let textLabel else { return }

        textLabel.stringValue = text

        let size = popupSize(for: text)
        let frame = popupFrame(size: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        scheduleAutoHide()
    }

    func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let panelRect = NSRect(x: 0, y: 0, width: 280, height: 80)
        let popupPanel = NSPanel(contentRect: panelRect,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        popupPanel.level = .statusBar
        popupPanel.isFloatingPanel = true
        popupPanel.hidesOnDeactivate = false
        popupPanel.hasShadow = true
        popupPanel.isOpaque = false
        popupPanel.backgroundColor = .clear
        popupPanel.ignoresMouseEvents = true
        popupPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let content = NSView(frame: panelRect)
        let bubble = NSVisualEffectView(frame: content.bounds)
        bubble.autoresizingMask = [.width, .height]
        bubble.material = .popover
        bubble.blendingMode = .withinWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        bubble.layer?.masksToBounds = true

        let label = NSTextField(wrappingLabelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 8
        label.lineBreakMode = .byWordWrapping

        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
        ])

        content.addSubview(bubble)
        popupPanel.contentView = content

        panel = popupPanel
        textLabel = label
        logger.debug("Translation popup panel created")
    }

    private func popupSize(for text: String) -> NSSize {
        let maxTextWidth: CGFloat = 320
        let minWidth: CGFloat = 180
        let maxWidth: CGFloat = 360
        let minHeight: CGFloat = 52
        let maxHeight: CGFloat = 220
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)

        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )

        let width = min(maxWidth, max(minWidth, ceil(bounds.width) + 24))
        let height = min(maxHeight, max(minHeight, ceil(bounds.height) + 20))
        return NSSize(width: width, height: height)
    }

    private func popupFrame(size: NSSize) -> NSRect {
        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8

        var x = cursor.x + 12
        var y = cursor.y - size.height - 14

        if x + size.width > visible.maxX - margin {
            x = visible.maxX - size.width - margin
        }
        if x < visible.minX + margin {
            x = visible.minX + margin
        }

        if y < visible.minY + margin {
            y = min(visible.maxY - size.height - margin, cursor.y + 14)
        }
        if y + size.height > visible.maxY - margin {
            y = visible.maxY - size.height - margin
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        hideWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppConstants.popupAutoHideSeconds,
            execute: workItem
        )
    }
}
