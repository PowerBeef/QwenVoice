from __future__ import annotations

import json
import os
import pathlib
import queue
import subprocess
import sys
import threading
from typing import Any


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT_DIR / "Sources/Resources/backend/server.py"
BUNDLED_PYTHON_PATH = ROOT_DIR / "Sources/Resources/python/bin/python3"


class BackendServerHarness:
    LONG_RUNNING_METHODS = {"load_model", "prewarm_model", "generate", "unload_model", "convert_audio"}

    def __init__(self, python_executable: str | None = None) -> None:
        self.python_executable = python_executable or default_python_executable()
        self.process: subprocess.Popen[str] | None = None
        self._stdout_queue: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stderr_lines: list[str] = []
        self._request_id = 0
        self._stdout_thread: threading.Thread | None = None
        self._stderr_thread: threading.Thread | None = None

    def start(self) -> None:
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"

        self.process = subprocess.Popen(
            [self.python_executable, "-u", str(SERVER_PATH)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(ROOT_DIR),
            env=env,
            text=True,
            bufsize=1,
        )

        assert self.process.stdout is not None
        assert self.process.stderr is not None

        self._stdout_thread = threading.Thread(
            target=self._drain_stdout,
            args=(self.process.stdout,),
            daemon=True,
        )
        self._stderr_thread = threading.Thread(
            target=self._drain_stderr,
            args=(self.process.stderr,),
            daemon=True,
        )
        self._stdout_thread.start()
        self._stderr_thread.start()

        ready = self.read_message()
        if ready.get("method") != "ready":
            raise AssertionError(f"Expected initial ready notification, got: {ready}")

    def stop(self) -> None:
        if self.process is None:
            return

        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)

        if self.process.stdin is not None:
            self.process.stdin.close()
        if self.process.stdout is not None:
            self.process.stdout.close()
        if self.process.stderr is not None:
            self.process.stderr.close()

        self.process = None

    def send_request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self._request_id += 1
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": self._request_id,
                "method": method,
                "params": params or {},
            }
        )
        return self.send_raw_for_id(
            payload,
            self._request_id,
            timeout=self._timeout_for_method(method),
        )

    def send_request_collect_notifications(
        self,
        method: str,
        params: dict[str, Any] | None = None,
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        self._request_id += 1
        payload = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": self._request_id,
                "method": method,
                "params": params or {},
            }
        )
        return self.send_raw_collect_notifications(
            payload,
            self._request_id,
            timeout=self._timeout_for_method(method),
        )

    def send_raw(self, line: str) -> dict[str, Any]:
        if self.process is None or self.process.stdin is None:
            raise RuntimeError("Backend process is not running")

        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()
        return self.read_message()

    def send_raw_for_id(self, line: str, request_id: int, timeout: float = 10.0) -> dict[str, Any]:
        response, _ = self.send_raw_collect_notifications(line, request_id, timeout=timeout)
        return response

    def send_raw_collect_notifications(
        self,
        line: str,
        request_id: int,
        timeout: float = 10.0,
    ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        if self.process is None or self.process.stdin is None:
            raise RuntimeError("Backend process is not running")

        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

        notifications: list[dict[str, Any]] = []
        while True:
            message = self.read_message(timeout=timeout)
            if message.get("id") == request_id:
                return message, notifications
            notifications.append(message)

    def read_message(self, timeout: float = 5.0) -> dict[str, Any]:
        try:
            return self._stdout_queue.get(timeout=timeout)
        except queue.Empty as exc:
            stderr = "".join(self._stderr_lines).strip()
            raise AssertionError(f"Timed out waiting for backend message. stderr={stderr!r}") from exc

    def _drain_stdout(self, stream: Any) -> None:
        for line in stream:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                self._stdout_queue.put(json.loads(stripped))
            except json.JSONDecodeError:
                self._stderr_lines.append(f"[stdout] {stripped}\n")

    def _drain_stderr(self, stream: Any) -> None:
        for line in stream:
            self._stderr_lines.append(line)

    def _timeout_for_method(self, method: str) -> float:
        if method in self.LONG_RUNNING_METHODS:
            return 180.0
        return 10.0


def default_python_executable() -> str:
    bundled = os.environ.get("QWENVOICE_BACKEND_TEST_PYTHON")
    if bundled:
        return bundled
    if BUNDLED_PYTHON_PATH.exists():
        return str(BUNDLED_PYTHON_PATH)
    return sys.executable
