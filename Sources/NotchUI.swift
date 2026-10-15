import AppKit
import CoreGraphics

/// A passive, local-only companion. No key window, event taps, or captured screens.
@MainActor
final class NotchController: NSObject, NSMenuDelegate {
    var demoHandler: ((CompanionState) -> Void)?
    var healthHandler: (() -> Void)?
    var dashboardHandler: (() -> Void)?
    var liveHandler: (() -> Void)?
    var acknowledgeHandler: ((String?) -> Void)?
    private var completions: [CompletedTurn] = []
    private var queueError: String?
    private var quiet = false
    private var noticeSessionID: String?

    private let panel: CompanionPanel
    private let companionView: CompanionView
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let screenMenu = NSMenu()
    private var snapshot = CompanionSnapshot(state: .idle, sessionID: nil, activeCount: 0, updatedAt: Date())
    private var selectedDisplay: CGDirectDisplayID?
    private var isVisible = true
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var animationStarted = Date()
    private var lastFrame = Date.distantPast
    private var expandedUntil = Date.distantPast
    private var attentionUntil = Date.distantPast
    private var hoverUntil = Date.distantPast
    private var hoverStarted: Date?
    private var suppressHoverUntilExit = false
    private var isExpanded = false

    override init() {
        let size = NSSize(width: 32, height: 32)
        companionView = CompanionView(frame: NSRect(origin: .zero, size: size))
        panel = CompanionPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = companionView
        panel.acceptsMouseMovedEvents = false
        panel.animationBehavior = .none
        companionView.snapshot = snapshot
        companionView.onClick = { [weak self] in
            guard let self else { return }
            self.dashboardHandler?()
        }
        companionView.contextMenu = menu
        companionView.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        statusItem.button?.image = Self.menuBarImage()
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityHelp("Нажмите, чтобы открыть чаты. Правый клик открывает настройки.")
        statusItem.menu = nil
        updateStatusItemDescription()
        menu.delegate = self
        rebuildMenu()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionPanel() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.companionView.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.companionView.needsDisplay = true
            }
        }
        // This reads only the pointer position to pass through transparent corners.
        // It is not an event monitor and does not require Accessibility access.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        positionPanel()
    }

    deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    func update(_ snapshot: CompanionSnapshot) {
        if self.snapshot.state != snapshot.state {
            animationStarted = Date()
            statusItem.button?.image = Self.menuBarImage(state: snapshot.state)
            statusItem.button?.image?.isTemplate = true
            statusItem.button?.contentTintColor = snapshot.state == .idle ? nil : snapshot.state.companionAccent
        }
        self.snapshot = snapshot
        companionView.snapshot = snapshot
        refreshExpansion()
        companionView.needsDisplay = true
        updateStatusItemDescription()
    }

    func updateQueue(_ completions: [CompletedTurn], error: String?, pendingCount: Int? = nil) {
        self.completions = completions
        queueError = error
        let count = pendingCount ?? completions.count
        companionView.unreadCount = count
        statusItem.button?.title = count == 0 ? "" : " \(min(count, 99))"
        statusItem.length = count == 0 ? NSStatusItem.squareLength : NSStatusItem.variableLength
        companionView.needsDisplay = true
    }

    func setQuiet(_ active: Bool) {
        quiet = active
        if active { attentionUntil = .distantPast; companionView.notice = nil; noticeSessionID = nil }
        refreshExpansion()
    }

    func notify(title: String, sessionID: String? = nil, duration: TimeInterval = 8) {
        guard !quiet else { return }
        noticeSessionID = sessionID
        companionView.notice = title
        attentionUntil = Date().addingTimeInterval(duration)
        refreshExpansion()
    }

    func show() {
        isVisible = true
        expandedUntil = Date().addingTimeInterval(5)
        refreshExpansion()
        positionPanel()
    }

    /// Global screen coordinates for a dashboard immediately below the notch or menu-bar button.
    func dashboardLocation() -> (anchor: NSRect, screen: NSScreen)? {
        guard let selectedScreen = targetScreen() else { return nil }
        if Self.hasPhysicalNotch(selectedScreen),
           let left = selectedScreen.auxiliaryTopLeftArea,
           let right = selectedScreen.auxiliaryTopRightArea {
            let height = selectedScreen.safeAreaInsets.top
            let anchor = NSRect(x: left.maxX, y: selectedScreen.frame.maxY - height,
                                width: max(0, right.minX - left.maxX), height: height)
            return (anchor, selectedScreen)
        }
        if let button = statusItem.button, let statusWindow = button.window,
           let statusScreen = statusWindow.screen {
            let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            return (anchor, statusScreen)
        }
        let top = min(selectedScreen.visibleFrame.maxY, selectedScreen.frame.maxY)
        return (NSRect(x: selectedScreen.frame.midX - 16, y: top, width: 32,
                       height: max(1, selectedScreen.frame.maxY - top)), selectedScreen)
    }

    /// Dismissing a transient state card never acknowledges results or explicit requests.
    func dismissStateCard() {
        expandedUntil = .distantPast
        attentionUntil = .distantPast
        hoverUntil = .distantPast
        hoverStarted = nil
        suppressHoverUntilExit = true
        companionView.notice = nil
        noticeSessionID = nil
        setExpanded(false)
    }

    /// Renders only our view into a PNG. Does not record or read the display.
    func capturePreview(to url: URL) {
        setExpanded(true)
        writeViewBitmap(to: url)
    }

    /// A 2× rendering of the compact notch extension, without a screen capture.
    func captureCompactPreview(to url: URL) {
        setExpanded(false)
        writeViewBitmap(to: url)
    }

    /// Only our window and public display geometry; no other apps or screen pixels.
    func layoutReport() -> [String: Any] {
        let screen: Any = targetScreen().map { screen -> [String: Any] in
            ["frame": Self.geometry(screen.frame),
             "safeAreaTop": Double(screen.safeAreaInsets.top),
             "auxiliaryTopRightFrame": screen.auxiliaryTopRightArea.map { Self.geometry($0) } as Any? ?? NSNull(),
             "hasPhysicalNotch": Self.hasPhysicalNotch(screen)]
        } ?? NSNull()
        let location = dashboardLocation()
        return ["targetScreen": screen, "panelFrame": Self.geometry(panel.frame),
                "dashboardAnchor": location.map { Self.geometry($0.anchor) } as Any? ?? NSNull(),
                "dashboardScreenFrame": location.map { Self.geometry($0.screen.frame) } as Any? ?? NSNull(),
                "isExpanded": isExpanded, "visible": panel.isVisible, "characterEnabled": isVisible]
    }

    private static func geometry(_ rect: NSRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY),
         "width": Double(rect.width), "height": Double(rect.height)]
    }

    private func writeViewBitmap(to url: URL) {
        companionView.layoutSubtreeIfNeeded()
        let size = companionView.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        companionView.cacheDisplay(in: companionView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { rebuildMenu() }
    }

    private func tick() {
        guard isVisible else { return }
        let localPointer = companionView.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let hovered = panel.isVisible && companionView.containsCapsule(localPointer)
        panel.ignoresMouseEvents = !hovered
        let now = Date()
        if !hovered { suppressHoverUntilExit = false }
        if hovered && !suppressHoverUntilExit {
            if hoverStarted == nil { hoverStarted = now }
            if isExpanded || now.timeIntervalSince(hoverStarted ?? now) >= 0.5 {
                hoverUntil = now.addingTimeInterval(0.35)
                if !isExpanded {
                    // The card is below the notch; allow time to move into it.
                    expandedUntil = max(expandedUntil, now.addingTimeInterval(3))
                }
            }
        } else {
            hoverStarted = nil
        }
        refreshExpansion(now: now)
        let animated = snapshot.state == .working || snapshot.state == .coding || snapshot.state == .checking || snapshot.state == .finished
        let frameInterval = (animated && !companionView.reducedMotion) ? 1.0 / 20.0 : 1.0
        guard now.timeIntervalSince(lastFrame) >= frameInterval else { return }
        lastFrame = now
        companionView.animationTime = now.timeIntervalSince(animationStarted)
        companionView.needsDisplay = true
    }

    private func refreshExpansion(now: Date = Date()) {
        if now >= attentionUntil { companionView.notice = nil; noticeSessionID = nil }
        setExpanded(now < attentionUntil || now < expandedUntil || now < hoverUntil)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        let safeTop = targetScreen()?.safeAreaInsets.top ?? 0
        let size = expanded ? NSSize(width: 324, height: 88)
            : NSSize(width: 32, height: safeTop > 0 ? safeTop : 32)
        panel.setContentSize(size)
        companionView.frame = NSRect(origin: .zero, size: size)
        panel.hasShadow = expanded
        positionPanel()
        companionView.needsDisplay = true
    }

    private func positionPanel() {
        guard let screen = targetScreen() else { panel.orderOut(nil); return }
        let notched = Self.hasPhysicalNotch(screen)
        if !isExpanded && !notched {
            // External and older displays use the normal, native menu-bar icon only.
            panel.orderOut(nil)
            return
        }
        let frame: NSRect
        if isExpanded {
            let notchMidpoint: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchMidpoint = (left.maxX + right.minX) / 2
            } else {
                notchMidpoint = screen.frame.midX
            }
            let top = notched
                ? screen.frame.maxY - screen.safeAreaInsets.top - 2
                : min(screen.visibleFrame.maxY, screen.frame.maxY - 8) - 6
            frame = NSRect(x: notchMidpoint - panel.frame.width / 2,
                           y: top - panel.frame.height,
                           width: panel.frame.width, height: panel.frame.height)
        } else {
            // Only the extra 32pt next to the camera are used. The physical camera
            // cutout itself cannot display pixels. No other app's menu is inspected.
            let rightEdge = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
            let height = screen.safeAreaInsets.top
            let size = NSSize(width: 32, height: height)
            if companionView.bounds.size != size {
                panel.setContentSize(size)
                companionView.frame = NSRect(origin: .zero, size: size)
            }
            frame = NSRect(x: rightEdge - 1,
                           y: screen.frame.maxY - height,
                           width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)
        if isVisible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        return selectedDisplay.flatMap { wanted in screens.first { Self.displayID($0) == wanted } }
            ?? screens.first { $0.safeAreaInsets.top > 0 && CGDisplayIsBuiltin(Self.displayID($0)) != 0 }
            ?? screens.first { CGDisplayIsBuiltin(Self.displayID($0)) != 0 }
            ?? NSScreen.main ?? screens.first
    }

    private static func hasPhysicalNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && CGDisplayIsBuiltin(displayID(screen)) != 0
            && screen.auxiliaryTopRightArea != nil
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let state = NSMenuItem(title: "Codex · \(snapshot.state.companionTitle)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let privacy = NSMenuItem(title: "Только на этом Mac · без сети", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)
        menu.addItem(.separator())
        if let queueError {
            let warning = NSMenuItem(title: queueError, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        if !completions.isEmpty {
            let results = NSMenu()
            for result in completions.reversed().prefix(30) {
                let row = item("Ход завершён · " + String(result.sessionID.prefix(8)), action: #selector(openResult(_:)))
                row.representedObject = result.id
                results.addItem(row)
            }
            results.addItem(.separator())
            results.addItem(item("Отметить все просмотренными", action: #selector(acknowledgeResults)))
            let queue = NSMenuItem(title: "Ожидают просмотра: \(completions.count)", action: nil, keyEquivalent: "")
            queue.submenu = results
            menu.addItem(queue)
        }
        menu.addItem(item("Проверить подключение…", action: #selector(openHealth)))
        menu.addItem(item("Чаты и результаты…", action: #selector(openDashboard)))
        menu.addItem(item("Показать состояние", action: #selector(revealState)))
        menu.addItem(item(isVisible ? "Скрыть персонажа" : "Показать персонажа", action: #selector(toggleVisibility)))
        menu.addItem(item("Открыть Codex", action: #selector(openCodex)))

        screenMenu.removeAllItems()
        let automatic = item("Автоматически · встроенный экран", action: #selector(selectAutomaticScreen))
        automatic.state = selectedDisplay == nil ? .on : .off
        screenMenu.addItem(automatic)
        screenMenu.addItem(.separator())
        for screen in NSScreen.screens {
            let id = Self.displayID(screen)
            let suffix = screen.safeAreaInsets.top > 0 ? " · с вырезом" : ""
            let choice = item(screen.localizedName + suffix, action: #selector(selectScreen(_:)))
            choice.representedObject = NSNumber(value: id)
            choice.state = selectedDisplay == id ? .on : .off
            screenMenu.addItem(choice)
        }
        let screenItem = NSMenuItem(title: "Экран", action: nil, keyEquivalent: "")
        screenItem.submenu = screenMenu
        menu.addItem(screenItem)

        let demos = NSMenu()
        let states: [CompanionState] = [.idle, .working, .coding, .checking, .finished, .interrupted, .unknown, .needsAnswer, .needsReview]
        for state in states {
            let demo = item(state.companionTitle, action: #selector(selectDemo(_:)))
            demo.representedObject = state.rawValue
            demos.addItem(demo)
        }
        let demoItem = NSMenuItem(title: "Посмотреть состояния", action: nil, keyEquivalent: "")
        demoItem.submenu = demos
        menu.addItem(demoItem)
        menu.addItem(item("Вернуться к живому состоянию", action: #selector(returnToLive)))
        menu.addItem(.separator())
        menu.addItem(item("Завершить Codex Notch", action: #selector(quit), key: "q"))
    }

    private func updateStatusItemDescription() {
        statusItem.button?.toolTip = "Codex · \(snapshot.state.companionTitle) · клик: чаты · правый клик: настройки"
        statusItem.button?.setAccessibilityLabel("Codex Notch: \(snapshot.state.companionTitle). Открыть чаты")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            NSMenu.popUpContextMenu(menu, with: event, for: sender)
        } else {
            dashboardHandler?()
        }
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    @objc private func toggleVisibility() {
        isVisible.toggle()
        if isVisible { show() } else { panel.orderOut(nil) }
    }

    @objc private func revealState() { show() }

    @objc private func selectAutomaticScreen() {
        selectedDisplay = nil
        positionPanel()
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        selectedDisplay = (sender.representedObject as? NSNumber)?.uint32Value
        positionPanel()
    }

    @objc private func selectDemo(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let state = CompanionState(rawValue: raw) else { return }
        if let demoHandler { demoHandler(state) }
        else { update(CompanionSnapshot(state: state, sessionID: nil, activeCount: state == .idle ? 0 : 1, updatedAt: Date())) }
        show()
    }

    @objc private func returnToLive() { liveHandler?() }

    @objc private func openHealth() { healthHandler?() }

    @objc private func openDashboard() { dashboardHandler?() }

    @objc private func acknowledgeResults() { acknowledgeHandler?(nil) }

    @objc private func openResult(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let result = completions.first(where: { $0.id == key }) else { return }
        if openChat(result.sessionID) { acknowledgeHandler?(result.id) }
    }

    @discardableResult func openChat(_ sessionID: String) -> Bool {
        guard let id = UUID(uuidString: sessionID),
              let url = URL(string: "codex://threads/\(id.uuidString.lowercased())") else { return false }
        return NSWorkspace.shared.open(url)
    }

    @objc private func openCodex() {
        if let rawID = noticeSessionID ?? snapshot.sessionID, let id = UUID(uuidString: rawID),
           let url = URL(string: "codex://threads/\(id.uuidString.lowercased())") {
            NSWorkspace.shared.open(url)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "codex://") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func menuBarImage(state: CompanionState = .idle) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let head = NSBezierPath(roundedRect: NSRect(x: 3, y: 5, width: 14, height: 11), xRadius: 4, yRadius: 4)
            head.lineWidth = 1.5
            head.stroke()
            let antenna = NSBezierPath()
            antenna.move(to: NSPoint(x: 10, y: 16))
            antenna.line(to: NSPoint(x: 10, y: 18))
            antenna.lineWidth = 1.5
            antenna.stroke()
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6, y: 9, width: 2, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 9, width: 2, height: 3)).fill()
            if state == .checking || state == .finished || state == .interrupted {
                // Persistent state indicator remains after the attention card folds.
                NSBezierPath(ovalIn: NSRect(x: 15, y: 2, width: 4, height: 4)).fill()
            }
            return true
        }
    }
}

private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CompanionView: NSView {
    var snapshot = CompanionSnapshot(state: .idle, sessionID: nil, activeCount: 0, updatedAt: Date())
    var unreadCount = 0
    var notice: String?
    var animationTime: TimeInterval = 0
    var reducedMotion = false
    var onClick: (() -> Void)?
    var contextMenu: NSMenu?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    private let mint = NSColor(calibratedRed: 0.64, green: 0.96, blue: 0.80, alpha: 1)
    private var capsule: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 27, yRadius: 27)
    }
    private var notchLip: NSBezierPath {
        let width = bounds.width
        let height = bounds.height
        let radius = min(11, height / 2)
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: width, y: 0))
        path.line(to: NSPoint(x: width, y: height - radius))
        path.curve(to: NSPoint(x: width - radius, y: height),
                   controlPoint1: NSPoint(x: width, y: height - radius * 0.4477),
                   controlPoint2: NSPoint(x: width - radius * 0.4477, y: height))
        path.line(to: NSPoint(x: 0, y: height))
        path.close()
        return path
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Нажмите, чтобы открыть чаты Codex под вырезом. Правый клик открывает настройки.")
        toolTip = "Нажмите, чтобы открыть чаты; наведите на полсекунды, чтобы увидеть состояние"
    }

    required init?(coder: NSCoder) { nil }

    func containsCapsule(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        if bounds.width > 120 { return capsule.contains(point) }
        return notchLip.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { containsCapsule(point) ? self : nil }

    override func mouseDown(with event: NSEvent) {
        if containsCapsule(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let contextMenu, containsCapsule(convert(event.locationInWindow, from: nil)) {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
        }
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let accent = snapshot.state.companionAccent
        guard bounds.width > 120 else {
            notchLip.addClip()
            NSColor.black.setFill()
            notchLip.fill()
            // About 24pt high, vertically centered in the actual menu-bar band.
            let scale: CGFloat = min(0.42, (bounds.height - 5) / 58)
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.width / 2 - 27.75 * scale,
                                 yBy: bounds.height / 2 - 25 * scale)
            transform.scale(by: scale)
            transform.concat()
            drawRobot(at: .zero, accent: accent, showAura: false)
            NSGraphicsContext.restoreGraphicsState()
            if unreadCount > 0 {
                mint.setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.width - 6, y: bounds.height - 6, width: 4, height: 4)).fill()
            }
            setAccessibilityLabel("Codex: \(snapshot.state.companionTitle), ждут просмотра: \(unreadCount)")
            return
        }
        capsule.addClip()
        let background = NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.052, alpha: 0.985)
        background.setFill()
        capsule.fill()
        // A restrained tint keeps the black capsule visually attached to the notch.
        let wash = NSGradient(starting: accent.withAlphaComponent(0.10), ending: .clear)
        wash?.draw(in: NSRect(x: 0, y: 0, width: 118, height: bounds.height), angle: 0)
        NSColor.white.withAlphaComponent(0.11).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 26, yRadius: 26)
        border.lineWidth = 0.7
        border.stroke()

        drawRobot(at: NSPoint(x: 23, y: 16), accent: accent)
        drawText("CODEX", at: NSPoint(x: 96, y: 19), font: .systemFont(ofSize: 10, weight: .semibold),
                 color: NSColor.white.withAlphaComponent(0.48), tracking: 2.1)
        drawText(notice ?? snapshot.state.companionTitle, at: NSPoint(x: 96, y: 37),
                 font: .systemFont(ofSize: 15, weight: .medium), color: NSColor.white.withAlphaComponent(0.95),
                 maxWidth: 191)
        drawText(snapshot.state.companionDetail, at: NSPoint(x: 96, y: 59),
                 font: .systemFont(ofSize: 10.5, weight: .regular), color: NSColor.white.withAlphaComponent(0.42),
                 maxWidth: 191)
        drawStatus(accent: accent)
        NSGraphicsContext.restoreGraphicsState()
        setAccessibilityLabel("Codex: \(snapshot.state.companionTitle)")
    }

    private func drawRobot(at origin: NSPoint, accent: NSColor, showAura: Bool = true) {
        let busy = snapshot.state == .working || snapshot.state == .coding
        let t = reducedMotion ? 0 : animationTime
        let bounce: CGFloat = busy ? CGFloat(sin(t * 3.4)) * 1.3 : 0
        let x = origin.x
        let y = origin.y + bounce

        // A small robot, drawn entirely with local vector paths.
        if showAura {
            accent.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 8, y: y - 4, width: 73, height: 63)).fill()
        }
        let antenna = NSBezierPath()
        antenna.move(to: NSPoint(x: x + 28, y: y + 6))
        antenna.line(to: NSPoint(x: x + 28, y: y))
        antenna.lineWidth = 2
        accent.withAlphaComponent(0.75).setStroke()
        antenna.stroke()
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: x + 25.5, y: y - 4, width: 5, height: 5)).fill()

        NSColor(calibratedRed: 0.14, green: 0.21, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 3, y: y + 21, width: 7, height: 15), xRadius: 3, yRadius: 3).fill()
        NSBezierPath(roundedRect: NSRect(x: x + 51, y: y + 21, width: 7, height: 15), xRadius: 3, yRadius: 3).fill()

        let head = NSBezierPath(roundedRect: NSRect(x: x, y: y + 6, width: 56, height: 43), xRadius: 13, yRadius: 13)
        mint.setFill()
        head.fill()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        head.lineWidth = 0.6
        head.stroke()
        NSColor(calibratedRed: 0.045, green: 0.105, blue: 0.095, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 6, y: y + 14, width: 44, height: 25), xRadius: 8, yRadius: 8).fill()

        let blink = !reducedMotion && animationTime.truncatingRemainder(dividingBy: 6.7) > 6.48
        mint.setFill()
        if snapshot.state == .finished {
            eyeSmile(x: x + 14, y: y + 23)
            eyeSmile(x: x + 35, y: y + 23)
        } else if snapshot.state == .checking {
            NSBezierPath(roundedRect: NSRect(x: x + 15, y: y + 21, width: 5, height: 8), xRadius: 2.5, yRadius: 2.5).fill()
            NSBezierPath(roundedRect: NSRect(x: x + 36, y: y + 21, width: 5, height: 8), xRadius: 2.5, yRadius: 2.5).fill()
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 27, y: y + 32, width: 3, height: 3)).fill()
        } else if snapshot.state == .interrupted || snapshot.state == .unknown {
            NSBezierPath(roundedRect: NSRect(x: x + 14, y: y + 25, width: 8, height: 2.5), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: x + 34, y: y + 25, width: 8, height: 2.5), xRadius: 1, yRadius: 1).fill()
        } else {
            let glance: CGFloat = snapshot.state == .working ? CGFloat(sin(t * 1.4)) * 2 : 0
            NSBezierPath(roundedRect: NSRect(x: x + 15 + glance, y: y + 22, width: 5, height: blink ? 1.7 : 7), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: x + 36 + glance, y: y + 22, width: 5, height: blink ? 1.7 : 7), xRadius: 2, yRadius: 2).fill()
        }

        // Tiny feet and keyboard make coding distinct even without animation.
        mint.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + 11, y: y + 49, width: 11, height: 5), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: NSRect(x: x + 34, y: y + 49, width: 11, height: 5), xRadius: 2, yRadius: 2).fill()
        if snapshot.state == .coding {
            NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 1, y: y + 44, width: 54, height: 8), xRadius: 3, yRadius: 3).fill()
            for index in 0..<8 {
                let lit = Int(t * 8).quotientAndRemainder(dividingBy: 8).remainder == index
                mint.withAlphaComponent(lit ? 1 : 0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 7 + CGFloat(index) * 5.6, y: y + 46, width: 3.5, height: 2), xRadius: 0.5, yRadius: 0.5).fill()
            }
        }
        if snapshot.state == .finished {
            drawSparkle(center: NSPoint(x: x + 59, y: y + 8), size: 4, color: accent)
            drawSparkle(center: NSPoint(x: x - 5, y: y + 10), size: 2.5, color: accent.withAlphaComponent(0.7))
        }
    }

    private func eyeSmile(x: CGFloat, y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y + 4))
        path.curve(to: NSPoint(x: x + 8, y: y + 4),
                   controlPoint1: NSPoint(x: x + 1, y: y - 2), controlPoint2: NSPoint(x: x + 7, y: y - 2))
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        mint.setStroke()
        path.stroke()
    }

    private func drawStatus(accent: NSColor) {
        let center = NSPoint(x: 299, y: 24)
        let t = reducedMotion ? 0 : animationTime
        if snapshot.activeCount > 1 {
            drawText("\(min(snapshot.activeCount, 99))", at: NSPoint(x: 289, y: 17),
                     font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: accent, maxWidth: 23)
            return
        }
        if snapshot.state == .coding || snapshot.state == .working {
            for index in 0..<3 {
                let alpha = reducedMotion ? 0.7 : 0.3 + 0.7 * max(0, sin(t * 4 - Double(index) * 0.8))
                accent.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 8 + CGFloat(index) * 5, y: center.y - 1, width: 2.5, height: 2.5)).fill()
            }
        } else if snapshot.state == .checking {
            let pulse = reducedMotion ? 0.15 : 0.08 + (sin(t * 2.3) + 1) * 0.09
            accent.withAlphaComponent(pulse).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)).fill()
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: center.x - 1, y: center.y - 5, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1, y: center.y + 3, width: 2, height: 2)).fill()
        } else if snapshot.state == .finished {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: center.x - 5, y: center.y))
            check.line(to: NSPoint(x: center.x - 1, y: center.y + 4))
            check.line(to: NSPoint(x: center.x + 6, y: center.y - 4))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            accent.setStroke()
            check.stroke()
        } else {
            accent.withAlphaComponent(0.7).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
        }
    }

    private func drawSparkle(center: NSPoint, size: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y - size))
        path.line(to: NSPoint(x: center.x + size * 0.3, y: center.y - size * 0.3))
        path.line(to: NSPoint(x: center.x + size, y: center.y))
        path.line(to: NSPoint(x: center.x + size * 0.3, y: center.y + size * 0.3))
        path.line(to: NSPoint(x: center.x, y: center.y + size))
        path.line(to: NSPoint(x: center.x - size * 0.3, y: center.y + size * 0.3))
        path.line(to: NSPoint(x: center.x - size, y: center.y))
        path.line(to: NSPoint(x: center.x - size * 0.3, y: center.y - size * 0.3))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor,
                          tracking: CGFloat = 0, maxWidth: CGFloat = 215) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .kern: tracking, .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: NSRect(origin: point, size: NSSize(width: maxWidth, height: 23)), withAttributes: attributes)
    }
}

