import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: MainViewModel
    @FocusState private var isSearchFieldFocused: Bool
    private let floatingToolbarClearance: CGFloat = 52

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
                        MessageListView(viewModel: viewModel, toolbarClearance: floatingToolbarClearance)
                            .ignoresSafeArea(.container, edges: .top)
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
