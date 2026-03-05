import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        Form {
            TextField("服务器 URL", text: $viewModel.serverURL)
                .textFieldStyle(.roundedBorder)

            SecureField("Client Token", text: $viewModel.clientToken)
                .textFieldStyle(.roundedBorder)

            LabeledContent("字体大小") {
                HStack(spacing: 10) {
                    Slider(value: $viewModel.messageFontSize, in: 12...22, step: 1)
                        .frame(width: 180)
                    Text("\(Int(viewModel.messageFontSize))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }

            LabeledContent("连接状态") {
                Text(viewModel.connectionStatusText)
                    .foregroundStyle(viewModel.connectionStatusText == "已连接" ? .green : .secondary)
                    .multilineTextAlignment(.trailing)
            }

            if !viewModel.lastConnectionErrorText.isEmpty {
                LabeledContent("最近错误") {
                    Text(viewModel.lastConnectionErrorText)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack {
                Spacer()
                Button("保存并重连") {
                    viewModel.saveSettingsAndReconnect()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
