import AppKit

/// On-demand, local diagnostics. Opening this window never runs the write test.
@MainActor
final class HealthController: NSObject {
    private let window: NSWindow
    private let reportProvider: (Bool) -> (IntegrationHealth.Report, String)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let lastEvent = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()

    init(reportProvider: @escaping (Bool) -> (IntegrationHealth.Report, String)) {
        self.reportProvider = reportProvider
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Подключение Codex"
        window.minSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.center()

        let root = HealthRootView()
        window.contentView = root
        let title = NSTextField(labelWithString: "Подключение Codex")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.maximumNumberOfLines = 0
        lastEvent.font = .systemFont(ofSize: 12)
        lastEvent.textColor = .secondaryLabelColor
        lastEvent.maximumNumberOfLines = 0

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = HealthDocumentView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        document.addSubview(rows)
        scroll.documentView = document

        let refreshButton = NSButton(title: "Обновить", target: self, action: #selector(refreshReport))
        let testButton = NSButton(title: "Проверить запись и чтение", target: self, action: #selector(runSelfTest))
        refreshButton.bezelStyle = .rounded
        testButton.bezelStyle = .rounded
        testButton.toolTip = "Проверить локальный файл событий. Живая очередь и настройки не изменяются."
        let controls = NSStackView(views: [refreshButton, testButton])
        controls.spacing = 8

        [title, summary, lastEvent, scroll, controls].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            summary.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            lastEvent.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            lastEvent.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            lastEvent.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: lastEvent.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -14),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4)
        ])
    }

    func hide() { window.orderOut(nil) }

    func show() {
        render(runSelfTest: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Captures this window's content only; no screen recording permission is used.
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

    @objc private func refreshReport() { render(runSelfTest: false) }
    @objc private func runSelfTest() { render(runSelfTest: true) }

    private func render(runSelfTest: Bool) {
        let (report, lastEventDescription) = reportProvider(runSelfTest)
        summary.stringValue = report.summary
        summary.textColor = report.hasFailures ? .systemRed : .labelColor
        lastEvent.stringValue = lastEventDescription
        lastEvent.toolTip = lastEventDescription
        for row in rows.arrangedSubviews {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for check in report.checks {
            let row = HealthCheckRow(check)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
}

private final class HealthDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class HealthRootView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class HealthCheckRow: NSView {
    init(_ check: IntegrationHealth.Check) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: check.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSTextField(labelWithString: Self.statusText(check.status))
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = Self.statusColor(check.status)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = NSStackView(views: [title, status])
        heading.distribution = .fill
        heading.spacing = 8
        let detail = NSTextField(wrappingLabelWithString: check.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        [heading, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor),
            heading.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(check.title + ". " + Self.statusText(check.status) + ". " + check.detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func statusText(_ status: IntegrationHealth.Status) -> String {
        switch status {
        case .ok: return "Проверено"
        case .warning: return "Есть замечание"
        case .failure: return "Проблема"
        case .unknown: return "Не подтверждено"
        }
    }

    private static func statusColor(_ status: IntegrationHealth.Status) -> NSColor {
        switch status {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .failure: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }
}
