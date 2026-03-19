"""Shared JSON-RPC client for the QwenVoice backend server."""

from __future__ import annotations

import json
import os
import queue
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .paths import PROJECT_DIR, SERVER_PATH, resolve_ffmpeg_binary


class BackendClient:
    """Newline-delimited JSON-RPC client for the backend server.

    Usage::

        with BackendClient(python_path, log_dir="/tmp/logs") as client:
            result = client.call("ping")
    """

    def __init__(
        self,
        python_path: str,
        log_dir: str | Path | None = None,
        env_overrides: dict[str, str] | None = None,
    ) -> None:
        self.python_path = python_path
        self.log_dir = Path(log_dir) if log_dir else None
        self.env_overrides = env_overrides or {}
        self.proc: subprocess.Popen[str] | None = None
        self._stdout_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None
        self._events: queue.Queue[tuple[float, dict[str, Any]]] = queue.Queue()
        self._next_id = 1
        self._stderr_tail: list[str] = []
        self._rpc_log: Any = None
        self._backend_log: Any = None

    def __enter__(self) -> BackendClient:
        self.start()
        return self

    def __exit__(self, *exc: Any) -> None:
        self.stop()

    def _open_logs(self) -> None:
        if self.log_dir:
            self.log_dir.mkdir(parents=True, exist_ok=True)
            self._rpc_log = (self.log_dir / "rpc_events.jsonl").open("a", encoding="utf-8")
            self._backend_log = (self.log_dir / "backend.log").open("a", encoding="utf-8")

    def _record_event(self, direction: str, payload: dict[str, Any]) -> None:
        if self._rpc_log is None:
            return
        record = {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "direction": direction,
            "payload": payload,
        }
        try:
            self._rpc_log.write(json.dumps(record, sort_keys=True) + "\n")
            self._rpc_log.flush()
        except ValueError:
            return

    def _stdout_loop(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        for raw in self.proc.stdout:
            line = raw.rstrip("\n")
            if not line:
                continue
            timestamp = time.perf_counter()
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            self._record_event("from_backend", message)
            self._events.put((timestamp, message))

    def _stderr_loop(self) -> None:
        assert self.proc is not None and self.proc.stderr is not None
        for raw in self.proc.stderr:
            if self._backend_log is not None:
                try:
                    self._backend_log.write(raw)
                    self._backend_log.flush()
                except ValueError:
                    pass
            line = raw.rstrip("\n")
            if line:
                self._stderr_tail.append(line)
                if len(self._stderr_tail) > 200:
                    self._stderr_tail = self._stderr_tail[-200:]

    def start(self) -> None:
        """Launch the backend process and wait for the ready notification."""
        self._open_logs()
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        ffmpeg_path = resolve_ffmpeg_binary()
        if ffmpeg_path:
            env["QWENVOICE_FFMPEG_PATH"] = ffmpeg_path
        env.update(self.env_overrides)

        self.proc = subprocess.Popen(
            [self.python_path, str(SERVER_PATH)],
            cwd=str(PROJECT_DIR),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self._stdout_thread = threading.Thread(target=self._stdout_loop, daemon=True)
        self._stderr_thread = threading.Thread(target=self._stderr_loop, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()
        self._wait_ready()

    def _wait_ready(self, timeout: float = 60.0) -> None:
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            remaining = max(0.1, deadline - time.perf_counter())
            try:
                _, message = self._events.get(timeout=min(1.0, remaining))
            except queue.Empty:
                continue
            if message.get("method") == "ready":
                return
        raise RuntimeError("Timed out waiting for backend ready")

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 900.0,
    ) -> dict[str, Any]:
        """Send a JSON-RPC request and wait for the response."""
        if self.proc is None or self.proc.stdin is None:
            raise RuntimeError("Backend process is not running")

        request_id = self._next_id
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        self._record_event("to_backend", request)
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()

        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            remaining = max(0.1, deadline - time.perf_counter())
            try:
                _, message = self._events.get(timeout=min(1.0, remaining))
            except queue.Empty:
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"].get("message", "Unknown RPC error"))
                return message.get("result", {})

        raise TimeoutError(f"Timed out waiting for RPC response: {method}")

    def call_collecting_notifications(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 900.0,
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        """Send a JSON-RPC request and collect notifications until the response arrives."""
        if self.proc is None or self.proc.stdin is None:
            raise RuntimeError("Backend process is not running")

        request_id = self._next_id
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        self._record_event("to_backend", request)
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()

        notifications: list[dict[str, Any]] = []
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            remaining = max(0.1, deadline - time.perf_counter())
            try:
                _, message = self._events.get(timeout=min(1.0, remaining))
            except queue.Empty:
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"].get("message", "Unknown RPC error"))
                return message.get("result", {}), notifications
            if message.get("method"):
                notifications.append(message)

        raise TimeoutError(f"Timed out waiting for RPC response: {method}")

    def call_collecting_notifications_timed(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 900.0,
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        """Like call_collecting_notifications but each notification gets a _received_at_ms field.

        The ``_received_at_ms`` value is measured from the moment the request is
        sent (monotonic clock), so it can be used to compute first-chunk latency.
        """
        if self.proc is None or self.proc.stdin is None:
            raise RuntimeError("Backend process is not running")

        request_id = self._next_id
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        self._record_event("to_backend", request)
        call_start = time.perf_counter()
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()

        notifications: list[dict[str, Any]] = []
        deadline = call_start + timeout
        while time.perf_counter() < deadline:
            remaining = max(0.1, deadline - time.perf_counter())
            try:
                ts, message = self._events.get(timeout=min(1.0, remaining))
            except queue.Empty:
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"].get("message", "Unknown RPC error"))
                result = message.get("result", {})
                wall_ms = (time.perf_counter() - call_start) * 1000
                result["_wall_ms"] = round(wall_ms, 2)
                return result, notifications
            if message.get("method"):
                elapsed_ms = (ts - call_start) * 1000
                message["_received_at_ms"] = round(elapsed_ms, 2)
                notifications.append(message)

        raise TimeoutError(f"Timed out waiting for RPC response: {method}")

    def get_process_rss_mb(self) -> float | None:
        """Return the backend process RSS in MB, or None if unavailable."""
        if self.proc is None or self.proc.poll() is not None:
            return None
        try:
            import subprocess as _sp
            out = _sp.check_output(
                ["ps", "-o", "rss=", "-p", str(self.proc.pid)],
                text=True,
                timeout=5,
            ).strip()
            return round(int(out) / 1024, 1) if out else None
        except Exception:
            return None

    def stderr_excerpt(self, lines: int = 25) -> str:
        """Return the last N lines of stderr output."""
        return "\n".join(self._stderr_tail[-lines:])

    def stop(self) -> None:
        """Terminate the backend process and clean up threads."""
        if self.proc is not None:
            if self.proc.stdin is not None:
                try:
                    self.proc.stdin.close()
                except OSError:
                    pass
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)
        if self._stdout_thread is not None:
            self._stdout_thread.join(timeout=2)
        if self._stderr_thread is not None:
            self._stderr_thread.join(timeout=2)
        if self._rpc_log is not None:
            self._rpc_log.close()
        if self._backend_log is not None:
            self._backend_log.close()
