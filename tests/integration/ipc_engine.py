"""Native local IPC and transfer smoke check for Phase 0 CI runners."""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import uuid


MAX_FRAME = 1_048_576
PAYLOAD = bytes(index % 251 for index in range(4 * 1024 * 1024))


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        try:
            for offset in range(0, len(PAYLOAD), 16 * 1024):
                self.wfile.write(PAYLOAD[offset : offset + 16 * 1024])
                self.wfile.flush()
                time.sleep(0.004)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_args):
        pass


class PipeStream:
    def __init__(self, handle):
        self.handle = handle
        self.kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        self.kernel32.CloseHandle.restype = ctypes.c_int
        self.kernel32.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]
        self.kernel32.WriteFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p]

    def read_exact(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = ctypes.create_string_buffer(size - len(result))
            count = ctypes.c_uint32()
            if not self.kernel32.ReadFile(self.handle, chunk, len(chunk), ctypes.byref(count), None):
                raise OSError(ctypes.get_last_error(), "ReadFile failed")
            result.extend(chunk.raw[: count.value])
        return bytes(result)

    def write_all(self, data):
        offset = 0
        while offset < len(data):
            chunk = ctypes.create_string_buffer(data[offset:])
            count = ctypes.c_uint32()
            if not self.kernel32.WriteFile(self.handle, chunk, len(chunk) - 1, ctypes.byref(count), None):
                raise OSError(ctypes.get_last_error(), "WriteFile failed")
            offset += count.value

    def close(self):
        self.kernel32.CloseHandle(self.handle)


def windows_pipe_identity():
    command = (
        "[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value;"
        "[System.Diagnostics.Process]::GetCurrentProcess().SessionId"
    )
    lines = subprocess.check_output(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", command], text=True
    ).splitlines()
    if len(lines) < 2:
        raise RuntimeError("Could not determine Windows pipe identity")
    return rf"\\.\pipe\SpeedDownload-{lines[0].strip()}-{lines[1].strip()}"


def connect_pipe(path, deadline):
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.restype = ctypes.c_void_p
    kernel32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    while time.monotonic() < deadline:
        handle = kernel32.CreateFileW(path, 0x80000000 | 0x40000000, 0, None, 3, 0, None)
        if handle not in (None, ctypes.c_void_p(-1).value):
            return PipeStream(handle)
        time.sleep(0.1)
    raise TimeoutError("Windows named pipe did not become available")


def connect_unix(path, deadline):
    import socket

    while time.monotonic() < deadline:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.connect(path)
            return client
        except OSError:
            client.close()
            time.sleep(0.1)
    raise TimeoutError(f"Unix socket did not become available: {path}")


def read_exact(stream, size):
    if isinstance(stream, PipeStream):
        return stream.read_exact(size)
    result = bytearray()
    while len(result) < size:
        chunk = stream.recv(size - len(result))
        if not chunk:
            raise ConnectionError("Engine closed the IPC stream")
        result.extend(chunk)
    return bytes(result)


def write_all(stream, data):
    if isinstance(stream, PipeStream):
        stream.write_all(data)
        return
    stream.sendall(data)


def rpc(stream, method, params):
    request_id = str(uuid.uuid4())
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
        separators=(",", ":"),
    ).encode()
    if not payload or len(payload) > MAX_FRAME:
        raise ValueError("IPC request exceeded frame limit")
    write_all(stream, len(payload).to_bytes(4, "little") + payload)
    size = int.from_bytes(read_exact(stream, 4), "little")
    if not 0 < size <= MAX_FRAME:
        raise ValueError("Engine returned an invalid frame size")
    response = json.loads(read_exact(stream, size))
    if response.get("id") != request_id:
        raise ValueError("Engine response ID did not match request")
    if "error" in response:
        raise RuntimeError(f"{method} failed: {response['error']}")
    return response["result"]


