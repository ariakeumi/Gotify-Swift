import SwiftUI

@main
struct GotifyMacClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MainViewModel()

    var body: some Scene {
        Window("Gotify", id: "main") {
            ContentView(viewModel: viewModel)
                .onAppear {
                    appDelegate.configure(with: viewModel)
                    viewModel.start()
                }
                .background(MainWindowMarker())
                .background(MainWindowOpenerBinder(appDelegate: appDelegate, viewModel: viewModel))
        }

        Settings {
            SettingsView(viewModel: viewModel)
                .frame(width: 480, height: 220)
        }
    }
}

private struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView {
        MarkerView()
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier("main-window")
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
