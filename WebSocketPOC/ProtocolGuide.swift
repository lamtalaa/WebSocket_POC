import SwiftUI

struct ProtocolGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(diagram)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LabTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(LabTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    section("The handshake", """
                    Connect opens a TCP connection and sends an ordinary HTTP GET. Three headers ask the server to change what that connection is for:

                    Upgrade: websocket
                    Connection: Upgrade
                    Sec-WebSocket-Key: 16 random bytes, base64-encoded

                    A willing server answers 101 Switching Protocols and Sec-WebSocket-Accept. The accept value is base64(SHA-1(key + 258EAFA5-E914-47DA-95CA-C5AB0DC85B11)). Anyone who saw the key can recompute it. The value proves the server completed this handshake.
                    """)

                    section("Frames", """
                    After 101, both sides send frames on the same connection. A frame is a small header plus a payload. The opcode says what the payload is:

                    1 text — UTF-8
                    2 binary — raw bytes
                    8 close
                    9 ping
                    10 pong

                    receive() in the app returns one complete text or binary message. URLSession has already joined any fragments and removed the mask. The server process prints each frame as it arrives, including the mask key.
                    """)

                    section("Masking", """
                    Each client frame carries a 4-byte key. Every payload byte is XOR'd with that key, repeating every four bytes. The server undoes the XOR before it reads the message. Frames the server sends travel with the mask bit off.

                    The app log shows the text you typed. URLSession applies the mask as it writes the frame. The terminal running server.py prints the key it removed.
                    """)

                    section("Either side can speak", """
                    The welcome message shows up because the server decided to send it. Server push sends three more text frames on a timer. The app does not request each one. The connection is already open, so the server can write first.
                    """)

                    section("Ping and close", """
                    Ping is a control frame. The peer answers with a pong that carries the same payload. URLSession hands that pong to the sendPing callback, so it stays out of the receive loop. The server terminal prints the ping and the pong.

                    Close is a frame with a numeric code. 1000 means the close was intentional. The other side replies with Close, then both drop TCP. Stopping the server with Ctrl-C skips that frame, and the app records a failed connection.
                    """)

                    section("Try this", """
                    1. Run python3 server/server.py and tap Connect. Read the HTTP 101 in the terminal.
                    2. Send a sentence. The app should show echo:, and the terminal should show a masked frame.
                    3. Open http://127.0.0.1:8765 in a browser and send from both clients.
                    4. Tap Ping, then Binary (de ad be ef), then Server push.
                    5. Press Ctrl-C in the server terminal and watch this log.
                    """)

                    section("Where to read", """
                    WebSocketClient.swift — URLSessionWebSocketTask: connect, receive, ping, close.
                    server/server.py — the upgrade, the mask, and every opcode.
                    server/lab.html — the same socket from a browser. Page scripts can send text, binary, and close. Ping stays in the iOS app, where URLSession exposes sendPing.

                    wss:// is this same conversation inside TLS. This lab uses ws:// so the server can print the handshake in cleartext.
                    """)
                }
                .padding(20)
            }
            .background(LabTheme.background)
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(LabTheme.signal)
                }
            }
        }
        .presentationBackground(LabTheme.background)
        .presentationDragIndicator(.visible)
    }

    private func section(_ title: String, _ copy: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(LabTheme.ink)
            Text(copy)
                .font(.system(size: 15))
                .foregroundStyle(LabTheme.ink.opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var diagram: String {
        """
        client                         server
          |---- TCP connect -------------->|
          |---- GET Upgrade: websocket --->|
          |<--- 101 + Accept --------------|
          |==== text, binary, ping ========|
          |---- Close 1000 --------------->|
          |<--- Close 1000 ----------------|
        """
    }
}
