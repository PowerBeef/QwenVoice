"""HTTP client for the test-mode UI state server (localhost:19876)."""

import json
import time
import urllib.request
import urllib.error


class UIStateClient:
    def __init__(self, base_url: str = "http://localhost:19876"):
        self.base_url = base_url

    def health(self) -> bool:
        try:
            resp = urllib.request.urlopen(f"{self.base_url}/health", timeout=2)
            data = json.loads(resp.read())
            return data.get("ok", False)
        except (urllib.error.URLError, OSError, json.JSONDecodeError):
            return False

    def query_state(self) -> dict:
        resp = urllib.request.urlopen(f"{self.base_url}/state", timeout=5)
        return json.loads(resp.read())

    def navigate(self, screen: str) -> dict:
        resp = urllib.request.urlopen(
            f"{self.base_url}/navigate?screen={screen}", timeout=10
        )
        return json.loads(resp.read())

    def wait_for_ready(self, timeout: float = 15) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                if self.health():
                    state = self.query_state()
                    if state.get("isReady"):
                        return True
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(0.5)
        return False

    def wait_for_screen(self, screen_id: str, timeout: float = 5) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                state = self.query_state()
                if state.get("activeScreen") == screen_id:
                    return True
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(0.3)
        return False
