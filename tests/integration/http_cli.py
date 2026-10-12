"""Local-only HTTP CLI integration checks; requires no external service."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time


PAYLOAD = b"local fixture payload\x00with binary data\n"
LARGE_PAYLOAD = bytes(i % 251 for i in range(4 * 1024 * 1024))
ETAG = '"fixture-v1"'
CHANGED_ETAG = '"fixture-v2"'
resume_requests = {"/resume": 0, "/resume-change": 0, "/target-a": 0, "/target-b": 0}
ranged_requests = {"/resume": 0, "/resume-change": 0, "/target-a": 0, "/target-b": 0}
redirect_resume_requests = 0
request_lock = threading.Lock()
race_destination = None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/race":
            assert race_destination is not None
            race_destination.write_bytes(b"concurrent winner")
        if self.path == "/redirect-resume":
            global redirect_resume_requests
            with request_lock:
                redirect_resume_requests += 1
                target = "/target-a" if redirect_resume_requests == 1 else "/target-b"
            self.send_response(302)
            self.send_header("Location", target)
            self.end_headers()
            return
        if self.path in resume_requests:
            self.handle_resume_fixture()
            return
        if self.path == "/missing":
            status, body = 404, b"missing"
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/download")
            self.end_headers()
            return
        elif self.path == "/partial":
            status, body = 206, PAYLOAD
        elif self.path == "/compressed":
            status, body = 200, PAYLOAD
        else:
            status, body = 200, PAYLOAD

        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if self.path == "/partial":
            self.send_header("Content-Range", f"bytes 0-{len(body) - 1}/{len(body)}")
        if self.path == "/compressed":
            self.send_header("Content-Encoding", "gzip")
        self.end_headers()
        self.wfile.write(body)

    def handle_resume_fixture(self):
        route = self.path
        with request_lock:
            resume_requests[route] += 1
            request_number = resume_requests[route]

        range_header = self.headers.get("Range")
        if range_header:
            match = re.fullmatch(r"bytes=(\d+)-", range_header)
            assert match, range_header
            offset = int(match.group(1))
            with request_lock:
                ranged_requests[route] += 1
            etag = CHANGED_ETAG if route == "/resume-change" else ETAG
            body = LARGE_PAYLOAD[offset:]
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {offset}-{len(LARGE_PAYLOAD) - 1}/{len(LARGE_PAYLOAD)}")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("ETag", etag)
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            return

        self.send_response(200)
        self.send_header("Content-Length", str(len(LARGE_PAYLOAD)))
        self.send_header("ETag", ETAG)
        self.end_headers()
        if request_number > 1:
            self.wfile.write(LARGE_PAYLOAD)
            return

        # Close the response before its declared length. The client should
        # preserve only bytes covered by its last synced journal checkpoint.
        try:
            stop = 3 * 1024 * 1024
            for start in range(0, stop, 16 * 1024):
                self.wfile.write(LARGE_PAYLOAD[start : start + 16 * 1024])
                self.wfile.flush()
                time.sleep(0.001)
        except (BrokenPipeError, ConnectionResetError, socket.error):
            pass
        self.close_connection = True

    def log_message(self, *_args):
        pass


def run(binary: str, url: str, destination: Path, *options: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [binary, *options, url, str(destination)],
        capture_output=True,
        timeout=10,
        check=False,
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: http_cli.py <speed-download-binary>")
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_port}"

    try:
        with tempfile.TemporaryDirectory(prefix="speed-download-http-test-") as tmp:
            successful_path = Path(tmp) / "download.bin"
            result = run(binary, base_url + "/redirect", successful_path)
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            assert successful_path.read_bytes() == PAYLOAD
            assert not Path(str(successful_path) + ".part").exists()

            checksum_path = Path(tmp) / "checksum.bin"
            expected_digest = hashlib.sha256(PAYLOAD).hexdigest()
            verified = run(binary, base_url + "/download", checksum_path, "--sha256", expected_digest)
            assert verified.returncode == 0, verified.stderr.decode(errors="replace")
            assert checksum_path.read_bytes() == PAYLOAD

            mismatch_path = Path(tmp) / "checksum-mismatch.bin"
            mismatch = run(binary, base_url + "/download", mismatch_path, "--sha256", "0" * 64)
            assert mismatch.returncode != 0
            assert b"SHA-256 mismatch" in mismatch.stderr
            assert not mismatch_path.exists()

            malformed_checksum = run(binary, base_url + "/download", Path(tmp) / "malformed.bin", "--sha256", "not-a-digest")
            assert malformed_checksum.returncode != 0
            assert b"exactly 64 hexadecimal digits" in malformed_checksum.stderr

            overwrite = run(binary, base_url + "/download", successful_path)
            assert overwrite.returncode != 0
            assert successful_path.read_bytes() == PAYLOAD

            global race_destination
            race_destination = Path(tmp) / "raced.bin"
            raced = run(binary, base_url + "/race", race_destination)
            assert raced.returncode != 0
            assert b"destination already exists" in raced.stderr
            assert race_destination.read_bytes() == b"concurrent winner"

            missing_path = Path(tmp) / "missing.bin"
            missing = run(binary, base_url + "/missing", missing_path)
            assert missing.returncode != 0
            assert not missing_path.exists()
            assert not Path(str(missing_path) + ".part").exists()

            for route in ("/partial", "/compressed"):
                rejected_path = Path(tmp) / (route[1:] + ".bin")
                rejected = run(binary, base_url + route, rejected_path)
                assert rejected.returncode != 0
                assert not rejected_path.exists()
                assert not Path(str(rejected_path) + ".part").exists()

            resume_path = Path(tmp) / "resumed.bin"
            interrupted = run(binary, base_url + "/resume", resume_path)
            assert interrupted.returncode != 0
            resume_part = Path(str(resume_path) + ".part")
            resume_journal = Path(str(resume_part) + ".odm")
            assert resume_part.exists() and resume_journal.exists()
            assert resume_part.stat().st_size >= 1024 * 1024, (
                f"durable prefix too small: {resume_part.stat().st_size}; "
                f"stderr={interrupted.stderr.decode(errors='replace')}"
            )

            resumed_digest = hashlib.sha256(LARGE_PAYLOAD).hexdigest()
            resumed = run(binary, base_url + "/resume", resume_path, "--sha256", resumed_digest)
            assert resumed.returncode == 0, resumed.stderr.decode(errors="replace")
            assert ranged_requests["/resume"] == 1
            assert resume_path.read_bytes() == LARGE_PAYLOAD
            assert not resume_part.exists() and not resume_journal.exists()

            changed_path = Path(tmp) / "changed.bin"
            first_attempt = run(binary, base_url + "/resume-change", changed_path)
            assert first_attempt.returncode != 0
            changed_part = Path(str(changed_path) + ".part")
            changed_journal = Path(str(changed_part) + ".odm")
            assert changed_part.exists() and changed_journal.exists()
            assert changed_part.stat().st_size >= 1024 * 1024, (
                f"changed-resource test had no durable prefix: {changed_part.stat().st_size}; "
                f"stderr={first_attempt.stderr.decode(errors='replace')}"
            )

            changed = run(binary, base_url + "/resume-change", changed_path)
            assert changed.returncode != 0, (
                f"changed ETag was accepted; ranged={ranged_requests['/resume-change']}; "
                f"stderr={changed.stderr.decode(errors='replace')}"
            )
            assert ranged_requests["/resume-change"] == 1
            assert not changed_path.exists()
            assert changed_part.exists() and changed_journal.exists()

            redirect_path = Path(tmp) / "redirect-change.bin"
            redirect_first = run(binary, base_url + "/redirect-resume", redirect_path)
            assert redirect_first.returncode != 0
            redirect_part = Path(str(redirect_path) + ".part")
            redirect_journal = Path(str(redirect_part) + ".odm")
            assert redirect_part.exists() and redirect_journal.exists()
            redirect_changed = run(binary, base_url + "/redirect-resume", redirect_path)
            assert redirect_changed.returncode != 0
            assert ranged_requests["/target-b"] == 1
            assert not redirect_path.exists()
            assert redirect_part.exists() and redirect_journal.exists()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    print("HTTP CLI integration checks passed.")


if __name__ == "__main__":
    main()
