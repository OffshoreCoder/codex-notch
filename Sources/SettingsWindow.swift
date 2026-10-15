import AppKit

/// Only local presentation preferences and status strings cross this UI boundary.
struct SettingsPreferences: Equatable {
    var skin: CharacterSkin = .robot
    var screenSharing = false
    var keepAwakeEnabled = false
    var statisticsEnabled = true
    var shortcut: GlobalShortcut = .standard
    var shortcutEnabled = true
    var shortcutError: String? = nil
    var energyStatus = "Анимация подстраивается под активность"
    var powerStatus = "Выключено"
    var powerActive = false
    var powerFailed = false
    var powerDetail: String? = nil
    var version = "0.2.1"
}

enum SettingsAction {
    case selectSkin(CharacterSkin)
    case toggleSharing
    case toggleKeepAwake
    case toggleStatistics
    case configureShortcut(GlobalShortcut?)
    case openStatistics
    case openHealth
    case quit
}

private enum SettingsPalette {
    static let background = NSColor(settingsHex: 0x11151B)
    static let card = NSColor(settingsHex: 0x191F29)
    static let border = NSColor(settingsHex: 0x2A3340)
    static let text = NSColor(settingsHex: 0xE9EDF3)
    static let secondary = NSColor(settingsHex: 0xA0ACBD)
    static let dim = NSColor(settingsHex: 0x738095)
    static let blue = NSColor(settingsHex: 0x7FAEFF)
    static let green = NSColor(settingsHex: 0x81CFB0)
    static let amber = NSColor(settingsHex: 0xF1C27A)
}

/// Persistent controls live here so the dashboard can remain a short work queue.
/// All feedback and shortcut capture are nonmodal; this window never runs NSAlert.
@MainActor
final class SettingsController: NSObject, NSMenuDelegate {
    private let panel: SettingsPanel
    private let handler: (SettingsAction) -> Void
    private var preferences = SettingsPreferences()
    private var displayedPreferences: SettingsPreferences?
    private let skinButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let characterPreview = SettingsCharacterPreview()
    private let sharing = NSButton(checkboxWithTitle: "Скрывать названия при демонстрации", target: nil, action: nil)
    private let keepAwake = NSButton(checkboxWithTitle: "Не усыплять Mac, пока Codex работает", target: nil, action: nil)
    private let statistics = NSButton(checkboxWithTitle: "Собирать время и токены локально", target: nil, action: nil)
    private let shortcutButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private let powerStatus = NSTextField(wrappingLabelWithString: "")
    private let energyStatus = NSTextField(wrappingLabelWithString: "")
    private let version = NSTextField(labelWithString: "")
    private let recorder = SettingsShortcutRecorder(frame: .zero)
    private let recorderControls = NSStackView()
    private let feedback = NSTextField(labelWithString: "")
    private var feedbackTimer: Timer?
    private var trackingMenu = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var toggleRegion: NSRect?

    var isVisible: Bool { panel.isVisible }

    init(handler: @escaping (SettingsAction) -> Void) {
        self.handler = handler
        panel = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "Настройки Codex Notch"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.cancelOrHide() }
        let root = SettingsSurface()
        panel.contentView = root

