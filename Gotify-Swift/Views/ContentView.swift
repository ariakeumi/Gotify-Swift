import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var expandedMessageIDs: Set<Int> = []
    @State private var hoveringMessageIDs: Set<Int> = []
    @State private var highlightedMessageID: Int?
    private var titleFontSize: Double { viewModel.messageFontSize + 2 }
    private var bodyFontSize: Double { viewModel.messageFontSize }
    private var captionFontSize: Double { max(11, viewModel.messageFontSize - 2) }

    var body: some View {
        NavigationSplitView {
            List {
                sidebarRow(
                    title: "全部通知",
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
            .navigationTitle("通知 App")
        } detail: {
            NavigationStack {
                ScrollViewReader { proxy in
                    List(viewModel.filteredMessages) { item in
                        ZStack(alignment: .bottomTrailing) {
                            HStack(alignment: .top, spacing: 10) {
                                appIcon(for: item.appID)
                                    .onAppear {
                                        viewModel.loadIconIfNeeded(for: item.appID)
                                    }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.title.isEmpty ? "(No Title)" : item.title)
                                        .font(.system(size: titleFontSize, weight: .semibold))

                                    Text(attributedMessage(item.message))
                                        .font(.system(size: bodyFontSize))
                                        .lineLimit(expandedMessageIDs.contains(item.id) ? nil : 6)

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
                                        Button(expandedMessageIDs.contains(item.id) ? "收起" : "展开") {
                                            toggleExpanded(item.id)
                                        }
                                        .buttonStyle(.link)
                                        .font(.system(size: captionFontSize))
                                    }
                                }
                            }
                            .padding(.trailing, 44)

                            Button(role: .destructive) {
                                viewModel.deleteMessage(item)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .opacity(hoveringMessageIDs.contains(item.id) ? 1 : 0)
                            .allowsHitTesting(hoveringMessageIDs.contains(item.id))
                            .padding(.bottom, 2)
                            .padding(.trailing, 2)
                        }
                        .id(item.id)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            toggleExpanded(item.id)
                        }
                        .onHover { isHovering in
                            if isHovering {
                                hoveringMessageIDs.insert(item.id)
                            } else {
                                hoveringMessageIDs.remove(item.id)
                            }
                        }
                        .listRowBackground(
                            highlightedMessageID == item.id ? Color.accentColor.opacity(0.14) : Color.clear
                        )
                    }
                    .overlay {
                        if viewModel.filteredMessages.isEmpty {
                            ContentUnavailableView(
                                "暂无消息",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("应用已运行，收到 Gotify 推送后会显示在这里")
                            )
                        }
                    }
                    .onAppear {
                        scrollToFocusedMessage(with: proxy)
                    }
                    .onChange(of: viewModel.focusedMessageID) {
                        scrollToFocusedMessage(with: proxy)
                    }
                }
                .navigationTitle("Gotify")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            viewModel.refreshMessages()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
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
        .frame(minWidth: 860, minHeight: 560)
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
        if expandedMessageIDs.contains(messageID) {
            expandedMessageIDs.remove(messageID)
        } else {
            expandedMessageIDs.insert(messageID)
        }
    }

    private func attributedMessage(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: nsRange) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(stringRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }

    private func scrollToFocusedMessage(with proxy: ScrollViewProxy) {
        guard let messageID = viewModel.focusedMessageID else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(messageID, anchor: .center)
        }
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
