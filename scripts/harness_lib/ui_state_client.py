"""HTTP client for the test-mode UI state server (localhost:19876)."""

import http.client
import json
import time
import urllib.request
import urllib.error
import urllib.parse


class UIStateClientError(RuntimeError):
    def __init__(self, operation: str, url: str, kind: str, detail: str):
        super().__init__(f"{operation} failed: {detail}")
        self.operation = operation
        self.url = url
        self.kind = kind
        self.detail = detail


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
        return self._request_json("/state", timeout=5, operation="query_state")

    def navigate(self, screen: str) -> dict:
        return self._request_json(
            f"/navigate?screen={screen}",
            timeout=10,
            operation="navigate",
        )

    def start_preview(self, screen: str, text: str) -> dict:
        return self.start_generation(
            screen,
            text,
            operation="start_preview",
            endpoint="/start-preview",
        )

    def start_generation(
        self,
        screen: str,
        text: str,
        *,
        voice_description: str | None = None,
        emotion: str | None = None,
        reference_audio_path: str | None = None,
        reference_transcript: str | None = None,
        operation: str = "start_generation",
        endpoint: str = "/start-generation",
    ) -> dict:
        query = {
            "screen": screen,
            "text": text,
        }
        if voice_description:
            query["voiceDescription"] = voice_description
        if emotion:
            query["emotion"] = emotion
        if reference_audio_path:
            query["referenceAudioPath"] = reference_audio_path
        if reference_transcript:
            query["referenceTranscript"] = reference_transcript

        encoded_query = urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
        return self._request_json(
            f"{endpoint}?{encoded_query}",
            timeout=10,
            operation=operation,
        )

    def activate_window(self, reason: str = "remote_request") -> dict:
        encoded_reason = urllib.parse.quote(reason)
        return self._request_json(
            f"/activate-window?reason={encoded_reason}",
            timeout=10,
            operation="activate_window",
        )

    def capture_screenshot(self, name: str) -> dict:
        encoded_name = urllib.parse.quote(name)
        return self._request_json(
            f"/capture-screenshot?name={encoded_name}",
            timeout=10,
            operation="capture_screenshot",
        )

    def seed_screen(
        self,
        screen: str,
        *,
        text: str | None = None,
        speaker: str | None = None,
        voice_description: str | None = None,
        emotion: str | None = None,
        reference_audio_path: str | None = None,
        reference_transcript: str | None = None,
    ) -> dict:
        query = {
            "screen": screen,
        }
        if text is not None:
            query["text"] = text
        if speaker is not None:
            query["speaker"] = speaker
        if voice_description is not None:
            query["voiceDescription"] = voice_description
        if emotion is not None:
            query["emotion"] = emotion
        if reference_audio_path is not None:
            query["referenceAudioPath"] = reference_audio_path
        if reference_transcript is not None:
            query["referenceTranscript"] = reference_transcript

        encoded_query = urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
        return self._request_json(
            f"/seed-screen?{encoded_query}",
            timeout=10,
            operation="seed_screen",
        )

    def wait_for_ready(
        self,
        timeout: float = 15,
        ready_field: str = "isReady",
        max_activation_attempts: int = 2,
    ) -> tuple[bool, dict, str]:
        deadline = time.time() + timeout
        last_state: dict = {}
        health_seen = False
        activation_attempts = 0
        next_activation_at = 0.0

        while time.time() < deadline:
            try:
                if self.health():
                    health_seen = True
                    last_state = self.query_state()
                    if last_state.get(ready_field):
                        return True, last_state, "ready"

                    if (
                        activation_attempts < max_activation_attempts
                        and time.time() >= next_activation_at
                        and self._should_activate_window(last_state, ready_field)
                    ):
                        try:
                            last_state = self.activate_window(
                                reason=last_state.get("readinessBlocker", "window_not_mounted")
                            )
                        except (urllib.error.URLError, OSError, http.client.HTTPException, UIStateClientError):
                            pass
                        activation_attempts += 1
                        next_activation_at = time.time() + 1.0
            except (urllib.error.URLError, OSError, json.JSONDecodeError, http.client.HTTPException, UIStateClientError):
                pass
            time.sleep(0.5)

        if not last_state and health_seen:
            try:
                last_state = self.query_state()
            except (urllib.error.URLError, OSError, json.JSONDecodeError, http.client.HTTPException, UIStateClientError):
                pass

        return False, last_state, self._failure_reason(last_state, ready_field, health_seen)

    def wait_for_screen(self, screen_id: str, timeout: float = 5) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                state = self.query_state()
                if state.get("activeScreen") == screen_id:
                    return True
            except (urllib.error.URLError, OSError, http.client.HTTPException, UIStateClientError):
                pass
            time.sleep(0.3)
        return False

    def wait_for_navigation(
        self,
        screen_id: str,
        timeout: float = 10,
    ) -> tuple[bool, dict]:
        deadline = time.time() + timeout
        last_state: dict = {}
        while time.time() < deadline:
            try:
                last_state = self.query_state()
                if (
                    last_state.get("activeScreen") == screen_id
                    and last_state.get("lastNavigationCompletedScreen") == screen_id
                    and last_state.get("lastNavigationDurationMS", 0) > 0
                ):
                    return True, last_state
            except (urllib.error.URLError, OSError, http.client.HTTPException, UIStateClientError):
                pass
            time.sleep(0.05)
        return False, last_state

    def wait_for_state(
        self,
        predicate,
        timeout: float = 10,
        interval: float = 0.1,
    ) -> tuple[bool, dict]:
        deadline = time.time() + timeout
        last_state: dict = {}
        while time.time() < deadline:
            try:
                last_state = self.query_state()
                if predicate(last_state):
                    return True, last_state
            except (urllib.error.URLError, OSError, http.client.HTTPException, UIStateClientError):
                pass
            time.sleep(interval)
        return False, last_state

    def _request_json(self, path: str, *, timeout: float, operation: str) -> dict:
        url = f"{self.base_url}{path}"
        try:
            resp = urllib.request.urlopen(url, timeout=timeout)
            return json.loads(resp.read())
        except json.JSONDecodeError as exc:
            raise UIStateClientError(operation, url, "invalid_json", str(exc)) from exc
        except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
            raise UIStateClientError(operation, url, "transport", str(exc)) from exc

    def _should_activate_window(self, state: dict, ready_field: str) -> bool:
        if state.get(ready_field):
            return False

        blocker = state.get("readinessBlocker")
        if blocker in ("window_not_visible", "window_not_mounted"):
            return True

        return bool(state.get("environmentReady")) and not bool(state.get("windowMounted"))

    def _failure_reason(self, state: dict, ready_field: str, health_seen: bool) -> str:
        if not health_seen:
            return "state_server_unreachable"

        if not state:
            return "state_unavailable"

        if state.get(ready_field):
            return "ready"

        blocker = state.get("readinessBlocker")
        if blocker:
            return blocker

        if not state.get("environmentReady"):
            if state.get("windowMounted") or state.get("backendReady"):
                return "environment_state_desynced"
            return "environment_not_ready"

        if ready_field == "interactiveReady" and not state.get("backendReady"):
            return "backend_never_ready"

        if not state.get("windowMounted"):
            return "window_never_mounted"

        return "interactive_ready_timeout"
