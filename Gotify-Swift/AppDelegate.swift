import AppKit
import SwiftUI
import CoreServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    // 无边框、不抢焦点的下拉面板;相比 NSPopover 没有指向箭头。
    private lazy var statusPanel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()
    private weak var viewModel: MainViewModel?
    private var windowObservers: [NSObjectProtocol] = []
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var openMainWindowHandler: (() -> Void)?
    private var openMessageHandler: ((Int) -> Void)?
    private var unreadCountObserver: NSObjectProtocol?
    private var hasUnreadNotifications = false
    // 调试用:--preview-unread 强制保持未读态,不被真实未读数覆盖
    private let forceUnreadPreview = ProcessInfo.processInfo.arguments.contains("--preview-unread")
    private var unreadEyesOverlay: NSView?
    private var statusRightClickMonitor: Any?
    private let launchedAsLoginItem = AppDelegate.detectLaunchedAsLoginItem()
    private var didSuppressInitialMainWindow = false

    func configure(with viewModel: MainViewModel) {
        self.viewModel = viewModel
        if let window = mainWindow(), window.isVisible {
            viewModel.mainWindowDidOpen()
        }
    }

    func setOpenMainWindowHandler(_ handler: @escaping () -> Void) {
        openMainWindowHandler = handler
    }

    func setOpenMessageHandler(_ handler: @escaping (Int) -> Void) {
        openMessageHandler = handler
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationService.shared.requestAuthorizationIfNeeded()
        setupStatusItem()
        setupUnreadBadgeObserver()
        setupWindowObservers()
        updateActivationPolicyForWindows()
        NotificationService.shared.refreshUnreadCount()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in background when all windows are closed.
        false
    }

    @objc
    private func onStatusItemClick(_ sender: AnyObject?) {
        if NSApp.currentEvent?.clickCount == 2 {
            openMainWindow()
            return
        }

        guard let button = statusItem?.button else { return }
        if statusPanel.isVisible {
            closeStatusPanel()
        } else if let viewModel {
            showStatusPanel(viewModel: viewModel)
        }
    }

    private func makeStatusContextMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: L10n.text("statusbar.open_main_window"),
            action: #selector(openMainWindowFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.text("statusbar.quit"),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func openMainWindowFromMenu() {
        openMainWindow()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func makeStatusPanelContent(viewModel: MainViewModel) -> NSHostingController<StatusBarPopoverView> {
        NSHostingController(
            rootView: StatusBarPopoverView(
                viewModel: viewModel,
                onSelectMessage: { [weak self] messageID in
                    self?.openMessageFromStatusBar(messageID)
                }
            )
        )
    }

    private func showStatusPanel(viewModel: MainViewModel) {
        let content = makeStatusPanelContent(viewModel: viewModel)
        statusPanel.contentViewController = content
        let contentSize = content.view.fittingSize
        statusPanel.setContentSize(contentSize)

        // 图标下方水平居中弹出;靠近屏幕边缘时收进可视区域内
        if let button = statusItem?.button, let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var topLeftX = buttonRect.midX - contentSize.width / 2
            if let visibleFrame = buttonWindow.screen?.visibleFrame {
                topLeftX = max(visibleFrame.minX + 8,
                               min(topLeftX, visibleFrame.maxX - contentSize.width - 8))
            }
            statusPanel.setFrameTopLeftPoint(
                NSPoint(x: topLeftX, y: buttonRect.minY - 8)
            )
        }

        statusPanel.orderFront(nil)
        NotificationService.shared.clearDeliveredGotifyNotifications()
        installDismissMonitors()
    }

    private func closeStatusPanel() {
        statusPanel.orderOut(nil)
        statusPanel.contentViewController = nil
        removeDismissMonitors()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeBaseStatusImage()
        item.button?.imagePosition = .imageOnly
        item.button?.action = #selector(onStatusItemClick(_:))
        item.button?.target = self
        statusItem = item
        item.button?.menu = makeStatusContextMenu()   // 辅助功能(AXShowMenu)路径
        installStatusRightClickMonitor()              // 真实右键 / 触控板双指点按
        installUnreadEyesOverlayIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("--preview-unread") {
            hasUnreadNotifications = true             // 调试用:直接以未读态启动
            updateUnreadEyes()
        }
    }

    /// NSStatusBarButton 不会因 button.menu 在真实右键时弹菜单,
    /// 所以在事件到达按钮前拦截 rightMouseDown(触控板双指点按即此事件)。
    private func installStatusRightClickMonitor() {
        guard statusRightClickMonitor == nil else { return }
        statusRightClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self,
                  let button = self.statusItem?.button,
                  event.window === button.window else { return event }

            let isRightClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            if isRightClick {
                self.showStatusContextMenu()
                return nil   // 消费掉,避免再触发左键 action
            }
            return event
        }
    }

    private func showStatusContextMenu() {
        closeStatusPanel()

        // 临时把 menu 挂到状态项上:此时点击按钮只弹菜单、不触发左键 action
        statusItem?.menu = makeStatusContextMenu()
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func setupUnreadBadgeObserver() {
        unreadCountObserver = NotificationCenter.default.addObserver(
            forName: NotificationService.unreadCountDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let unreadCount = notification.object as? Int ?? 0
            guard let self, !self.forceUnreadPreview,
                  self.hasUnreadNotifications != (unreadCount > 0) else { return }
            self.hasUnreadNotifications = unreadCount > 0
            self.updateUnreadEyes()
        }
    }

    private func setupWindowObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ]

        windowObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if let window = notification.object as? NSWindow,
                   window.identifier?.rawValue == "main-window" {
                    if notification.name == NSWindow.willCloseNotification {
                        self?.viewModel?.mainWindowWillClose()
                    } else if notification.name == NSWindow.didBecomeKeyNotification
                                || notification.name == NSWindow.didBecomeMainNotification {
                        self?.viewModel?.mainWindowDidOpen()
                    }
                }
                DispatchQueue.main.async {
                    self?.clearNotificationsIfMainWindowForegrounded(notification)
                    self?.updateActivationPolicyForWindows()
                }
            }
        }
    }

    private func updateActivationPolicyForWindows() {
        let hasVisibleNormalWindow = NSApp.windows.contains { window in
            window.isVisible &&
            !window.isMiniaturized &&
            window.level == .normal &&
            window.styleMask.contains(.titled)
        }

        let targetPolicy: NSApplication.ActivationPolicy = hasVisibleNormalWindow ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            _ = NSApp.setActivationPolicy(targetPolicy)
        }
        if !hasVisibleNormalWindow {
            NSApp.hide(nil)
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closeStatusPanel()
        }

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.statusPanel.isVisible else { return event }

            let statusButtonWindow = self.statusItem?.button?.window
            let clickedWindow = event.window

            if clickedWindow !== self.statusPanel && clickedWindow !== statusButtonWindow {
                self.closeStatusPanel()
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
    }

    private func openMainWindow(andThen completion: (() -> Void)? = nil) {
        removeDismissMonitors()
        closeStatusPanel()

        _ = NSApp.setActivationPolicy(.regular)

        if mainWindow() == nil {
            openMainWindowHandler?()
        }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let window = self.mainWindow() {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            completion?()
        }
    }

    private func openMessageFromStatusBar(_ messageID: Int) {
        openMainWindow { [weak self] in
            self?.openMessageHandler?(messageID)
        }
    }

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "main-window" })
    }

    private func clearNotificationsIfMainWindowForegrounded(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            window.identifier?.rawValue == "main-window"
        else { return }

        if notification.name == NSWindow.didBecomeKeyNotification || notification.name == NSWindow.didBecomeMainNotification {
            NotificationService.shared.clearDeliveredGotifyNotifications()
        }
    }

    private func makeBaseStatusImage() -> NSImage? {
        guard let image = NSImage(named: "StatusBarIcon") else { return nil }
        let ratio = image.size.height / image.size.width
        image.size = NSSize(width: 18, height: 18 * ratio)
        image.isTemplate = true
        image.accessibilityDescription = "Gotify"
        return image
    }

    /// 未读红眼:身体保持模板图(由系统按菜单栏实际着色渲染),
    /// 在镂空眼睛的位置叠加一层红色圆点视图,未读时显示。
    private func installUnreadEyesOverlayIfNeeded() {
        guard unreadEyesOverlay == nil,
              let button = statusItem?.button,
              let imageSize = button.image?.size else { return }
        let overlay = UnreadEyesOverlayView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(overlay)
        // 图标在按钮内居中,overlay 覆盖图标区域即可对准镂空眼睛
        NSLayoutConstraint.activate([
            overlay.widthAnchor.constraint(equalToConstant: imageSize.width),
            overlay.heightAnchor.constraint(equalToConstant: imageSize.height),
            overlay.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        overlay.isHidden = true
        unreadEyesOverlay = overlay
    }

    private func updateUnreadEyes() {
        unreadEyesOverlay?.isHidden = !hasUnreadNotifications
    }

    func configureMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("main-window")

        guard launchedAsLoginItem, !didSuppressInitialMainWindow else { return }
        didSuppressInitialMainWindow = true

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.orderOut(nil)
            window.close()
            self.updateActivationPolicyForWindows()
        }
    }

    private static func detectLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }

    deinit {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        if let unreadCountObserver {
            center.removeObserver(unreadCountObserver)
        }
        if let statusRightClickMonitor {
            NSEvent.removeMonitor(statusRightClickMonitor)
        }
        removeDismissMonitors()
    }
}

/// 未读红眼叠加层:覆盖在状态栏图标的图像区域上,
/// 按方案 2 地鼠头像的眼睛占比画两个红色圆点。
/// 坐标为图像宽高比例(眼睛中心 x=0.338/0.662,距顶 0.4575,半径 0.0926×宽),
/// 圆点略大于镂空孔径以盖住抗锯齿边缘。
private final class UnreadEyesOverlayView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        NSColor.systemRed.setFill()
        let radius = 0.0926 * bounds.width * 1.18
        for cx in [0.338, 0.662] {
            let rect = NSRect(
                x: cx * bounds.width - radius,
                y: (1 - 0.4575) * bounds.height - radius,
                width: radius * 2,
                height: radius * 2
            )
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}
