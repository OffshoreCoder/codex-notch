import AppKit

/// An on-demand window, never another persistent dashboard or background poll.
@MainActor
final class StatisticsController: NSObject {
    enum Action {
        case openChat(String)
        case assignTicket(String, String?)
        case reset
    }
    private let window: NSWindow
    private let provider: (TaskStatistics.Period) -> TaskStatistics.Snapshot
    private let action: (Action) -> Void
    private let period = NSSegmentedControl(labels: TaskStatistics.Period.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let summary = NSStackView()
    private let groups = NSStackView()
    private let scroll = NSScrollView()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let editor = NSStackView()
    private let editorName = NSTextField(labelWithString: "")
    private let ticketField = NSTextField()
    private let resetButton = NSButton(title: "Сбросить время…", target: nil, action: nil)
    private var collapsedEditor: NSLayoutConstraint!
    private var editingSession: String?
    private var resetArmed = false
    private var snapshot: TaskStatistics.Snapshot?
    private var renderSignature: String?
    var isVisible: Bool { window.isVisible }

    init(provider: @escaping (TaskStatistics.Period) -> TaskStatistics.Snapshot, action: @escaping (Action) -> Void) {
        self.provider = provider
        self.action = action
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Статистика Codex"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.09, alpha: 1)
        window.minSize = NSSize(width: 650, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        let root = StatisticsBackground()
        window.contentView = root

        let title = NSTextField(labelWithString: "Статистика задач")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Локально · без содержимого чатов")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical; titleStack.alignment = .leading; titleStack.spacing = 4
        let heading = NSStackView(views: [titleStack, NSView(), period])
        heading.orientation = .horizontal; heading.spacing = 12; heading.alignment = .centerY
        period.selectedSegment = 0
        period.target = self; period.action = #selector(changePeriod)
        period.setContentHuggingPriority(.required, for: .horizontal)

        summary.orientation = .horizontal; summary.distribution = .fillEqually; summary.spacing = 10
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 0
        explanation.setContentCompressionResistancePriority(.required, for: .vertical)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = StatisticsDocument()
        groups.orientation = .vertical; groups.alignment = .leading; groups.spacing = 12
        document.addSubview(groups)
        scroll.documentView = document

        configureEditor()
        collapsedEditor = editor.heightAnchor.constraint(equalToConstant: 0)
        closeEditor()
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        let refresh = NSButton(title: "Обновить", target: self, action: #selector(refreshPressed))
        refresh.bezelStyle = .rounded
        resetButton.bezelStyle = .rounded
        resetButton.target = self; resetButton.action = #selector(resetPressed)
        resetButton.toolTip = "Удалить только накопленные интервалы и привязки тикетов. Данные Codex и очередь результатов сохранятся."
        let bottom = NSStackView(views: [status, NSView(), resetButton, refresh])
        bottom.spacing = 8; bottom.alignment = .centerY
        [heading, summary, explanation, scroll, editor, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        document.translatesAutoresizingMaskIntoConstraints = false
        groups.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            summary.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            summary.leadingAnchor.constraint(equalTo: heading.leadingAnchor), summary.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            summary.heightAnchor.constraint(equalToConstant: 86),
            explanation.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10),
            explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor), explanation.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: editor.topAnchor, constant: -10),
            editor.leadingAnchor.constraint(equalTo: heading.leadingAnchor), editor.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            bottom.leadingAnchor.constraint(equalTo: heading.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            groups.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4), groups.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            groups.topAnchor.constraint(equalTo: document.topAnchor, constant: 2), groups.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
    }

    func show() {
        resetConfirmation(); closeEditor()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func hide() { window.orderOut(nil) }
    func refreshIfVisible() {
        guard window.isVisible else { return }
        if editingSession != nil || resetArmed {
            // Sharing must mask an editor immediately even while ordinary live
            // refreshes preserve the in-progress input or reset confirmation.
            let updated = provider(TaskStatistics.Period(rawValue: period.selectedSegment) ?? .today)
            if updated.masked != snapshot?.masked { resetConfirmation(); closeEditor(); refresh() }
        } else { refresh() }
    }
    func refresh() {
        let selected = TaskStatistics.Period(rawValue: period.selectedSegment) ?? .today
        let value = provider(selected)
        snapshot = value
        let signature = Self.signature(value)
        guard signature != renderSignature else { return }
        renderSignature = signature
        let scrollOrigin = scroll.contentView.bounds.origin
        clear(summary); clear(groups)
        summary.addArrangedSubview(StatisticsMetric(title: "ВРЕМЯ ХОДОВ", value: TaskStatistics.durationText(value.summedDuration), detail: "Параллельные ходы суммируются"))
        summary.addArrangedSubview(StatisticsMetric(title: "БЕЗ ПЕРЕСЕЧЕНИЙ", value: TaskStatistics.durationText(value.elapsedDuration), detail: "Интервалы работы по часам"))
        summary.addArrangedSubview(StatisticsMetric(title: "ТОКЕНЫ ЧАТОВ", value: TaskStatistics.tokenText(value.tokens), detail: "Счётчик за всё время · \(value.tokenCoverage)/\(value.chatCount)"))
        explanation.stringValue = "Время за выбранный период: от запроса до завершения, включая ожидание; сон и перерывы наблюдения не учитываются. Токены — текущий счётчик Codex за всё время показанных чатов, без разбивки по дням и стоимости."
        explanation.toolTip = value.tokenDetail
        if value.groups.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Новые ходы появятся здесь после первого запроса в Codex. Прошлое время по переписке не восстанавливаем.")
            empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 13)
            empty.maximumNumberOfLines = 0
            groups.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: groups.widthAnchor).isActive = true
        }
        for group in value.groups {
            let card = StatisticsGroup(group: group, masked: value.masked, open: { [weak self] in self?.action(.openChat($0)) }, edit: { [weak self] in self?.edit($0) })
            groups.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: groups.widthAnchor).isActive = true
        }
        let formatter = DateFormatter(); formatter.dateFormat = "d MMM, HH:mm"
        status.stringValue = value.error ?? (value.collectionEnabled
            ? "Наблюдаем с \(formatter.string(from: value.observedSince)) · завершено ходов: \(value.completed)/\(value.turns)"
            : "Сбор выключен в настройках · сохранённые интервалы доступны")
        status.toolTip = value.error ?? "Храним до 8192 ходов и 512 чатов. Только ID, интервалы, исходы и привязки тикетов; названия и токены не сохраняются."
        status.textColor = value.error == nil ? .secondaryLabelColor : .systemOrange
        if value.masked { closeEditor(); resetConfirmation(); resetButton.isHidden = true } else { resetButton.isHidden = false }
        window.contentView?.layoutSubtreeIfNeeded()
        let maximumY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOrigin.y, maximumY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Captures only this window, with no screen-recording access.
    func capturePreview(to url: URL) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url, options: .atomic) }
    }

    private func configureEditor() {
        editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 7
        editorName.font = .systemFont(ofSize: 11, weight: .medium)
        editorName.lineBreakMode = .byTruncatingTail
        ticketField.placeholderString = "Например, JP-1234"
        ticketField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        ticketField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let save = NSButton(title: "Привязать", target: self, action: #selector(saveTicket))
        let none = NSButton(title: "Без тикета", target: self, action: #selector(clearTicket))
        let auto = NSButton(title: "Авто из имени", target: self, action: #selector(automaticTicket))
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelEdit))
        [save, none, auto, cancel].forEach { $0.bezelStyle = .rounded }
        let row = NSStackView(views: [ticketField, save, none, auto, cancel]); row.spacing = 7
        editor.addArrangedSubview(editorName); editor.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
    }
    private func edit(_ row: TaskStatistics.ChatRow) {
        guard snapshot?.masked == false else { return }
        editingSession = row.sessionID
        editorName.stringValue = "Тикет для чата: " + row.name
        ticketField.stringValue = row.ticket ?? ""
        collapsedEditor.isActive = false
        editor.arrangedSubviews.forEach { $0.isHidden = false }
        editor.isHidden = false
        window.makeFirstResponder(ticketField)
    }
    private func closeEditor() {
        editingSession = nil
        editor.arrangedSubviews.forEach { $0.isHidden = true }
        editor.isHidden = true
        collapsedEditor?.isActive = true
        ticketField.stringValue = ""
    }
    private func assign(_ value: String?) {
        guard let id = editingSession else { return }
        action(.assignTicket(id, value)); closeEditor(); refresh()
    }
    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    private static func signature(_ value: TaskStatistics.Snapshot) -> String {
        var parts = [String(value.period.rawValue), TaskStatistics.durationText(value.summedDuration), TaskStatistics.durationText(value.elapsedDuration),
                     TaskStatistics.tokenText(value.tokens), String(value.tokenCoverage), String(value.chatCount), String(value.completed), String(value.turns),
                     String(value.collectionEnabled), String(value.masked), value.error ?? "", value.tokenDetail, String(value.observedSince.timeIntervalSince1970)]
        for group in value.groups {
            parts += [group.title, TaskStatistics.durationText(group.duration), TaskStatistics.tokenText(group.tokens)]
            for chat in group.chats {
                parts += [chat.sessionID, chat.name, chat.ticket ?? "", chat.automaticTicket ?? "", String(chat.hasManualAssignment),
                          TaskStatistics.durationText(chat.duration), String(chat.turns), TaskStatistics.tokenText(chat.tokens)]
            }
        }
        return parts.joined(separator: "\u{001F}")
    }
    @objc private func changePeriod() { resetConfirmation(); closeEditor(); refresh() }
    @objc private func refreshPressed() { resetConfirmation(); refresh() }
    @objc private func saveTicket() {
        guard let value = TaskStatistics.normalizedTicket(ticketField.stringValue) else {
            editorName.stringValue = "Нужен один тикет в формате JP-1234. Для отмены группировки — «Без тикета»."
            return
        }
        assign(value)
    }
    @objc private func clearTicket() { assign("") }
    @objc private func automaticTicket() { assign(nil) }
    @objc private func cancelEdit() { closeEditor() }
    @objc private func resetPressed() {
        if resetArmed {
            action(.reset); resetConfirmation(); closeEditor(); refresh()
            status.stringValue = "Локальные интервалы и привязки удалены. Данные Codex сохранены."
        } else {
            resetArmed = true; resetButton.title = "Подтвердить сброс"
            status.stringValue = "Удалить накопленное время и привязки? Нажми ещё раз для подтверждения."
        }
    }
    private func resetConfirmation() { resetArmed = false; resetButton.title = "Сбросить время…" }
}

