import SwiftUI
import AppKit

struct StatusBarPopoverView: View {
    @ObservedObject var viewModel: MainViewModel
    let onSelectMessage: (Int) -> Void
    @State private var hoveringMessageIDs: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.recentStatusBarMessages.isEmpty {
                Text(L10n.text("statusbar.no_notifications"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(viewModel.recentStatusBarMessages) { item in
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
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .opacity(hoveringMessageIDs.contains(item.id) ? 1 : 0)
                            .allowsHitTesting(hoveringMessageIDs.contains(item.id))
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            if isHovering {
                                hoveringMessageIDs.insert(item.id)
                            } else {
                                hoveringMessageIDs.remove(item.id)
                            }
                        }

                        Button {
                            onSelectMessage(item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.isEmpty ? L10n.text("message.no_title") : item.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                MarkdownMessageView(
                                    message: item.message,
                                    fontSize: 13,
                                    lineLimit: 3,
                                    showsImages: false
                                )
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
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
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.18))
                    .overlay {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
