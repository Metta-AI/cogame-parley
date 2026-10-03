"""Verify native HTTP/WebSocket trajectory evidence without provider credentials.

Arguments: compiled game binary, fresh private output directory, source commit.
"""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from websockets.sync.client import connect

binary, output, revision = sys.argv[1:]
root = Path(output)
root.mkdir(mode=0o700, parents=True, exist_ok=False)
reports = []
for mode in ["accepted", "retry", "fallback", "registration"]:
    seats = 5 if mode == "registration" else 4
    folder = root / mode
    folder.mkdir(mode=0o700)
    requests = []

    class Native(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            assert self.path == "/v1/messages"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            user = body["messages"][0]["content"]
            target = re.search(r'<one of "([^"]+)"', user)
            action = {"say": "fixture public speech"}
            if target:
                action.update(shoot=target[1], aim="head")
            raw = json.dumps(action, separators=(",", ":"))
            if (
                mode == "fallback"
                or mode == "retry"
                and "previous reply was invalid" not in user
            ):
                raw = "invalid-json-fixture"
            call_id = str(uuid.uuid4())
            response = {
                "id": call_id,
                "type": "message",
                "role": "assistant",
                "model": body["model"],
                "content": [{"type": "text", "text": raw}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 100, "output_tokens": 20},
            }
            requests.append(
                {
                    "platform_call_id": call_id,
                    "caller_request": body,
                    "provider_response": response,
                }
            )
            payload = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Native)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    config = {
        "seed": 17,
        "sampled": mode != "registration",
        "rounds": 2,
        "hitPoints": 1,
        "survivors": 1,
        "reactions": True,
        "maxReactions": 3 if mode == "registration" else 1,
        "turnDelayMs": 0,
        "player_connect_timeout_seconds": 3,
        "episodeTimeoutSeconds": 60,
        "tokens": [str(i) for i in range(seats)],
        "players": [{"name": "fixture-" + str(i)} for i in range(seats)],
    }
    config_path = folder / "config.json"
    config_path.write_text(json.dumps(config))
    environment = dict(os.environ)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=config_path.as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.server_port}",
        COWORLD_LLM_MODEL="fixture/native",
        COWORLD_LLM_TEMPERATURE="0",
        LLM_REQUEST_METADATA=json.dumps({"episode_request_id": "fixture-" + mode}),
    )
    with (folder / "game.log").open("w") as log:
        process = subprocess.Popen(
            [binary], env=environment, stdout=log, stderr=subprocess.STDOUT
        )
        try:
            deadline = time.monotonic() + 10
            while True:
                probe = socket.socket()
                ready = probe.connect_ex(("127.0.0.1", port)) == 0
                probe.close()
                if ready:
                    break
                assert process.poll() is None, (folder / "game.log").read_text()
                assert time.monotonic() < deadline
                threading.Event().wait(0.01)
            sockets = [
                connect(f"ws://127.0.0.1:{port}/player?slot={slot}&token={slot}")
                for slot in range(seats)
            ]
            try:
                for index, seat in enumerate(sockets):
                    if mode == "registration" and index == seats - 1:
                        time.sleep(0.8)
                        assert not requests, (
                            "Decision requested before final control registration"
                        )
                    seat.send(
                        json.dumps(
                            {"type": "prompt", "prompt": "PRIVATE OPERATOR SENTINEL"}
                        )
                    )
                assert process.wait(timeout=45) == 0, (folder / "game.log").read_text()
            finally:
                for seat in sockets:
                    seat.close()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            server.shutdown()
            server.server_close()
    events = [
        json.loads(line)
        for line in (folder / "trajectory.jsonl").read_text().splitlines()
    ]
    decisions = events[:-1]
    assert events[-1]["status"] == "completed"
    if mode == "registration":
        assert 3 <= events[-1]["outcome"]["rounds"] <= 20
    else:
        assert events[-1]["outcome"]["rounds"] == 2
    calls = {record["platform_call_id"]: record for record in requests}
    for decision in decisions:
        for attempt in decision["attempts"]:
            archive = calls[attempt["platform_call_id"]]
            assert attempt["request"] == archive["caller_request"]
            assert attempt["raw_response"] == archive["provider_response"]
        if decision["action_status"] == "accepted":
            selected = next(
                a
                for a in decision["attempts"]
                if a["attempt_id"] == decision["selected_attempt_id"]
            )
            assert (
                selected["accepted"]
                and selected["parsed_action"] == decision["executed_action"]
            )
        else:
            assert mode == "fallback" and decision["selected_attempt_id"] is None
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "replay.json").read_text()
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "game.log").read_text()
    assert "PRIVATE OPERATOR SENTINEL" in (folder / "trajectory.jsonl").read_text()
    assert (folder / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
    reports.append(
        {
            "mode": mode,
            "complete_episodes": 1,
            "seats": seats,
            "completed_rounds": events[-1]["outcome"]["rounds"],
            "decisions": len(decisions),
            "native_call_joins": len(requests),
            "source_revision": revision,
            "cohort": "native HTTP fixture; no platform hosted claim",
        }
    )
(root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
print(json.dumps(reports))
