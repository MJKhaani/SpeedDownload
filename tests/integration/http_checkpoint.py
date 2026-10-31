"""Exercise exact multipart checkpoint boundaries through the real CLI."""

import hashlib
import http.server
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import time


PAYLOAD = bytes(range(251)) * ((16 * 1024 * 1024 // 251) + 1)
PAYLOAD = PAYLOAD[: 16 * 1024 * 1024]
ETAG = '"checkpoint-boundary"'
RANGES = []


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if not match:
            self.send_error(400, "Range header required")
            return
        start, end = map(int, match.groups())
        RANGES.append((start, end))
        if start > end or end >= len(PAYLOAD):
            self.send_error(416)
            return
        body = memoryview(PAYLOAD)[start : end + 1]
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Range", f"bytes {start}-{end}/{len(PAYLOAD)}")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", ETAG)
        self.end_headers()
        for offset in range(0, len(body), 32 * 1024):
            self.wfile.write(body[offset : offset + 32 * 1024])

    def log_message(self, *args):
        pass


def main():
    with tempfile.TemporaryDirectory() as folder:
        root = pathlib.Path(folder)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            destination = root / "multipart.bin"
            process = subprocess.Popen(
                [sys.argv[1], f"http://127.0.0.1:{server.server_port}/file", str(destination)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            sidecar_seen = False
            deadline = time.monotonic() + 90
            while process.poll() is None and time.monotonic() < deadline:
                sidecar_seen |= any(root.glob("*.sdr*"))
                time.sleep(0.02)
            if process.poll() is None:
                process.kill()
                raise AssertionError("Multipart CLI timed out")
            stdout, stderr = process.communicate()
            if process.returncode != 0:
                raise AssertionError(f"Multipart CLI exited {process.returncode}: {stderr.decode(errors='replace')}")
            if sidecar_seen:
                raise AssertionError("Checkpoint sidecar appeared beside the download")
            if len(RANGES) < 5 or (0, 0) not in RANGES:
                raise AssertionError(f"Expected range probe and multipart workers, got {RANGES}")
            if hashlib.sha256(destination.read_bytes()).digest() != hashlib.sha256(PAYLOAD).digest():
                raise AssertionError("Multipart output differs from server payload")
            print("Multipart checkpoint boundary smoke passed")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
