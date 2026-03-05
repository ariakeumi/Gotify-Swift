import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DefaultsKeys {
        static let askedLaunchAtLogin = "gotify.askedLaunchAtLogin"
    }

    private var statusItem: NSStatusItem?
    private let statusPopover = NSPopover()
    private weak var viewModel: MainViewModel?
    private var windowObservers: [NSObjectProtocol] = []
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var openMainWindowHandler: (() -> Void)?
    private var openMessageHandler: ((Int) -> Void)?

    func configure(with viewModel: MainViewModel) {
        self.viewModel = viewModel
        statusPopover.contentViewController = NSHostingController(
            rootView: StatusBarPopoverView(
                viewModel: viewModel,
                onSelectMessage: { [weak self] messageID in
                    self?.openMessageFromStatusBar(messageID)
                }
            )
        )
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
        setupWindowObservers()
        updateActivationPolicyForWindows()
        requestLaunchAtLoginIfNeeded()
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
        if statusPopover.isShown {
            statusPopover.performClose(sender)
            removeDismissMonitors()
        } else {
            if let viewModel {
                statusPopover.contentViewController = NSHostingController(
                    rootView: StatusBarPopoverView(
                        viewModel: viewModel,
                        onSelectMessage: { [weak self] messageID in
                            self?.openMessageFromStatusBar(messageID)
                        }
                    )
                )
            }
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installDismissMonitors()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let statusImage = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: "Gotify Mail")
        statusImage?.size = NSSize(width: 18, height: 18)
        statusImage?.isTemplate = true
        item.button?.image = statusImage
        item.button?.action = #selector(onStatusItemClick(_:))
        item.button?.target = self
        statusItem = item

        statusPopover.behavior = .transient
        statusPopover.animates = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPopoverDidClose(_:)),
            name: NSPopover.didCloseNotification,
            object: statusPopover
        )
    }

    @objc
    private func onPopoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
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

    private func requestLaunchAtLoginIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKeys.askedLaunchAtLogin) else { return }
        defaults.set(true, forKey: DefaultsKeys.askedLaunchAtLogin)

        let alert = NSAlert()
        alert.messageText = "开机启动"
        alert.informativeText = "是否允许 Gotify 在登录 macOS 后自动启动并后台运行？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "允许")
        alert.addButton(withTitle: "暂不")

        if alert.runModal() == .alertFirstButtonReturn {
            enableLaunchAtLogin()
        }
    }

    private func enableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            let alert = NSAlert()
            alert.messageText = "开机启动设置失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.statusPopover.performClose(nil)
            self?.removeDismissMonitors()
        }

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.statusPopover.isShown else { return event }

            let popoverWindow = self.statusPopover.contentViewController?.view.window
            let statusButtonWindow = self.statusItem?.button?.window
            let clickedWindow = event.window

            if clickedWindow !== popoverWindow && clickedWindow !== statusButtonWindow {
                self.statusPopover.performClose(nil)
                self.removeDismissMonitors()
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
        statusPopover.performClose(nil)

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

    deinit {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        center.removeObserver(self, name: NSPopover.didCloseNotification, object: statusPopover)
        removeDismissMonitors()
    }
}
