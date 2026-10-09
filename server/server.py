#!/usr/bin/env python3
"""A WebSocket lab server that shows the bytes URLSession hides.

Read this file from top to bottom:

1. encode_frame / read_frame  — one frame on the wire (RFC 6455)
2. accept_value               — the HTTP 101 handshake
3. serve_websocket            — what happens after the upgrade
4. The block under __main__   — a tiny client that checks the whole path

Run it from the project root:

    python3 server/server.py

Then connect the iOS app to ws://127.0.0.1:8765, or open
http://127.0.0.1:8765 for a second client in the browser.

    python3 server/server.py --check
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import socket
import sys
from dataclasses import dataclass
from pathlib import Path

# Both sides of every WebSocket handshake mix the client's key with this GUID.
# It is a fixed string from RFC 6455, published so intermediaries can recognize
# a real WebSocket accept value.
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OP_CONTINUATION = 0x0
OP_TEXT = 0x1
OP_BINARY = 0x2
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA

OP_NAME = {
    OP_CONTINUATION: "cont",
    OP_TEXT: "text",
    OP_BINARY: "bin",
    OP_CLOSE: "close",
    OP_PING: "ping",
    OP_PONG: "pong",
}

MAX_FRAME = 1_000_000
HOST = "0.0.0.0"
PORT = 8765

clients: dict[int, "Client"] = {}
next_id = 1
background: set[asyncio.Task] = set()


@dataclass
class Frame:
    fin: bool
    opcode: int
    payload: bytes
    mask: bytes | None

    def summary(self) -> str:
        name = OP_NAME.get(self.opcode, f"op{self.opcode}")
        fin = "fin" if self.fin else "fragment"
        mask = "unmasked" if self.mask is None else f"mask={self.mask.hex()}"
        return f"{name:<5} {fin:<8} {mask:<18} {preview(self.opcode, self.payload)}"


class ProtocolError(Exception):
    pass


class Client:
    def __init__(self, writer: asyncio.StreamWriter, ident: int) -> None:
        self.writer = writer
        self.ident = ident
        # The read loop and the /push task both write this socket.
        # Frames must not interleave mid-header, so one lock owns the writer.
        self.lock = asyncio.Lock()

    async def send(self, opcode: int, payload: bytes) -> None:
        frame = encode_frame(opcode, payload)
        try:
            async with self.lock:
                self.writer.write(frame)
                await self.writer.drain()
        except (ConnectionError, OSError) as exc:
            log("error", f"#{self.ident} send failed: {exc}")
            raise
        outgoing = Frame(True, opcode, payload, None)
        log("frame", f"#{self.ident:<3} out  {outgoing.summary()}")


def log(tag: str, message: str) -> None:
    print(f"{tag:<8} {message}", flush=True)


def accept_value(key: str) -> str:
    """base64( SHA-1( key + GUID ) ). The RFC 6455 sample is checked at startup."""
    digest = hashlib.sha1((key + GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def encode_frame(opcode: int, payload: bytes, *, mask: bytes | None = None, fin: bool = True) -> bytes:
    """Build one frame.

    Client-to-server frames pass a 4-byte mask. Each payload byte is XOR'd with
    mask[i % 4]. Server-to-client frames leave mask empty, so the mask bit is 0
    and the payload is written unchanged.
    """
    first = (0x80 if fin else 0) | (opcode & 0x0F)
    length = len(payload)
    mask_bit = 0x80 if mask else 0
    if length < 126:
        header = bytes([first, mask_bit | length])
    elif length < 65536:
        header = bytes([first, mask_bit | 126]) + length.to_bytes(2, "big")
    else:
        header = bytes([first, mask_bit | 127]) + length.to_bytes(8, "big")
    if mask is None:
        return header + payload
    if len(mask) != 4:
        raise ValueError("mask must be 4 bytes")
    masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    return header + mask + masked


async def read_frame(reader: asyncio.StreamReader, *, expect_mask: bool) -> Frame:
    """Read one frame. Clients must mask. Servers must not."""
    try:
        head = await reader.readexactly(2)
    except asyncio.IncompleteReadError as exc:
        raise ConnectionError("connection closed while reading a frame header") from exc

    fin = bool(head[0] & 0x80)
    rsv = head[0] & 0x70
    opcode = head[0] & 0x0F
    masked = bool(head[1] & 0x80)
    length = head[1] & 0x7F

    if rsv:
        raise ProtocolError("RSV bits are set, and this server negotiates no extensions")
    if length == 126:
        length = int.from_bytes(await reader.readexactly(2), "big")
    elif length == 127:
        wide = int.from_bytes(await reader.readexactly(8), "big")
        if wide & (1 << 63):
            raise ProtocolError("the 64-bit payload length has its high bit set")
        length = wide
    if length > MAX_FRAME:
        raise ProtocolError(f"frame is {length} bytes, over the {MAX_FRAME} byte cap")

    # Control frames are not fragmented, and their payload fits in 7 length bits.
    if opcode in (OP_CLOSE, OP_PING, OP_PONG):
        if not fin or length > 125:
            raise ProtocolError("control frames are final and at most 125 bytes")

    mask = await reader.readexactly(4) if masked else None
    try:
        payload = await reader.readexactly(length) if length else b""
    except asyncio.IncompleteReadError as exc:
        raise ConnectionError("connection closed in the middle of a frame") from exc
    if mask is not None:
        payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))

    if expect_mask and mask is None:
        raise ProtocolError("a client frame arrived with the mask bit off")
    if not expect_mask and mask is not None:
        raise ProtocolError("a server frame arrived with the mask bit on")
    return Frame(fin, opcode, payload, mask)


def preview(opcode: int, payload: bytes) -> str:
    if opcode == OP_TEXT:
        text = payload.decode("utf-8", "replace")
        if len(text) > 180:
            text = text[:180] + "…"
        return f"bytes={len(payload)} {text!r}"
    if opcode == OP_BINARY:
        shown = payload[:16].hex(" ")
        return f"bytes={len(payload)} {shown}"
    if opcode == OP_CLOSE:
        return describe_close(payload)
    return f"bytes={len(payload)} {payload[:32]!r}"


def describe_close(payload: bytes) -> str:
    if not payload:
        return "no status code"
    if len(payload) < 2:
        return "truncated close payload"
    code = int.from_bytes(payload[:2], "big")
    reason = payload[2:].decode("utf-8", "replace")
    if reason:
        return f"code={code} reason={reason!r}"
    return f"code={code}"


def close_payload(code: int, reason: str = "") -> bytes:
    return code.to_bytes(2, "big") + reason.encode("utf-8")


async def read_http_head(reader: asyncio.StreamReader) -> bytes:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(1024)
        if not chunk:
            raise ConnectionError("connection closed during the HTTP handshake")
        data += chunk
        if len(data) > 8192:
            raise ProtocolError("HTTP headers exceeded 8KB")
    head, extra = data.split(b"\r\n\r\n", 1)
    if extra:
        # The client must wait for 101 before sending frames, so anything
        # past the header on this read is a protocol mixup.
        raise ProtocolError("bytes arrived after the HTTP headers before 101")
    return head


def parse_request(head: bytes) -> tuple[str, str, dict[str, str]]:
    text = head.decode("iso-8859-1")
    lines = text.split("\r\n")
    try:
        method, path, _version = lines[0].split(" ", 2)
    except ValueError as exc:
        raise ProtocolError(f"bad request line: {lines[0]!r}") from exc
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        name, separator, value = line.partition(":")
        if not separator:
            raise ProtocolError(f"bad header: {line!r}")
        headers[name.strip().lower()] = value.strip()
    return method.upper(), path, headers


def http_response(status: int, reason: str, content_type: str, body: bytes) -> bytes:
    head = (
        f"HTTP/1.1 {status} {reason}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n"
        "\r\n"
    )
    return head.encode("ascii") + body


def lab_page() -> bytes:
    path = Path(__file__).with_name("lab.html")
    return path.read_bytes()


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")
    sock = writer.get_extra_info("socket")
    if sock is not None:
        # Small frames should leave immediately. Nagle would sit on them.
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    log("tcp", f"accepted {peer}")
    try:
        head = await read_http_head(reader)
        method, path, headers = parse_request(head)
        if is_websocket_upgrade(headers):
            await serve_websocket(reader, writer, method, headers)
        else:
            await serve_http(writer, method, path)
    except ProtocolError as exc:
        log("error", f"{peer} {exc}")
        try:
            writer.write(http_response(400, "Bad Request", "text/plain; charset=utf-8", f"{exc}\n".encode()))
            await writer.drain()
        except OSError:
            pass
    except (ConnectionError, asyncio.IncompleteReadError, OSError) as exc:
        log("close", f"{peer} {exc}")
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, OSError):
            pass


def is_websocket_upgrade(headers: dict[str, str]) -> bool:
    upgrade = headers.get("upgrade", "")
    connection = headers.get("connection", "")
    return "websocket" in upgrade.lower() and "upgrade" in connection.lower()


async def serve_http(writer: asyncio.StreamWriter, method: str, path: str) -> None:
    if method != "GET":
        body = b"this port speaks GET for the lab page, and GET + Upgrade for WebSocket\n"
        writer.write(http_response(405, "Method Not Allowed", "text/plain; charset=utf-8", body))
        await writer.drain()
        log("http", f"{method} {path} -> 405")
        return
    if path in ("/", "/index.html", "/lab.html"):
        writer.write(http_response(200, "OK", "text/html; charset=utf-8", lab_page()))
        await writer.drain()
        log("http", f"GET {path} -> 200 lab page")
        return
    writer.write(http_response(404, "Not Found", "text/plain; charset=utf-8", b"not found\n"))
    await writer.drain()
    log("http", f"GET {path} -> 404")


async def serve_websocket(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    method: str,
    headers: dict[str, str],
) -> None:
    if method != "GET":
        raise ProtocolError("the opening handshake uses GET")
    version = headers.get("sec-websocket-version", "")
    key = headers.get("sec-websocket-key", "")
    log("http", "Upgrade: websocket")
    log("http", f"Connection: {headers.get('connection', '')}")
    log("http", f"Sec-WebSocket-Version: {version or '(missing)'}")
    log("http", f"Sec-WebSocket-Key: {key or '(missing)'}")
    if origin := headers.get("origin"):
        log("http", f"Origin: {origin}")
    if offered := headers.get("sec-websocket-protocol"):
        log("http", f"client offered subprotocol(s): {offered} — accepting the socket with none")

    if version != "13":
        raise ProtocolError("Sec-WebSocket-Version must be 13")
    try:
        key_bytes = base64.b64decode(key, validate=True)
    except Exception:
        key_bytes = b""
    if len(key_bytes) != 16:
        raise ProtocolError("Sec-WebSocket-Key must be 16 bytes, base64-encoded")

    accept = accept_value(key)
    log("http", f"Sec-WebSocket-Accept = base64(sha1(key + {GUID}))")
    log("http", f"Sec-WebSocket-Accept: {accept}")

    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )
    writer.write(response.encode("ascii"))
    await writer.drain()
    log("http", "101 Switching Protocols — frames follow on this same TCP connection")

    global next_id
    ident = next_id
    next_id += 1
    client = Client(writer, ident)
    clients[ident] = client
    try:
        welcome = (
            f"welcome — you are client {ident}\n"
            "the handshake is done, so this frame arrived without a request\n"
            "text you send is echoed to you and copied to every other socket"
        )
        await client.send(OP_TEXT, welcome.encode())
        await socket_loop(reader, client)
    finally:
        clients.pop(ident, None)
        log("close", f"#{ident} left — {len(clients)} still open")


async def socket_loop(reader: asyncio.StreamReader, client: Client) -> None:
    buffered = bytearray()
    message_opcode: int | None = None
    try:
        while True:
            frame = await read_frame(reader, expect_mask=True)
            log("frame", f"#{client.ident:<3} in   {frame.summary()}")

            if frame.opcode == OP_PING:
                await client.send(OP_PONG, frame.payload)
                continue
            if frame.opcode == OP_PONG:
                continue
            if frame.opcode == OP_CLOSE:
                code = 1000 if len(frame.payload) < 2 else int.from_bytes(frame.payload[:2], "big")
                await client.send(OP_CLOSE, close_payload(code))
                return

            if frame.opcode == OP_CONTINUATION:
                if message_opcode is None:
                    raise ProtocolError("continuation frame with nothing to continue")
                buffered += frame.payload
            elif frame.opcode in (OP_TEXT, OP_BINARY):
                if message_opcode is not None:
                    raise ProtocolError("a new data frame started before the previous one finished")
                message_opcode = frame.opcode
                buffered = bytearray(frame.payload)
            else:
                raise ProtocolError(f"unknown opcode {frame.opcode}")

            if not frame.fin:
                continue

            payload = bytes(buffered)
            opcode = message_opcode
            buffered = bytearray()
            message_opcode = None
            if opcode == OP_TEXT:
                try:
                    text = payload.decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise ProtocolError("text frame is not UTF-8") from exc
                if await handle_text(client, text):
                    # /close already wrote a Close frame. Read the peer's reply
                    # so the handshake finishes before this TCP connection drops.
                    try:
                        reply = await asyncio.wait_for(
                            read_frame(reader, expect_mask=True),
                            timeout=2,
                        )
                        log("frame", f"#{client.ident:<3} in   {reply.summary()}")
                    except (asyncio.TimeoutError, ConnectionError, ProtocolError, OSError) as exc:
                        log("close", f"#{client.ident} close reply not read ({exc})")
                    return
            else:
                await client.send(OP_BINARY, payload)
                shown = payload[:8].hex(" ")
                await broadcast(client.ident, f"from #{client.ident}: {len(payload)} binary bytes ({shown})")
    except ConnectionError:
        return
    except ProtocolError as exc:
        log("error", f"#{client.ident} {exc}")
        try:
            await client.send(OP_CLOSE, close_payload(1002, str(exc)))
        except OSError:
            pass


async def handle_text(client: Client, text: str) -> bool:
    """Returns True when the socket should close."""
    command = text.strip()
    if command == "/push":
        spawn(push_frames(client.ident))
        return False
    if command == "/clients":
        names = ", ".join(f"#{ident}" for ident in sorted(clients)) or "none"
        await client.send(OP_TEXT, f"{len(clients)} open: {names}".encode())
        return False
    if command == "/close":
        await client.send(OP_TEXT, b"closing from the server with code 1000")
        await client.send(OP_CLOSE, close_payload(1000, "server close"))
        return True

    await client.send(OP_TEXT, f"echo: {text}".encode())
    await broadcast(client.ident, f"from #{client.ident}: {text}")
    return False


def spawn(coro) -> None:
    task = asyncio.create_task(coro)
    background.add(task)
    task.add_done_callback(background.discard)


async def push_frames(ident: int) -> None:
    lines = (
        "push 1/3 — sent by the server, on the socket that is already open",
        "push 2/3 — the app did not send a request for this frame",
        "push 3/3 — three writes, zero new handshakes",
    )
    for line in lines:
        client = clients.get(ident)
        if client is None:
            return
        try:
            await client.send(OP_TEXT, line.encode())
        except OSError:
            return
        await asyncio.sleep(0.45)


async def broadcast(sender: int, text: str) -> None:
    payload = text.encode()
    for ident, client in list(clients.items()):
        if ident == sender:
            continue
        try:
            await client.send(OP_TEXT, payload)
        except OSError:
            clients.pop(ident, None)


def lan_ip() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("8.8.8.8", 80))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


def print_banner(port: int) -> None:
    phone = lan_ip()
    print("WebSocket lab", flush=True)
    print(f"  simulator    ws://127.0.0.1:{port}", flush=True)
    print(f"  browser      http://127.0.0.1:{port}", flush=True)
    if phone != "127.0.0.1":
        print(f"  phone        ws://{phone}:{port}", flush=True)
    sample = accept_value("dGhlIHNhbXBsZSBub25jZQ==")
    print(f"  rfc sample   key dGhlIHNhbXBsZSBub25jZQ== accepts as {sample}", flush=True)
    print("Ctrl-C stops the server. Handshakes and frames print below.", flush=True)
    print(flush=True)


async def serve(port: int) -> None:
    try:
        server = await asyncio.start_server(handle_client, HOST, port)
    except OSError as exc:
        print(f"could not listen on port {port}: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print_banner(port)
    async with server:
        await server.serve_forever()


def reset_state() -> None:
    global next_id
    clients.clear()
    next_id = 1


async def self_check() -> None:
    """A raw client: handshake, text, binary, ping, broadcast, push, close.

    This is the same sequence the iOS app runs, with the bytes written by hand.
    """
    sample = accept_value("dGhlIHNhbXBsZSBub25jZQ==")
    if sample != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=":
        raise SystemExit(f"RFC 6455 accept sample mismatch: {sample}")

    reset_state()
    port = 8766
    server = await asyncio.start_server(handle_client, "127.0.0.1", port)
    try:
        async with RawClient(port) as page:
            body = await page.http_get("/")
            expect(b"200" in body.split(b"\r\n", 1)[0], "lab page status")
            expect(b"WebSocket Lab" in body, "lab page title")

        async with RawClient(port) as first:
            welcome = await first.handshake()
            expect(welcome.startswith("welcome — you are client "), welcome)
            await first.send_text("hello")
            echo = await first.read_text()
            expect(echo == "echo: hello", echo)

            await first.send_binary(bytes.fromhex("deadbeef"))
            binary = await first.read_frame()
            expect(binary.opcode == OP_BINARY and binary.payload == bytes.fromhex("deadbeef"), binary.summary())

            await first.send_masked(OP_PING, b"xyz")
            pong = await first.read_frame()
            expect(pong.opcode == OP_PONG and pong.payload == b"xyz", pong.summary())

            await first.send_text("/push")
            for index in (1, 2, 3):
                pushed = await first.read_text()
                expect(pushed.startswith(f"push {index}/3"), pushed)

            async with RawClient(port) as second:
                other = await second.handshake()
                expect("client 2" in other.split("\n", 1)[0], other)
                await first.send_text("cross")
                expect(await first.read_text() == "echo: cross", "echo cross")
                expect(await second.read_text() == "from #1: cross", "broadcast")
                await second.send_masked(OP_CLOSE, close_payload(1000, "bye"))
                closing = await second.read_frame()
                expect(closing.opcode == OP_CLOSE, closing.summary())

            await first.send_masked(OP_CLOSE, close_payload(1000, "bye"))
            closing = await first.read_frame()
            expect(closing.opcode == OP_CLOSE, closing.summary())

        async with RawClient(port) as bare:
            await bare.handshake()
            # Mask bit off. The server must refuse this with close code 1002.
            bare.writer.write(encode_frame(OP_TEXT, b"no mask"))
            await bare.writer.drain()
            refused = await bare.read_frame()
            expect(refused.opcode == OP_CLOSE, refused.summary())
            code = int.from_bytes(refused.payload[:2], "big")
            expect(code == 1002, refused.summary())
    finally:
        server.close()
        await server.wait_closed()
    print("self-check passed", flush=True)


def expect(condition: bool, detail: object) -> None:
    if not condition:
        raise SystemExit(f"self-check failed: {detail}")


class RawClient:
    def __init__(self, port: int) -> None:
        self.port = port
        self.reader: asyncio.StreamReader
        self.writer: asyncio.StreamWriter

    async def __aenter__(self) -> "RawClient":
        self.reader, self.writer = await asyncio.open_connection("127.0.0.1", self.port)
        return self

    async def __aexit__(self, *_) -> None:
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except (ConnectionError, OSError):
            pass

    async def http_get(self, path: str) -> bytes:
        self.writer.write(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".encode())
        await self.writer.drain()
        return await self.reader.read()

    async def handshake(self) -> str:
        key = base64.b64encode(b"0123456789abcdef").decode("ascii")
        request = (
            "GET / HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.writer.write(request.encode("ascii"))
        await self.writer.drain()
        # Read one byte at a time so a welcome frame that shares a TCP segment
        # with the 101 response stays in the socket for read_frame.
        data = bytearray()
        while b"\r\n\r\n" not in data:
            data += await self.reader.readexactly(1)
            if len(data) > 8192:
                raise SystemExit("handshake headers too large")
        head = bytes(data)
        status = head.split(b"\r\n", 1)[0]
        expect(b"101" in status, head)
        expect(accept_value(key).encode("ascii") in head, head)
        return await self.read_text()

    async def send_text(self, text: str) -> None:
        await self.send_masked(OP_TEXT, text.encode())

    async def send_binary(self, payload: bytes) -> None:
        await self.send_masked(OP_BINARY, payload)

    async def send_masked(self, opcode: int, payload: bytes) -> None:
        self.writer.write(encode_frame(opcode, payload, mask=b"\x01\x02\x03\x04"))
        await self.writer.drain()

    async def read_frame(self) -> Frame:
        return await asyncio.wait_for(read_frame(self.reader, expect_mask=False), timeout=5)

    async def read_text(self) -> str:
        frame = await self.read_frame()
        expect(frame.opcode == OP_TEXT, frame.summary())
        return frame.payload.decode()


def main() -> None:
    if "--check" in sys.argv:
        asyncio.run(self_check())
        return
    try:
        asyncio.run(serve(PORT))
    except KeyboardInterrupt:
        print("\nstopped", flush=True)


if __name__ == "__main__":
    main()
