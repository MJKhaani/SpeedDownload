"""Two local peers each own one piece and require concurrent requests."""
from __future__ import annotations

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


PIECES = [b"a" * 16384, b"b" * 16384]
PAYLOAD = b"".join(PIECES)


def bencode(value):
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    return b"d" + b"".join(bencode(k) + bencode(value[k]) for k in sorted(value)) + b"e"


def exact(stream, length):
    data = b""
    while len(data) < length:
        chunk = stream.recv(length - len(data))
        if not chunk:
            raise EOFError("peer closed")
        data += chunk
    return data


def frame(stream, body):
    stream.sendall(struct.pack(">I", len(body)) + body)


class Shared:
    def __init__(self):
        self.requested = [threading.Event(), threading.Event()]
        self.info_hash = b""
        self.ports = []


def peer_type(index, shared):
    class Peer(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(8)
            hello = exact(self.request, 68)
            assert hello[28:48] == shared.info_hash
            self.request.sendall(hello[:48] + b"-SDTEST-" + b"0" * 12)
            frame(self.request, b"\x05" + bytes([0x80 if index == 0 else 0x40]))
            frame(self.request, b"\x01")
            while True:
                try:
                    length = struct.unpack(">I", exact(self.request, 4))[0]
                    message = exact(self.request, length)
                except EOFError:
                    return
                if len(message) != 13 or message[0] != 6:
                    continue
                piece, begin, amount = struct.unpack(">III", message[1:])
                assert piece == index and begin == 0 and amount == len(PIECES[index])
                shared.requested[index].set()
                if not shared.requested[1 - index].wait(6):
                    return
                frame(self.request, b"\x07" + struct.pack(">II", piece, begin) + PIECES[index])
    return Peer


def run(binary):
    shared = Shared()
    peers = [socketserver.ThreadingTCPServer(("127.0.0.1", 0), peer_type(i, shared)) for i in range(2)]
    shared.ports = [server.server_address[1] for server in peers]

    class Tracker(BaseHTTPRequestHandler):
        def do_GET(self):
            addresses = b"".join(socket.inet_aton("127.0.0.1") + struct.pack(">H", port) for port in shared.ports)
            body = bencode({b"interval": 60, b"peers": addresses})
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    tracker = ThreadingHTTPServer(("127.0.0.1", 0), Tracker)
    for server in [*peers, tracker]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="sd-parallel-peers-") as directory:
            folder = Path(directory)
            info = {b"length": len(PAYLOAD), b"name": b"two-peers.bin", b"piece length": 16384,
                    b"pieces": b"".join(hashlib.sha1(piece).digest() for piece in PIECES)}
            shared.info_hash = hashlib.sha1(bencode(info)).digest()
            source = folder / "two-peers.torrent"
            source.write_bytes(bencode({b"announce": f"http://127.0.0.1:{tracker.server_port}/announce".encode(), b"info": info}))
            destination = folder / "two-peers.bin"
            try:
                result = subprocess.run([str(Path(binary).resolve()), "torrent-download", str(source), str(destination)],
                                        capture_output=True, timeout=8)
            except subprocess.TimeoutExpired as exc:
                raise AssertionError("Only one peer requested a piece before timeout") from exc
            assert all(event.is_set() for event in shared.requested), "Both peers must request pieces concurrently"
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            assert destination.read_bytes() == PAYLOAD
            print("PASS: both peers transferred distinct verified pieces concurrently")
    finally:
        for server in [*peers, tracker]:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    run(sys.argv[1])
