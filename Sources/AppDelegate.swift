import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, RateLimitStoreDelegate {
    private enum OpacitySetting {
        case background
        case content
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = RateLimitStore()
    private var hudAppearance = HUDAppearance.load()
    private var hudVisibilityMenuItem: NSMenuItem?
    private var touchBarMenuItem: NSMenuItem?
    private var menuBarIconOnlyMenuItem: NSMenuItem?
    private var lastState = RateLimitDisplayState.initial
    private var workspaceObserver: Any?
    private var colorMenuItems: [HUDAppearance.ColorChoice: NSMenuItem] = [:]
    private var backgroundOpacityMenuItems: [Double: NSMenuItem] = [:]
    private var contentOpacityMenuItems: [Double: NSMenuItem] = [:]
    private lazy var hudController = CompactHUDViewController(
        initialAppearance: hudAppearance,
        onRefresh: { [weak self] in
            self?.refreshQuotaNow()
        },
        onQuit: { [weak self] in
            self?.quitFromHUD()
        },
        onCollapseTouchBar: { [weak self] in
            self?.setTouchBarDisplay(false)
        },
        contextMenuProvider: { [weak self] in
            self?.makeHUDContextMenu() ?? NSMenu()
        }
    )
    private lazy var hudWindow = CompactHUDPanel(contentViewController: hudController)

    private var touchBarDisplayEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "settings.touchbar.enabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "settings.touchbar.enabled")
        }
    }

    private var menuBarIconOnly: Bool {
        get {
            UserDefaults.standard.object(forKey: "settings.menubar.iconOnly") as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "settings.menubar.iconOnly")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store.delegate = self
        configureStatusItem()
        ZCodeAutoLauncher.installOrUpdate()
        ZCodeAutoLauncher.clearManualQuitLock()

        store.start()
        observeFrontmostApplication()

        // TouchBar 触摸事件只派发给激活过的 app：启动时激活一次即可。
        // 之后跟随前台自动呈现时不可再激活，否则会抢走 ZCode 的输入焦点
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        store.stop()
    }

    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState) {
        lastState = state
        updateStatusTitle(with: state)
        hudController.update(with: state)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.image = Self.menuBarIcon()
        button.imagePosition = .imageLeft
        button.title = menuBarIconOnly ? "" : " --"
        button.toolTip = "ZCode 额度"

        statusItem.menu = makeStatusMenu()
        updateMenuState()
    }

    /// ZCode 桌面端安装路径与 bundle id（图标、前台判定共用）
    private static let zcodeAppPath = "/Applications/ZCode.app"
    private static let zcodeBundleID = Bundle(url: URL(fileURLWithPath: zcodeAppPath))?.bundleIdentifier

    /// 菜单栏用 ZCode 应用图标（与 Touch Bar 视图同源），缩放到菜单栏标准尺寸
    private static func menuBarIcon() -> NSImage {
        let image: NSImage
        if FileManager.default.fileExists(atPath: zcodeAppPath) {
            image = NSWorkspace.shared.icon(forFile: zcodeAppPath)
        } else {
            image = Bundle.main.image(forResource: "AppIcon")
                ?? NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: "ZQuota")
                ?? NSImage()
        }
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = false
        return image
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let visibilityItem = NSMenuItem(
            title: "隐藏浮窗",
            action: #selector(toggleHUDWindow(_:)),
            keyEquivalent: ""
        )
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        hudVisibilityMenuItem = visibilityItem

        let touchBarItem = NSMenuItem(
            title: "显示在 Touch Bar",
            action: #selector(toggleTouchBarDisplay(_:)),
            keyEquivalent: ""
        )
        touchBarItem.target = self
        menu.addItem(touchBarItem)
        touchBarMenuItem = touchBarItem

        let refreshItem = NSMenuItem(
            title: "刷新额度",
            action: #selector(refreshQuotaFromMenu(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        menu.setSubmenu(makeAppearanceSettingsMenu(registerItems: true), for: settingsItem)
        menu.addItem(settingsItem)
        if let versionItem = makeVersionItem() {
            menu.addItem(versionItem)
        }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeHUDContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(
            title: "隐藏浮窗",
            action: #selector(hideHUDFromContextMenu(_:)),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        let refreshItem = NSMenuItem(
            title: "刷新额度",
            action: #selector(refreshQuotaFromMenu(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        menu.setSubmenu(makeAppearanceSettingsMenu(registerItems: false), for: settingsItem)
        menu.addItem(settingsItem)
        if let versionItem = makeVersionItem() {
            menu.addItem(versionItem)
        }
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeAppearanceSettingsMenu(registerItems: Bool) -> NSMenu {
        let settingsMenu = NSMenu(title: "设置")

        let menuBarHeader = NSMenuItem(title: "菜单栏", action: nil, keyEquivalent: "")
        menuBarHeader.isEnabled = false
        settingsMenu.addItem(menuBarHeader)

        let iconOnlyItem = NSMenuItem(
            title: "仅显示图标",
            action: #selector(toggleMenuBarIconOnly(_:)),
            keyEquivalent: ""
        )
        iconOnlyItem.target = self
        iconOnlyItem.state = menuBarIconOnly ? .on : .off
        settingsMenu.addItem(iconOnlyItem)
        if registerItems {
            menuBarIconOnlyMenuItem = iconOnlyItem
        }

        settingsMenu.addItem(.separator())

        let colorHeader = NSMenuItem(title: "浮窗颜色", action: nil, keyEquivalent: "")
        colorHeader.isEnabled = false
        settingsMenu.addItem(colorHeader)

        for colorChoice in HUDAppearance.ColorChoice.allCases {
            let item = NSMenuItem(
                title: colorChoice.title,
                action: #selector(selectHUDColor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = colorChoice.rawValue
            item.state = colorChoice == hudAppearance.colorChoice ? .on : .off
            settingsMenu.addItem(item)
            if registerItems {
                colorMenuItems[colorChoice] = item
            }
        }

        settingsMenu.addItem(.separator())

        let backgroundOpacityItem = NSMenuItem(title: "背景透明度", action: nil, keyEquivalent: "")
        settingsMenu.setSubmenu(
            makeOpacityMenu(for: .background, registerItems: registerItems),
            for: backgroundOpacityItem
        )
        settingsMenu.addItem(backgroundOpacityItem)

        let contentOpacityItem = NSMenuItem(title: "文字透明度", action: nil, keyEquivalent: "")
        settingsMenu.setSubmenu(
            makeOpacityMenu(for: .content, registerItems: registerItems),
            for: contentOpacityItem
        )
        settingsMenu.addItem(contentOpacityItem)

        return settingsMenu
    }

    /// 版本号菜单项（禁用态）；版本由打包脚本写入 Info.plist，swift run 开发环境无此值则不显示
    private func makeVersionItem() -> NSMenuItem? {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        let item = NSMenuItem(title: "ZQuota v\(version)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeOpacityMenu(for setting: OpacitySetting, registerItems: Bool) -> NSMenu {
        let menu = NSMenu(title: setting == .background ? "背景透明度" : "文字透明度")
        let currentOpacity: Double
        let action: Selector

        switch setting {
        case .background:
            currentOpacity = hudAppearance.backgroundOpacity
            action = #selector(selectHUDBackgroundOpacity(_:))
        case .content:
            currentOpacity = hudAppearance.contentOpacity
            action = #selector(selectHUDContentOpacity(_:))
        }

        for opacity in HUDAppearance.opacityChoices {
            let item = NSMenuItem(
                title: "\(Int((opacity * 100).rounded()))%",
                action: action,
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: opacity)
            item.state = abs(opacity - currentOpacity) < 0.001 ? .on : .off
            menu.addItem(item)
            if registerItems {
                switch setting {
                case .background:
                    backgroundOpacityMenuItems[opacity] = item
                case .content:
                    contentOpacityMenuItems[opacity] = item
                }
            }
        }

        return menu
    }

    private func updateStatusTitle(with state: RateLimitDisplayState) {
        guard let button = statusItem.button else {
            return
        }

        var titleParts: [String] = []
        var tooltipParts: [String] = []

        if let fiveHour = state.fiveHour {
            titleParts.append("\(fiveHour.shortTitle) \(fiveHour.remainingText)")
            tooltipParts.append("5 小时剩余 \(fiveHour.remainingText)")
        }

        if let weekly = state.weekly {
            titleParts.append("\(weekly.shortTitle) \(weekly.remainingText)")
            tooltipParts.append("周限额剩余 \(weekly.remainingText)")
        }

        if let usage = state.usage {
            tooltipParts.append("MCP 工具剩余 \(usage.mcpRemaining.map(String.init) ?? "--") 次，档位 \(usage.level ?? "--")")
        }

        if !titleParts.isEmpty {
            let stalePrefix = state.isStale ? "⚠ " : ""
            button.title = menuBarIconOnly ? "" : " \(stalePrefix)\(titleParts.joined(separator: "  "))"
            var tooltip = "ZCode 额度：\(tooltipParts.joined(separator: "，"))"
            if state.isStale, let lastUpdated = state.lastUpdated {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                tooltip += "（⚠ 数据已过期，上次成功刷新 \(formatter.string(from: lastUpdated))）"
            }
            button.toolTip = tooltip
        } else if state.isRefreshing {
            button.title = menuBarIconOnly ? "" : " ..."
            button.toolTip = "ZCode 额度：正在刷新"
        } else {
            button.title = menuBarIconOnly ? "" : " --"
            button.toolTip = state.errorMessage ?? "ZCode 额度"
        }
    }

    @objc private func toggleHUDWindow(_ sender: AnyObject?) {
        if hudWindow.isVisible {
            hudWindow.orderOut(sender)
        } else {
            showHUDWindow()
        }
        updateMenuState()
    }

    @objc private func toggleTouchBarDisplay(_ sender: AnyObject?) {
        setTouchBarDisplay(!touchBarDisplayEnabled)
    }

    @objc private func toggleMenuBarIconOnly(_ sender: AnyObject?) {
        menuBarIconOnly.toggle()
        menuBarIconOnlyMenuItem?.state = menuBarIconOnly ? .on : .off
        updateStatusTitle(with: lastState)
    }

    private func setTouchBarDisplay(_ enabled: Bool) {
        touchBarDisplayEnabled = enabled
        if enabled, let app = NSWorkspace.shared.frontmostApplication {
            syncTouchBarPresence(with: app)
        } else {
            hudController.dismissTouchBarFromSystem()
        }
        updateMenuState()
    }

    // MARK: - TouchBar 跟随前台应用

    /// 系统 TouchBar 只有一块：额度条以系统模态方式呈现时会遮挡其他应用的
    /// TouchBar 内容（微信、Trae 等）。因此仅当 ZCode 桌面端处于前台时呈现，
    /// 切到其他应用自动让位，回到 ZCode 自动恢复。
    private func observeFrontmostApplication() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self.syncTouchBarPresence(with: app)
        }

        // 启动时按当前前台应用决定初始呈现状态
        if let app = NSWorkspace.shared.frontmostApplication {
            syncTouchBarPresence(with: app)
        }
    }

    private func syncTouchBarPresence(with app: NSRunningApplication) {
        // 自身激活（启动时的 activate、点击 HUD 等）不代表离开 ZCode 使用场景
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        if touchBarDisplayEnabled, Self.isZCodeApp(app) {
            if !hudController.isTouchBarPresentedOnSystem {
                hudController.presentTouchBarOnSystem()
            }
        } else {
            hudController.dismissTouchBarFromSystem()
        }
    }

    /// ZCode 桌面端判定：优先按安装路径，其次按从 /Applications/ZCode.app 读取的 bundle id
    private static func isZCodeApp(_ app: NSRunningApplication) -> Bool {
        if app.bundleURL?.path == zcodeAppPath {
            return true
        }
        guard let zcodeBundleID,
              let bundleID = app.bundleIdentifier else {
            return false
        }
        return bundleID == zcodeBundleID
    }

    private func showHUDWindow() {
        hudWindow.orderFrontPinned()
        hudController.activateTouchBar()
        updateMenuState()
    }

    private func refreshQuotaNow() {
        store.start()
    }

    private func quitFromHUD() {
        // HUD 上的 × 仅隐藏浮窗；退出应用走菜单「退出」
        hudWindow.orderOut(nil)
        updateMenuState()
    }

    @objc private func refreshQuotaFromMenu(_ sender: AnyObject?) {
        refreshQuotaNow()
    }

    @objc private func hideHUDFromContextMenu(_ sender: AnyObject?) {
        hudWindow.orderOut(sender)
        updateMenuState()
    }

    @objc private func quitFromMenu(_ sender: AnyObject?) {
        quitApp()
    }

    @objc private func selectHUDColor(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let colorChoice = HUDAppearance.ColorChoice(rawValue: rawValue) else {
            return
        }

        hudAppearance.colorChoice = colorChoice
        applyHUDAppearance()
    }

    @objc private func selectHUDBackgroundOpacity(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else {
            return
        }

        hudAppearance.backgroundOpacity = number.doubleValue
        applyHUDAppearance()
    }

    @objc private func selectHUDContentOpacity(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else {
            return
        }

        hudAppearance.contentOpacity = number.doubleValue
        applyHUDAppearance()
    }

    private func applyHUDAppearance() {
        hudAppearance.save()
        hudController.updateAppearance(hudAppearance)
        updateMenuState()
    }

    private func updateMenuState() {
        hudVisibilityMenuItem?.title = hudWindow.isVisible ? "隐藏浮窗" : "显示浮窗"
        touchBarMenuItem?.state = touchBarDisplayEnabled ? .on : .off

        for (colorChoice, item) in colorMenuItems {
            item.state = colorChoice == hudAppearance.colorChoice ? .on : .off
        }

        for (opacity, item) in backgroundOpacityMenuItems {
            item.state = abs(opacity - hudAppearance.backgroundOpacity) < 0.001 ? .on : .off
        }

        for (opacity, item) in contentOpacityMenuItems {
            item.state = abs(opacity - hudAppearance.contentOpacity) < 0.001 ? .on : .off
        }
    }

    private func quitApp() {
        ZCodeAutoLauncher.markManualQuit()
        hudWindow.orderOut(nil)
        store.stop()
        NSApp.terminate(nil)
    }
}
