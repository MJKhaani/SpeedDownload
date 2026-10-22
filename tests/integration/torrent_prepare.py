"""Check torrent review preparation without contacting trackers or a swarm."""
from __future__ import annotations
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import socketserver
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import unquote, urlsplit
import uuid


def bencode(value):
    if isinstance(value, bytes): return str(len(value)).encode() + b":" + value
    if isinstance(value, int): return b"i" + str(value).encode() + b"e"
    if isinstance(value, list): return b"l" + b"".join(map(bencode, value)) + b"e"
    return b"d" + b"".join(bencode(key) + bencode(value[key]) for key in sorted(value)) + b"e"


INFO = {
    b"files": [{b"length": 1, b"path": [f"file-{i:03}.bin".encode()]} for i in range(250)],
    b"name": b"Review fixture", b"piece length": 16384,
    b"pieces": hashlib.sha1(b"x" * 250).digest(),
}
METAINFO = bencode({b"announce": b"https://tracker.example/announce", b"comment": b"Keep this extension", b"info": INFO})
INFO_HASH = hashlib.sha1(bencode(INFO)).hexdigest()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-bittorrent")
        self.send_header("Content-Length", str(len(METAINFO)))
        self.end_headers()
        self.wfile.write(METAINFO)
    def log_message(self, *_): pass


def exact(stream, length):
    data = b""
    while len(data) < length:
        chunk = stream.recv(length - len(data))
        if not chunk: raise RuntimeError("Engine closed connection")
        data += chunk
    return data


def exchange(stream, method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": method, "method": method, "params": params}).encode()
    stream.sendall(struct.pack("<I", len(payload)) + payload)
    response = json.loads(exact(stream, struct.unpack("<I", exact(stream, 4))[0]))
    assert "error" not in response, response
    return response["result"]



class MetadataPeer(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        hello = exact(self.request, 68)
        assert hello[28:48].hex() == INFO_HASH
        self.request.sendall(hello[:48] + b"-SDTEST-" + b"0" * 12)
        exact(self.request, struct.unpack(">I", exact(self.request, 4))[0])
        raw = bencode(INFO)
        def frame(value):
            self.request.sendall(struct.pack(">I", len(value)) + value)
        frame(b"\x14\x00" + bencode({b"m": {b"ut_metadata": 1}, b"metadata_size": len(raw)}))
        blocks = (len(raw) + 16383) // 16384
        for _ in range(blocks):
            request = exact(self.request, struct.unpack(">I", exact(self.request, 4))[0])
            piece = int(re.search(rb"5:piecei(\d+)e", request).group(1))
            frame(b"\x14\x01" + bencode({b"msg_type": 1, b"piece": piece, b"total_size": len(raw)}) + raw[piece * 16384:(piece + 1) * 16384])


def run(binary):
    with tempfile.TemporaryDirectory(prefix="sd-torrent-", dir="/private/tmp") as directory:
        folder = Path(directory)
        original = folder / "source file.torrent"
        original.write_bytes(METAINFO)
        source = original.as_uri().replace("file:", "torrent-file:", 1)
        env = dict(os.environ, TMPDIR=directory + "/", SPEED_DOWNLOAD_STATE_DIR=directory + "/state")
        engine = subprocess.Popen([str(Path(binary).resolve()), "engine"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        peer = socketserver.TCPServer(("127.0.0.1", 0), MetadataPeer)
        threading.Thread(target=peer.serve_forever, daemon=True).start()
        endpoint = folder / "speed-download/engine.sock"
        try:
            for _ in range(100):
                if endpoint.exists(): break
                if engine.poll() is not None: raise RuntimeError(engine.stderr.read().decode())
                time.sleep(.05)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(10)
                stream.connect(str(endpoint))
                exchange(stream, "engine.hello", {"protocol": {"major": 1, "minor": 0}, "client": {"kind": "regression", "version": "1"}, "features": ["torrents.prepare-v1"]})
                first = exchange(stream, "torrents.prepare", {"url": source})
                assert first["torrent_info_hash"] == INFO_HASH
                assert len(first["torrent_files"]) == 200
                second = exchange(stream, "torrents.prepare", {"url": first["final_url"], "offset": int(first["torrent_next_offset"])})
                assert len(second["torrent_files"]) == 50 and second["torrent_next_offset"] is None
                edited = exchange(stream, "torrents.prepare", {"url": first["final_url"], "trackers": ["udp://tracker.example:6969/announce"]})
                assert edited["torrent_info_hash"] == INFO_HASH
                assert edited["torrent_trackers"] == ["udp://tracker.example:6969/announce"]
                saved = Path(unquote(urlsplit(edited["final_url"]).path)).read_bytes()
                assert bencode(INFO) in saved and b"Keep this extension" in saved
                assert original.read_bytes() == METAINFO
                remote = exchange(stream, "torrents.prepare", {"url": f"http://127.0.0.1:{server.server_port}/download?id=1"})
                assert remote["torrent_info_hash"] == INFO_HASH
                magnet = exchange(stream, "torrents.prepare", {"url": f"magnet:?xt=urn:btih:{INFO_HASH}&x.pe=127.0.0.1:{peer.server_address[1]}&tr=https%3A%2F%2Ftracker.example%2Fannounce"})
                assert magnet["torrent_info_hash"] == INFO_HASH and magnet["torrent_file_count"] == 250
                settings = exchange(stream, "settings.get", {})
                settings["queue_schedule_enabled"] = True
                settings["queue_schedule_slots"] = [False] * 168
                exchange(stream, "settings.update", {"settings": settings})
                chosen = [first["torrent_files"][0]["path"], second["torrent_files"][0]["path"]]
                job = exchange(stream, "jobs.add", {"url": edited["final_url"], "name": "Selected files", "destination": directory,
                    "idempotency_key": str(uuid.uuid4()), "selected_torrent_files": chosen, "torrent_info_hash": INFO_HASH})
                record = next(entry for entry in json.loads((folder / "state/jobs.json").read_text())["jobs"] if entry["id"] == job["job_id"])
                assert record["selected_torrent_files"] == chosen
                print("PASS: local/remote/magnet preparation, paged file lists, tracker edits, unchanged info hash, and queued file selection")
        except BaseException:
            if engine.poll() is not None:
                print(engine.stderr.read().decode(errors="replace"), file=sys.stderr)
            raise
        finally:
            server.shutdown(); server.server_close()
            peer.shutdown(); peer.server_close()
            engine.terminate()
            try: engine.wait(timeout=5)
            except subprocess.TimeoutExpired: engine.kill(); engine.wait()


if __name__ == "__main__": run(sys.argv[1])