        let title = Self.label("Настройки", size: 19, weight: .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Закрыть настройки") ?? NSImage(), target: self, action: #selector(closePanel))
        close.isBordered = false
        close.contentTintColor = SettingsPalette.secondary
        close.toolTip = "Закрыть настройки · Esc"
        close.widthAnchor.constraint(equalToConstant: 24).isActive = true
        close.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let heading = NSStackView(views: [title, Self.spacer(), close])
        let subtitle = Self.label("Твой помощник. Всё остаётся на этом Mac.", size: 11, color: SettingsPalette.secondary)
        let header = Self.stack([heading, subtitle], spacing: 5)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let document = SettingsDocument()
        scroll.documentView = document
        let sections = Self.stack([], spacing: 12)
        document.addSubview(sections)

        skinButton.font = .systemFont(ofSize: 12, weight: .medium)
        skinButton.controlSize = .regular
        skinButton.target = self
        skinButton.action = #selector(selectSkin)
        skinButton.menu?.delegate = self
        for skin in CharacterSkin.allCases {
            skinButton.addItem(withTitle: skin.title)
            skinButton.lastItem?.representedObject = skin.rawValue
            skinButton.lastItem?.toolTip = skin.detail
        }
        skinButton.setAccessibilityLabel("Персонаж")
        characterPreview.widthAnchor.constraint(equalToConstant: 52).isActive = true
        characterPreview.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let skinDescription = Self.label("Живёт рядом с вырезом и в строке меню", size: 10, color: SettingsPalette.secondary)
        let skinText = Self.stack([skinButton, skinDescription], spacing: 5)
        let skinRow = NSStackView(views: [characterPreview, skinText, Self.spacer()])
        skinRow.spacing = 12
        sections.addArrangedSubview(Self.card(title: "ПЕРСОНАЖ", views: [skinRow]))

        Self.configure(sharing, target: self, action: #selector(toggleSharing))
        Self.configure(keepAwake, target: self, action: #selector(toggleKeepAwake))
        let sleepHint = Self.hint("Экран может гаснуть. Закрытие крышки всё ещё может усыпить Mac.")
        powerStatus.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        powerStatus.textColor = SettingsPalette.dim
        powerStatus.maximumNumberOfLines = 2
        powerStatus.isHidden = true

        shortcutButton.controlSize = .small
        shortcutButton.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcutButton.menu?.delegate = self
        for (title, tag) in [("⌃⌥Пробел", 0), ("⇧⌘Пробел", 1), ("Другое…", 2), ("Выключено", 3)] {
            shortcutButton.addItem(withTitle: title)
            shortcutButton.lastItem?.tag = tag
        }
        shortcutButton.target = self
        shortcutButton.action = #selector(selectShortcut)
        shortcutButton.setAccessibilityLabel("Сочетание для открытия пульта")
        let shortcutRow = NSStackView(views: [Self.label("Открыть пульт", size: 12), Self.spacer(), shortcutButton])
        shortcutRow.spacing = 10
        shortcutStatus.font = .systemFont(ofSize: 10)
        shortcutStatus.textColor = SettingsPalette.amber
        shortcutStatus.maximumNumberOfLines = 2
        shortcutStatus.isHidden = true
        recorder.onChange = { [weak self] in self?.shortcutStatus.isHidden = true }
        recorder.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let saveShortcut = NSButton(title: "Сохранить", target: self, action: #selector(saveCustomShortcut))
        saveShortcut.bezelStyle = .rounded
        saveShortcut.controlSize = .small
        saveShortcut.contentTintColor = SettingsPalette.blue
        let cancelShortcut = NSButton(title: "Отмена", target: self, action: #selector(cancelCustomShortcut))
        cancelShortcut.bezelStyle = .rounded
        cancelShortcut.controlSize = .small
        let recorderButtons = NSStackView(views: [Self.spacer(), cancelShortcut, saveShortcut])
        recorderControls.orientation = .vertical
        recorderControls.alignment = .leading
        recorderControls.spacing = 5
        recorderControls.addArrangedSubview(recorder)
        recorderControls.addArrangedSubview(recorderButtons)
        recorder.widthAnchor.constraint(equalTo: recorderControls.widthAnchor).isActive = true
        recorderButtons.widthAnchor.constraint(equalTo: recorderControls.widthAnchor).isActive = true
        recorderControls.isHidden = true
        sections.addArrangedSubview(Self.card(title: "РАБОТА", views: [shortcutRow, shortcutStatus, recorderControls, sharing, keepAwake, sleepHint, powerStatus]))

        Self.configure(statistics, target: self, action: #selector(toggleStatistics))
        let statsHint = Self.hint("Время ходов и счётчики токенов по тикетам. Без сохранения текста сообщений.")
        let openStatistics = NSButton(title: "Открыть статистику  →", target: self, action: #selector(showStatistics))
        openStatistics.bezelStyle = .rounded
        openStatistics.controlSize = .small
        openStatistics.font = .systemFont(ofSize: 11, weight: .medium)
        openStatistics.contentTintColor = SettingsPalette.blue
        sections.addArrangedSubview(Self.card(title: "СТАТИСТИКА", views: [statistics, statsHint, openStatistics]))

        energyStatus.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        energyStatus.textColor = SettingsPalette.secondary
        energyStatus.maximumNumberOfLines = 2
        let energyIcon = NSImageView(image: NSImage(systemSymbolName: "leaf", accessibilityDescription: "Энергия") ?? NSImage())
        energyIcon.contentTintColor = SettingsPalette.green
        energyIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let energy = NSStackView(views: [energyIcon, energyStatus])
        energy.spacing = 7
        sections.addArrangedSubview(energy)
        sections.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true }

        version.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        version.textColor = SettingsPalette.dim
        let health = NSButton(title: "Диагностика", target: self, action: #selector(showHealth))
        health.isBordered = false
        health.font = .systemFont(ofSize: 11)
        health.contentTintColor = SettingsPalette.secondary
        let quit = NSButton(title: "Выйти", target: self, action: #selector(quitApplication))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11, weight: .medium)
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quit.imagePosition = .imageLeading
        quit.contentTintColor = NSColor(settingsHex: 0xE6A49E)
        quit.toolTip = "Полностью завершить Codex Notch. Чаты Codex продолжат работать."
        quit.setAccessibilityLabel("Выйти из Codex Notch")
        let footer = NSStackView(views: [version, Self.spacer(), health, quit])
        footer.spacing = 10
        feedback.font = .systemFont(ofSize: 10)
        feedback.textColor = SettingsPalette.green
        feedback.lineBreakMode = .byTruncatingTail
        feedback.isHidden = true
        let bottom = Self.stack([feedback, footer], spacing: 6)

        [header, scroll, bottom].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        sections.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -14),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -15),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            sections.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            sections.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            sections.topAnchor.constraint(equalTo: document.topAnchor),
            sections.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2)
        ])
        update(preferences)
    }

    deinit {
        feedbackTimer?.invalidate()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    func update(_ value: SettingsPreferences) {
        preferences = value
        guard !trackingMenu, displayedPreferences != value else { return }
        displayedPreferences = value
        for (index, item) in (skinButton.menu?.items ?? []).enumerated() where item.representedObject as? String == value.skin.rawValue {
            skinButton.selectItem(at: index)
        }
        characterPreview.skin = value.skin
        sharing.state = value.screenSharing ? .on : .off
        keepAwake.state = value.keepAwakeEnabled ? .on : .off
        statistics.state = value.statisticsEnabled ? .on : .off
        powerStatus.stringValue = value.powerStatus
        powerStatus.textColor = value.powerFailed ? SettingsPalette.amber : value.powerActive ? SettingsPalette.green : SettingsPalette.dim
        powerStatus.toolTip = value.powerDetail ?? value.powerStatus
        powerStatus.isHidden = !value.keepAwakeEnabled && !value.powerFailed
        energyStatus.stringValue = value.energyStatus
        version.stringValue = "Codex Notch · \(value.version)"
        shortcutStatus.stringValue = value.shortcutError ?? ""
        shortcutStatus.isHidden = value.shortcutError == nil
        if !recorderControls.isHidden { return }
        updateShortcutSelection()
    }

    private func updateShortcutSelection() {
        let value = preferences
        if !value.shortcutEnabled { shortcutButton.selectItem(withTag: 3) }
        else if value.shortcut == .standard { shortcutButton.selectItem(withTag: 0) }
        else if value.shortcut == .alternate { shortcutButton.selectItem(withTag: 1) }
        else {
            shortcutButton.selectItem(withTag: 2)
            shortcutButton.menu?.item(withTag: 2)?.title = value.shortcut.title
        }
    }

    func show(anchor: NSRect, screen: NSScreen) {
        toggleRegion = anchor.insetBy(dx: -40, dy: -8)
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(480, bounds.width)
        let top = min(anchor.minY - 8, bounds.maxY)
        let height = min(600, max(300, top - bounds.minY))
        let x = min(max(anchor.midX - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(top - height, bounds.minY), bounds.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        present()
    }

    func show() {
        toggleRegion = nil
        panel.center()
        present()
    }

    func hide() {
        panel.orderOut(nil)
        recorderControls.isHidden = true
        panel.makeFirstResponder(nil)
        updateShortcutSelection()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
    }

    func showFeedback(_ text: String) {
        feedbackTimer?.invalidate()
        feedback.stringValue = text
        feedback.isHidden = false
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.feedback.isHidden = true
                self?.feedbackTimer = nil
            }
        }
    }

    /// Captures only our native content for safe, synthetic previews.
    func capturePreview(to url: URL) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url, options: .atomic) }
    }

