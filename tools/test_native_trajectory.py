"""Verify native HTTP/WebSocket trajectory evidence without provider credentials.

Arguments: compiled game binary, fresh private output directory, source commit.
"""

import base64
import json
import os
import re
import socket
import signal
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
for mode in ["accepted", "retry", "fallback", "seat-budget", "random-seed",
             "interrupted-started-term", "interrupted-partial-term", "interrupted-partial-int", "runtime-failure"]:
    folder = root / mode
    folder.mkdir(mode=0o700)
    requests = []
    entered = threading.Event()
    release = threading.Event()
    seat_calls = [0] * 4

    class Native(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            assert self.path == "/v1/messages"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            user = body["messages"][0]["content"]
            slot = int(self.headers["x-coworld-player-slot"])
            seat_calls[slot] += 1
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
            category = ""
            if mode == "seat-budget" and (
                slot == 2 or slot == 1 and seat_calls[slot] == 1
            ):
                category = "spend_limit" if slot == 2 else "provider_rate_limit"
                response = {
                    "type": "error",
                    "error": {"type": "rate_limit_error", "message": "fixture"},
                    "softmax_error": {
                        "category": category,
                        "retryable": slot != 2,
                        "call_id": call_id,
                    },
                }
            requests.append(
                {
                    "platform_call_id": call_id,
                    "caller_request": body,
                    "provider_response": json.dumps(response),
                }
            )
            payload = json.dumps(response).encode()
            if mode == "interrupted-started-term":
                entered.set()
                release.wait(10)
                return
            self.send_response(429 if category else 200)
            if category:
                self.send_header("X-Softmax-Llm-Error-Category", category)
                self.send_header(
                    "X-Softmax-Llm-Retryable", "false" if slot == 2 else "true"
                )
            self.send_header("Content-Type", "application/json")
            self.send_header("request-id", "fixture-provider-" + call_id)
            self.send_header("X-Softmax-Llm-Call-Id", call_id)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if mode.startswith("interrupted-partial"):
                self.wfile.write(b'{"content":"\xe2\x82')
                self.wfile.flush()
                entered.set()
                release.wait(10)
            else:
                self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Native)
    server_owner = threading.Thread(target=server.serve_forever)
    server_owner.start()
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    config = {
        "seed": 17,
        "sampled": True,
        "rounds": 2,
        "hitPoints": 1,
        "survivors": 1,
        "reactions": True,
        "maxReactions": 1,
        "turnDelayMs": 0,
        "player_connect_timeout_seconds": 3,
        "episodeTimeoutSeconds": 60,
        "tokens": ["private-auth-sentinel-" + str(i) for i in range(4)],
        "players": [{"name": "fixture-" + str(i)} for i in range(4)],
    }
    if mode == "random-seed":
        del config["seed"]
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
    if mode == "runtime-failure":
        environment["COWORLD_LLM_TEMPERATURE"] = "2"
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
                connect(
                    f"ws://127.0.0.1:{port}/player?slot={slot}&token={config['tokens'][slot]}"
                )
                for slot in range(4)
            ]
            try:
                for seat in sockets:
                    seat.send(
                        json.dumps(
                            {"type": "prompt", "prompt": "PRIVATE OPERATOR SENTINEL"}
                        )
                    )
                if mode.startswith("interrupted-"):
                    assert entered.wait(10), "owned native request never reached fixture"
                    if mode.startswith("interrupted-partial"):
                        time.sleep(0.2)
                    requested = signal.SIGINT if mode.endswith("-int") else signal.SIGTERM
                    process.send_signal(requested)
                    time.sleep(0.05)
                    if process.poll() is None:
                        process.send_signal(requested)
                status = process.wait(timeout=45)
                assert (status != 0 if mode == "runtime-failure" else status == 0), (folder / "game.log").read_text()
            finally:
                for seat in sockets:
                    seat.close()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            release.set()
            server.shutdown()
            server_owner.join(timeout=4)
            assert not server_owner.is_alive()
            server.server_close()
    events = [
        json.loads(line)
        for line in (folder / "trajectory.jsonl").read_text().splitlines()
    ]
    decisions = events[:-1]
    if mode.startswith("interrupted-") or mode == "runtime-failure":
        assert events[-1]["status"] == ("failed" if mode == "runtime-failure" else "truncated")
        assert not (folder / "results.json").exists()
        assert not (folder / "replay.json").exists()
        assert events[-1]["participant_outcomes"] is None
        assert (folder / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        if mode.startswith("interrupted-"):
            assert len(decisions) == 1 and len(requests) == 1
            decision = decisions[0]
            assert decision["selected_attempt_id"] is None and decision["executed_action"] is None
            assert decision["action_status"] == "missing"
            attempt = decision["attempts"][0]
            assert not attempt["accepted"]
            assert attempt["request"] == requests[0]["caller_request"]
            if mode.startswith("interrupted-partial"):
                assert attempt["response_complete"] is False
                body = base64.b64decode(attempt["response_body_b64"], validate=True)
                headers = base64.b64decode(attempt["response_headers_b64"], validate=True)
                assert body == b'{"content":"\xe2\x82'
                assert attempt["raw_response"] is None
                assert attempt["http_status"] == 200
                assert attempt["platform_call_id"] == requests[0]["platform_call_id"]
                assert b"X-Softmax-Llm-Call-Id:" in headers
            else:
                assert attempt["response_body_b64"] is None and attempt["response_headers_b64"] is None
                assert attempt["response_complete"] is None and attempt["raw_response"] is None
                assert attempt["response_headers"] is None
                assert attempt["platform_call_id"] is None and attempt["http_status"] is None
        reports.append({"mode": mode, "complete_episodes": 0, "decisions": len(decisions),
                        "native_call_joins": len(requests), "source_revision": revision,
                        "cohort": "owned CPU interruption/failure fixture; no platform hosted claim"})
        continue
    assert events[-1]["status"] == "completed"
    outcome = events[-1]["outcome"]
    assert outcome["protocol"] == "parley.native-outcome.v1"
    assert outcome["results"] == json.loads((folder / "results.json").read_text())
    assert outcome["results"]["rounds"] == 2
    assert outcome["input_config"] == {k: v for k, v in config.items() if k != "tokens"}
    assert str(outcome["selected_seed"]) == events[-1]["seed_family"]
    assert (
        outcome["selected_seed"]
        == json.loads((folder / "replay.json").read_text())["config"]["seed"]
    )
    if mode != "random-seed":
        assert outcome["selected_seed"] == config["seed"]
    for token in config["tokens"]:
        assert token not in (folder / "trajectory.jsonl").read_text()
        assert token not in (folder / "replay.json").read_text()
        assert token not in (folder / "game.log").read_text()
    calls = {record["platform_call_id"]: record for record in requests}
    for decision in decisions:
        for attempt in decision["attempts"]:
            archive = calls[attempt["platform_call_id"]]
            assert attempt["request"] == archive["caller_request"]
            assert attempt["raw_response"] == archive["provider_response"]
            assert base64.b64decode(attempt["response_body_b64"], validate=True).decode() == archive["provider_response"]
            assert attempt["response_complete"] is True
            assert attempt["http_status"] == (429 if "softmax_error" in json.loads(archive["provider_response"]) else 200)
            assert attempt["provider_request_id"] == "fixture-provider-" + attempt["platform_call_id"]
            received_headers = {key.lower(): value for key, value in attempt["response_headers"].items()}
            assert received_headers["request-id"] == attempt["provider_request_id"]
            assert received_headers["x-softmax-llm-call-id"] == attempt["platform_call_id"]
            assert attempt["decoder"] == {
                key: archive["caller_request"][key] for key in ("temperature", "max_tokens")
            }
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
            assert (
                mode in ("fallback", "seat-budget")
                and decision["selected_attempt_id"] is None
            )
            if mode == "seat-budget":
                assert decision["seat"] == "2"
                assert decision["fallback_origin"] == "scripted_after_budget_exhausted"
    if mode == "seat-budget":
        assert seat_calls[2] == 1, seat_calls
        assert seat_calls[1] > 1, seat_calls
        assert all(
            d["action_status"] == "accepted" for d in decisions if d["seat"] != "2"
        )
        assert sum(len(d["attempts"]) for d in decisions if d["seat"] == "2") == 1
        assert any(len(d["attempts"]) == 2 for d in decisions if d["seat"] == "1")
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "replay.json").read_text()
    assert "PRIVATE OPERATOR SENTINEL" not in (folder / "game.log").read_text()
    assert "PRIVATE OPERATOR SENTINEL" in (folder / "trajectory.jsonl").read_text()
    assert (folder / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
    reports.append(
        {
            "mode": mode,
            "complete_episodes": 1,
            "decisions": len(decisions),
            "native_call_joins": len(requests),
            "source_revision": revision,
            "cohort": "native HTTP fixture; no platform hosted claim",
        }
    )
(root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
print(json.dumps(reports))
