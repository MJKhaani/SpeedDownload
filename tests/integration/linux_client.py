#!/usr/bin/env python3
"""Launch the actual GTK window on Xvfb and observe its post-render state."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid


ENGINE = str(Path(sys.argv[1]).resolve())
CLIENT = str(Path(sys.argv[2]).resolve())


def exact(stream, size):
    result = bytearray()
    while len(result) < size:
        chunk = stream.recv(size - len(result))
        if not chunk:
            raise RuntimeError("IPC connection closed")
        result.extend(chunk)
    return result


def rpc(socket_path, method, params):
    with socket.socket(socket.AF_UNIX) as stream:
        stream.connect(socket_path)
        for number, name, arguments in (
            (1, "engine.hello", {"protocol": {"major": 1, "minor": 0},
                                  "client": {"kind": "phase0-gtk", "version": "0.1.0"}, "features": []}),
            (2, method, params),
        ):
            payload = json.dumps({"jsonrpc": "2.0", "id": number,
                                  "method": name, "params": arguments}).encode()
            stream.sendall(struct.pack("<I", len(payload)) + payload)
            size = struct.unpack("<I", exact(stream, 4))[0]
            response = json.loads(exact(stream, size))
            if "error" in response:
                raise RuntimeError(f"{name}: {response['error']}")
            if name == "engine.hello":
                instance = response["result"]["engine_instance_id"]
            else:
                return instance, response["result"]


def until(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise TimeoutError("GTK client did not reach the expected state")


class Handler(BaseHTTPRequestHandler):
    size = 8 * 1024 * 1024

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", str(self.size))
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(self.size))
        self.end_headers()
        try:
            for _ in range(self.size // 16384):
                self.wfile.write(b"g" * 16384)
                self.wfile.flush()
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="sd-phase0-gtk-") as root:
    root = Path(root)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    downloads = root / "downloads"
    downloads.mkdir()
    report = root / "ui-state.txt"
    env = os.environ.copy()
    env.update(XDG_RUNTIME_DIR=str(runtime), SPEED_DOWNLOAD_STATE_DIR=str(root / "state"),
               SPEED_DOWNLOAD_ENGINE_PATH=ENGINE, SPEED_DOWNLOAD_PHASE0_REPORT=str(report))
    endpoint = str(runtime / "speed-download" / "engine.sock")
    engine = subprocess.Popen([ENGINE, "engine"], env=env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    client = None
    server = None
    try:
        until(lambda: Path(endpoint).exists())
        client = subprocess.Popen([CLIENT], env=env, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        until(lambda: report.exists() and report.read_text().startswith("Engine connected"))
        first_instance, _ = rpc(endpoint, "jobs.list", {"offset": 0, "limit": 50})

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        _, added = rpc(endpoint, "jobs.add", {
            "url": f"http://127.0.0.1:{server.server_port}/gtk-progress.bin",
            "name": "gtk-progress.bin", "destination": str(downloads),
            "idempotency_key": str(uuid.uuid4()), "priority": 0,
        })
        job_id = added["job_id"]
        observed_ui_states = []

        def progress_visible():
            if not report.exists():
                return False
            current_report = report.read_text()
            if not observed_ui_states or current_report != observed_ui_states[-1]:
                observed_ui_states.append(current_report)
            for line in current_report.splitlines()[1:]:
                fields = line.split("\t")
                if len(fields) == 3 and fields[0] == job_id and 0 < int(fields[2]) < Handler.size:
                    return True
            return False

        try:
            until(progress_visible, timeout=40)
        except TimeoutError:
            print("GTK report:", report.read_text() if report.exists() else "<missing>", flush=True)
            print("GTK state history:", observed_ui_states, flush=True)
            print("Engine jobs:", rpc(endpoint, "jobs.list", {"offset": 0, "limit": 50})[1], flush=True)
            print("GTK exit status:", client.poll(), flush=True)
            raise
        engine.terminate()
        engine.wait(timeout=10)
        until(lambda: report.exists() and report.read_text().startswith("Engine disconnected"))

        def reconnected():
            if not Path(endpoint).exists():
                return False
            try:
                instance, _ = rpc(endpoint, "jobs.list", {"offset": 0, "limit": 50})
                return instance != first_instance and report.read_text().startswith("Engine connected")
            except (OSError, RuntimeError):
                return False

        until(reconnected, timeout=40)
        if client.poll() is not None:
            raise RuntimeError("GTK client exited during restart")
        print("Phase 0 GTK GUI smoke passed: connection, visible progress, disconnect, restart/reconnect")
    finally:
        if server is not None:
            server.shutdown()
        if client is not None:
            client.terminate()
            try:
                client.wait(timeout=10)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait()
        if engine.poll() is None:
            engine.terminate()
            engine.wait(timeout=10)
