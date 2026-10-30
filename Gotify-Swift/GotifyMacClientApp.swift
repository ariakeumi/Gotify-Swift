import SwiftUI

@main
struct GotifyMacClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MainViewModel()
    @State private var didBootstrap = false

    var body: some Scene {
        let _ = bootstrapIfNeeded()

        // 空标题:避免窗口标题文本渲染进工具栏
        Window("", id: "main") {
            Group {
                if viewModel.isMainWindowOpen {
                    ContentView(viewModel: viewModel)
                } else {
                    Color.clear
                        .frame(minWidth: 640, minHeight: 560)
                }
            }
            .background(MainWindowMarker(appDelegate: appDelegate))
            .background(MainWindowOpenerBinder(appDelegate: appDelegate, viewModel: viewModel))
        }
        .defaultSize(width: 860, height: 560)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(viewModel: viewModel)
                .frame(width: 480, height: 280)
        }
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        DispatchQueue.main.async {
            guard !didBootstrap else { return }
            didBootstrap = true
            appDelegate.configure(with: viewModel)
            viewModel.start()
        }
    }
}

private struct MainWindowMarker: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(appDelegate: appDelegate)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        private let appDelegate: AppDelegate

        init(appDelegate: AppDelegate) {
            self.appDelegate = appDelegate
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            appDelegate.configureMainWindow(window)
        }
    }
}

private struct MainWindowOpenerBinder: View {
    let appDelegate: AppDelegate
    let viewModel: MainViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appDelegate.setOpenMainWindowHandler {
                    openWindow(id: "main")
                }
                appDelegate.setOpenMessageHandler { messageID in
                    viewModel.focusMessage(messageID)
                }
            }
    }
}
