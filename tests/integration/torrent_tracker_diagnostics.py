"""Tracker failures must be diagnosable without logging tracker credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import ipc_engine as ipc
from torrent_parallel_peers import bencode


class RejectedTracker(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args):
        pass


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="sd-torrent-diag-", dir="/private/tmp" if sys.platform == "darwin" else None) as temp:
        root = Path(temp)
        state, destination = root / "state", root / "downloads"
        state.mkdir(); destination.mkdir()
        env = os.environ.copy()
        env["SPEED_DOWNLOAD_STATE_DIR"] = str(state)
        if os.name == "nt":
            endpoint = ipc.windows_pipe_identity()
        else:
            runtime = root / "run"
            runtime.mkdir(mode=0o700)
            env["HOME"] = str(root)
            env["TMPDIR" if sys.platform == "darwin" else "XDG_RUNTIME_DIR"] = str(runtime) + os.sep
            endpoint = str(runtime / "speed-download" / "engine.sock")
        server = ThreadingHTTPServer(("127.0.0.1", 0), RejectedTracker)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        info = {b"length": 4, b"name": b"fixture.bin", b"piece length": 4,
                b"pieces": hashlib.sha1(b"data").digest(), b"private": 1}
        torrent = root / "fixture.torrent"
        tracker = f"http://127.0.0.1:{server.server_port}/announce?token=secret".encode()
        torrent.write_bytes(bencode({b"announce": tracker, b"info": info}))
        source = torrent.as_uri().replace("file:", "torrent-file:", 1)
        process = subprocess.Popen([binary, "engine"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            stream = ipc.new_connection(endpoint) if os.name == "nt" else ipc.connect_unix(endpoint, time.monotonic() + 10)
            try:
                ipc.rpc(stream, "engine.hello", {"protocol": {"major": 1, "minor": 0}, "client": {"kind": "torrent-diagnostic-test", "version": "1"}, "features": []})
                settings = ipc.rpc(stream, "settings.get", {})
                settings["debug_log_enabled"] = True
                settings["proxy_mode"] = "disabled"
                ipc.rpc(stream, "settings.update", {"settings": settings})
                job = ipc.rpc(stream, "jobs.add", {"url": source, "name": "fixture.bin", "destination": str(destination), "idempotency_key": str(uuid.uuid4()), "priority": 0})
                deadline = time.monotonic() + 15
                log_file = state / "engine-debug.log"
                while time.monotonic() < deadline:
                    text = log_file.read_text() if log_file.exists() else ""
                    if "stage=tracker error=" in text and not text.split("stage=tracker error=")[-1].splitlines()[0].startswith("none"):
                        assert f"job={job['job_id']}" in text
                        assert "token=secret" not in text
                        print("PASS: tracker failure is logged without its URL or token")
                        return
                    time.sleep(0.05)
                raise AssertionError("Tracker failure diagnostic was not recorded")
            finally:
                stream.close()
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            server.shutdown(); server.server_close()


if __name__ == "__main__":
    main()