    func menuWillOpen(_ menu: NSMenu) { trackingMenu = true }
    func menuDidClose(_ menu: NSMenu) {
        trackingMenu = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.update(self.preferences)
        }
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
    }

    private func installDismissMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside(eventWindow: event.window) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissIfOutside(eventWindow: nil) }
        }
    }

    private func dismissIfOutside(eventWindow: NSWindow?) {
        guard panel.isVisible, !trackingMenu, NSApp.modalWindow == nil, eventWindow?.level != .statusBar else { return }
        let pointer = NSEvent.mouseLocation
        guard !panel.frame.contains(pointer), toggleRegion?.contains(pointer) != true else { return }
        hide()
    }

    private func cancelOrHide() {
        if !recorderControls.isHidden { cancelCustomShortcut() } else { hide() }
    }
    @objc private func closePanel() { hide() }
    @objc private func toggleSharing() { handler(.toggleSharing) }
    @objc private func toggleKeepAwake() { handler(.toggleKeepAwake) }
    @objc private func toggleStatistics() { handler(.toggleStatistics) }
    @objc private func showStatistics() { handler(.openStatistics) }
    @objc private func showHealth() { handler(.openHealth) }
    @objc private func quitApplication() { handler(.quit) }
    @objc private func selectSkin() {
        guard let raw = skinButton.selectedItem?.representedObject as? String,
              let skin = CharacterSkin(rawValue: raw) else { return }
        handler(.selectSkin(skin))
    }
    @objc private func selectShortcut() {
        switch shortcutButton.selectedItem?.tag {
        case 0: handler(.configureShortcut(.standard))
        case 1: handler(.configureShortcut(.alternate))
        case 3: handler(.configureShortcut(nil))
        default:
            recorder.shortcut = preferences.shortcut
            recorderControls.isHidden = false
            panel.makeFirstResponder(recorder)
        }
    }
    @objc private func saveCustomShortcut() {
        guard let value = recorder.shortcut else { return }
        recorderControls.isHidden = true
        panel.makeFirstResponder(shortcutButton)
        handler(.configureShortcut(value))
        updateShortcutSelection()
    }
    @objc private func cancelCustomShortcut() {
        recorderControls.isHidden = true
        panel.makeFirstResponder(shortcutButton)
        updateShortcutSelection()
    }

    private static func configure(_ button: NSButton, target: AnyObject, action: Selector) {
        button.target = target
        button.action = action
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = SettingsPalette.text
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = SettingsPalette.text) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = .systemFont(ofSize: size, weight: weight)
        result.textColor = color
        return result
    }
    private static func hint(_ text: String) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        result.font = .systemFont(ofSize: 10)
        result.textColor = SettingsPalette.secondary
        result.maximumNumberOfLines = 3
        result.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return result
    }
    private static func spacer() -> NSView {
        let result = NSView()
        result.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return result
    }
    private static func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }
        return result
    }
    private static func card(title: String, views: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 11
        box.layer?.backgroundColor = SettingsPalette.card.cgColor
        box.layer?.borderColor = SettingsPalette.border.cgColor
        box.layer?.borderWidth = 1
        let heading = label(title, size: 9, weight: .semibold, color: SettingsPalette.dim)
        heading.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        let body = stack([heading] + views, spacing: 8)
        body.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            body.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -13),
            body.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12)
        ])
        return box
    }
}

