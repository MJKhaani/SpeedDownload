"""Local-only smoke test for the early HTTP CLI; requires no external service."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
import threading


PAYLOAD = b"local fixture payload\x00with binary data\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/missing":
            status, body = 404, b"missing"
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/download")
            self.end_headers()
            return
        else:
            status, body = 200, PAYLOAD

        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def run(binary: str, url: str, destination: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [binary, url, str(destination)],
        capture_output=True,
        timeout=10,
        check=False,
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: http_cli.py <odm-binary>")
    binary = str(Path(sys.argv[1]).resolve())
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_port}"

    try:
        with tempfile.TemporaryDirectory(prefix="odm-http-test-") as tmp:
            successful_path = Path(tmp) / "download.bin"
            result = run(binary, base_url + "/redirect", successful_path)
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            assert successful_path.read_bytes() == PAYLOAD
            assert not Path(str(successful_path) + ".part").exists()

            overwrite = run(binary, base_url + "/download", successful_path)
            assert overwrite.returncode != 0
            assert successful_path.read_bytes() == PAYLOAD

            missing_path = Path(tmp) / "missing.bin"
            missing = run(binary, base_url + "/missing", missing_path)
            assert missing.returncode != 0
            assert not missing_path.exists()
            assert not Path(str(missing_path) + ".part").exists()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    print("HTTP CLI integration checks passed.")


if __name__ == "__main__":
    main()
