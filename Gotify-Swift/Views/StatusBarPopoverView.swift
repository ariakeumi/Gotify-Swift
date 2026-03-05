import SwiftUI
import AppKit

struct StatusBarPopoverView: View {
    @ObservedObject var viewModel: MainViewModel
    let onSelectMessage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("最近通知", systemImage: "bell.badge")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("退出 Gotify")
            }

            if viewModel.recentStatusBarMessages.isEmpty {
                Text("暂无通知")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(viewModel.recentStatusBarMessages) { item in
                    Button {
                        onSelectMessage(item.id)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            appIcon(for: item.appID)
                                .onAppear {
                                    viewModel.loadIconIfNeeded(for: item.appID)
                                }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.isEmpty ? "(No Title)" : item.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                Text(item.message)
                                    .font(.subheadline)
                                    .lineLimit(3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
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
