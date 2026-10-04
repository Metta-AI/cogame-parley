"""Exercise the compiled native producer against an owned synthetic HTTP scorer.

Arguments: compiled fixture binary, new private evidence directory.
Scores and token IDs are fixtures, not a tokenizer or model qualification.
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread
from uuid import uuid4


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


class Scorer(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        assert self.path == "/v1/parley/score-choices"
        seat = request["seat"]
        assert seat == (int(self.server.mode[5:]) if self.server.mode.startswith("seat-") else 2)
        assert self.headers["x-coworld-player-slot"] == str(seat)
        assert self.headers["x-coworld-actor-id"] == request["actor_id"] == f"actor-{seat}"
        assert self.headers["x-coworld-policy-id"] == request["policy_id"] == f"policy-{seat}"
        assert self.headers["x-coworld-model-roster-sha256"] == request["model_roster_sha256"]
        assert request["model"] == "local-sha256:" + str(seat) * 64
        actions = [json.loads(candidate) for candidate in request["candidates"]]
        assert digest(actions) == request["candidate_sha256"]
        call_id = str(uuid4())
        response = {
            "protocol": "parley.legal-choice-score-response.v1",
            "provider_call_id": call_id,
            "model_identity": request["model"],
            "tokenizer_identity": "b" * 64,
            "chat_template_sha256": "c" * 64,
            "candidate_sha256": request["candidate_sha256"],
            "score_rule": request["score_rule"],
            "candidates": [
                {"action_sha256": digest(action), "score": -3.0,
                 "full_input_token_ids": [10, 20, 30, 40], "scored_token_positions": [2, 3],
                 "target_token_ids": [30, 40], "per_token_log_probs": [-1.0, -2.0]}
                for action in actions
            ],
        }
        mode = self.server.mode
        status = 200
        if mode == "pass":
            assert actions[-1] == {"say": "", "shoot": "pass"}
            response["candidates"][-1]["score"] = -1.0
            response["candidates"][-1]["per_token_log_probs"] = [-0.5, -0.5]
        elif mode == "reaction":
            assert actions == [{"say": ""}]
        elif mode == "unsupported":
            status = 501
            response = {"error": "fixture scorer unsupported"}
        elif mode == "auth":
            status = 403
            response = {"error": "fixture auth rejected"}
        elif mode == "identity":
            response["model_identity"] = "local-sha256:" + "1" * 64
        elif mode == "provider":
            response["provider_call_id"] = str(uuid4())
        elif mode == "prefix":
            response["candidates"][1]["full_input_token_ids"][0] = 99
        elif mode == "mask":
            response["candidates"][0]["scored_token_positions"] = [2]
        elif mode == "sum":
            response["candidates"][0]["score"] = -2.9
        elif mode == "order":
            response["candidates"][0]["action_sha256"] = response["candidates"][1]["action_sha256"]
        elif mode == "extra":
            response["hidden_selection"] = 2
        raw = b"{" if mode == "malformed" else json.dumps(response, ensure_ascii=False).encode()
        self.server.exchanges.append({"path": self.path, "request_headers": dict(self.headers),
                                      "request_body": body.decode(), "response_body": raw.decode(),
                                      "status": status, "generated_provider_call_id": call_id,
                                      "provider_call_id_header": None if mode == "missing-provider" else call_id})
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        if mode != "missing-provider":
            self.send_header("x-softmax-llm-call-id", call_id)
        self.send_header("x-coworld-checkpoint-sha256", "foreign" if mode == "header-identity" else request["model"])
        self.send_header("x-coworld-tokenizer-sha256", "b" * 64)
        self.send_header("x-coworld-chat-template-sha256", "c" * 64)
        self.server.exchanges[-1]["response_headers_b64"] = base64.b64encode(b"".join(self._headers_buffer) + b"\r\n").decode()
        self.end_headers()
        self.wfile.write(raw)


binary, destination = sys.argv[1:]
directory = Path(destination)
directory.mkdir(mode=0o700)
results = []
for mode in ["shot", "pass", "reaction", "unsupported", "identity", "provider", "prefix", "mask", "sum", "order", "extra", "auth", "header-identity", "malformed", "missing-provider", "seat-0", "seat-1", "seat-3", "seat-4"]:
    server = HTTPServer(("127.0.0.1", 0), Scorer)
    server.mode = mode
    server.exchanges = []
    thread = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
    thread.start()
    try:
        environment = dict(os.environ, COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.server_port}")
        result = subprocess.run([binary, mode, str(directory / f"{mode}.jsonl")], env=environment,
                                text=True, capture_output=True, timeout=8)
    finally:
        server.shutdown()
        thread.join(timeout=2)
        assert not thread.is_alive()
        server.server_close()
    (directory / f"{mode}.process.json").write_text(json.dumps({"exit_code": result.returncode,
                                                              "stdout": result.stdout, "stderr": result.stderr}))
    (directory / f"{mode}.provider.json").write_text(json.dumps(server.exchanges, indent=2))
    assert result.returncode == 0, result.stderr
    events = [json.loads(line) for line in (directory / f"{mode}.jsonl").read_text().splitlines()]
    assert events[-1]["status"] == "truncated"
    attempts = events[0]["attempts"]
    assert len(attempts) == len(server.exchanges) == (1 if mode in ["shot", "pass", "reaction"] or mode.startswith("seat-") else 2)
    for attempt, exchange in zip(attempts, server.exchanges, strict=True):
        assert attempt["request"] == json.loads(exchange["request_body"])
        raw = attempt["raw_response"]
        if mode == "malformed":
            assert raw == exchange["response_body"]
        else:
            assert (json.loads(raw) if isinstance(raw, str) else raw) == json.loads(exchange["response_body"])
        assert attempt["platform_call_id"] == exchange["provider_call_id_header"]
        response_headers = base64.b64decode(exchange["response_headers_b64"]).decode("latin-1")
        if mode == "missing-provider":
            assert "x-softmax-llm-call-id:" not in response_headers.lower()
            assert exchange["generated_provider_call_id"] != attempt["platform_call_id"]
        else:
            assert "x-softmax-llm-call-id: " + exchange["provider_call_id_header"] in response_headers.lower()
        assert attempt["response"] is None
        assert attempt["sampled_token_ids"] is None and attempt["behavior_logprobs"] is None
    results.append({"case": mode, "attempts": len(attempts), "status": events[0]["action_status"]})
(directory / "results.json").write_text(json.dumps({"protocol": "parley.synthetic-native-scoring-cpu.v1",
                                                  "cases": results, "actual_model_calls": 0,
                                                  "tokenizer_qualified": False}, indent=2))
print(json.dumps(results))
