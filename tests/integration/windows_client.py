#!/usr/bin/env python3
"""Exercise a published WinUI window and its live engine state on Windows CI."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import ipc_engine as ipc


ENGINE = str(Path(sys.argv[1]).resolve())
CLIENT = str(Path(sys.argv[2]).resolve())


def until(predicate, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise TimeoutError("WinUI client did not reach the expected state")


def rpc(endpoint, method, params):
    stream = ipc.connect_pipe(endpoint, time.monotonic() + 2)
    try:
        hello = ipc.rpc(stream, "engine.hello", {
            "protocol": {"major": 1, "minor": 0},
            "client": {"kind": "phase0-winui", "version": "0.1.0"}, "features": [],
        })
        return hello["engine_instance_id"], ipc.rpc(stream, method, params)
    finally:
        stream.close()


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
                self.wfile.write(b"w" * 16384)
                self.wfile.flush()
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="sd-phase0-winui-") as root:
    root = Path(root)
    state = root / "state"
    state.mkdir()
    downloads = root / "downloads"
    downloads.mkdir()
    report = root / "ui-state.txt"
    env = os.environ.copy()
    env.update(SPEED_DOWNLOAD_STATE_DIR=str(state), SPEED_DOWNLOAD_ENGINE_PATH=ENGINE,
               SPEED_DOWNLOAD_PHASE0_REPORT=str(report))
    endpoint = ipc.windows_pipe_identity()
    engine = subprocess.Popen([ENGINE, "engine"], env=env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    client = None
    server = None
    try:
        def engine_ready():
            try:
                return ipc.one_connection(endpoint) is not None
            except (OSError, TimeoutError):
                return False

        until(engine_ready)
        client = subprocess.Popen([CLIENT], env=env, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        until(lambda: report.exists() and report.read_text().startswith("Engine connected"))
        first_instance, _ = rpc(endpoint, "jobs.list", {"offset": 0, "limit": 50})

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        _, added = rpc(endpoint, "jobs.add", {
            "url": f"http://127.0.0.1:{server.server_port}/winui-progress.bin",
            "name": "winui-progress.bin", "destination": str(downloads),
            "idempotency_key": str(uuid.uuid4()), "priority": 0,
        })
        job_id = added["job_id"]

        def progress_visible():
            if not report.exists():
                return False
            for line in report.read_text().splitlines()[1:]:
                fields = line.split("\t")
                if len(fields) == 3 and fields[0] == job_id and 0 < int(fields[2]) < Handler.size:
                    return True
            return False

        until(progress_visible, timeout=40)
        engine.terminate()
        engine.wait(timeout=10)
        until(lambda: report.exists() and report.read_text().startswith("Engine disconnected"))

        def reconnected():
            try:
                instance, _ = rpc(endpoint, "jobs.list", {"offset": 0, "limit": 50})
                return instance != first_instance and report.read_text().startswith("Engine connected")
            except (OSError, RuntimeError, TimeoutError):
                return False

        until(reconnected, timeout=40)
        if client.poll() is not None:
            raise RuntimeError("WinUI client exited during restart")
        print("Phase 0 WinUI GUI smoke passed: connection, visible progress, disconnect, restart/reconnect")
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
