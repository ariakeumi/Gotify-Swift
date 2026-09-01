import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Form {
            TextField(L10n.text("settings.server_url"), text: $viewModel.serverURL)
                .textFieldStyle(.roundedBorder)

            SecureField(L10n.text("settings.client_token"), text: $viewModel.clientToken)
                .textFieldStyle(.roundedBorder)

            LabeledContent(L10n.text("settings.font_size")) {
                HStack(spacing: 10) {
                    Slider(value: $viewModel.messageFontSize, in: 12...22, step: 1)
                        .frame(width: 180)
                    Text("\(Int(viewModel.messageFontSize))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }

            Toggle(
                L10n.text("settings.launch_at_login"),
                isOn: Binding(
                    get: { viewModel.launchAtLoginEnabled },
                    set: { viewModel.setLaunchAtLoginEnabled($0) }
                )
            )

            if !viewModel.launchAtLoginErrorText.isEmpty {
                LabeledContent(L10n.text("settings.launch_at_login_error")) {
                    Text(viewModel.launchAtLoginErrorText)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                }
            }

            LabeledContent(L10n.text("settings.connection_status")) {
                Text(viewModel.connectionStatusText)
                    .foregroundStyle(viewModel.connectionStatusText == L10n.text("connection.connected") ? .green : .secondary)
                    .multilineTextAlignment(.trailing)
            }

            if !viewModel.lastConnectionErrorText.isEmpty {
                LabeledContent(L10n.text("settings.recent_error")) {
                    Text(viewModel.lastConnectionErrorText)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack {
                Spacer()
                Button(L10n.text("settings.save_and_reconnect")) {
                    viewModel.saveSettingsAndReconnect()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
