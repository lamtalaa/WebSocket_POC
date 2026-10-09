import SwiftUI

struct ContentView: View {
    @StateObject private var client = WebSocketClient()
    @State private var urlText = "ws://127.0.0.1:8765"
    @State private var draft = ""
    @State private var showGuide = false
    @FocusState private var draftFocused: Bool

    var body: some View {
        ZStack {
            LabTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                urlSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                lesson
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                logHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                log
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
        }
        .sheet(isPresented: $showGuide) {
            ProtocolGuide()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("WebSocket Lab")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(LabTheme.ink)
            Spacer(minLength: 8)
            Button {
                showGuide = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(LabTheme.muted)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How it works")

            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(client.phase.label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.14), in: Capsule())
        .accessibilityIdentifier("statusPill")
        .accessibilityLabel("Status \(client.phase.label)")
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("ws://127.0.0.1:8765", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(LabTheme.ink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(urlLocked)
                    .accessibilityIdentifier("urlField")

                connectButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(LabTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LabTheme.line, lineWidth: 1)
            )

            Text("Simulator: 127.0.0.1. A phone on the same Wi-Fi uses the address the server prints.")
                .font(.system(size: 12))
                .foregroundStyle(LabTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectButton: some View {
        Button(action: toggleConnection) {
            Text(connectTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(connectIsPrimary ? Color.black : LabTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(connectIsPrimary ? LabTheme.signal : LabTheme.cardRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(client.phase == .closing)
        .accessibilityIdentifier("connectButton")
    }

    private var lesson: some View {
        Text(lessonText)
            .font(.system(size: 14))
            .foregroundStyle(LabTheme.ink.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .background(LabTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var logHeader: some View {
        HStack {
            Text("Frames")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LabTheme.muted)
            Spacer()
            Button("Clear") {
                client.clearEvents()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LabTheme.muted)
            .disabled(client.events.isEmpty)
            .buttonStyle(.plain)
        }
    }

    private var log: some View {
        ZStack {
            if client.events.isEmpty {
                Text("Nothing on the wire yet.\nConnect, then read this list beside the server terminal.")
                    .font(.system(size: 14))
                    .foregroundStyle(LabTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(32)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(client.events) { event in
                                EventRow(event: event)
                                    .id(event.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: client.events.count) { _, _ in
                        guard let last = client.events.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(LabTheme.line)
                .frame(height: 1)

            HStack(spacing: 8) {
                toolButton("Ping", id: "pingButton", action: client.sendPing)
                toolButton("Binary", id: "binaryButton", action: client.sendSampleBinary)
                toolButton("Server push", id: "pushButton") {
                    client.send(text: "/push")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                TextField("Type a text frame", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(LabTheme.ink)
                    .focused($draftFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .accessibilityIdentifier("messageField")

                Button(action: sendDraft) {
                    Text("Send")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canSend ? Color.black : LabTheme.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(canSend ? LabTheme.sent : LabTheme.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("sendButton")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(LabTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LabTheme.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(LabTheme.background.ignoresSafeArea(edges: .bottom))
    }

    private func toolButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(socketOpen ? LabTheme.ink : LabTheme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LabTheme.cardRaised, in: Capsule())
                .overlay(Capsule().stroke(LabTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!socketOpen)
        .accessibilityIdentifier(id)
    }

    private var socketOpen: Bool {
        client.phase == .open
    }

    private var canSend: Bool {
        socketOpen && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var urlLocked: Bool {
        switch client.phase {
        case .connecting, .open, .closing: true
        case .idle, .closed, .failed: false
        }
    }

    private var connectIsPrimary: Bool {
        switch client.phase {
        case .idle, .closed, .failed: true
        case .connecting, .open, .closing: false
        }
    }

    private var connectTitle: String {
        switch client.phase {
        case .idle, .closed, .failed: "Connect"
        case .connecting: "Cancel"
        case .open: "Disconnect"
        case .closing: "Closing"
        }
    }

    private var statusColor: Color {
        switch client.phase {
        case .idle, .closed: LabTheme.muted
        case .connecting, .closing: LabTheme.warn
        case .open: LabTheme.signal
        case .failed: LabTheme.bad
        }
    }

    private var lessonText: String {
        switch client.phase {
        case .idle:
            "A WebSocket starts as HTTP. Connect sends a GET that asks the server to upgrade this TCP connection."
        case .connecting:
            "TCP is opening. URLSession then sends Upgrade: websocket and a random key, and waits for HTTP 101."
        case .open:
            "The handshake finished. This connection stays open, and either side can send a frame at any time."
        case .closing:
            "A Close frame is going out. The server should answer with Close, and then the TCP connection ends."
        case .closed:
            "This socket is done. The next Connect runs the handshake again from the start."
        case .failed:
            "The connection stopped. Read the last line in the log, then connect again when the server is ready."
        }
    }

    private func toggleConnection() {
        switch client.phase {
        case .idle, .closed, .failed:
            draftFocused = false
            client.connect(urlString: urlText)
        case .connecting, .open:
            client.disconnect()
        case .closing:
            break
        }
    }

    private func sendDraft() {
        let text = draft
        guard socketOpen, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        client.send(text: text)
    }
}

private struct EventRow: View {
    let event: WebSocketClient.Event

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.clock.string(from: event.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LabTheme.muted)
                Text(event.kind.tag)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LabTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(event.detail)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(LabTheme.ink.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(LabTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 3)
        }
    }

    private var tint: Color {
        switch event.kind {
        case .status: LabTheme.warn
        case .sent: LabTheme.sent
        case .received: LabTheme.received
        case .ping: LabTheme.warn
        case .pong: LabTheme.signal
        case .close: LabTheme.muted
        case .error: LabTheme.bad
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        return formatter
    }()
}

enum LabTheme {
    static let background = Color(red: 0.067, green: 0.071, blue: 0.082)
    static let card = Color(red: 0.110, green: 0.118, blue: 0.137)
    static let cardRaised = Color(red: 0.155, green: 0.165, blue: 0.188)
    static let ink = Color(red: 0.945, green: 0.933, blue: 0.902)
    static let muted = Color(red: 0.62, green: 0.63, blue: 0.67)
    static let line = Color.white.opacity(0.08)
    static let signal = Color(red: 0.42, green: 0.86, blue: 0.62)
    static let sent = Color(red: 0.49, green: 0.72, blue: 0.98)
    static let received = Color(red: 0.78, green: 0.64, blue: 0.96)
    static let warn = Color(red: 0.95, green: 0.76, blue: 0.38)
    static let bad = Color(red: 0.96, green: 0.48, blue: 0.42)
}

#Preview {
    ContentView()
}