extension CompanionState {
    var companionTitle: String {
        switch self {
        case .idle: return "Готов к работе"
        case .working: return "Разбирается в задаче"
        case .coding: return "Пишет код"
        case .checking: return "Проверка действия"
        case .needsAnswer: return "Нужен твой ответ"
        case .needsReview: return "Посмотри результат"
        case .finished: return "Ход завершён"
        case .interrupted: return "Остановлен"
        case .unknown: return "Нет свежих событий"
        }
    }

    var companionDetail: String {
        switch self {
        case .idle: return "Можно начинать новую задачу"
        case .working: return "Думает, читает и проверяет"
        case .coding: return "Шуршит маленькой клавиатурой"
        case .checking: return "Codex проверяет действие"
        case .needsAnswer, .needsReview: return "Явный сигнал из чата"
        case .finished: return "Результат ждёт в чате"
        case .interrupted: return "Можно продолжить в чате"
        case .unknown: return "Ожидает локальный сигнал"
        }
    }

    var companionAccent: NSColor {
        switch self {
        case .idle: return NSColor(calibratedRed: 0.64, green: 0.96, blue: 0.80, alpha: 1)
        case .working: return NSColor(calibratedRed: 0.60, green: 0.77, blue: 1, alpha: 1)
        case .coding: return NSColor(calibratedRed: 0.64, green: 0.96, blue: 0.80, alpha: 1)
        case .checking: return NSColor(calibratedRed: 1, green: 0.75, blue: 0.38, alpha: 1)
        case .needsAnswer, .needsReview: return NSColor(calibratedRed: 1, green: 0.75, blue: 0.38, alpha: 1)
        case .finished: return NSColor(calibratedRed: 0.64, green: 0.96, blue: 0.80, alpha: 1)
        case .interrupted: return NSColor(calibratedRed: 0.90, green: 0.64, blue: 0.58, alpha: 1)
        case .unknown: return NSColor(calibratedRed: 0.65, green: 0.67, blue: 0.72, alpha: 1)
        }
    }
}
