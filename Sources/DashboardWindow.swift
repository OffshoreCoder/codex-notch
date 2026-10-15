import AppKit

enum DashboardStatus: String, Equatable {
    case running, attention, completed, idle, unknown, interrupted
}

/// Display metadata only: names are entered locally by the user, never read from chats.
struct DashboardEntry: Equatable {
    let id: String
    let name: String
    let stateText: String
    let elapsedText: String
    let updatedText: String
    let unreadCount: Int
    var isImportant: Bool = false
    var canRemindResult: Bool = false
    var canWatchDuration: Bool = false
    var reminderText: String = ""
    var attentionText: String = ""
    var status: DashboardStatus = .idle
}

enum DashboardAction {
    case openChat(String)
    case acknowledgeChat(String)
    case rename(String, String)
    case important(String?)
    case quiet(TimeInterval?)
    case endQuiet
    case remindCompleted(String, TimeInterval)
    case watchDuration(String, TimeInterval)
    case cancelReminders(String)
    case copyAttentionInstruction
    case configureShortcut(GlobalShortcut?)
}

private enum DashboardPalette {
    static let background = NSColor(hex: 0x11151B)
    static let card = NSColor(hex: 0x191F29)
    static let border = NSColor(hex: 0x2A3340)
    static let text = NSColor(hex: 0xE9EDF3)
    static let secondary = NSColor(hex: 0xA0ACBD)
    static let dim = NSColor(hex: 0x738095)
    static let blue = NSColor(hex: 0x7FAEFF)
    static let amber = NSColor(hex: 0xF1C27A)
    static let green = NSColor(hex: 0x81CFB0)
    static func color(for status: DashboardStatus) -> NSColor {
        switch status {
        case .running: return blue
        case .attention: return amber
        case .completed: return green
        case .interrupted: return NSColor(hex: 0xE69A97)
        case .idle, .unknown: return secondary
        }
    }
}

