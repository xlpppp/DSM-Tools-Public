import SwiftUI
import SwiftTerm
import DSMSSH

/// A full SSH shell in an xterm-compatible terminal. `initialCommand` is typed in once the shell starts.
struct TerminalScreen: View {
    let title: String
    var initialCommand: String? = nil
    var quickCommands: [QuickCommand] = []

    struct QuickCommand: Hashable {
        let label: String
        let command: String
    }

    var body: some View {
        SSHGate { session in
            ShellView(session: session, initialCommand: initialCommand, quickCommands: quickCommands)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(SwiftUI.Color.black)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct ShellView: View {
    let session: SSHSession
    let initialCommand: String?
    let quickCommands: [TerminalScreen.QuickCommand]
    @Environment(DeviceStore.self) private var store
    @State private var controller = TerminalController()

    var body: some View {
        VStack(spacing: 0) {
            if !quickCommands.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickCommands, id: \.self) { q in
                            Button(q.label) { controller.type(q.command + "\r") }
                                .font(.caption.monospaced())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(SwiftUI.Color.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(SwiftUI.Color(hex: 0x111827))
            }
            TerminalRepresentable(controller: controller)
                .ignoresSafeArea(.container, edges: .bottom)
            if controller.closed {
                Text(controller.closeReason.map { "会话已结束：\($0)" } ?? "会话已结束")
                    .font(.caption).foregroundStyle(.white.opacity(0.7)).padding(6)
            }
        }
        .background(SwiftUI.Color.black)
        .onAppear {
            controller.sudoPassword = sudoPassword
            controller.start(session: session, initialCommand: initialCommand)
        }
        .onDisappear { controller.stop() }
    }

    /// The same password SSHGate signs in with; sudo on DSM asks for the account's own password.
    private var sudoPassword: String? {
        guard let id = store.selected?.id else { return nil }
        return KeychainStore.get(KeychainStore.sshPasswordKey(id)) ?? store.password(for: id)
    }
}

/// Bridges SwiftTerm's view and the SSH channel.
@MainActor
@Observable
final class TerminalController: NSObject, TerminalViewDelegate {
    /// The prompt for `sudo -p` in commands the app types, so only those get the password. sudo turns
    /// "%%" into "%", so the echoed command line never matches `sudoPromptShown` and the password
    /// is sent only once sudo is really asking (with echo off).
    nonisolated static let sudoPrompt = "Password (NASHelper%%auto): "
    nonisolated static let sudoPromptShown = "Password (NASHelper%auto):"

    private(set) var closed = false
    private(set) var closeReason: String?
    /// Answered once to a `sudoPrompt`, so a wrong password falls back to the user typing it.
    @ObservationIgnored var sudoPassword: String?
    @ObservationIgnored weak var view: TerminalView?
    @ObservationIgnored private var terminal: SSHTerminal?
    @ObservationIgnored private var recentOutput = ""

    func start(session: SSHSession, initialCommand: String?) {
        guard terminal == nil else { return }
        let dims = view?.getTerminal().getDims() ?? (cols: 80, rows: 24)
        let t = session.openTerminal(columns: dims.cols, rows: dims.rows)
        t.onOutput = { [weak self] data in
            let bytes = ArraySlice([UInt8](data))
            Task { @MainActor in
                self?.view?.feed(byteArray: bytes)
                self?.answerSudoPrompt(data)
            }
        }
        t.onClose = { [weak self] error in
            let reason = error.map { String(describing: $0) }
            Task { @MainActor in
                self?.closeReason = reason
                self?.closed = true
            }
        }
        terminal = t
        // The view may have been laid out before the channel existed; send its real size once.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if let d = self.view?.getTerminal().getDims() { self.terminal?.resize(columns: d.cols, rows: d.rows) }
        }
        if let initialCommand {
            // Give the shell a moment to print its prompt before typing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.type(initialCommand + "\r")
            }
        }
    }

    func stop() {
        terminal?.close()
        terminal = nil
        sudoPassword = nil
    }

    private func answerSudoPrompt(_ data: Data) {
        guard sudoPassword != nil else { return }
        // The prompt can arrive split across chunks; keep a short tail to match against.
        recentOutput = String((recentOutput + String(decoding: data, as: UTF8.self)).suffix(256))
        guard recentOutput.contains(Self.sudoPromptShown), let password = sudoPassword else { return }
        sudoPassword = nil
        recentOutput = ""
        terminal?.send(password + "\r")
    }

    func type(_ text: String) {
        terminal?.send(text)
    }

    // MARK: TerminalViewDelegate

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        Task { @MainActor in self.terminal?.send(bytes) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in self.terminal?.resize(columns: newCols, rows: newRows) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in _ = await UIApplication.shared.open(url) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        let text = String(data: content, encoding: .utf8)
        Task { @MainActor in UIPasteboard.general.string = text }
    }
}

private struct TerminalRepresentable: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = controller
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.optionAsMetaKey = true
        controller.view = view
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}
}
