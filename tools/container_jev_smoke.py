"""Run one local Coworld Jev episode with private SystemOne call traces."""

import argparse
import json
import os
import secrets
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import uuid4

import httpx


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=5)
    args = parser.parse_args()
    key = os.environ["TYPESAFE_API_KEY"]
    output = args.output_dir.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    trace_fd = os.open(
        output / "systemone.jsonl", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
    )
    trace = os.fdopen(trace_fd, "w")
    capture_key = secrets.token_urlsafe(32)
    lock = threading.Lock()
    client = httpx.Client(timeout=45)

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if (
                self.path != "/v1/systemone"
                or self.headers.get("authorization") != "Bearer " + capture_key
            ):
                self.send_error(401)
                return
            payload = json.loads(self.rfile.read(int(self.headers["content-length"])))
            trace_id = str(uuid4())
            started = time.monotonic()
            with lock:
                trace.write(
                    json.dumps(
                        {
                            "kind": "request",
                            "version": 1,
                            "trace_id": trace_id,
                            "trajectory_id": f"parley-container-{args.seed}",
                            "workload": "parley",
                            "schema_revision": "parley.player.v2-external-action",
                            "started_at": datetime.now(timezone.utc).isoformat(),
                            "request": payload,
                        }
                    )
                    + "\n"
                )
                trace.flush()
                os.fsync(trace.fileno())
            finished = False
            try:
                response = client.post(
                    "https://api.typesafe.ai/v1/systemone",
                    headers={"Authorization": "Bearer " + key},
                    json=payload,
                )
                with lock:
                    trace.write(
                        json.dumps(
                            {
                                "kind": "response",
                                "trace_id": trace_id,
                                "status": response.status_code,
                                "body": response.text,
                                "latency_ms": (time.monotonic() - started) * 1000,
                            }
                        )
                        + "\n"
                    )
                    trace.flush()
                    os.fsync(trace.fileno())
                finished = True
            finally:
                if not finished:
                    with lock:
                        trace.write(
                            json.dumps({"kind": "interrupted", "trace_id": trace_id})
                            + "\n"
                        )
                        trace.flush()
                        os.fsync(trace.fileno())
            self.send_response(response.status_code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(response.content)))
            self.end_headers()
            self.wfile.write(response.content)

        def log_message(self, *_args):
            pass

    proxy = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    thread = threading.Thread(target=proxy.serve_forever, daemon=True)
    thread.start()
    try:
        manifest = json.loads(args.manifest.read_text())
        game_env = manifest["game"]["runnable"]["env"]
        game_env.pop("ANTHROPIC_API_KEY_URI", None)
        next(player for player in manifest["player"]
             if player["id"] == "parley-jev")["env"].update(
            {
                "METTA_CAPTURE_URL": f"http://host.docker.internal:{proxy.server_port}",
                "METTA_CAPTURE_KEY": capture_key,
                "METTA_CAPTURE_MODEL": "jev-latest",
            }
        )
        config = manifest["certification"]["game_config"]
        config.update(
            {
                "seed": args.seed,
                "rounds": 1,
                "survivors": 3,
                "hitPoints": 1,
                "maxSkips": 0,
                "reactions": True,
                "maxReactions": 4,
                "turnDelayMs": 0,
                "sampled": True,
                "episodeTimeoutSeconds": 120,
            }
        )
        properties = manifest["game"]["config_schema"]["properties"]
        properties["survivors"] = {"type": "integer", "minimum": 1, "maximum": 4}
        properties["sampled"] = {"type": "boolean"}
        manifest["certification"]["players"] = [
            {"player_id": "parley-jev"},
            *({"player_id": "parley-scripted"} for _ in range(4)),
        ]
        local_manifest = output / "manifest.json"
        local_manifest.write_text(json.dumps(manifest))
        local_manifest.chmod(0o600)
        environment = {
            name: value
            for name, value in os.environ.items()
            if name
            not in {"TYPESAFE_API_KEY", "ANTHROPIC_API_KEY", "OPENROUTER_API_KEY"}
        }
        with (output / "coworld.log").open("w") as log:
            result = subprocess.run(
                [
                    "coworld",
                    "run-episode",
                    str(local_manifest),
                    "-o",
                    str(output / "episode"),
                    "--timeout-seconds",
                    "180",
                    "--verify-replay",
                ],
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        print("Coworld exit", result.returncode)
        print(
            "Trace records", len((output / "systemone.jsonl").read_text().splitlines())
        )
        if result.returncode:
            raise RuntimeError(
                f"Coworld episode failed; inspect {output / 'coworld.log'}"
            )
    finally:
        proxy.shutdown()
        proxy.server_close()
        thread.join()
        trace.close()
        client.close()


if __name__ == "__main__":
    main()
