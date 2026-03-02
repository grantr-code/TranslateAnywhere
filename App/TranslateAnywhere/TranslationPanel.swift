/*
 * TranslationPanel.swift
 * Spotlight-style floating panel that shows translation results.
 *
 * The panel never steals focus from the frontmost app (nonactivatingPanel).
 * It uses NSVisualEffectView with hudWindow material for the translucent look,
 * and provides key bindings for Esc, Cmd+C, Enter, Cmd+Z, Tab, and the
 * configured hotkey.
 */

import AppKit
import Carbon.HIToolbox
import os.log

// MARK: - Notifications for panel actions

extension Notification.Name {
    static let replaceSelection = Notification.Name("TranslateAnywhere.replaceSelection")
    static let undoReplace      = Notification.Name("TranslateAnywhere.undoReplace")
    static let flipDirection    = Notification.Name("TranslateAnywhere.flipDirection")
}

// MARK: - TranslationPanel

@MainActor
final class TranslationPanel: NSPanel {

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "Panel")

    // MARK: - UI Elements

    private let visualEffectView = NSVisualEffectView()
    private let directionBadge = BadgePillView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let translationField = NSTextField(wrappingLabelWithString: "")
    private let hintBar = NSTextField(labelWithString: "Esc \u{00B7} \u{2318}C \u{00B7} Enter \u{00B7} \u{2318}Z")

    // MARK: - State

    private var currentTranslation: String = ""
    private var hasReplaced = false

    // MARK: - Initialization

    init() {
        let panelRect = NSRect(x: 0, y: 0, width: 600, height: 200)
        super.init(contentRect: panelRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .borderless],
                   backing: .buffered,
                   defer: false)
        configurePanel()
        setupLayout()
        logger.info("TranslationPanel initialized")
    }

    // MARK: - Panel Configuration

    private func configurePanel() {
        self.level = .floating
        self.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.animationBehavior = .utilityWindow
        self.hidesOnDeactivate = false

        // Do NOT activate the app - the panel must not steal focus
        self.styleMask.insert(.nonactivatingPanel)
    }

    // MARK: - Layout

    private func setupLayout() {
        // Visual effect background
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: self.contentRect(forFrameRect: self.frame))
        container.wantsLayer = true
        self.contentView = container

        container.addSubview(visualEffectView)

        // Direction badge
        directionBadge.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(directionBadge)

        // Status label
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(statusLabel)

        // Translation field - large, selectable, non-editable
        translationField.font = NSFont.systemFont(ofSize: 20, weight: .regular)
        translationField.textColor = .labelColor
        translationField.backgroundColor = .clear
        translationField.isBezeled = false
        translationField.isEditable = false
        translationField.isSelectable = true
        translationField.usesSingleLineMode = false
        translationField.maximumNumberOfLines = 5
        translationField.lineBreakMode = .byWordWrapping
        translationField.cell?.wraps = true
        translationField.cell?.isScrollable = false
        translationField.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(translationField)

        // Hint bar
        hintBar.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hintBar.textColor = .tertiaryLabelColor
        hintBar.alignment = .center
        hintBar.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hintBar)

        // Constraints
        NSLayoutConstraint.activate([
            // Visual effect fills the content view
            visualEffectView.topAnchor.constraint(equalTo: container.topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            // Top row: badge + status
            directionBadge.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 16),
            directionBadge.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 20),

            statusLabel.centerYAnchor.constraint(equalTo: directionBadge.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -20),

            // Translation field - center
            translationField.topAnchor.constraint(equalTo: directionBadge.bottomAnchor, constant: 16),
            translationField.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 20),
            translationField.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -20),

            // Hint bar - bottom
            hintBar.topAnchor.constraint(greaterThanOrEqualTo: translationField.bottomAnchor, constant: 12),
            hintBar.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -12),
            hintBar.centerXAnchor.constraint(equalTo: visualEffectView.centerXAnchor),
        ])
    }

    // MARK: - Key Handling

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Esc -> dismiss
        if keyCode == 53 {
            logger.info("Panel: Esc pressed -> dismiss")
            dismiss()
            return
        }

        // Cmd+C -> copy
        if flags.contains(.command) && keyCode == 8 { // C key
            logger.info("Panel: Cmd+C pressed -> copy to clipboard")
            copyTranslation()
            return
        }

        // Cmd+Z -> undo
        if flags.contains(.command) && keyCode == 6 { // Z key
            logger.info("Panel: Cmd+Z pressed -> undo")
            NotificationCenter.default.post(name: .undoReplace, object: nil)
            dismiss()
            return
        }

        // Enter -> replace selection
        if keyCode == 36 {
            logger.info("Panel: Enter pressed -> replace")
            primaryAction()
            return
        }

        // Tab -> flip direction
        if keyCode == 48 {
            logger.info("Panel: Tab pressed -> flip direction")
            NotificationCenter.default.post(name: .flipDirection, object: nil)
            return
        }

        // Check if the pressed key matches the configured hotkey
        let settings = SettingsManager.shared
        let hotkeyKeyCode = settings.hotkeyKeyCode
        let hotkeyMods = settings.hotkeyModifiers
        if hotkeyKeyCode != 0 && keyCode == hotkeyKeyCode {
            let carbonMods = nsModifiersToCarbonModifiers(flags)
            if carbonMods == hotkeyMods {
                logger.info("Panel: configured hotkey pressed -> primary action")
                primaryAction()
                return
            }
        }

        super.keyDown(with: event)
    }

    // MARK: - Public API

    /// Shows the panel with translation results. Positions it centered on the screen
    /// containing the mouse cursor (multi-monitor aware).
    func show(original: String, translation: String,
              direction: TranslateDirection, detectedDirection: TranslateDirection) {
        currentTranslation = translation
        hasReplaced = false

        // Update UI
        let displayDir = (direction == .autoDetect) ? detectedDirection : direction
        directionBadge.update(direction: displayDir)
        statusLabel.stringValue = "Ready"
        translationField.stringValue = translation

        // Update hint bar based on state
        hintBar.stringValue = "Esc \u{00B7} \u{2318}C \u{00B7} Enter \u{00B7} \u{2318}Z"

        // Position on screen containing mouse
        positionOnMouseScreen()

        // Animate in
        self.alphaValue = 0
        self.makeKeyAndOrderFront(nil)

        // Do NOT activate the app
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }

        // Also apply a subtle scale animation via layer
        if let layer = self.contentView?.layer {
            let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation.fromValue = 0.95
            scaleAnimation.toValue = 1.0
            scaleAnimation.duration = 0.15
            scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(scaleAnimation, forKey: "scaleIn")
        }

        logger.info("Panel shown with translation (\(translation.count) chars)")

        // Auto-copy if enabled
        if SettingsManager.shared.autoCopyToClipboard {
            copyTranslation()
        }
    }

    /// Dismisses the panel with a fade-out animation.
    func dismiss() {
        logger.info("Panel dismissing")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// Updates the status label (e.g. "Loading...", "Ready", "Error").
    func updateStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    // MARK: - Private

    private func primaryAction() {
        if !hasReplaced {
            NotificationCenter.default.post(name: .replaceSelection, object: nil,
                                            userInfo: ["text": currentTranslation])
            hasReplaced = true
            hintBar.stringValue = "Esc \u{00B7} \u{2318}C \u{00B7} \u{2318}Z to undo"
        } else {
            // Already replaced -> undo
            NotificationCenter.default.post(name: .undoReplace, object: nil)
            dismiss()
        }
    }

    private func copyTranslation() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(currentTranslation, forType: .string)
        logger.info("Translation copied to clipboard")

        // Brief flash on the status label
        let prev = statusLabel.stringValue
        statusLabel.stringValue = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.statusLabel.stringValue = prev
        }
    }

    private func positionOnMouseScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let screenFrame = screen.visibleFrame
        let panelSize = self.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY - panelSize.height / 2 + screenFrame.height * 0.15 // slightly above center
        self.setFrameOrigin(NSPoint(x: x, y: y))
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
}

// MARK: - BadgePillView

/// A colored pill-shaped badge showing the translation direction.
@MainActor
final class BadgePillView: NSView {

    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        update(direction: .autoDetect)
    }

    func update(direction: TranslateDirection) {
        label.stringValue = direction.badge

        switch direction {
        case .enToRu:
            layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .ruToEn:
            layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .autoDetect:
            layer?.backgroundColor = NSColor.systemGray.cgColor
        }
    }
}