private final class StatisticsBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.09, alpha: 1).setFill(); dirtyRect.fill() }
}
private final class StatisticsDocument: NSView { override var isFlipped: Bool { true } }

private final class StatisticsMetric: NSView {
    init(title: String, value: String, detail: String) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(calibratedRed: 0.095, green: 0.113, blue: 0.146, alpha: 1).cgColor
        let caption = NSTextField(labelWithString: title)
        caption.font = .monospacedSystemFont(ofSize: 9, weight: .medium); caption.textColor = .secondaryLabelColor
        let number = NSTextField(labelWithString: value)
        number.font = .monospacedSystemFont(ofSize: 21, weight: .semibold); number.textColor = NSColor(calibratedRed: 0.68, green: 0.81, blue: 1, alpha: 1)
        let note = NSTextField(labelWithString: detail)
        note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor; note.lineBreakMode = .byTruncatingTail
        [caption, number, note].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), caption.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            number.leadingAnchor.constraint(equalTo: caption.leadingAnchor), number.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4),
            number.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            note.leadingAnchor.constraint(equalTo: caption.leadingAnchor), note.topAnchor.constraint(equalTo: number.bottomAnchor, constant: 4), note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class StatisticsGroup: NSView {
    private var callbacks: [StatisticsChatRow] = []
    init(group: TaskStatistics.GroupRow, masked: Bool, open: @escaping (String) -> Void, edit: @escaping (TaskStatistics.ChatRow) -> Void) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(calibratedRed: 0.085, green: 0.099, blue: 0.128, alpha: 1).cgColor
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        let title = NSTextField(labelWithString: group.title)
        title.font = .monospacedSystemFont(ofSize: 12, weight: .semibold); title.textColor = .systemTeal
        let coverage = group.tokenCoverage < group.chats.count ? " · \(group.tokenCoverage)/\(group.chats.count) чатов" : ""
        let total = NSTextField(labelWithString: TaskStatistics.durationText(group.duration) + "  ·  " + TaskStatistics.tokenText(group.tokens) + " ток." + coverage)
        total.font = .monospacedSystemFont(ofSize: 11, weight: .medium); total.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, NSView(), total]); heading.spacing = 8
        stack.addArrangedSubview(heading)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for chat in group.chats {
            let row = StatisticsChatRow(chat: chat, masked: masked, open: open, edit: edit)
            callbacks.append(row); stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class StatisticsChatRow: NSView {
    private let chat: TaskStatistics.ChatRow
    private let open: (String) -> Void
    private let edit: (TaskStatistics.ChatRow) -> Void
    init(chat: TaskStatistics.ChatRow, masked: Bool, open: @escaping (String) -> Void, edit: @escaping (TaskStatistics.ChatRow) -> Void) {
        self.chat = chat; self.open = open; self.edit = edit
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: chat.name)
        name.font = .systemFont(ofSize: 12, weight: .medium); name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: chat.turns == 0 ? "Время ещё не наблюдалось" : "\(TaskStatistics.durationText(chat.duration)) · ходов: \(chat.turns)")
        detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        let tokens = NSTextField(labelWithString: TaskStatistics.tokenText(chat.tokens) + " ток.")
        tokens.font = .monospacedSystemFont(ofSize: 11, weight: .regular); tokens.textColor = .secondaryLabelColor
        tokens.toolTip = "Текущий счётчик Codex за всё время чата."
        tokens.setContentCompressionResistancePriority(.required, for: .horizontal)
        let editButton = NSButton(title: "Тикет…", target: self, action: #selector(editPressed))
        editButton.bezelStyle = .rounded; editButton.controlSize = .small; editButton.isHidden = masked
        let openButton = StatisticsOpenButton(frame: .zero)
        openButton.title = "Открыть"; openButton.target = self; openButton.action = #selector(openPressed)
        let row = NSStackView(views: [text, NSView(), tokens, editButton, openButton]); row.alignment = .centerY; row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openPressed() { open(chat.sessionID) }
    @objc private func editPressed() { edit(chat) }
}

@MainActor
private final class StatisticsOpenButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryPushIn); state = .off; isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold); focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var allowsVibrancy: Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 11, weight: .semibold)]).width) + 24, height: 26)
    }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        let fill = !isEnabled ? NSColor(calibratedWhite: 0.25, alpha: 1)
            : pressed ? NSColor(srgbRed: 32.0 / 255, green: 83.0 / 255, blue: 159.0 / 255, alpha: 1)
                : NSColor(srgbRed: 40.0 / 255, green: 100.0 / 255, blue: 190.0 / 255, alpha: 1)
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 11, weight: .semibold), .foregroundColor: isEnabled ? NSColor.white : NSColor.secondaryLabelColor]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), withAttributes: attributes)
    }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { defer { state = .off; highlight(false) }; super.mouseDown(with: event) }
    override func performClick(_ sender: Any?) { defer { state = .off; highlight(false) }; super.performClick(sender) }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 0.5, dy: 0.5) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill() }
}
