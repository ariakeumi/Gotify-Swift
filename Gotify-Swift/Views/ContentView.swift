import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var expandedMessageIDs: Set<Int> = []
    @State private var highlightedMessageID: Int?
    @FocusState private var isSearchFieldFocused: Bool
    private let floatingToolbarClearance: CGFloat = 52
    private let historyPrefetchRowCount = 10
    private var titleFontSize: Double { viewModel.messageFontSize + 2 }
    private var bodyFontSize: Double { viewModel.messageFontSize }
    private var captionFontSize: Double { max(11, viewModel.messageFontSize - 2) }

    var body: some View {
        NavigationSplitView {
            List {
                sidebarRow(
                    title: L10n.text("sidebar.all_notifications"),
                    icon: "tray.full",
                    appID: MainViewModel.allAppsSelectionID
                )

                ForEach(viewModel.applications) { app in
                    sidebarRow(
                        title: app.name,
                        icon: nil,
                        appID: app.id
                    )
                    .onAppear { viewModel.loadIconIfNeeded(for: app.id) }
                }
            }
            .navigationTitle(L10n.text("sidebar.title"))
        } detail: {
            NavigationStack {
                ScrollViewReader { proxy in
                    let messages = viewModel.filteredMessages
                    let lastMessageID = messages.last?.id
                    let prefetchMessageID = viewModel.hasMoreMessages && !viewModel.isRefreshing && messages.count >= historyPrefetchRowCount
                        ? messages[messages.count - historyPrefetchRowCount].id : nil
                    Group {
                        if messages.isEmpty && !viewModel.isRefreshing && !viewModel.hasMoreMessages {
                            if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ContentUnavailableView(
                                    L10n.text("content.empty_title"),
                                    systemImage: "bubble.left.and.bubble.right",
                                    description: Text(L10n.text("content.empty_description"))
                                )
                            } else {
                                ContentUnavailableView.search(text: viewModel.searchText)
                            }
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(messages) { item in
                                        messageRow(item, isLast: item.id == lastMessageID)
                                            .id(item.id)
                                            .background {
                                                if item.id == prefetchMessageID {
                                                    Color.clear.onScrollVisibilityChange(threshold: 0.1) { isVisible in
                                                        loadMoreWhenVisible(isVisible)
                                                    }
                                                }
                                            }
                                    }
                                    if viewModel.isRefreshing {
                                        ProgressView()
                                            .frame(maxWidth: .infinity)
                                    } else if viewModel.hasMoreMessages {
                                        Button {
                                            viewModel.loadMoreMessages()
                                        } label: {
                                            HStack {
                                                Spacer()
                                                if viewModel.isLoadingMore {
                                                    ProgressView().controlSize(.small)
                                                } else {
                                                    Text(L10n.text(viewModel.historyLoadError ? "content.retry_loading" : "content.load_more"))
                                                }
                                                Spacer()
                                            }
                                            .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(viewModel.isLoadingMore)
                                        .id("load-more-\(viewModel.messages.count)")
                                        .onScrollVisibilityChange(threshold: 0.1) { isVisible in
                                            loadMoreWhenVisible(isVisible)
                                        }
                                    }
                                }
                                // Insets belong to the content, keeping the scrollbar at the window edge.
                                .padding(.horizontal, 16)
                                .padding(.top, floatingToolbarClearance + 10)
                                .padding(.bottom, 10)
                            }
                            .scrollEdgeEffectStyle(.soft, for: .top)
                            .contentMargins(.top, floatingToolbarClearance, for: .scrollIndicators)
                            .ignoresSafeArea(.container, edges: .top)
                            .id("message-scroll-\(viewModel.selectedAppID)")
                        }
                    }
                    .onAppear {
                        scrollToFocusedMessage(with: proxy)
                    }
                    .onChange(of: viewModel.focusedMessageID) {
                        scrollToFocusedMessage(with: proxy)
                    }
                    .onChange(of: viewModel.messages.count) {
                        scrollToFocusedMessage(with: proxy)
                    }
                }
                .searchable(
                    text: $viewModel.searchText,
                    placement: .toolbar,
                    prompt: L10n.text("search.placeholder")
                )
                .searchFocused($isSearchFieldFocused)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.refreshMessages()
                        } label: {
                            Label(L10n.text("toolbar.refresh"), systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(viewModel.isRefreshing)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        SettingsLink {
                            Image(systemName: "gearshape.fill")
                        }
                    }
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .background(sidebarShortcutBindings)
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    private func sidebarRow(title: String, icon: String?, appID: Int) -> some View {
        Button {
            viewModel.selectSidebarApp(appID)
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .frame(width: 34, height: 34)
                } else {
                    appIcon(for: appID)
                }
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(viewModel.selectedAppID == appID ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func messageRow(_ item: GotifyMessage, isLast: Bool) -> some View {
        let isExpanded = expandedMessageIDs.contains(item.id)
        let canExpand = item.markdownPreview?.isTruncated
            ?? MarkdownContent.previewSource(item.message, maxLines: MarkdownContent.previewLineLimit).isTruncated
        return HStack(alignment: .top, spacing: 10) {
            MessageActionIcon(onDelete: { viewModel.deleteMessage(item) }) {
                appIcon(for: item.appID)
                    .onAppear {
                        viewModel.loadIconIfNeeded(for: item.appID)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title.isEmpty ? L10n.text("message.no_title") : item.title)
                    .font(.system(size: titleFontSize, weight: .semibold))

                MarkdownMessageView(
                    message: item.message,
                    fontSize: bodyFontSize,
                    lineLimit: isExpanded ? nil : MarkdownContent.previewLineLimit,
                    showsImages: true,
                    imageMaxHeight: isExpanded ? 280 : 180,
                    preparedContent: isExpanded ? nil : item.markdownPreview
                )

                HStack(spacing: 8) {
                    Text(viewModel.appName(for: item.appID))
                    if let priority = item.priority {
                        Text("P\(priority)")
                    }
                    if let date = item.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.system(size: captionFontSize))
                .foregroundStyle(.secondary)

                if canExpand {
                    Button(isExpanded ? L10n.text("message.collapse") : L10n.text("message.expand")) {
                        toggleExpanded(item.id)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: captionFontSize))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(highlightedMessageID == item.id ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            toggleExpanded(item.id)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(isLast ? 0 : 1)
        }
    }

    private func appIcon(for appID: Int?) -> some View {
        Group {
            if let image = viewModel.icon(for: appID) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(1)
            } else {
                placeholderIcon
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
        }
    }

    private var placeholderIcon: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                Image(systemName: "bell.badge")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
    }

    private func loadMoreWhenVisible(_ isVisible: Bool) {
        guard isVisible, !viewModel.historyLoadError,
              viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.loadMoreMessages()
    }

    private func toggleExpanded(_ messageID: Int) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedMessageIDs.contains(messageID) {
                expandedMessageIDs.remove(messageID)
            } else {
                expandedMessageIDs.insert(messageID)
            }
        }
    }

    private func scrollToFocusedMessage(with proxy: ScrollViewProxy) {
        guard let messageID = viewModel.focusedMessageID else { return }
        guard viewModel.filteredMessages.contains(where: { $0.id == messageID }) else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(messageID, anchor: .center)
        }
        viewModel.clearFocusedMessage(messageID)
        highlightedMessageID = messageID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if highlightedMessageID == messageID {
                highlightedMessageID = nil
            }
        }
    }

    private var sidebarShortcutBindings: some View {
        VStack {
            Button("") {
                viewModel.selectSidebarApp(MainViewModel.allAppsSelectionID)
            }
            .keyboardShortcut("1", modifiers: .command)

            ForEach(2...9, id: \.self) { number in
                Button("") {
                    selectSidebarAppByShortcut(number)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }

            Button("") {
                isSearchFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .allowsHitTesting(false)
    }

    private func selectSidebarAppByShortcut(_ number: Int) {
        let appIndex = number - 2
        guard appIndex >= 0, appIndex < viewModel.applications.count else { return }
        viewModel.selectSidebarApp(viewModel.applications[appIndex].id)
    }
}

private struct MessageActionIcon<Icon: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var isHovering = false

    var body: some View {
        icon()
            .overlay {
                if isHovering {
                    Button(role: .destructive, action: onDelete) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.regular)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
