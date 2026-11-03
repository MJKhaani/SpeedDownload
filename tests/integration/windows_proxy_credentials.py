"""Exercise endpoint-scoped Windows Credential Manager proxy authentication."""
import base64
import ctypes
from ctypes import wintypes
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

import ipc_engine as ipc

if os.name != "nt":
    raise SystemExit("This test requires Windows Credential Manager")


class Credential(ctypes.Structure):
    _fields_ = [("flags", wintypes.DWORD), ("type", wintypes.DWORD), ("target", wintypes.LPWSTR),
                ("comment", wintypes.LPWSTR), ("last_written", wintypes.FILETIME),
                ("blob_size", wintypes.DWORD), ("blob", ctypes.POINTER(ctypes.c_ubyte)),
                ("persist", wintypes.DWORD), ("attribute_count", wintypes.DWORD),
                ("attributes", ctypes.c_void_p), ("alias", wintypes.LPWSTR), ("username", wintypes.LPWSTR)]


advapi = ctypes.WinDLL("advapi32", use_last_error=True)
advapi.CredWriteW.argtypes = [ctypes.POINTER(Credential), wintypes.DWORD]
advapi.CredWriteW.restype = wintypes.BOOL
advapi.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
advapi.CredDeleteW.restype = wintypes.BOOL


class Proxy(BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):
        self.seen.append(self.headers.get("Proxy-Authorization"))
        self.send_response(206)
        self.send_header("Content-Length", "1")
        self.send_header("Content-Range", "bytes 0-0/2")
        self.send_header("ETag", '"fixture"')
        self.end_headers()
        self.wfile.write(b"x")

    def log_message(self, *_args):
        pass


binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="sd-win-proxy-") as temporary:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    pipe = ipc.windows_pipe_identity()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.restype = ctypes.c_void_p
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel32.CreateFileW(pipe, 0xC0000000, 0, None, 3, 0, None)
    if handle not in (None, ctypes.c_void_p(-1).value):
        kernel32.CloseHandle(handle)
        raise RuntimeError("A Speed Download engine is already running; stop it before this isolated test")
    if ctypes.get_last_error() != 2:
        raise RuntimeError("Cannot safely determine whether a Speed Download engine is already running")
    endpoint = f"http://127.0.0.1:{server.server_port}"
    target = "SpeedDownload.ManualProxy." + hashlib.sha256(endpoint.encode()).hexdigest()
    secret = ctypes.create_string_buffer(b"fixture-user\nfixture-password")
    credential = Credential(type=1, target=target, blob_size=len(secret.raw) - 1,
                            blob=ctypes.cast(secret, ctypes.POINTER(ctypes.c_ubyte)), persist=2, username="fixture-user")
    if not advapi.CredWriteW(ctypes.byref(credential), 0):
        raise ctypes.WinError(ctypes.get_last_error())
    env = dict(os.environ, SPEED_DOWNLOAD_STATE_DIR=str(Path(temporary) / "state"))
    engine = None
    stream = None
    try:
        engine = subprocess.Popen([binary, "engine"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stream = ipc.connect_pipe(pipe, time.monotonic() + 10)
        time.sleep(0.25)
        if engine.poll() is not None:
            raise RuntimeError("The isolated test engine exited before proxy configuration")
        hello = ipc.rpc(stream, "engine.hello", {"protocol": {"major": 1, "minor": 0},
            "client": {"kind": "proxy-test", "version": "1"}, "features": ["proxy.windows-credentials-v1"]})
        if "proxy.windows-credentials-v1" not in hello.get("features", []):
            raise RuntimeError("Windows proxy credential capability is missing")
        settings = ipc.rpc(stream, "settings.get", {})
        settings.update(proxy_mode="custom", proxy_url=endpoint, proxy_authentication_required=True)
        ipc.rpc(stream, "settings.update", {"settings": settings})
        ipc.rpc(stream, "jobs.probe", {"url": "http://fixture.invalid/file"})
        expected = "Basic " + base64.b64encode(b"fixture-user:fixture-password").decode()
        if Proxy.seen != [expected]:
            raise RuntimeError("The manual proxy did not receive the expected authorization")
        settings["proxy_url"] = f"http://localhost:{server.server_port}"
        ipc.rpc(stream, "settings.update", {"settings": settings})
        if ipc.rpc_error_code(stream, "jobs.probe", {"url": "http://fixture.invalid/file"}) != -32021 or Proxy.seen != [expected]:
            raise RuntimeError("Credentials were reused for a different proxy endpoint")
        settings["proxy_url"] = endpoint
        ipc.rpc(stream, "settings.update", {"settings": settings})
        if ipc.rpc_error_code(stream, "jobs.probe", {"url": "https://fixture.invalid/file"}) != -32021:
            raise RuntimeError("Authenticated HTTPS proxy did not fail closed")
        print("PASS: Windows credential-backed HTTP proxy and fail-closed HTTPS")
    finally:
        if stream is not None: stream.close()
        if engine is not None and engine.poll() is None: engine.terminate(); engine.wait(timeout=10)
        advapi.CredDeleteW(target, 1, 0)
        ctypes.memset(ctypes.addressof(secret), 0, ctypes.sizeof(secret))
        server.shutdown(); server.server_close()