def one_connection(endpoint):
    if os.name == "nt":
        stream = connect_pipe(endpoint, time.monotonic() + 10)
    else:
        stream = connect_unix(endpoint, time.monotonic() + 10)
    try:
        hello = rpc(
            stream,
            "engine.hello",
            {
                "protocol": {"major": 1, "minor": 0},
                "client": {"kind": "phase0-smoke", "version": "0.1.0"},
                "features": [],
            },
        )
        if hello["protocol"]["major"] != 1 or not hello.get("engine_instance_id"):
            raise RuntimeError("Engine returned invalid handshake metadata")
        return rpc(stream, "jobs.list", {"offset": 0, "limit": 50})
    finally:
        stream.close()


def main():
    binary = Path(sys.argv[1]).resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)

    # Darwin's sockaddr_un path is short; the default per-user temp path can
    # already consume most of it before our runtime/socket suffix is added.
    temp_parent = "/private/tmp" if sys.platform == "darwin" else None
    with tempfile.TemporaryDirectory(prefix="sd-p0-", dir=temp_parent) as temp:
        root = Path(temp)
        state = root / "state"
        destination = root / "downloads"
        state.mkdir()
        destination.mkdir()
        env = os.environ.copy()
        env["SPEED_DOWNLOAD_STATE_DIR"] = str(state)
        if os.name == "nt":
            endpoint = windows_pipe_identity()
        else:
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            env["HOME"] = str(root)
            if sys.platform == "darwin":
                env["TMPDIR"] = str(runtime) + os.sep
            else:
                env["XDG_RUNTIME_DIR"] = str(runtime)
            endpoint = str(runtime / "speed-download" / "engine.sock")

        fixture = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        fixture_thread = threading.Thread(target=fixture.serve_forever, daemon=True)
        fixture_thread.start()
        log = (root / "engine.log").open("wb")
        process = None

        def start_engine():
            nonlocal process
            process = subprocess.Popen([str(binary), "engine"], env=env, stdout=log, stderr=log)
            return process

        try:
            start_engine()
            if process is None:
                raise RuntimeError("Engine process did not start")
            first = one_connection(endpoint)
            if first["total"] != "0":
                raise RuntimeError("Fresh engine should start with an empty job list")
            # Reconnect with a fresh transport/session and prove the listener accepts it.
            if one_connection(endpoint)["total"] != "0":
                raise RuntimeError("Engine reconnect smoke check failed")

            add_stream = connect_pipe(endpoint, time.monotonic() + 10) if os.name == "nt" else connect_unix(endpoint, time.monotonic() + 10)
            try:
                rpc(add_stream, "engine.hello", {
                    "protocol": {"major": 1, "minor": 0},
                    "client": {"kind": "phase0-smoke", "version": "0.1.0"},
                    "features": [],
                })
                rpc(add_stream, "jobs.add", {
                    "url": f"http://127.0.0.1:{fixture.server_port}/phase0.bin",
                    "name": "phase0.bin",
                    "destination": str(destination),
                    "idempotency_key": str(uuid.uuid4()),
                    "priority": 0,
                })
            finally:
                add_stream.close()

            deadline = time.monotonic() + 30
            saw_progress = False
            while time.monotonic() < deadline:
                listing = one_connection(endpoint)
                job = listing["jobs"][0]
                completed = int(job.get("received_bytes") or job["completed_bytes"] or "0")
                total = int(job.get("total_bytes") or "0")
                saw_progress |= job["state"] == "downloading" and 0 < completed < total
                if job["state"] == "completed":
                    break
                if job["state"] == "failed":
                    raise RuntimeError(f"Fixture job failed: {job.get('error_message')}")
                time.sleep(0.05)
            else:
                raise TimeoutError("Fixture download did not complete")
            if not saw_progress:
                raise RuntimeError("No live download progress was observed")
            output = destination / "phase0.bin"
            if not output.is_file() or output.read_bytes() != PAYLOAD:
                raise RuntimeError("Fixture download did not produce the expected bytes")

            process.terminate()
            process.wait(timeout=10)
            start_engine()
            recovered = one_connection(endpoint)
            if recovered["total"] != "1" or recovered["jobs"][0]["state"] != "completed":
                raise RuntimeError("Engine restart did not recover the completed job")
            print("Phase 0 IPC smoke passed: hello, list, reconnect, live progress, transfer, restart persistence")
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
            fixture.shutdown()
            fixture.server_close()
            fixture_thread.join(timeout=2)
            log.close()


if __name__ == "__main__":
    main()
