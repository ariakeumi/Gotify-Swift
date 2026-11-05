import AppKit
import SwiftUI

/// Only the bridge is SwiftUI; scrolling, row reuse and message rendering belong to AppKit.
struct MessageListView: NSViewRepresentable {
    @ObservedObject var viewModel: MainViewModel
    let toolbarClearance: CGFloat

    func makeNSView(context: Context) -> MessageListScrollView {
        context.coordinator.scrollView
    }

    func makeCoordinator() -> MessageListController {
        MessageListController(toolbarClearance: toolbarClearance)
    }

    func updateNSView(_ nsView: MessageListScrollView, context: Context) {
        context.coordinator.update(viewModel: viewModel)
    }

    static func dismantleNSView(_ nsView: MessageListScrollView, coordinator: MessageListController) {
        coordinator.stop()
    }
}

final class MessageListScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
final class MessageListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = MessageListScrollView()
    let tableView = NSTableView()
    private(set) var messages: [GotifyMessage] = []
    private(set) var expandedMessageIDs: Set<Int> = []
    private(set) var highlightedMessageID: Int?
    private weak var viewModel: MainViewModel?
    private var selectionID: Int?
    private var query = ""
    private var fontSize: CGFloat = 14
    private var contentWidth: CGFloat = 0
    private var hasFooter = false
    private var layouts: [Int: MessageRowLayout] = [:]
    private var preparedContent: [Int: MarkdownContent] = [:]
    private var parseTasks: [Int: Task<Void, Never>] = [:]
    private var viewportObserver: NSObjectProtocol?
    private var pendingViewportUpdate = false
    private var isUpdating = false
    private var isStopped = false

    init(toolbarClearance: CGFloat) {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickMessage)
        tableView.setAccessibilityLabel(L10n.text("sidebar.all_notifications"))

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: toolbarClearance + 10, left: 0, bottom: 10, right: 0)
        // AppKit already includes contentInsets when positioning the scroller.
        // Applying toolbar clearance again would push its track down twice.
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleViewportUpdate() }
        }
        scrollView.onLayout = { [weak self] in self?.resizeIfNeeded() }
    }

    func stop() {
        isStopped = true
        parseTasks.values.forEach { $0.cancel() }
        parseTasks.removeAll()
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
        viewportObserver = nil
        scrollView.onLayout = nil
    }

    func update(viewModel: MainViewModel) {
        self.viewModel = viewModel
        isUpdating = true
        defer {
            isUpdating = false
            scheduleViewportUpdate()
        }
        let nextMessages = viewModel.filteredMessages
        let nextFooter = viewModel.isRefreshing || viewModel.hasMoreMessages
        let resetScroll = selectionID != viewModel.selectedAppID || query != viewModel.searchText
        let anchor = visibleAnchor()
        let oldMessages = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let nextIDs = Set(nextMessages.map(\.id))
        let changedIDs = Set(nextMessages.compactMap { item -> Int? in
            guard let old = oldMessages[item.id], old.message == item.message,
                  old.title == item.title, old.appID == item.appID,
                  old.priority == item.priority, old.date == item.date,
                  (old.markdownPreview == nil) == (item.markdownPreview == nil) else { return item.id }
            return nil
        })
        var resizedIDs = changedIDs
        for id in Set(oldMessages.keys).subtracting(nextIDs).union(changedIDs) {
            layouts[id] = nil
            preparedContent[id] = nil
            parseTasks.removeValue(forKey: id)?.cancel()
        }
        // Keep caches bounded by the currently loaded history, including during refresh/close.
        expandedMessageIDs.formIntersection(nextIDs)
        let structureChanged = messages.map(\.id) != nextMessages.map(\.id) || hasFooter != nextFooter
        messages = nextMessages
        selectionID = viewModel.selectedAppID
        query = viewModel.searchText
        hasFooter = nextFooter
        if fontSize != viewModel.messageFontSize {
            fontSize = viewModel.messageFontSize
            layouts.removeAll()
            resizedIDs.formUnion(nextIDs)
        }
        // App names can arrive after the history, so refresh cached metadata as well.
        let appNames = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, viewModel.appName(for: $0.appID)) })
        resizedIDs.formUnion(layouts.compactMap { appNames[$0.key] == $0.value.appName ? nil : $0.key })
        layouts = layouts.filter { appNames[$0.key] == $0.value.appName }
        if structureChanged {
            tableView.reloadData()
        } else if !resizedIDs.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(messages.indices.filter { resizedIDs.contains(messages[$0].id) }))
        }
        resizeIfNeeded()
        refreshVisibleRows()
        if resetScroll {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        } else if structureChanged || !resizedIDs.isEmpty, let anchor,
                  let row = messages.firstIndex(where: { $0.id == anchor.id }) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: row).minY + anchor.offset))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        messages.count + (hasFooter ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < messages.count ? layout(for: messages[row]).height : 40
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == messages.count {
            let identifier = NSUserInterfaceItemIdentifier("footer")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageFooterView ?? MessageFooterView()
            cell.identifier = identifier
            configureFooter(cell)
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("message")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCellView ?? MessageTableCellView()
        cell.identifier = identifier
        configure(cell, at: row)
        return cell
    }

    private func layout(for item: GotifyMessage) -> MessageRowLayout {
        if let layout = layouts[item.id] { return layout }
        let isExpanded = expandedMessageIDs.contains(item.id)
        let content = preparedContent[item.id] ?? item.markdownPreview
        let layout = MessageRowLayout(
            message: item, content: content, expanded: isExpanded,
            appName: viewModel?.appName(for: item.appID) ?? "", fontSize: fontSize,
            width: max(1, tableView.bounds.width)
        )
        layouts[item.id] = layout
        return layout
    }

    private func configure(_ cell: MessageTableCellView, at row: Int) {
        guard let viewModel else { return }
        let item = messages[row]
        cell.configure(
            layout: layout(for: item), icon: viewModel.icon(for: item.appID),
            highlighted: highlightedMessageID == item.id, isLast: row == messages.count - 1,
            onDelete: { [weak viewModel] in viewModel?.deleteMessage(item) },
            onToggle: { [weak self] in self?.toggleExpanded(item.id) }
        )
    }

    private func configureFooter(_ footer: MessageFooterView) {
        guard let viewModel else { return }
        footer.configure(loading: viewModel.isRefreshing || viewModel.isLoadingMore, error: viewModel.historyLoadError) { [weak viewModel] in
            viewModel?.loadMoreMessages()
        }
    }

    private func refreshVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        for row in visible.location..<NSMaxRange(visible) {
            if row < messages.count,
               let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCellView {
                configure(cell, at: row)
            } else if let footer = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageFooterView {
                configureFooter(footer)
            }
        }
    }

    private func resizeIfNeeded() {
        let width = scrollView.contentSize.width
        guard width > 0, abs(width - contentWidth) > 0.5 else { return }
        let anchor = visibleAnchor()
        contentWidth = width
        tableView.frame.size.width = width
        tableView.tableColumns.first?.width = width
        layouts.removeAll()
        if !messages.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: messages.indices))
        }
        refreshVisibleRows()
        if let anchor, let row = messages.firstIndex(where: { $0.id == anchor.id }) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: row).minY + anchor.offset))
        }
        scheduleViewportUpdate()
    }

    private func visibleAnchor() -> (id: Int, offset: CGFloat)? {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.location < messages.count else { return nil }
        return (messages[visible.location].id, scrollView.contentView.bounds.minY - tableView.rect(ofRow: visible.location).minY)
    }

    private func scheduleViewportUpdate() {
        guard !pendingViewportUpdate, !isStopped else { return }
        pendingViewportUpdate = true
        // Never publish model changes from updateNSView or while AppKit is laying out rows.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.pendingViewportUpdate = false
            self.updateViewport()
        }
    }

    private func updateViewport() {
        guard !isUpdating, let viewModel, scrollView.window != nil else { return }
        if let id = viewModel.focusedMessageID, let row = messages.firstIndex(where: { $0.id == id }) {
            let rect = tableView.rect(ofRow: row)
            let y = rect.midY - scrollView.contentView.bounds.height / 2
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(-scrollView.contentInsets.top, y)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            viewModel.clearFocusedMessage(id)
            highlightedMessageID = id
            refreshVisibleRows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.highlightedMessageID == id else { return }
                self.highlightedMessageID = nil
                self.refreshVisibleRows()
            }
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        for row in visible.location..<min(NSMaxRange(visible), messages.count) {
            let item = messages[row]
            viewModel.loadIconIfNeeded(for: item.appID)
            prepareContentIfNeeded(for: item)
        }
        if hasFooter, NSMaxRange(visible) >= max(1, messages.count - 9),
           !viewModel.historyLoadError, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.loadMoreMessages()
        }
    }

    private func prepareContentIfNeeded(for item: GotifyMessage) {
        guard parseTasks[item.id] == nil, preparedContent[item.id] == nil,
              expandedMessageIDs.contains(item.id) || item.markdownPreview == nil else { return }
        let lineLimit = expandedMessageIDs.contains(item.id) ? nil : MarkdownContent.previewLineLimit
        parseTasks[item.id] = Task { [weak self] in
            do {
                let content = try await MarkdownContent.prepare(message: item.message, lineLimit: lineLimit)
                try Task.checkCancellation()
                guard let self else { return }
                self.preparedContent[item.id] = content
                self.parseTasks[item.id] = nil
                self.invalidateRow(item.id)
            } catch {
                // Obsolete work is cancelled when a row changes or history is released.
            }
        }
    }

    func toggleExpanded(_ id: Int) {
        guard let item = messages.first(where: { $0.id == id }) else { return }
        if !expandedMessageIDs.insert(id).inserted { expandedMessageIDs.remove(id) }
        parseTasks.removeValue(forKey: id)?.cancel()
        preparedContent[id] = nil
        invalidateRow(id)
        prepareContentIfNeeded(for: item)
    }

    private func invalidateRow(_ id: Int) {
        layouts[id] = nil
        guard let row = messages.firstIndex(where: { $0.id == id }) else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCellView {
            configure(cell, at: row)
        }
        scheduleViewportUpdate()
    }

    @objc private func doubleClickMessage() {
        let row = tableView.clickedRow
        guard messages.indices.contains(row) else { return }
        toggleExpanded(messages[row].id)
    }
}