/// Opened only by an explicit user action; event polling never opens this panel.
@MainActor
final class DashboardController: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    private enum Filter: Int { case all, running, attention, completed }
    private let panel: DashboardPanel
    private let rows = NSStackView()
    private let search = NSSearchField()
    private let shortcutButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var shortcut: GlobalShortcut = .standard
    private var selectedID: String?
    private let chatCount = NSTextField(labelWithString: "")
    private let runningCount = NSTextField(labelWithString: "")
    private let attentionCount = NSTextField(labelWithString: "")
    private let completedCount = NSTextField(labelWithString: "")
    private let focusStatus = NSTextField(labelWithString: "Все чаты могут уведомлять")
    private let quietButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let quietStatus = NSTextField(labelWithString: "Уведомления включены")
    private let endQuietItem = NSMenuItem(title: "Выключить режим", action: nil, keyEquivalent: "")
    private let filterControl = NSSegmentedControl(labels: ["Все", "В работе", "Ждут тебя", "Готовы"],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let handler: (DashboardAction) -> Void
    private var entries: [DashboardEntry] = []
    private var renderedEntries: [DashboardEntry] = []
    private var rowViews: [DashboardRow] = []
    private var filter = Filter.all
    private var isRenaming = false
    private var trackingMenu = false
    private var toggleRegion: NSRect?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(handler: @escaping (DashboardAction) -> Void) {
        self.handler = handler
        panel = DashboardPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = "Чаты Codex"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.hide() }

        let root = DashboardSurface()
        panel.contentView = root
        let title = Self.label("Чаты Codex", size: 19, weight: .semibold, color: DashboardPalette.text)
        configureMetadata(chatCount)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Закрыть") ?? NSImage(),
                             target: self, action: #selector(closePanel))
        close.isBordered = false
        close.contentTintColor = DashboardPalette.secondary
        close.toolTip = "Закрыть · Esc"
        close.setAccessibilityLabel("Закрыть чаты Codex")
        let heading = NSStackView(views: [title, chatCount, Self.spacer(), close])
        heading.spacing = 10
        close.widthAnchor.constraint(equalToConstant: 24).isActive = true
        close.heightAnchor.constraint(equalToConstant: 24).isActive = true

        configureCounter(runningCount, color: DashboardPalette.blue)
        configureCounter(attentionCount, color: DashboardPalette.amber)
        configureCounter(completedCount, color: DashboardPalette.green)
        let counts = NSStackView(views: [runningCount, attentionCount, completedCount, Self.spacer()])
        counts.spacing = 18
        filterControl.controlSize = .small
        filterControl.segmentStyle = .rounded
        filterControl.font = .systemFont(ofSize: 11, weight: .medium)
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(changeFilter)

        search.placeholderString = "Найти чат · ↑ ↓ выбрать · Enter открыть"
        search.font = .systemFont(ofSize: 12)
        search.controlSize = .regular
        search.sendsSearchStringImmediately = true
        search.maximumRecents = 0
        search.delegate = self
        search.setAccessibilityLabel("Поиск чатов по названию")

        focusStatus.font = .systemFont(ofSize: 11)
        focusStatus.textColor = DashboardPalette.secondary
        focusStatus.lineBreakMode = .byTruncatingTail
        focusStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        quietButton.controlSize = .small
        quietButton.font = .systemFont(ofSize: 11)
        quietButton.addItem(withTitle: "Не отвлекать")
        quietButton.menu?.autoenablesItems = false
        quietButton.menu?.delegate = self
        for (title, seconds) in [("На 25 минут", 1500), ("На 30 минут", 1800),
                                 ("На 1 час", 3600), ("До выключения вручную", -1)] {
            let item = NSMenuItem(title: title, action: #selector(selectQuiet(_:)), keyEquivalent: "")
            item.tag = seconds
            item.target = self
            quietButton.menu?.addItem(item)
        }
        quietButton.menu?.addItem(.separator())
        endQuietItem.target = self
        endQuietItem.action = #selector(endQuiet)
        endQuietItem.isEnabled = false
        quietButton.menu?.addItem(endQuietItem)
        configureMetadata(quietStatus)
        quietStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let focusControls = NSStackView(views: [focusStatus, Self.spacer(), quietButton])
        focusControls.spacing = 10
        let top = NSStackView(views: [heading, counts, search, filterControl, focusControls, quietStatus])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 12
        [heading, counts, search, filterControl, focusControls, quietStatus].forEach {
            $0.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        }
        let divider = NSBox()
        divider.boxType = .separator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let document = DashboardDocumentView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        document.addSubview(rows)
        scroll.documentView = document
        let instruction = NSButton(title: "Сигналы…", target: self, action: #selector(copyAttentionInstruction))
        instruction.bezelStyle = .rounded
        instruction.controlSize = .small
        instruction.font = .systemFont(ofSize: 11)
        instruction.toolTip = "Скопировать инструкцию в нужный чат. Сигнал появляется только после явной команды; проверка разрешений сама по себе его не включает."
        let privacy = Self.label("Без чтения переписки", size: 10, color: DashboardPalette.dim, monospaced: true)
        shortcutButton.addItem(withTitle: shortcut.title)
        shortcutButton.controlSize = .small
        shortcutButton.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutButton.menu?.autoenablesItems = false
        shortcutButton.menu?.delegate = self
        for (title, tag) in [("⌃⌥Пробел · по умолчанию", 0), ("⇧⌘Пробел", 1),
                              ("Другое сочетание…", 2), ("Выключить", 3)] {
            let item = NSMenuItem(title: title, action: #selector(configureShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            shortcutButton.menu?.addItem(item)
        }
        shortcutButton.setAccessibilityLabel("Сочетание клавиш для пульта")
        let footer = NSStackView(views: [instruction, shortcutButton, Self.spacer(), privacy])
        footer.spacing = 8
        [top, divider, scroll, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            divider.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2)
        ])
        renderEntries()
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    func update(entries: [DashboardEntry]) {
        guard self.entries != entries else { return }
        self.entries = entries
        guard !isRenaming, !trackingMenu else { return }
        renderEntries()
    }

    func toggle(anchor: NSRect, screen: NSScreen) {
        if panel.isVisible { hide() } else { show(anchor: anchor, screen: screen) }
    }

    func show(anchor: NSRect, screen: NSScreen) {
        guard !isRenaming else { return }
        // Include the compact robot next to the band so mouse-down cannot hide and
        // then immediately reopen the panel when its mouse-up toggle arrives.
        toggleRegion = anchor.insetBy(dx: -40, dy: -8)
        let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(520, bounds.width)
        let top = min(anchor.minY - 8, bounds.maxY)
        let height = min(560, max(260, top - bounds.minY))
        let x = min(max(anchor.midX - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(top - height, bounds.minY), bounds.maxY - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        present()
    }

    /// Standalone fallback, also used by bitmap previews.
    func show() {
        toggleRegion = nil
        panel.center()
        present()
    }

    /// A system hotkey always opens a fresh name search instead of toggling a visible panel off.
    func showForKeyboard(anchor: NSRect?, screen: NSScreen?) {
        guard !isRenaming, !trackingMenu, NSApp.modalWindow == nil else { return }
        search.stringValue = ""
        filter = .all
        filterControl.selectedSegment = 0
        selectedID = nil
        renderEntries()
        if let anchor, let screen { show(anchor: anchor, screen: screen) } else { show() }
        panel.makeFirstResponder(search)
    }

    func updateShortcut(_ value: GlobalShortcut, enabled: Bool, error: String?) {
        shortcut = value
        shortcutButton.item(at: 0)?.title = enabled && error == nil ? value.title : "Клавиши…"
        shortcutButton.toolTip = error ?? (enabled ? "Открыть пульт: \(value.title). ↑ ↓ выбрать чат, Enter открыть." : "Настроить горячую клавишу")
        for item in shortcutButton.menu?.items ?? [] {
            item.state = ((item.tag == 0 && enabled && value == .standard) ||
                          (item.tag == 1 && enabled && value == .alternate) ||
                          (item.tag == 3 && !enabled)) ? .on : .off
        }
    }

    func hide() {
        guard !isRenaming else { return }
        panel.orderOut(nil)
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor); self.localMouseMonitor = nil }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
    }

    func updateQuiet(status: String, active: Bool) {
        quietStatus.stringValue = status
        quietStatus.toolTip = status
        quietButton.item(at: 0)?.title = active ? "Тишина включена" : "Не отвлекать"
        quietStatus.textColor = active ? DashboardPalette.amber : DashboardPalette.dim
        endQuietItem.isEnabled = active
    }

    /// Render only this panel's own content, without reading screen pixels.
    func capturePreview(to url: URL) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    func layoutReport() -> [String: Any] {
        ["x": Double(panel.frame.minX), "y": Double(panel.frame.minY),
         "width": Double(panel.frame.width), "height": Double(panel.frame.height),
         "visible": panel.isVisible]
    }

    func menuWillOpen(_ menu: NSMenu) { trackingMenu = true }
    func menuDidClose(_ menu: NSMenu) { finishMenuTracking() }

    private func finishMenuTracking() {
        trackingMenu = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.trackingMenu, !self.isRenaming else { return }
            self.renderEntries()
        }
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
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
        guard panel.isVisible, !isRenaming, !trackingMenu, NSApp.modalWindow == nil else { return }
        // Status-bar controls dispatch their own explicit toggle on mouse-up.
        if eventWindow?.level == .statusBar { return }
        let pointer = NSEvent.mouseLocation
        guard !panel.frame.contains(pointer), toggleRegion?.contains(pointer) != true else { return }
        hide()
    }

    @objc private func closePanel() { hide() }
    @objc private func changeFilter() {
        filter = Filter(rawValue: filterControl.selectedSegment) ?? .all
        renderEntries()
    }
    @objc private func selectQuiet(_ sender: NSMenuItem) {
        handler(.quiet(sender.tag < 0 ? nil : TimeInterval(sender.tag)))
    }
    @objc private func endQuiet() { handler(.endQuiet) }
    @objc private func copyAttentionInstruction() { handler(.copyAttentionInstruction) }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as AnyObject? === search else { return }
        selectedID = nil
        renderEntries()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let selectedID { handler(.openChat(selectedID)) }
            return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !renderedEntries.isEmpty else { return }
        let old = renderedEntries.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(old + delta, 0), renderedEntries.count - 1)
        selectedID = renderedEntries[next].id
        updateSelection()
        rowViews[next].scrollToVisible(rowViews[next].bounds)
    }

    private func updateSelection() {
        for (row, entry) in zip(rowViews, renderedEntries) { row.setSelected(entry.id == selectedID) }
    }

    @objc private func configureShortcut(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: handler(.configureShortcut(.standard))
        case 1: handler(.configureShortcut(.alternate))
        case 3: handler(.configureShortcut(nil))
        default:
            let alert = NSAlert()
            alert.window.appearance = NSAppearance(named: .darkAqua)
            alert.messageText = "Сочетание для открытия пульта"
            alert.informativeText = "Нажми сочетание с ⌃, ⌥ или ⌘. Оно работает через системную регистрацию macOS и не требует Accessibility."
            alert.addButton(withTitle: "Сохранить")
            alert.addButton(withTitle: "Отмена")
            let recorder = ShortcutRecorder(frame: NSRect(x: 0, y: 0, width: 340, height: 48))
            recorder.shortcut = shortcut
            alert.accessoryView = recorder
            alert.window.initialFirstResponder = recorder
            isRenaming = true
            alert.beginSheetModal(for: panel) { [weak self] response in
                guard let self else { return }
                self.isRenaming = false
                if response == .alertFirstButtonReturn, let value = recorder.shortcut {
                    self.handler(.configureShortcut(value))
                }
                self.renderEntries()
                self.panel.makeFirstResponder(self.search)
            }
        }
    }

    private func renderEntries() {
        chatCount.stringValue = "\(entries.count) \(Self.chatWord(entries.count))"
        runningCount.stringValue = "В работе  \(entries.filter { $0.status == .running }.count)"
        attentionCount.stringValue = "Ждут тебя  \(entries.filter { $0.status == .attention }.count)"
        completedCount.stringValue = "Готовы  \(entries.reduce(0) { $0 + max(0, $1.unreadCount) })"
        if let important = entries.first(where: \.isImportant) {
            focusStatus.stringValue = "Уведомляет только «\(important.name)»"
        } else { focusStatus.stringValue = "Все чаты могут уведомлять" }
        focusStatus.toolTip = focusStatus.stringValue
        let terms = search.stringValue.split(whereSeparator: \.isWhitespace).map(String.init)
        let visible = entries.filter { entry in
            guard terms.allSatisfy({ entry.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil }) else { return false }
            switch filter {
            case .all: return true
            case .running: return entry.status == .running
            case .attention: return entry.status == .attention
            case .completed: return entry.unreadCount > 0
            }
        }
        if !visible.isEmpty, renderedEntries.map(\.id) == visible.map(\.id), rowViews.count == visible.count {
            for (row, entry) in zip(rowViews, visible) { row.update(entry) }
        } else {
            rows.arrangedSubviews.forEach {
                rows.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            rowViews.removeAll()
            if visible.isEmpty {
                let text = !terms.isEmpty ? "Ничего не найдено\nПопробуй другое название или очисти поиск." : entries.isEmpty
                    ? "Пока нет чатов\nЗапусти задачу в Codex с подключёнными hooks. Состояния появятся здесь автоматически."
                    : "Здесь пока пусто\nВ этом фильтре нет чатов. Остальные доступны во вкладке «Все»."
                let empty = NSTextField(wrappingLabelWithString: text)
                empty.font = .systemFont(ofSize: 12)
                empty.textColor = DashboardPalette.secondary
                empty.maximumNumberOfLines = 5
                empty.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                rows.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            } else {
                for entry in visible {
                    let row = DashboardRow(entry: entry, handler: { [weak self] action in
                        guard let self else { return }
                        switch action {
                        case .rename(let id, _): self.rename(id: id)
                        default: self.handler(action)
                        }
                    }, menuTracking: { [weak self] active in
                        if active { self?.trackingMenu = true } else { self?.finishMenuTracking() }
                    })
                    rows.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                    rowViews.append(row)
                }
            }
        }
        renderedEntries = visible
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
        updateSelection()
    }

    private func rename(id: String) {
        guard !isRenaming, let entry = entries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.messageText = "Название чата на этом Mac"
        alert.informativeText = "Локальная подпись заменит имя только в пульте. Оставь поле пустым, чтобы использовать имя из Codex."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let input = NSTextField(string: entry.name)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        input.placeholderString = "Например, исправление сборки"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        isRenaming = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            self.isRenaming = false
            if response == .alertFirstButtonReturn {
                let name = String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                self.handler(.rename(id, name))
            }
            self.renderEntries()
        }
    }

    private func configureMetadata(_ field: NSTextField) {
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.textColor = DashboardPalette.dim
        field.lineBreakMode = .byTruncatingTail
    }
    private func configureCounter(_ field: NSTextField, color: NSColor) {
        field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        field.textColor = color
    }
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                              color: NSColor, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
    private static func chatWord(_ count: Int) -> String {
        if count % 100 >= 11 && count % 100 <= 14 { return "чатов" }
        switch count % 10 { case 1: return "чат"; case 2...4: return "чата"; default: return "чатов" }
    }
}

