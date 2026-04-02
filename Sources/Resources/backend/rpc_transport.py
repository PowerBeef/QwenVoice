import json
import sys


class JSONRPCTransport:
    def __init__(self, stdout=None, original_stderr=None):
        self.stdout = stdout or sys.stdout
        self.original_stderr = original_stderr or sys.stderr

    def send_response(self, req_id, result):
        self.stdout.write(
            json.dumps(
                {"jsonrpc": "2.0", "id": req_id, "result": result}, ensure_ascii=False
            )
            + "\n"
        )
        self.stdout.flush()

    def send_error(self, req_id, code, message):
        self.stdout.write(
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": code, "message": message},
                },
                ensure_ascii=False,
            )
            + "\n"
        )
        self.stdout.flush()

    def send_notification(self, method, params):
        self.stdout.write(
            json.dumps(
                {"jsonrpc": "2.0", "method": method, "params": params},
                ensure_ascii=False,
            )
            + "\n"
        )
        self.stdout.flush()

    def send_progress(self, percent, message, request_id=None):
        self.send_notification(
            "progress",
            {"percent": percent, "message": message, "request_id": request_id},
        )

    def send_generation_chunk(
        self,
        *,
        request_id,
        chunk_index,
        chunk_path,
        is_final,
        chunk_duration_seconds,
        cumulative_duration_seconds,
        stream_session_dir,
    ):
        if request_id is None:
            return
        self.send_notification(
            "generation_chunk",
            {
                "request_id": request_id,
                "chunk_index": chunk_index,
                "chunk_path": chunk_path,
                "is_final": is_final,
                "chunk_duration_seconds": round(chunk_duration_seconds, 4),
                "cumulative_duration_seconds": round(
                    cumulative_duration_seconds, 4
                ),
                "stream_session_dir": stream_session_dir,
            },
        )
