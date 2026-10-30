import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var expandedMessageIDs: Set<Int> = []
    @State private var hoveringMessageIDs: Set<Int> = []
    @State private var highlightedMessageID: Int?
    @FocusState private var isSearchFieldFocused: Bool
    private let floatingToolbarClearance: CGFloat = 52
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
                    Group {
                        if viewModel.filteredMessages.isEmpty && !viewModel.isRefreshing && !viewModel.hasMoreMessages {
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
                            // List(AppKit 表格,真实单元格复用):只保留可见行,
                            // 内存有界;布局精确,没有 LazyVStack 的高度估算空白问题。
                            List {
                                ForEach(viewModel.filteredMessages) { item in
                                    messageRow(item, isLast: item.id == viewModel.filteredMessages.last?.id)
                                        .padding(.top, item.id == viewModel.filteredMessages.first?.id ? floatingToolbarClearance : 0)
                                        .id(item.id)
                                        .listRowInsets(EdgeInsets())
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                }
                                if viewModel.isRefreshing {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .listRowSeparator(.hidden)
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
                                    .listRowSeparator(.hidden)
                                    .id("load-more-\(viewModel.messages.count)")
                                    .onScrollVisibilityChange(threshold: 0.1) { isVisible in
                                        guard isVisible, !viewModel.historyLoadError,
                                              viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                        viewModel.loadMoreMessages()
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .scrollEdgeEffectStyle(.soft, for: .top)
                            .contentMargins(.top, 10, for: .scrollContent)
                            .contentMargins(.bottom, 10, for: .scrollContent)
                            .ignoresSafeArea(.container, edges: .top)
                            .padding(.horizontal, 16)
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
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                appIcon(for: item.appID)
                    .onAppear {
                        viewModel.loadIconIfNeeded(for: item.appID)
                    }

                Button(role: .destructive) {
                    viewModel.deleteMessage(item)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .controlSize(.regular)
                .opacity(hoveringMessageIDs.contains(item.id) ? 1 : 0)
                .allowsHitTesting(hoveringMessageIDs.contains(item.id))
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    hoveringMessageIDs.insert(item.id)
                } else {
                    hoveringMessageIDs.remove(item.id)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title.isEmpty ? L10n.text("message.no_title") : item.title)
                    .font(.system(size: titleFontSize, weight: .semibold))

                MarkdownMessageView(
                    message: item.message,
                    fontSize: bodyFontSize,
                    lineLimit: expandedMessageIDs.contains(item.id) ? nil : 6,
                    showsImages: true,
                    imageMaxHeight: expandedMessageIDs.contains(item.id) ? 280 : 180
                )
                .id("markdown-\(item.id)-\(expandedMessageIDs.contains(item.id))")

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

                if shouldShowExpandButton(for: item.message) {
                    Button(expandedMessageIDs.contains(item.id) ? L10n.text("message.collapse") : L10n.text("message.expand")) {
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

    private func shouldShowExpandButton(for message: String) -> Bool {
        let lineCount = message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return lineCount > 6
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
