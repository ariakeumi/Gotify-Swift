import AppKit
import SwiftUI
import CoreServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusPopover = NSPopover()
    private weak var viewModel: MainViewModel?
    private var windowObservers: [NSObjectProtocol] = []
    private var globalDismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var openMainWindowHandler: (() -> Void)?
    private var openMessageHandler: ((Int) -> Void)?
    private var unreadCountObserver: NSObjectProtocol?
    private var unreadBadgeView: NSView?
    private let launchedAsLoginItem = AppDelegate.detectLaunchedAsLoginItem()
    private var didSuppressInitialMainWindow = false

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
            NotificationService.shared.clearDeliveredGotifyNotifications()
            installDismissMonitors()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeBaseStatusImage()
        item.button?.imagePosition = .imageOnly
        item.button?.action = #selector(onStatusItemClick(_:))
        item.button?.target = self
        statusItem = item
        installUnreadBadgeViewIfNeeded()
        updateUnreadBadgeVisibility(hasUnread: false)

        statusPopover.behavior = .transient
        statusPopover.animates = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onPopoverDidClose(_:)),
            name: NSPopover.didCloseNotification,
            object: statusPopover
        )
    }

    private func setupUnreadBadgeObserver() {
        unreadCountObserver = NotificationCenter.default.addObserver(
            forName: NotificationService.unreadCountDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let unreadCount = notification.object as? Int ?? 0
            self?.updateUnreadBadgeVisibility(hasUnread: unreadCount > 0)
        }
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

    private func makeBaseStatusImage() -> NSImage? {
        guard let image = NSImage(named: "StatusBarIcon") else { return nil }
        let ratio = image.size.height / image.size.width
        image.size = NSSize(width: 18, height: 18 * ratio)
        image.isTemplate = true
        image.accessibilityDescription = "Gotify"
        return image
    }

    private func installUnreadBadgeViewIfNeeded() {
        guard unreadBadgeView == nil, let button = statusItem?.button else { return }
        let badgeView = NSView(frame: NSRect(x: 14, y: 14, width: 8, height: 8))
        badgeView.wantsLayer = true
        badgeView.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeView.layer?.cornerRadius = 4
        badgeView.layer?.borderWidth = 1
        badgeView.layer?.borderColor = NSColor.white.cgColor
        badgeView.isHidden = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: 8),
            badgeView.heightAnchor.constraint(equalToConstant: 8),
            badgeView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
            badgeView.topAnchor.constraint(equalTo: button.topAnchor, constant: 3)
        ])
        unreadBadgeView = badgeView
    }

    private func updateUnreadBadgeVisibility(hasUnread: Bool) {
        if statusItem?.button?.image == nil {
            statusItem?.button?.image = makeBaseStatusImage()
        }
        unreadBadgeView?.isHidden = !hasUnread
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
        center.removeObserver(self, name: NSPopover.didCloseNotification, object: statusPopover)
        removeDismissMonitors()
    }
}
