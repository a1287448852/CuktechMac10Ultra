import AppKit
import ServiceManagement
import CuktechCore
import CuktechBle

/// 菜单栏状态项、右键菜单与面板的总控。
/// 全程事件驱动：直接消费 DeviceSession.makeSnapshotStream()，没有任何定时轮询。
@MainActor
final class TrayController: NSObject {
    private var settings: AppSettings
    private let log: LogFile
    private let statusItem: NSStatusItem
    let panel = PanelController()

    private var session: DeviceSession?
    private var snapshot = DeviceSnapshot()
    private var streamTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private let statusMenu = NSMenu()
    private var statusLineItem: NSMenuItem!
    private var pinItem: NSMenuItem!
    private var wattsItem: NSMenuItem!
    private var fixedWidthItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var sceneItems: [Int: NSMenuItem] = [:]

    private var lastRenderedTitleKey = ""
    private var sceneSyncTask: Task<Void, Never>?
    private var desiredSceneMode: Int?
    private var portSyncTasks: [Int: Task<Void, Never>] = [:]
    private var desiredPortStates: [Int: Bool] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        self.log = LogFile()
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: settings.fixedMenuBarWidth ? 58 : NSStatusItem.variableLength
        )
        super.init()
        panel.model.pinned = settings.pinPanel
        buildMenu()
        wireStatusItemButton()
        wirePanel()
        updateTitle(force: true)
    }

    // MARK: - 生命周期

    func start() {
        log.write("[tray] 启动 version=\(BuildInfo.version) config=\(AppSettings.fileURL.path)")
        bootSession()
        installWakeObserver()
    }

    func shutdown() {
        streamTask?.cancel()
        streamTask = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        if let s = session {
            Task { await s.stop() }
        }
        log.write("[tray] 退出")
    }

    // MARK: - 会话与事件流

    private func bootSession() {
        streamTask?.cancel()
        streamTask = nil

        guard let mac = settings.macBytes, let token = settings.tokenBytes else {
            log.write("[tray] 还没配对：\(AppSettings.fileURL.path) 里缺 mac 或 token")
            statusLineItem.title = "还没配对，右键「重新配对…」走一遍向导"
            updateTitle(force: true)
            return
        }

        let s = DeviceSession(mac: mac, token: token)
        session = s
        let activePoll = settings.activePollInterval
        let bgPoll = settings.backgroundPollInterval
        let panelOpen = panel.isVisible
        let logger = log

        streamTask = Task { @MainActor [weak self] in
            await s.setPollIntervals(active: activePoll, background: bgPoll)
            await s.setPanelOpen(panelOpen)
            await s.setLogHandler { line in logger.write(line) }
            await s.start()

            let stream = await s.makeSnapshotStream()
            for await snap in stream {
                if Task.isCancelled { break }
                self?.apply(snap)
            }
        }
    }

    private func apply(_ snap: DeviceSnapshot) {
        let changed = !snap.hasSameDisplayState(as: snapshot)
        snapshot = snap
        panel.model.snapshot = snap
        if changed {
            updateTitle()
            refreshMenuState()
        }
    }

    private func installWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.session else { return }
                self.log.write("[tray] 系统唤醒，触发蓝牙重连")
                await s.reconnectNow()
            }
        }
    }

    // MARK: - 菜单栏文字

    private func updateTitle(force: Bool = false) {
        guard let button = statusItem.button else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)

        let text: String
        let image: NSImage?
        let explicitColor: NSColor?
        let colorKey: String

        if !settings.showWattsInMenuBar {
            text = ""
            image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "酷态科功率")?
                .withSymbolConfiguration(symbolConfig)
            image?.isTemplate = true
            explicitColor = nil
            colorKey = "icon"
        } else if snapshot.connected {
            image = nil
            text = snapshot.totalText
            if snapshot.totalWatts <= 0.05 {
                // 空载 0.0W 不指定硬编码颜色，交给菜单栏原生 vibrancy 自动适配深/浅壁纸
                explicitColor = nil
                colorKey = "idle"
            } else {
                let rgb = snapshot.totalColor
                explicitColor = Theme.menuBarNSColor(for: rgb)
                colorKey = "\(rgb.r)-\(rgb.g)-\(rgb.b)"
            }
        } else if session != nil {
            // 未连接时用原生 template 图标 + 文本（不指定暗灰 foregroundColor），确保任何壁纸下都清晰可见
            image = NSImage(systemSymbolName: "bolt.slash", accessibilityDescription: "酷态科未连接")?
                .withSymbolConfiguration(symbolConfig)
            image?.isTemplate = true
            text = " —"
            explicitColor = nil
            colorKey = "disconnected"
        } else {
            image = NSImage(systemSymbolName: "bolt.badge.questionmark", accessibilityDescription: "酷态科未配对")?
                .withSymbolConfiguration(symbolConfig)
            image?.isTemplate = true
            text = " 未配对"
            explicitColor = nil
            colorKey = "unpaired"
        }

        let renderKey = "\(text)|\(colorKey)"
        guard force || renderKey != lastRenderedTitleKey else { return }
        lastRenderedTitleKey = renderKey

        if colorKey == "unpaired" {
            statusItem.length = NSStatusItem.variableLength
        } else {
            statusItem.length = settings.fixedMenuBarWidth ? 58 : NSStatusItem.variableLength
        }

        button.image = image
        button.imagePosition = image != nil ? (text.isEmpty ? .imageOnly : .imageLeft) : .noImage

        if let explicitColor {
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: explicitColor,
                ]
            )
        } else {
            // 不传 .foregroundColor，由 macOS Menu Bar 自动渲染纯白或纯黑高对比文字
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: font]
            )
        }
        button.toolTip = snapshot.connected ? snapshot.headline : "酷态科 10 号 Ultra · \(snapshot.status)"
    }

    private func refreshMenuState() {
        statusLineItem.title = snapshot.connected
            ? snapshot.headline
            : (snapshot.error.map { "没连上：" + $0 } ?? snapshot.status)
        for (mode, mi) in sceneItems {
            mi.state = (snapshot.connected && snapshot.sceneMode == mode) ? .on : .off
            mi.isEnabled = snapshot.connected
        }
        pinItem.state = settings.pinPanel ? .on : .off
        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    // MARK: - 右键菜单

    private func buildMenu() {
        let menu = statusMenu
        menu.autoenablesItems = false

        statusLineItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        menu.addItem(item("显示功率面板", #selector(showPanel)))
        pinItem = item("固定面板在屏幕最前", #selector(togglePin))
        pinItem.state = settings.pinPanel ? .on : .off
        menu.addItem(pinItem)

        let modeMenu = NSMenu()
        for mode in SceneMode.all {
            let mi = NSMenuItem(title: mode.name, action: #selector(selectScene(_:)), keyEquivalent: "")
            mi.tag = mode.value
            mi.target = self
            mi.isEnabled = false
            modeMenu.addItem(mi)
            sceneItems[mode.value] = mi
        }
        let modeRoot = NSMenuItem(title: "充电模式", action: nil, keyEquivalent: "")
        modeRoot.submenu = modeMenu
        menu.addItem(modeRoot)

        menu.addItem(.separator())
        menu.addItem(item("重新连接", #selector(reconnect)))
        menu.addItem(item("重新配对…", #selector(runWizard)))
        menu.addItem(.separator())

        wattsItem = item("菜单栏显示功率数字", #selector(toggleWatts))
        wattsItem.state = settings.showWattsInMenuBar ? .on : .off
        menu.addItem(wattsItem)

        fixedWidthItem = item("固定菜单栏宽度（防抖动）", #selector(toggleFixedWidth))
        fixedWidthItem.state = settings.fixedMenuBarWidth ? .on : .off
        menu.addItem(fixedWidthItem)

        launchAtLoginItem = item("登录时自动启动", #selector(toggleLaunchAtLogin))
        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        menu.addItem(item("打开日志", #selector(openLog)))
        menu.addItem(item("显示配置文件", #selector(showConfig)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit)))
    }

    private func wireStatusItemButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isSecondary {
            refreshMenuState()
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            panel.toggle(relativeTo: statusItem.button)
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    @objc private func showPanel() {
        panel.toggle(relativeTo: statusItem.button)
    }

    @objc private func togglePin() {
        settings.pinPanel.toggle()
        panel.model.pinned = settings.pinPanel
        pinItem.state = settings.pinPanel ? .on : .off
        try? settings.save()
    }

    @objc private func selectScene(_ sender: NSMenuItem) {
        setScene(sender.tag)
    }

    @objc private func reconnect() {
        guard let s = session else { return }
        Task { await s.reconnectNow() }
    }

    @objc private func toggleWatts() {
        settings.showWattsInMenuBar.toggle()
        wattsItem.state = settings.showWattsInMenuBar ? .on : .off
        try? settings.save()
        updateTitle(force: true)
    }

    @objc private func toggleFixedWidth() {
        settings.fixedMenuBarWidth.toggle()
        fixedWidthItem.state = settings.fixedMenuBarWidth ? .on : .off
        statusItem.length = settings.fixedMenuBarWidth ? 58 : NSStatusItem.variableLength
        try? settings.save()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            launchAtLoginItem.state = (service.status == .enabled) ? .on : .off
        } catch {
            log.write("[tray] 切换开机自启失败（非 .app 包调试运行属正常现象）：\(error)")
        }
    }

    @objc private func runWizard() {
        showWizard()
    }

    func showWizardIfNeeded() {
        guard !settings.isComplete else { return }
        log.write("[tray] 配置不全，先弹向导：\(AppSettings.fileURL.path)")
        showWizard()
    }

    private func showWizard() {
        WizardController.show(settings: settings) { [weak self] newSettings in
            guard let self else { return }
            self.log.write("[tray] 向导写完配置，重建会话")
            if let old = self.session {
                Task { await old.stop() }
            }
            self.session = nil
            self.settings = newSettings
            self.bootSession()
            self.updateTitle(force: true)
        }
    }

    @objc private func openLog() {
        let url = AppSettings.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func showConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.fileURL])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 面板回调

    private func wirePanel() {
        panel.onVisibilityChanged = { [weak self] visible in
            guard let self, let s = self.session else { return }
            Task { await s.setPanelOpen(visible) }
        }
        panel.model.onReconnect = { [weak self] in self?.reconnect() }
        panel.model.onTogglePin = { [weak self] in self?.togglePin() }
        panel.model.onQuit = { NSApp.terminate(nil) }
        panel.model.onSetPort = { [weak self] zeroBasedIndex, on in self?.setPort(zeroBasedIndex, on) }
        panel.model.onSetScene = { [weak self] mode in self?.setScene(mode) }
    }

    private func setPort(_ zeroBasedIndex: Int, _ on: Bool) {
        guard let s = session else {
            panel.model.optimisticPorts.removeValue(forKey: zeroBasedIndex)
            return
        }
        desiredPortStates[zeroBasedIndex] = on
        if portSyncTasks[zeroBasedIndex] != nil {
            log.write("[panel] 快速连击端口 \(zeroBasedIndex) 合并目标 -> \(on ? "通电" : "断电")")
            return
        }

        portSyncTasks[zeroBasedIndex] = Task { @MainActor [weak self] in
            guard let self else { return }
            while let targetOn = self.desiredPortStates.removeValue(forKey: zeroBasedIndex) {
                let started = Date()
                self.log.write("[panel] 设置端口 \(zeroBasedIndex) -> \(targetOn ? "通电" : "断电")")
                do {
                    try await s.setPortEnabled(zeroBasedIndex, targetOn)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    self.log.write("[panel] 设置端口 \(zeroBasedIndex) 成功 (\(ms)ms)")
                } catch {
                    let msg = "端口控制失败：\(error)"
                    self.log.write("[panel] \(msg)")
                    self.panel.model.showFeedback(msg)
                    break
                }
            }
            self.portSyncTasks.removeValue(forKey: zeroBasedIndex)
            self.panel.model.optimisticPorts.removeValue(forKey: zeroBasedIndex)
        }
    }

    private func setScene(_ mode: Int) {
        guard let s = session else {
            panel.model.optimisticSceneMode = nil
            panel.model.syncingScene = false
            return
        }
        // 合并快速连击（Latest-Wins）：若前一次写入还在跑，只更新目标档位，不堆积蓝牙队列
        desiredSceneMode = mode
        panel.model.syncingScene = true
        if sceneSyncTask != nil {
            log.write("[panel] 快速连击合并目标 -> \(mode) (\(SceneMode.name(mode)))")
            return
        }

        sceneSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let targetMode = self.desiredSceneMode {
                self.desiredSceneMode = nil
                let started = Date()
                self.log.write("[panel] 切换充电模式 -> \(targetMode) (\(SceneMode.name(targetMode)))")
                do {
                    try await s.setSceneMode(targetMode)
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    self.log.write("[panel] 切换充电模式 -> \(targetMode) 成功 (\(ms)ms)")
                } catch {
                    let msg = "切换模式失败：\(error)"
                    self.log.write("[panel] \(msg)")
                    self.panel.model.showFeedback(msg)
                    break
                }
            }
            self.sceneSyncTask = nil
            self.panel.model.syncingScene = false
            self.panel.model.optimisticSceneMode = nil
        }
    }
}
