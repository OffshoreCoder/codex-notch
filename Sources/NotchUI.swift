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
    var keepAwakeHandler: (() -> Void)?
    var screenSharingHandler: (() -> Void)?
    var skinHandler: ((CharacterSkin) -> Void)?
    private var skin: CharacterSkin = .robot
    private let headphoneAccessory = HeadphoneAccessoryController()
    private var completions: [CompletedTurn] = []
    private var queueError: String?
    private var chatNames: [String: String] = [:]
    private var keepAwakeEnabled = false
    private var keepAwakeStatus = "Обычный режим сна"
    private var menuTracking = false
    private var menuNeedsUpdate = false
    private var quiet = false
    private var noticeSessionID: String?
    private var noticeTitle: String?
    private var screenSharing = false
    private var privacyPresentation = PrivacyPresentation()

    private let panel: CompanionPanel
    private let companionView: CompanionView
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let screenMenu = NSMenu()
    private var snapshot = CompanionSnapshot(state: .idle, sessionID: nil, activeCount: 0, updatedAt: Date())
    private var selectedDisplay: CGDirectDisplayID?
    private var isVisible = true
    private var timer: Timer?
    private var renderSchedule = CompanionRenderSchedule.resolve(visible: false, displaySleeping: false,
        animated: false, reducedMotion: false, lowPower: false)
    private var screenSleeping = false
    private var systemSleeping = false
    private var displaySleeping: Bool { screenSleeping || systemSleeping }
    private var powerObserver: NSObjectProtocol?
    private var sleepObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var animationStarted = Date()
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
        companionView.onPointerChanged = { [weak self] in self?.tick(animate: false) }
        companionView.contextMenu = menu
        companionView.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        headphoneAccessory.onChange = { [weak self] wearing in
            guard let self else { return }
            self.companionView.headphones = wearing
            if self.panel.isVisible, !self.displaySleeping { self.companionView.needsDisplay = true }
        }

        statusItem.button?.image = Self.menuBarImage(skin: skin)
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
                self?.refreshRenderSchedule()
                self?.companionView.needsDisplay = true
            }
        }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRenderSchedule() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            sleepObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.willSleepNotification { self?.setSystemSleeping(true) }
                    else { self?.setDisplaySleeping(true) }
                }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            sleepObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didWakeNotification { self?.setSystemSleeping(false) }
                    else { self?.setDisplaySleeping(false) }
                }
            })
        }
        positionPanel()
    }

    deinit {
        timer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func update(_ snapshot: CompanionSnapshot) {
        let changed = self.snapshot.state != snapshot.state || self.snapshot.activeCount != snapshot.activeCount
        if self.snapshot.state != snapshot.state {
            animationStarted = Date()
            statusItem.button?.image = Self.menuBarImage(skin: skin, state: snapshot.state)
            statusItem.button?.image?.isTemplate = true
            statusItem.button?.contentTintColor = snapshot.state == .idle ? nil : snapshot.state.companionAccent
        }
        self.snapshot = snapshot
        companionView.snapshot = snapshot
        refreshExpansion()
        refreshRenderSchedule()
        if changed, panel.isVisible, !displaySleeping { companionView.needsDisplay = true }
        updateStatusItemDescription()
    }

    /// Changes only the appearance; state, events and actions keep the same behavior.
    func setSkin(_ skin: CharacterSkin) {
        guard self.skin != skin else { return }
        self.skin = skin
        companionView.skin = skin
        companionView.needsDisplay = true
        statusItem.button?.image = Self.menuBarImage(skin: skin, state: snapshot.state)
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()
    }

    /// This is a decoration only; monitoring the current output is off by default.
    /// CoreAudio listeners are removed as soon as the preference is disabled.
    func setHeadphoneAccessory(enabled: Bool) { headphoneAccessory.setEnabled(enabled) }

    func updateQueue(_ completions: [CompletedTurn], error: String?, pendingCount: Int? = nil, chatNames: [String: String] = [:]) {
        self.completions = completions
        privacyPresentation.observe(sessionIDs: completions.map { $0.sessionID })
        self.chatNames = chatNames
        queueError = error
        let count = pendingCount ?? completions.count
        let countChanged = companionView.unreadCount != count
        companionView.unreadCount = count
        statusItem.button?.title = count == 0 ? "" : " \(min(count, 99))"
        statusItem.length = count == 0 ? NSStatusItem.squareLength : NSStatusItem.variableLength
        if countChanged, panel.isVisible, !displaySleeping { companionView.needsDisplay = true }
    }

    /// Manual presentation mode: masks only this companion's visible surfaces.
    /// Pass the same ordered IDs used by the dashboard to keep generic task labels aligned.
    func setScreenSharing(_ active: Bool, sessionIDs: [String] = []) {
        privacyPresentation.observe(sessionIDs: sessionIDs)
        applyScreenSharing(active)
    }

    /// Share one presentation map with the dashboard, including ordinals assigned earlier.
    func setScreenSharing(_ active: Bool, presentation: PrivacyPresentation) {
        privacyPresentation = presentation
        applyScreenSharing(active)
    }

    private func applyScreenSharing(_ active: Bool) {
        guard screenSharing != active else { return }
        screenSharing = active
        if let noticeTitle {
            companionView.notice = privacyPresentation.notice(noticeTitle, isSharing: active)
        }
        rebuildMenu()
        updateStatusItemDescription()
        companionView.needsDisplay = true
    }

    func setKeepAwake(enabled: Bool, status: String) {
        guard keepAwakeEnabled != enabled || keepAwakeStatus != status else { return }
        keepAwakeEnabled = enabled
        keepAwakeStatus = status
        rebuildMenu()
    }

    func setQuiet(_ active: Bool) {
        let hadNotice = companionView.notice != nil
        quiet = active
        if active { attentionUntil = .distantPast; companionView.notice = nil; noticeSessionID = nil; noticeTitle = nil }
        refreshExpansion()
        if active, hadNotice, panel.isVisible, !displaySleeping { companionView.needsDisplay = true }
    }

    func notify(title: String, sessionID: String? = nil, duration: TimeInterval = 8) {
        guard !quiet else { return }
        noticeSessionID = sessionID
        noticeTitle = title
        companionView.notice = privacyPresentation.notice(title, isSharing: screenSharing)
        attentionUntil = Date().addingTimeInterval(duration)
        refreshExpansion()
        if panel.isVisible, !displaySleeping { companionView.needsDisplay = true }
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
        noticeTitle = nil
        setExpanded(false)
    }

    /// Renders only our view into a PNG. Does not record or read the display.
    func capturePreview(to url: URL) {
        setExpanded(true)
        writeViewBitmap(to: url)
    }

    /// A 2× rendering of the compact notch extension, without a screen capture.
    func captureCompactPreview(to url: URL, scale: CGFloat = 2) {
        setExpanded(false)
        writeViewBitmap(to: url, scale: scale)
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

    private func writeViewBitmap(to url: URL, scale: CGFloat = 2) {
        companionView.layoutSubtreeIfNeeded()
        let size = companionView.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        companionView.cacheDisplay(in: companionView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { rebuildMenu(); menuTracking = true }
    }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuTracking = false
        if menuNeedsUpdate { rebuildMenu() }
    }

    private func tick(animate: Bool = true) {
        guard isVisible, panel.isVisible, !displaySleeping else { return }
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
        guard animate, renderSchedule.drawsAnimation else { return }
        companionView.animationTime = now.timeIntervalSince(animationStarted)
        companionView.needsDisplay = true
    }

    /// macOS sends these notifications even when the app has no open dashboard.
    /// Sleeping displays never need pointer checks or animation frames.
    func setDisplaySleeping(_ sleeping: Bool) {
        guard screenSleeping != sleeping else { return }
        screenSleeping = sleeping
        refreshRenderSchedule()
        if !displaySleeping { refreshExpansion(); companionView.needsDisplay = true }
    }

    private func setSystemSleeping(_ sleeping: Bool) {
        guard systemSleeping != sleeping else { return }
        systemSleeping = sleeping
        refreshRenderSchedule()
        if !displaySleeping { refreshExpansion(); companionView.needsDisplay = true }
    }

    private func refreshRenderSchedule() {
        let animated = snapshot.state == .working || snapshot.state == .coding || snapshot.state == .checking
        let schedule = CompanionRenderSchedule.resolve(visible: isVisible && panel.isVisible,
            displaySleeping: displaySleeping, animated: animated,
            reducedMotion: companionView.reducedMotion, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard schedule != renderSchedule else { return }
        renderSchedule = schedule
        timer?.invalidate(); timer = nil
        guard let interval = schedule.timerInterval else { return }
        // Only reads the pointer, never monitors other apps' events. Native tracking
        // handles movement within our panel; this fallback re-enables transparent edges.
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = schedule.tolerance
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private func refreshExpansion(now: Date = Date()) {
        if now >= attentionUntil {
            let hadNotice = companionView.notice != nil
            companionView.notice = nil; noticeSessionID = nil; noticeTitle = nil
            if hadNotice, panel.isVisible, !displaySleeping { companionView.needsDisplay = true }
        }
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
        guard let screen = targetScreen() else { panel.orderOut(nil); refreshRenderSchedule(); return }
        let notched = Self.hasPhysicalNotch(screen)
        if !isExpanded && !notched {
            // External and older displays use the normal, native menu-bar icon only.
            panel.orderOut(nil)
            refreshRenderSchedule()
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
        refreshRenderSchedule()
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
        guard !menuTracking else { menuNeedsUpdate = true; return }
        menuNeedsUpdate = false
        menu.removeAllItems()
        let state = NSMenuItem(title: "Codex · \(snapshot.state.companionTitle)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let privacy = NSMenuItem(title: "Только на этом Mac · без сети", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)
        menu.addItem(.separator())
        if let queueError {
            let warning = NSMenuItem(title: privacyPresentation.diagnostic(queueError, isSharing: screenSharing), action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        if !completions.isEmpty {
            let results = NSMenu()
            for result in completions.reversed().prefix(30) {
                let original = chatNames[result.sessionID] ?? chatNames[result.sessionID.lowercased()] ?? "Чат без названия"
                let name = privacyPresentation.name(for: result.sessionID, original: original, isSharing: screenSharing)
                let row = item("Ход завершён · " + name, action: #selector(openResult(_:)))
                row.representedObject = result.id
                results.addItem(row)
            }
            results.addItem(.separator())
            results.addItem(item("Отметить все просмотренными", action: #selector(acknowledgeResults)))
            let queue = NSMenuItem(title: "Ожидают просмотра: \(completions.count)", action: nil, keyEquivalent: "")
            queue.submenu = results
            menu.addItem(queue)
        }
        let awake = item("Не усыплять Mac во время работы", action: #selector(toggleKeepAwake))
        awake.state = keepAwakeEnabled ? .on : .off
        awake.toolTip = "Только автоматический сон. Экран может гаснуть; закрытие крышки и ручной Сон остаются по правилам macOS."
        menu.addItem(awake)
        if keepAwakeEnabled {
            let status = NSMenuItem(title: keepAwakeStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        let presentation = item("Режим демонстрации", action: #selector(toggleScreenSharing))
        presentation.state = screenSharing ? .on : .off
        presentation.toolTip = "Скрывает названия задач и пути в Codex Notch"
        menu.addItem(presentation)
        menu.addItem(item("Проверить подключение…", action: #selector(openHealth)))
        menu.addItem(item("Чаты и результаты…", action: #selector(openDashboard)))
        menu.addItem(item("Показать состояние", action: #selector(revealState)))
        let skins = NSMenu()
        for skin in CharacterSkin.allCases {
            let choice = item(skin.title, action: #selector(selectSkin(_:)))
            choice.representedObject = skin.rawValue
            choice.state = self.skin == skin ? .on : .off
            choice.toolTip = skin.detail
            skins.addItem(choice)
        }
        let skinItem = NSMenuItem(title: "Персонаж", action: nil, keyEquivalent: "")
        skinItem.submenu = skins
        menu.addItem(skinItem)
        menu.addItem(item(isVisible ? "Скрыть персонажа" : "Показать персонажа", action: #selector(toggleVisibility)))
        menu.addItem(item("Открыть Codex", action: #selector(openCodex)))

        screenMenu.removeAllItems()
        let automatic = item("Автоматически · встроенный экран", action: #selector(selectAutomaticScreen))
        automatic.state = selectedDisplay == nil ? .on : .off
        screenMenu.addItem(automatic)
        screenMenu.addItem(.separator())
        for (index, screen) in NSScreen.screens.enumerated() {
            let id = Self.displayID(screen)
            let suffix = screen.safeAreaInsets.top > 0 ? " · с вырезом" : ""
            let screenName = screenSharing ? "Экран \(index + 1)" : screen.localizedName
            let choice = item(screenName + suffix, action: #selector(selectScreen(_:)))
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
        refreshRenderSchedule()
    }

    @objc private func revealState() { show() }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let skin = CharacterSkin(rawValue: raw) else { return }
        setSkin(skin)
        skinHandler?(skin)
    }

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

    @objc private func toggleKeepAwake() { keepAwakeHandler?() }
    @objc private func toggleScreenSharing() { screenSharingHandler?() }

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

    private static func menuBarImage(skin: CharacterSkin = .robot, state: CompanionState = .idle) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()
            let silhouette: NSBezierPath
            switch skin {
            case .robot:
                silhouette = NSBezierPath(roundedRect: NSRect(x: 3, y: 5, width: 14, height: 11), xRadius: 4, yRadius: 4)
                let antenna = NSBezierPath()
                antenna.move(to: NSPoint(x: 10, y: 5)); antenna.line(to: NSPoint(x: 10, y: 2))
                antenna.lineWidth = 1.5; antenna.stroke()
            case .cat:
                silhouette = NSBezierPath()
                silhouette.move(to: NSPoint(x: 3, y: 9)); silhouette.line(to: NSPoint(x: 3, y: 2))
                silhouette.line(to: NSPoint(x: 8, y: 6)); silhouette.line(to: NSPoint(x: 12, y: 6))
                silhouette.line(to: NSPoint(x: 17, y: 2)); silhouette.line(to: NSPoint(x: 17, y: 11))
                silhouette.curve(to: NSPoint(x: 3, y: 11), controlPoint1: NSPoint(x: 17, y: 19), controlPoint2: NSPoint(x: 3, y: 19))
                silhouette.close()
            case .ghost:
                silhouette = NSBezierPath()
                silhouette.move(to: NSPoint(x: 4, y: 17)); silhouette.line(to: NSPoint(x: 4, y: 8))
                silhouette.curve(to: NSPoint(x: 16, y: 8), controlPoint1: NSPoint(x: 4, y: 0), controlPoint2: NSPoint(x: 16, y: 0))
                silhouette.line(to: NSPoint(x: 16, y: 17)); silhouette.line(to: NSPoint(x: 13, y: 14))
                silhouette.line(to: NSPoint(x: 10, y: 17)); silhouette.line(to: NSPoint(x: 7, y: 14)); silhouette.close()
            case .astronaut:
                silhouette = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2, width: 15, height: 14))
                let visor = NSBezierPath(roundedRect: NSRect(x: 5, y: 6, width: 10, height: 6), xRadius: 2, yRadius: 2)
                visor.lineWidth = 1.2; visor.stroke()
                let feet = NSBezierPath()
                feet.move(to: NSPoint(x: 6, y: 16)); feet.line(to: NSPoint(x: 6, y: 18))
                feet.move(to: NSPoint(x: 14, y: 16)); feet.line(to: NSPoint(x: 14, y: 18))
                feet.lineWidth = 1.5; feet.stroke()
            }
            silhouette.lineWidth = 1.4; silhouette.lineJoinStyle = .round; silhouette.stroke()
            for x: CGFloat in [6.5, 12] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 8, width: 1.5, height: 3), xRadius: 0.7, yRadius: 0.7).fill()
            }
            if state == .checking || state == .finished || state == .interrupted || state == .needsAnswer || state == .needsReview {
                NSBezierPath(ovalIn: NSRect(x: 15, y: 15, width: 4, height: 4)).fill()
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
    var skin: CharacterSkin = .robot
    var headphones = false
    var notice: String?
    var animationTime: TimeInterval = 0
    var reducedMotion = false
    var onClick: (() -> Void)?
    var onPointerChanged: (() -> Void)?
    var contextMenu: NSMenu?
    private var pointerTracking: NSTrackingArea?
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

    override func updateTrackingAreas() {
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area); pointerTracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onPointerChanged?() }
    override func mouseExited(with event: NSEvent) { onPointerChanged?() }
    override func mouseMoved(with event: NSEvent) { onPointerChanged?() }

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
            CharacterRenderer.draw(skin: skin, state: snapshot.state, animationTime: animationTime,
                                   reducedMotion: reducedMotion, accent: accent, showAura: false, headphones: headphones)
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

        CharacterRenderer.draw(skin: skin, state: snapshot.state, animationTime: animationTime,
                               reducedMotion: reducedMotion, origin: NSPoint(x: 23, y: 16), accent: accent, headphones: headphones)
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
