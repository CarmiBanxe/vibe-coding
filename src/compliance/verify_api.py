"""
Verification API — HTTP wrapper around the orchestrator (port 8091)
Используется агентами OpenClaw через native HTTP tools.

GET  /verify?statement=<text>&agent_id=<id>&agent_role=<role>
GET  /health

Response:
  {"consensus": "CONFIRMED"|"REFUTED"|"UNCERTAIN",
   "hitl_required": bool, "confidence": float,
   "reason": str|null, "rule": str|null}
"""
from __future__ import annotations

import json
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent))

from compliance.verification.orchestrator import run_verification

PORT = 8094


class VerifyHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Suppress default access log — нет шума в systemd journal
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/health":
            self._respond(200, {"status": "ok", "port": PORT})
            return

        if parsed.path != "/verify":
            self._respond(404, {"error": "use /verify?statement=..."})
            return

        statement = params.get("statement", [""])[0].strip()
        if not statement:
            self._respond(400, {"error": "statement is required"})
            return

        agent_id   = params.get("agent_id",   ["unknown"])[0]
        agent_role = params.get("agent_role",  ["unknown"])[0]

        try:
            result = run_verification(
                statement=statement,
                agent_id=agent_id,
                agent_role=agent_role,
            )
            body = {
                "consensus":     result.consensus,
                "hitl_required": result.hitl_required,
                "confidence":    result.confidence_score,
                "drift_score":   result.drift_score,
                "reason":        result.correction,
                "rule":          result.correction_source,
                "training_flag": result.training_flag,
            }
            self._respond(200, body)
        except Exception as e:
            self._respond(500, {"error": str(e)})

    def _respond(self, code: int, body: dict):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), VerifyHandler)
    print(f"[verify-api] Listening on 127.0.0.1:{PORT}")
    server.serve_forever()
