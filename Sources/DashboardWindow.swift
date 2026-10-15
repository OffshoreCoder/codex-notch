import AppKit

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
}

/// Explicitly opened, keyboard-accessible window. The notch itself remains passive.
@MainActor
final class DashboardController: NSObject {
    private let window: NSWindow
    private let rows = NSStackView()
    private let summary = NSTextField(labelWithString: "")
    private let quietButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let quietStatus = NSTextField(labelWithString: "Уведомления включены")
    private let endQuietItem = NSMenuItem(title: "Выключить режим", action: nil, keyEquivalent: "")
    private let handler: (DashboardAction) -> Void
    private var entries: [DashboardEntry] = []
    private var renderedEntries: [DashboardEntry] = []
    private var rowViews: [DashboardRow] = []
    private var isRenaming = false

    init(handler: @escaping (DashboardAction) -> Void) {
        self.handler = handler
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Чаты Codex"
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.center()

        let root = NSView()
        window.contentView = root
        let title = NSTextField(labelWithString: "Чаты Codex")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byWordWrapping
        summary.maximumNumberOfLines = 3

        quietButton.controlSize = .small
        quietButton.font = .systemFont(ofSize: 12)
        quietButton.addItem(withTitle: "Не отвлекать")
        let quietOptions: [(String, Int)] = [
            ("На 25 минут", 25 * 60), ("На 30 минут", 30 * 60),
            ("На 1 час", 60 * 60), ("До выключения вручную", -1)
        ]
        quietButton.menu?.autoenablesItems = false
        for (title, seconds) in quietOptions {
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
        quietStatus.font = .systemFont(ofSize: 11)
        quietStatus.textColor = .secondaryLabelColor
        quietStatus.lineBreakMode = .byTruncatingTail
        quietStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let quietControls = NSStackView(views: [quietButton, quietStatus])
        quietControls.spacing = 10

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = DashboardDocumentView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        document.addSubview(rows)
        scroll.documentView = document
        [title, summary, quietControls, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            quietControls.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            quietControls.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            quietControls.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: quietControls.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
        renderEntries()
    }

    func update(entries: [DashboardEntry]) {
        guard self.entries != entries else { return }
        self.entries = entries
        // A sheet can stay open while events arrive. Preserve the edit and render afterward.
        guard !isRenaming else { return }
        renderEntries()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func updateQuiet(status: String, active: Bool) {
        quietStatus.stringValue = status
        quietStatus.toolTip = status
        quietButton.item(at: 0)?.title = active ? "Не отвлекать: вкл." : "Не отвлекать"
        endQuietItem.isEnabled = active
    }

    /// Render only this window's own content. Never reads pixels from the screen.
    func capturePreview(to url: URL) {
        guard let view = window.contentView else { return }
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

    @objc private func selectQuiet(_ sender: NSMenuItem) {
        handler(.quiet(sender.tag < 0 ? nil : TimeInterval(sender.tag)))
    }

    @objc private func endQuiet() { handler(.endQuiet) }

    private func renderEntries() {
        let unread = entries.reduce(0) { $0 + max(0, $1.unreadCount) }
        let notificationText = entries.contains(where: \.isImportant)
            ? "Автоуведомления только от выбранного чата; остальные результаты остаются в очереди."
            : "Автоуведомления от всех чатов. Можно выбрать один важный."
        summary.stringValue = entries.isEmpty
            ? "Здесь появятся чаты после событий Codex. Названия можно задать вручную."
            : "Чатов: \(entries.count) · непросмотренных результатов: \(unread). \(notificationText)"
        if renderedEntries.map(\.id) == entries.map(\.id), rowViews.count == entries.count, !entries.isEmpty {
            for (row, entry) in zip(rowViews, entries) { row.update(entry) }
        } else {
            rows.arrangedSubviews.forEach {
                rows.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            rowViews.removeAll()
            if entries.isEmpty {
                let empty = NSTextField(wrappingLabelWithString:
                    "Запусти задачу в Codex с подключёнными hooks. Здесь будут состояние, время и непросмотренные результаты каждого чата — без содержимого переписки.")
                empty.font = .systemFont(ofSize: 13)
                empty.textColor = .secondaryLabelColor
                rows.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            } else {
                for entry in entries {
                    let row = DashboardRow(entry: entry) { [weak self] action in
                        guard let self else { return }
                        switch action {
                        case .rename(let id, _): self.rename(id: id)
                        default: self.handler(action)
                        }
                    }
                    rows.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                    rowViews.append(row)
                }
            }
        }
        renderedEntries = entries
    }

    private func rename(id: String) {
        guard !isRenaming, let entry = entries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Название чата на этом Mac"
        alert.informativeText = "Это локальная подпись. Название в Codex не изменится."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let input = NSTextField(string: entry.name)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        input.placeholderString = "Например, исправление сборки"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        isRenaming = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isRenaming = false
            if response == .alertFirstButtonReturn {
                let name = String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                self.handler(.rename(id, name))
            }
            self.renderEntries()
        }
    }
}

private final class DashboardDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class DashboardRow: NSView {
    private let name = NSTextField(labelWithString: "")
    private let unread = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let updated = NSTextField(labelWithString: "")
    private let importantLabel = NSTextField(labelWithString: "")
    private let important = NSButton(checkboxWithTitle: "Уведомлять об этом", target: nil, action: nil)
    private let reminder = NSPopUpButton(frame: .zero, pullsDown: true)
    private let reminderLabel = NSTextField(labelWithString: "")
    private let acknowledge = NSButton(title: "Просмотрено", target: nil, action: nil)
    private var entry: DashboardEntry
    private let handler: (DashboardAction) -> Void

    init(entry: DashboardEntry, handler: @escaping (DashboardAction) -> Void) {
        self.entry = entry
        self.handler = handler
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5

        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        unread.font = .systemFont(ofSize: 11, weight: .semibold)
        unread.textColor = .controlAccentColor
        unread.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.font = .systemFont(ofSize: 12, weight: .medium)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsed.textColor = .secondaryLabelColor
        updated.font = .systemFont(ofSize: 11)
        updated.textColor = .secondaryLabelColor
        updated.lineBreakMode = .byTruncatingTail
        importantLabel.font = .systemFont(ofSize: 11, weight: .medium)
        importantLabel.textColor = .controlAccentColor
        important.font = .systemFont(ofSize: 11)
        important.target = self
        important.action = #selector(toggleImportant)
        reminderLabel.font = .systemFont(ofSize: 11)
        reminderLabel.textColor = .secondaryLabelColor
        reminderLabel.lineBreakMode = .byTruncatingTail
        reminder.controlSize = .small
        reminder.font = .systemFont(ofSize: 11)
        reminder.addItem(withTitle: "Напомнить")
        reminder.menu?.autoenablesItems = false
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
        let cancelReminder = NSMenuItem(title: "Отменить напоминания", action: #selector(cancelReminders), keyEquivalent: "")
        cancelReminder.target = self
        reminder.menu?.addItem(cancelReminder)

        let open = NSButton(title: "Открыть чат", target: self, action: #selector(openChat))
        let rename = NSButton(title: "Название…", target: self, action: #selector(renameChat))
        acknowledge.target = self
        acknowledge.action = #selector(acknowledgeChat)
        [open, rename, acknowledge].forEach {
            $0.bezelStyle = .rounded
            $0.controlSize = .small
            $0.font = .systemFont(ofSize: 11)
        }
        let heading = NSStackView(views: [name, unread])
        heading.distribution = .fill
        heading.spacing = 8
        let status = NSStackView(views: [state, elapsed])
        status.spacing = 10
        let actions = NSStackView(views: [open, rename, acknowledge, reminder])
        actions.spacing = 8
        let notification = NSStackView(views: [important, importantLabel])
        notification.spacing = 10
        let content = NSStackView(views: [heading, status, updated, notification, reminderLabel, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
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
        unread.stringValue = entry.unreadCount > 0 ? "Новых: \(entry.unreadCount)" : ""
        state.stringValue = entry.stateText
        elapsed.stringValue = entry.elapsedText
        updated.stringValue = entry.updatedText
        acknowledge.isEnabled = entry.unreadCount > 0
        important.state = entry.isImportant ? .on : .off
        importantLabel.stringValue = entry.isImportant ? "Выбран для уведомлений" : ""
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

    @objc private func openChat() { handler(.openChat(entry.id)) }
    @objc private func acknowledgeChat() { handler(.acknowledgeChat(entry.id)) }
    @objc private func renameChat() { handler(.rename(entry.id, entry.name)) }
    @objc private func toggleImportant() { handler(.important(entry.isImportant ? nil : entry.id)) }
    @objc private func remindCompleted(_ sender: NSMenuItem) { handler(.remindCompleted(entry.id, TimeInterval(sender.tag))) }
    @objc private func watchDuration(_ sender: NSMenuItem) { handler(.watchDuration(entry.id, TimeInterval(sender.tag))) }
    @objc private func cancelReminders() { handler(.cancelReminders(entry.id)) }
}
