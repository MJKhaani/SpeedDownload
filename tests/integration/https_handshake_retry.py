"""A dropped TLS handshake must leave a queued transfer eligible for retry."""
from pathlib import Path
import os
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import ipc_engine as ipc


class DropHandshake(socketserver.BaseRequestHandler):
    def handle(self):
        # Close after the client sends its TLS ClientHello, without an alert.
        self.request.settimeout(3)
        self.request.recv(4096)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="sd-tls-retry-", dir="/private/tmp" if sys.platform == "darwin" else None) as temp:
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
        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True
        server = Server(("127.0.0.1", 0), DropHandshake)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        log = (root / "engine.log").open("w+")
        process = subprocess.Popen([binary, "engine"], env=env, stdout=log, stderr=log)
        try:
            try:
                stream = ipc.new_connection(endpoint) if os.name == "nt" else ipc.connect_unix(endpoint, time.monotonic() + 10)
            except TimeoutError:
                log.flush(); log.seek(0)
                raise RuntimeError(f"Engine did not start: {log.read()}")
            try:
                ipc.rpc(stream, "engine.hello", {"protocol": {"major": 1, "minor": 0}, "client": {"kind": "tls-retry-test", "version": "1"}, "features": []})
                settings = ipc.rpc(stream, "settings.get", {})
                settings["proxy_mode"] = "disabled"
                settings["debug_log_enabled"] = True
                ipc.rpc(stream, "settings.update", {"settings": settings})
                job = ipc.rpc(stream, "jobs.add", {"url": f"https://127.0.0.1:{server.server_address[1]}/file", "name": "file.bin", "destination": str(destination), "idempotency_key": str(uuid.uuid4()), "priority": 0})
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    current = next(x for x in ipc.rpc(stream, "jobs.list", {"offset": 0, "limit": 50})["jobs"] if x["job_id"] == job["job_id"])
                    if current["state"] in ("retry_wait", "failed"):
                        assert current["state"] == "retry_wait", f"TLS handshake failure was not retried: {current['state']}, {current.get('error_message')}"
                        log_text = (state / "engine-debug.log").read_text()
                        assert "tls.handshake" in log_text and "underlying handshake error" in log_text
                        print("PASS: interrupted TLS handshake is queued for bounded retry")
                        return
                    time.sleep(0.05)
                raise TimeoutError("TLS failure did not reach retry or failed state")
            finally:
                stream.close()
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
            server.shutdown(); server.server_close()
            log.close()


if __name__ == "__main__":
    main()
