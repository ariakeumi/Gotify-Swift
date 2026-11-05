import AppKit
import Foundation

@MainActor
func runNativeMessageListTests(_ viewModel: MainViewModel) async throws {
    _ = NSApplication.shared
    let controller = MessageListController(toolbarClearance: 52)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.scrollView
    defer {
        controller.stop()
        window.close()
    }
    func layout() {
        controller.update(viewModel: viewModel)
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.tableView.layoutSubtreeIfNeeded()
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Native message list timed out")
    }

    layout()
    precondition(controller.tableView.numberOfRows == 31)
    precondition(controller.scrollView.documentView === controller.tableView)
    func checkScrollerGeometry() {
        let scroll = controller.scrollView
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        let scroller = scroll.verticalScroller!
        let track = scroll.convert(scroller.bounds, from: scroller)
        precondition(!scroller.isHidden)
        precondition(abs(track.minY - scroll.contentInsets.top) < 1)
        precondition(abs(track.maxY - (scroll.bounds.height - scroll.contentInsets.bottom)) < 1)
        precondition(abs(track.maxX - scroll.bounds.width) < 1)
    }
    let originalScrollerStyle = controller.scrollView.scrollerStyle
    for style in [NSScroller.Style.overlay, .legacy] {
        controller.scrollView.scrollerStyle = style
        layout()
        checkScrollerGeometry()
    }
    controller.scrollView.scrollerStyle = originalScrollerStyle
    layout()
    print("PASS: overlay and legacy scrollers stay at the right edge with one toolbar clearance")
    let firstID = controller.messages[0].id
    let firstRect = controller.tableView.rect(ofRow: 0)
    let firstCell = controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as! MessageTableCellView
    precondition(!firstCell.subviews.contains { String(describing: type(of: $0)).contains("Hosting") })
    let textViews = firstCell.subviews.compactMap { $0 as? NSTextView }
    precondition(!textViews.isEmpty && textViews.allSatisfy { !$0.isEditable && $0.isSelectable })
    let text = textViews[0].attributedString()
    var foundLink = false
    text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if value != nil { foundLink = true }
    }
    precondition(foundLink)
    print("PASS: native scroll/table/cells, selectable Markdown text and clickable links")

    if let path = ProcessInfo.processInfo.environment["GOTIFY_LIST_SNAPSHOT_PATH"],
       let bitmap = controller.scrollView.bitmapImageRepForCachingDisplay(in: controller.scrollView.bounds) {
        controller.scrollView.cacheDisplay(in: controller.scrollView.bounds, to: bitmap)
        let opaque = NSImage(size: bitmap.size)
        opaque.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: bitmap.size).fill()
        let transparent = NSImage(size: bitmap.size)
        transparent.addRepresentation(bitmap)
        transparent.draw(in: NSRect(origin: .zero, size: bitmap.size), from: .zero, operation: .sourceOver, fraction: 1)
        opaque.unlockFocus()
        let data = opaque.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        try data?.write(to: URL(fileURLWithPath: path))
    }

    let expandButton = firstCell.subviews.compactMap { $0 as? NSButton }.first { $0.title == L10n.text("message.expand") }!
    expandButton.performClick(nil)
    try await waitUntil { controller.tableView.rect(ofRow: 0).height > firstRect.height }
    precondition(controller.expandedMessageIDs.contains(firstID))
    controller.toggleExpanded(firstID)
    precondition(controller.tableView.rect(ofRow: 0).height == firstRect.height)
    print("PASS: async full Markdown expansion and collapsed row height restoration")

    let targetRow = 10
    let anchorID = controller.messages[targetRow].id
    controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: controller.tableView.rect(ofRow: targetRow).minY + 3))
    let anchorY = controller.scrollView.contentView.bounds.minY
    layout()
    precondition(abs(controller.scrollView.contentView.bounds.minY - anchorY) < 1)
    // Resizing must recalculate wrapped text without moving the first visible message.
    window.setContentSize(NSSize(width: 420, height: 520))
    layout()
    checkScrollerGeometry()
    let visibleRow = controller.tableView.rows(in: controller.tableView.visibleRect).location
    precondition(controller.messages[visibleRow].id == anchorID)
    precondition(controller.tableView.rect(ofRow: 0).height > firstRect.height)
    print("PASS: stable scroll position during updates and width-dependent native row heights")

    viewModel.searchText = "no-such-native-message"
    layout()
    precondition(controller.messages.isEmpty && controller.tableView.numberOfRows == 1)
    try await Task.sleep(for: .milliseconds(50))
    precondition(viewModel.messages.count == 30)
    viewModel.searchText = ""
    layout()
    precondition(controller.messages.count == 30)
    precondition(controller.scrollView.contentView.bounds.minY <= 0)
    print("PASS: search filters/reset and suppresses automatic history loading")

    viewModel.focusMessage(firstID)
    layout()
    try await waitUntil { viewModel.focusedMessageID == nil }
    precondition(controller.highlightedMessageID == firstID)
    precondition(controller.tableView.rows(in: controller.tableView.visibleRect).location == 0)
    print("PASS: notification focus scrolls to and highlights its native row")

    // Bring the native footer into view to trigger pagination.
    let footerRow = controller.tableView.numberOfRows - 1
    controller.tableView.scrollRowToVisible(footerRow)
    try await waitUntil { viewModel.messages.count == 60 && !viewModel.isLoadingMore }
    let oldLastID = controller.messages.last!.id
    let oldY = controller.scrollView.contentView.bounds.minY
    layout()
    precondition(controller.messages.count == 60 && controller.tableView.numberOfRows == 61)
    precondition(controller.messages[29].id == oldLastID)
    precondition(abs(controller.scrollView.contentView.bounds.minY - oldY) < 1)
    print("PASS: near-bottom native scrolling loads the next page and preserves its anchor")

    let deleteCell = controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as! MessageTableCellView
    let deleteButton = deleteCell.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == L10n.text("message.delete") }!
    deleteButton.performClick(nil)
    try await waitUntil { viewModel.messages.count == 59 }
    layout()
    precondition(!controller.messages.contains { $0.id == firstID })
    print("PASS: native delete button removes the corresponding message")

    viewModel.mainWindowWillClose()
    layout()
    precondition(controller.messages.count == 8 && controller.tableView.numberOfRows == 8)
    controller.stop()
    print("PASS: closing releases native history rows and stops pending list work")
}
