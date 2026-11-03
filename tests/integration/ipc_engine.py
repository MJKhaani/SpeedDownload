"""Native local IPC and transfer smoke check for Phase 0 CI runners."""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ctypes
import json
import os
from pathlib import Path
import stat
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
        self.send_header("ETag", '"phase0-fixture"')
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


def rpc_error_code(stream, method, params):
    request_id = str(uuid.uuid4())
    payload = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}, separators=(",", ":")).encode()
    write_all(stream, len(payload).to_bytes(4, "little") + payload)
    response = read_frame(stream)
    if response.get("id") != request_id or "error" not in response:
        raise RuntimeError(f"Expected an error for {method}, got {response}")
    return response["error"]["code"]


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


def new_connection(endpoint):
    return connect_pipe(endpoint, time.monotonic() + 10) if os.name == "nt" else connect_unix(endpoint, time.monotonic() + 10)


def read_frame(stream):
    size = int.from_bytes(read_exact(stream, 4), "little")
    if not 0 < size <= MAX_FRAME:
        raise ValueError("Engine returned an invalid event frame size")
    return json.loads(read_exact(stream, size))


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
        if os.name == "nt":
            (root / "queue action").mkdir()
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

            # A second daemon must not take over the same user profile/endpoint.
            competing = subprocess.Popen([str(binary), "engine"], env=env, stdout=log, stderr=log)
            try:
                try:
                    competing.wait(timeout=5)
                except subprocess.TimeoutExpired as error:
                    raise RuntimeError("Second engine remained running for the same profile") from error
                if competing.returncode == 0:
                    raise RuntimeError("Second engine reported successful startup for the same profile")
                if process.poll() is not None or one_connection(endpoint)["total"] != "0":
                    raise RuntimeError("Second engine disrupted the original instance")
            finally:
                if competing.poll() is None:
                    competing.terminate()
                    competing.wait(timeout=5)

            unnegotiated = new_connection(endpoint)
            try:
                if rpc_error_code(unnegotiated, "jobs.list", {"offset": 0, "limit": 1}) != -32001:
                    raise RuntimeError("Engine accepted a job request before handshake")
                if rpc_error_code(unnegotiated, "engine.hello", {
                    "protocol": {"major": 99, "minor": 0},
                    "client": {"kind": "phase0-smoke", "version": "0.1.0"},
                    "features": [],
                }) != -32002:
                    raise RuntimeError("Engine accepted an unsupported protocol major")
            finally:
                unnegotiated.close()
            if process.poll() is not None or one_connection(endpoint)["total"] != "0":
                raise RuntimeError("Invalid handshake disrupted the engine")

            simultaneous = []
            for _ in range(4):
                stream = new_connection(endpoint)
                simultaneous.append(stream)
                hello = rpc(stream, "engine.hello", {
                    "protocol": {"major": 1, "minor": 0},
                    "client": {"kind": "phase0-multi-client", "version": "0.1.0"},
                    "features": ["torrents.prepare-v1", "torrents.file-selection-v1", "jobs.per-job-bandwidth"],
                })
                if not {"torrents.prepare-v1", "torrents.file-selection-v1", "jobs.per-job-bandwidth"}.issubset(hello.get("features", [])):
                    raise RuntimeError("Engine did not negotiate torrent review, file selection, and per-download bandwidth")
            try:
                for stream in simultaneous:
                    if rpc(stream, "jobs.list", {"offset": 0, "limit": 1})["total"] != "0":
                        raise RuntimeError("Concurrent client saw inconsistent job state")
                status_stream = simultaneous[0]
                original_settings = rpc(status_stream, "settings.get", {})
                settings = dict(original_settings)
                settings["bandwidth_limit_bytes_per_second"] = 1_234_567
                settings["bandwidth_schedule_enabled"] = False
                rpc(status_stream, "settings.update", {"settings": settings})
                status = rpc(status_stream, "engine.status", {})
                if status.get("effective_bandwidth_limit_bytes_per_second") != 1_234_567 or status.get("scheduled_bandwidth_active") is not False:
                    raise RuntimeError("Engine status did not report the global bandwidth cap")
                settings["bandwidth_schedule_enabled"] = True
                settings["scheduled_bandwidth_limit_bytes_per_second"] = 456_789
                settings["bandwidth_schedule_slots"] = ["limited"] * 168
                rpc(status_stream, "settings.update", {"settings": settings})
                status = rpc(status_stream, "engine.status", {})
                if status.get("effective_bandwidth_limit_bytes_per_second") != 456_789 or status.get("scheduled_bandwidth_active") is not True:
                    raise RuntimeError("Engine status did not report the scheduled bandwidth cap")
                rpc(status_stream, "settings.update", {"settings": original_settings})
            finally:
                for stream in simultaneous:
                    stream.close()

            if os.name != "nt":
                for path in (Path(endpoint).parent, Path(endpoint)):
                    if stat.S_IMODE(path.stat().st_mode) & 0o077:
                        raise RuntimeError(f"IPC endpoint is accessible to other users: {path}")

            invalid = new_connection(endpoint)
            try:
                write_all(invalid, (MAX_FRAME + 1).to_bytes(4, "little"))
                try:
                    if read_exact(invalid, 1):
                        raise RuntimeError("Engine accepted an oversized IPC frame")
                except (OSError, ConnectionError):
                    pass
            finally:
                invalid.close()
            if one_connection(endpoint)["total"] != "0":
                raise RuntimeError("Engine failed after an oversized IPC frame")

            subscription_stream = new_connection(endpoint)
            rpc(subscription_stream, "engine.hello", {
                "protocol": {"major": 1, "minor": 0},
                "client": {"kind": "phase0-subscription-smoke", "version": "0.1.0"},
                "features": ["jobs.change-stream-v1"],
            })
            subscription = rpc(subscription_stream, "jobs.subscribe", {"max_updates_per_second": 5})
            if subscription["snapshot"]["total"] != "0":
                raise RuntimeError("Subscription did not start with an empty snapshot")

            add_stream = connect_pipe(endpoint, time.monotonic() + 10) if os.name == "nt" else connect_unix(endpoint, time.monotonic() + 10)
            try:
                hello = rpc(add_stream, "engine.hello", {
                    "protocol": {"major": 1, "minor": 0},
                    "client": {"kind": "phase0-smoke", "version": "0.1.0"},
                    "features": ["queue.finish-user-command-v1"],
                })
                if os.name == "nt":
                    if "queue.finish-user-command-v1" not in hello.get("features", []):
                        raise RuntimeError("Windows engine did not advertise queue completion commands")
                    settings = rpc(add_stream, "settings.get", {})
                    settings["debug_log_enabled"] = True
                    main_queue = next(q for q in settings["queues"] if q["id"] == "main")
                    main_queue["finish_action"] = "user_command"
                    main_queue["user_command"] = f'echo queue-finished>"{root / "queue action" / "queue-finished.txt"}"'
                    rpc(add_stream, "settings.update", {"settings": settings})
                rpc(add_stream, "jobs.add", {
                    "url": f"http://127.0.0.1:{fixture.server_port}/phase0.bin",
                    "name": "phase0.bin",
                    "destination": str(destination),
                    "idempotency_key": str(uuid.uuid4()),
                    "priority": 0,
                })
            finally:
                add_stream.close()

            event_result = []
            event_reader = threading.Thread(target=lambda: event_result.append(read_frame(subscription_stream)), daemon=True)
            event_reader.start()
            event_reader.join(timeout=10)
            subscription_stream.close()
            if not event_result or event_result[0].get("method") != "events.changed":
                raise RuntimeError("Subscription did not receive a job-change event")
            if event_result[0].get("params", {}).get("subscription_id") != subscription["subscription_id"]:
                raise RuntimeError("Subscription event ID did not match")

            deadline = time.monotonic() + 30
            saw_progress = False
            checked_busy_shutdown = False
            while time.monotonic() < deadline:
                listing = one_connection(endpoint)
                job = listing["jobs"][0]
                completed = int(job.get("received_bytes") or job["completed_bytes"] or "0")
                total = int(job.get("total_bytes") or "0")
                saw_progress |= job["state"] == "downloading" and 0 < completed < total
                if os.name == "nt" and saw_progress and not checked_busy_shutdown:
                    active_control = new_connection(endpoint)
                    try:
                        rpc(active_control, "engine.hello", {"protocol": {"major": 1, "minor": 0},
                            "client": {"kind": "shutdown-test", "version": "1"}, "features": ["engine.shutdown-v1"]})
                        if rpc_error_code(active_control, "engine.shutdown", {}) != -32025:
                            raise RuntimeError("Engine did not reject shutdown while a worker was active")
                        checked_busy_shutdown = True
                    finally: active_control.close()
                if job["state"] == "completed":
                    break
                if job["state"] == "failed":
                    raise RuntimeError(f"Fixture job failed: {job.get('error_message')}")
                time.sleep(0.05)
            else:
                raise TimeoutError("Fixture download did not complete")
            if not saw_progress:
                raise RuntimeError("No live download progress was observed")
            if os.name == "nt" and not checked_busy_shutdown:
                raise RuntimeError("Active-worker shutdown rejection was not exercised")
            output = destination / "phase0.bin"
            if not output.is_file() or output.read_bytes() != PAYLOAD:
                raise RuntimeError("Fixture download did not produce the expected bytes")
            if os.name == "nt":
                marker = root / "queue action" / "queue-finished.txt"
                deadline = time.monotonic() + 10
                completed_job = job
                while time.monotonic() < deadline:
                    completed_job = next(j for j in one_connection(endpoint)["jobs"] if j["job_id"] == job["job_id"])
                    if completed_job.get("queue_action_outcome") in ("succeeded", "failed"): break
                    time.sleep(0.05)
                outcome = completed_job.get("queue_action_outcome")
                marker_text = marker.read_text().strip() if marker.exists() else None
                if outcome != "succeeded" or marker_text != "queue-finished":
                    debug_log = state / "engine-debug.log"
                    action_log = [line for line in debug_log.read_text().splitlines()
                                  if "queue.finish-action" in line] if debug_log.exists() else []
                    raise RuntimeError(
                        "Windows queue completion command did not run successfully: "
                        f"action={completed_job.get('queue_finish_action')!r}, outcome={outcome!r}, "
                        f"marker_exists={marker.exists()}, marker_contents={marker_text!r}, action_log={action_log!r}"
                    )

                failure_stream = new_connection(endpoint)
                try:
                    rpc(failure_stream, "engine.hello", {"protocol": {"major": 1, "minor": 0},
                        "client": {"kind": "queue-action-test", "version": "1"}, "features": []})
                    settings = rpc(failure_stream, "settings.get", {})
                    main_queue = next(q for q in settings["queues"] if q["id"] == "main")
                    main_queue["finish_action"] = "user_command"
                    main_queue["user_command"] = "exit /b 1"
                    rpc(failure_stream, "settings.update", {"settings": settings})
                    failed_action = rpc(failure_stream, "jobs.add", {"url": f"http://127.0.0.1:{fixture.server_port}/queue-failure.bin",
                        "name": "queue-failure.bin", "destination": str(destination), "idempotency_key": str(uuid.uuid4()), "priority": 0})
                    deadline = time.monotonic() + 20
                    while time.monotonic() < deadline:
                        failed_job = next(j for j in rpc(failure_stream, "jobs.list", {"offset": 0, "limit": 50})["jobs"] if j["job_id"] == failed_action["job_id"])
                        if failed_job.get("queue_action_outcome") == "failed": break
                        time.sleep(0.05)
                    else: raise TimeoutError("Failed queue action was not recorded")
                    rpc(failure_stream, "jobs.delete", {"job_id": failed_job["job_id"], "expected_revision": failed_job["revision"], "delete_partial": False})
                    main_queue["finish_action"] = "none"
                    main_queue["user_command"] = None
                    rpc(failure_stream, "settings.update", {"settings": settings})
                finally:
                    failure_stream.close()

            # Cancel must preserve partial data unless deletion is explicitly requested.
            cancel_stream = new_connection(endpoint)
            try:
                rpc(cancel_stream, "engine.hello", {"protocol": {"major": 1, "minor": 0},
                    "client": {"kind": "cancel-preservation-test", "version": "1"}, "features": []})
                created = rpc(cancel_stream, "jobs.add", {"url": f"http://127.0.0.1:{fixture.server_port}/cancel.bin",
                    "name": "cancel.bin", "destination": str(destination), "idempotency_key": str(uuid.uuid4()), "priority": 0})
                cancel_id = created["job_id"]
                deadline = time.monotonic() + 15
                requested = False
                while time.monotonic() < deadline:
                    canceled = next(j for j in rpc(cancel_stream, "jobs.list", {"offset": 0, "limit": 50})["jobs"] if j["job_id"] == cancel_id)
                    if canceled["state"] == "canceled": break
                    if canceled["state"] == "completed": raise RuntimeError("Cancel fixture completed before it could be canceled")
                    if canceled["state"] == "downloading" and int(canceled.get("received_bytes") or "0") > 0 and not requested:
                        try:
                            rpc(cancel_stream, "jobs.control", {"job_id": cancel_id, "action": "cancel", "expected_revision": canceled["revision"]})
                            requested = True
                        except RuntimeError as error:
                            if "stale" not in str(error).lower(): raise
                    time.sleep(0.02)
                else: raise TimeoutError("Cancel fixture did not reach canceled state")
                partial = destination / "cancel.bin.part"
                if not partial.exists(): raise RuntimeError("Cancel unexpectedly deleted the partial file")
                rpc(cancel_stream, "jobs.delete", {"job_id": cancel_id, "expected_revision": canceled["revision"], "delete_partial": True})
                if partial.exists(): raise RuntimeError("Explicit partial deletion did not remove the partial file")
            finally:
                cancel_stream.close()

            # Resuming an individual job must immediately reapply its queue's
            # closed schedule, rather than starting it between scheduler ticks.
            control = new_connection(endpoint)
            try:
                rpc(control, "engine.hello", {
                    "protocol": {"major": 1, "minor": 0},
                    "client": {"kind": "phase0-resume-schedule", "version": "0.1.0"},
                    "features": ["engine.shutdown-v1"],
                })
                scheduled_settings = rpc(control, "settings.get", {})
                for queue in scheduled_settings["queues"]:
                    if queue["id"] == "main":
                        queue["schedule_enabled"] = True
                        queue["schedule_slots"] = [False] * 168
                        queue["finish_action"] = "none"
                        queue["user_command"] = None
                rpc(control, "settings.update", {"settings": scheduled_settings})
                created = rpc(control, "jobs.add", {
                    "url": f"http://127.0.0.1:{fixture.server_port}/scheduled.bin",
                    "name": "scheduled.bin", "destination": str(destination),
                    "idempotency_key": str(uuid.uuid4()), "priority": 0,
                })
                job_id = created["job_id"]
                deadline = time.monotonic() + 10
                while True:
                    job = next(j for j in rpc(control, "jobs.list", {"offset": 0, "limit": 50})["jobs"] if j["job_id"] == job_id)
                    if job["state"] == "scheduled": break
                    if time.monotonic() >= deadline: raise TimeoutError("Closed queue did not schedule the job")
                    time.sleep(0.05)
                limit = rpc(control, "jobs.set-bandwidth", {"job_id": job_id, "expected_revision": job["revision"], "bandwidth_limit_bytes_per_second": 750_000})
                job = next(j for j in rpc(control, "jobs.list", {"offset": 0, "limit": 50})["jobs"] if j["job_id"] == job_id)
                if job["bandwidth_limit_bytes_per_second"] != 750_000 or job["revision"] != limit["revision"]:
                    raise RuntimeError("Per-download bandwidth limit was not persisted in the job snapshot")
                paused = rpc(control, "jobs.control", {"job_id": job_id, "action": "pause", "expected_revision": job["revision"]})
                rpc(control, "jobs.control", {"job_id": job_id, "action": "resume", "expected_revision": paused["revision"]})
                job = next(j for j in rpc(control, "jobs.list", {"offset": 0, "limit": 50})["jobs"] if j["job_id"] == job_id)
                if job["state"] != "scheduled":
                    raise RuntimeError(f"Resume bypassed the closed schedule: {job['state']}")
                rpc(control, "jobs.delete", {"job_id": job_id, "expected_revision": job["revision"], "delete_partial": False})
                if os.name == "nt":
                    response = rpc(control, "engine.shutdown", {})
                    if response.get("stopping") is not True:
                        raise RuntimeError("Engine did not acknowledge graceful shutdown")
            finally:
                control.close()

            if os.name != "nt": process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired as error:
                debug_log = state / "engine-debug.log"
                shutdown_log = [line for line in debug_log.read_text().splitlines()
                                if "engine.shutdown" in line] if debug_log.exists() else []
                raise TimeoutError(f"Engine shutdown did not finish; shutdown_log={shutdown_log!r}") from error
            if os.name == "nt" and process.returncode != 0:
                raise RuntimeError("Engine did not exit cleanly after shutdown")
            start_engine()
            recovered = one_connection(endpoint)
            if recovered["total"] != "1" or recovered["jobs"][0]["state"] != "completed":
                raise RuntimeError("Engine restart did not recover the completed job")
            if os.name == "nt" and recovered["jobs"][0].get("queue_action_outcome") != "succeeded":
                raise RuntimeError("Engine restart did not recover the queue action outcome")
            print("Phase 0 IPC smoke passed: hello/version rejection, multi-client, single engine, list, reconnect, malformed-frame recovery, change subscription, live progress, transfer, restart persistence")
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