@MainActor
private final class DashboardPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class DashboardSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        DashboardPalette.background.setFill()
        path.fill()
        DashboardPalette.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class DashboardDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class DashboardRow: NSView, NSMenuDelegate {
    private let name = NSTextField(labelWithString: "")
    private let unread = NSTextField(labelWithString: "")
    private let star = NSTextField(labelWithString: "★")
    private let identity = NSTextField(labelWithString: "")
    private let state = DashboardStateChip()
    private let elapsed = NSTextField(labelWithString: "")
    private let updated = NSTextField(labelWithString: "")
    private let reminderLabel = NSTextField(labelWithString: "")
    private let acknowledge = NSButton(title: "Просмотрено", target: nil, action: nil)
    private let reminder = NSPopUpButton(frame: .zero, pullsDown: true)
    private let importantItem = NSMenuItem(title: "Уведомлять об этом чате", action: nil, keyEquivalent: "")
    private var entry: DashboardEntry
    private let handler: (DashboardAction) -> Void
    private let menuTracking: (Bool) -> Void

    init(entry: DashboardEntry, handler: @escaping (DashboardAction) -> Void, menuTracking: @escaping (Bool) -> Void) {
        self.entry = entry
        self.handler = handler
        self.menuTracking = menuTracking
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = DashboardPalette.card.cgColor
        layer?.borderColor = DashboardPalette.border.cgColor
        layer?.borderWidth = 0.5
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = DashboardPalette.text
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unread.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        unread.textColor = DashboardPalette.green
        star.font = .systemFont(ofSize: 12)
        star.textColor = DashboardPalette.amber
        star.toolTip = "Выбран для уведомлений"
        [identity, elapsed, updated, reminderLabel].forEach {
            $0.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            $0.textColor = DashboardPalette.secondary
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        identity.textColor = DashboardPalette.dim
        updated.textColor = DashboardPalette.dim
        reminderLabel.textColor = DashboardPalette.amber
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.addItem(withTitle: "•••")
        more.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        more.isBordered = false
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        more.contentTintColor = DashboardPalette.secondary
        more.toolTip = "Название и важный чат"
        more.setAccessibilityLabel("Действия с чатом")
        more.menu?.autoenablesItems = false
        more.menu?.delegate = self
        let rename = NSMenuItem(title: "Переименовать на этом Mac…", action: #selector(renameChat), keyEquivalent: "")
        rename.target = self
        more.menu?.addItem(rename)
        more.menu?.addItem(.separator())
        importantItem.target = self
        importantItem.action = #selector(toggleImportant)
        more.menu?.addItem(importantItem)
        let open = DashboardOpenButton(title: "Открыть", target: self, action: #selector(openChat))
        open.font = .systemFont(ofSize: 11, weight: .semibold)
        acknowledge.target = self
        acknowledge.action = #selector(acknowledgeChat)
        acknowledge.bezelStyle = .rounded
        acknowledge.controlSize = .small
        acknowledge.font = .systemFont(ofSize: 11, weight: .medium)
        reminder.controlSize = .small
        reminder.font = .systemFont(ofSize: 11)
        reminder.addItem(withTitle: "Напомнить")
        reminder.menu?.autoenablesItems = false
        reminder.menu?.delegate = self
        for minutes in [5, 10, 30] {
            let item = NSMenuItem(title: "Вернуться через \(minutes) мин", action: #selector(remindCompleted(_:)), keyEquivalent: "")
            item.tag = minutes * 60
            item.target = self
            reminder.menu?.addItem(item)
        }
        reminder.menu?.addItem(.separator())
        for minutes in [10, 20, 30] {
            let item = NSMenuItem(title: "Если ход длится дольше \(minutes) мин", action: #selector(watchDuration(_:)), keyEquivalent: "")
            item.tag = minutes * 60
            item.target = self
            reminder.menu?.addItem(item)
        }
        reminder.menu?.addItem(.separator())
        let cancel = NSMenuItem(title: "Отменить напоминания", action: #selector(cancelReminders), keyEquivalent: "")
        cancel.target = self
        reminder.menu?.addItem(cancel)
        let heading = NSStackView(views: [name, star, unread, more])
        heading.spacing = 8
        heading.distribution = .fill
        more.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let status = NSStackView(views: [state, elapsed])
        status.spacing = 10
        let actions = NSStackView(views: [open, acknowledge, reminder])
        actions.spacing = 8
        let content = NSStackView(views: [heading, identity, status, updated, reminderLabel, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            identity.widthAnchor.constraint(equalTo: content.widthAnchor),
            updated.widthAnchor.constraint(equalTo: content.widthAnchor),
            reminderLabel.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        update(entry)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ entry: DashboardEntry) {
        self.entry = entry
        name.stringValue = entry.name
        name.toolTip = entry.name
        star.isHidden = !entry.isImportant
        unread.stringValue = entry.unreadCount > 0 ? "новых: \(entry.unreadCount)" : ""
        unread.isHidden = entry.unreadCount == 0
        identity.stringValue = "ID " + String(entry.id.prefix(8))
        identity.toolTip = entry.id
        state.update(text: entry.stateText, status: entry.status)
        elapsed.stringValue = entry.elapsedText
        updated.stringValue = entry.updatedText
        let pending = entry.unreadCount > 0 || !entry.attentionText.isEmpty
        acknowledge.isHidden = !pending
        acknowledge.isEnabled = pending
        importantItem.state = entry.isImportant ? .on : .off
        reminderLabel.stringValue = entry.reminderText
        reminderLabel.toolTip = entry.reminderText
        reminderLabel.isHidden = entry.reminderText.isEmpty
        for item in reminder.menu?.items ?? [] {
            switch item.action {
            case #selector(remindCompleted(_:)): item.isEnabled = entry.canRemindResult
            case #selector(watchDuration(_:)): item.isEnabled = entry.canWatchDuration
            case #selector(cancelReminders): item.isEnabled = !entry.reminderText.isEmpty
            default: break
            }
        }
    }
    func setSelected(_ selected: Bool) {
        layer?.borderColor = (selected ? DashboardPalette.blue : DashboardPalette.border).cgColor
        layer?.borderWidth = selected ? 1.5 : 0.5
        setAccessibilitySelected(selected)
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking(true) }
    func menuDidClose(_ menu: NSMenu) { menuTracking(false) }
    @objc private func openChat() { handler(.openChat(entry.id)) }
    @objc private func acknowledgeChat() { handler(.acknowledgeChat(entry.id)) }
    @objc private func renameChat() { handler(.rename(entry.id, entry.name)) }
    @objc private func toggleImportant() { handler(.important(entry.isImportant ? nil : entry.id)) }
    @objc private func remindCompleted(_ sender: NSMenuItem) { handler(.remindCompleted(entry.id, TimeInterval(sender.tag))) }
    @objc private func watchDuration(_ sender: NSMenuItem) { handler(.watchDuration(entry.id, TimeInterval(sender.tag))) }
    @objc private func cancelReminders() { handler(.cancelReminders(entry.id)) }
}

/// Native button tracking/action/keyboard behavior with an explicit per-button appearance.
/// Drawing is independent of the panel becoming inactive after opening Codex.
@MainActor
private final class DashboardOpenButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryPushIn)
        state = .off
        isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var allowsVibrancy: Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 11, weight: .semibold)]
        return NSSize(width: ceil((title as NSString).size(withAttributes: attributes).width) + 24, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        let fill = !isEnabled ? NSColor(hex: 0x354050)
            : pressed ? NSColor(srgbRed: 32.0 / 255, green: 83.0 / 255, blue: 159.0 / 255, alpha: 1)
                : NSColor(srgbRed: 40.0 / 255, green: 100.0 / 255, blue: 190.0 / 255, alpha: 1)
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: isEnabled ? NSColor.white : DashboardPalette.secondary
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        (title as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        defer { state = .off; highlight(false) }
        super.mouseDown(with: event)
    }

    override func performClick(_ sender: Any?) {
        defer { state = .off; highlight(false) }
        super.performClick(sender)
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 0.5, dy: 0.5) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill()
    }
}

private final class DashboardStateChip: NSView {
    private let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(text: String, status: DashboardStatus) {
        label.stringValue = text
        let color = DashboardPalette.color(for: status)
        label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.11).cgColor
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// Receives keys only while this app's explicit shortcut sheet owns first responder.
@MainActor
private final class ShortcutRecorder: NSView {
    var shortcut: GlobalShortcut? { didSet { needsDisplay = true } }
    private var hint = "Нажми новое сочетание"
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { super.keyDown(with: event); return }
        if let value = GlobalShortcut.captured(from: event) {
            shortcut = value
            hint = "Сохранить новое сочетание"
        } else { hint = "Добавь ⌃, ⌥ или ⌘ к клавише" }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = "\(shortcut?.title ?? "…")\n\(hint)"
        (text as NSString).draw(in: bounds.insetBy(dx: 4, dy: 4), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: DashboardPalette.text, .paragraphStyle: paragraph])
    }
}