@MainActor
private final class SettingsPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        SettingsPalette.background.setFill(); shape.fill()
        SettingsPalette.border.setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

@MainActor
private final class SettingsCharacterPreview: NSView {
    var skin: CharacterSkin = .robot { didSet { if skin != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 5, yBy: 5)
        transform.scale(by: 0.72)
        transform.concat()
        CharacterRenderer.draw(skin: skin, state: .idle, animationTime: 0,
            reducedMotion: true, accent: SettingsPalette.green, showAura: false)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Receives keys only while the user has explicitly focused this native view.
/// No event tap, global key monitoring, or Accessibility permission is involved.
@MainActor
private final class SettingsShortcutRecorder: NSView {
    var shortcut: GlobalShortcut? { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?
    private var hint = "Нажми сочетание с ⌃, ⌥ или ⌘"
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.cancelOperation(nil); return }
        if let value = GlobalShortcut.captured(from: event) {
            shortcut = value
            hint = "Нажми «Сохранить», чтобы применить"
            onChange?()
        } else { hint = "Добавь ⌃, ⌥ или ⌘ к клавише" }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        SettingsPalette.background.setFill(); shape.fill()
        SettingsPalette.blue.withAlphaComponent(0.6).setStroke(); shape.lineWidth = 1; shape.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = "\(shortcut?.title ?? "…")\n\(hint)"
        (text as NSString).draw(in: bounds.insetBy(dx: 4, dy: 5), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: SettingsPalette.text, .paragraphStyle: paragraph])
    }
}

private extension NSColor {
    convenience init(settingsHex: UInt32) {
        self.init(calibratedRed: CGFloat((settingsHex >> 16) & 255) / 255,
                  green: CGFloat((settingsHex >> 8) & 255) / 255,
                  blue: CGFloat(settingsHex & 255) / 255, alpha: 1)
    }
}
