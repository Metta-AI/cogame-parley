"""Exercise the shipped replay server against a completed native game artifact.

Arguments: game binary, retained replay JSON, fresh private output directory,
optional compiled JavaScript replay reader.
"""

import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import urlopen

from websockets.sync.client import connect

binary, replay_path, output = sys.argv[1:4]
compiled_reader = sys.argv[4] if len(sys.argv) > 4 else None
root = Path(output)
root.mkdir(mode=0o700)
replay = json.loads(Path(replay_path).read_text())
reports = []
for version in ("current", "v1"):
    folder = root / version
    folder.mkdir(mode=0o700)
    retained = dict(replay)
    if version == "v1":
        retained["protocol"] = "parley.replay.v1"
        del retained["decisionRefs"]
    source = folder / "replay.json"
    source.write_text(json.dumps(retained))
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env = dict(os.environ, COGAME_HOST="127.0.0.1", COGAME_PORT=str(port),
               COGAME_LOAD_REPLAY_URI=source.as_uri())
    with (folder / "server.log").open("w") as log:
        process = subprocess.Popen([binary], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while True:
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                assert process.poll() is None, (folder / "server.log").read_text()
                assert time.monotonic() < deadline
                time.sleep(0.01)
            for route, content_type in {
                "replay": "text/html",
                "renderer.js": "application/javascript",
                "reasoning.js": "application/javascript",
                "replay.js": "application/javascript",
                "chrome.css": "text/css",
            }.items():
                with urlopen(f"http://127.0.0.1:{port}/client/{route}") as response:
                    assert response.status == 200
                    assert response.headers.get_content_type() == content_type
                    assert response.read()
            with connect(f"ws://127.0.0.1:{port}/replay") as connection:
                payload = json.loads(connection.recv(timeout=5))
            assert payload["type"] == "replay"
            for key in ("protocol", "names", "policyNames", "config", "events", "results"):
                assert payload[key] == retained[key]
            assert payload["decisionRefs"] == (retained["decisionRefs"] if version == "current" else [])
            assert len(payload["states"]) == len(retained["events"]) + 1
            assert [seat["score"] for seat in payload["states"][-1]] == retained["results"]["rawScores"]
            if compiled_reader is not None:
                javascript = subprocess.run([
                    "node", "-e",
                    "const fs=require('node:fs'),vm=require('node:vm');"
                    "const context=vm.createContext({console});"
                    "vm.runInContext(fs.readFileSync(process.argv[1],'utf8'),context);"
                    "process.stdout.write(context.parleyLoadReplay(fs.readFileSync(process.argv[2],'utf8')));",
                    compiled_reader, str(source),
                ], check=True, capture_output=True, text=True)
                assert json.loads(javascript.stdout) == payload
            reports.append({"version": version, "events": len(retained["events"]),
                            "states": len(payload["states"]), "http_assets": 5, "javascript_matches_native": compiled_reader is not None})
        finally:
            process.terminate()
            process.wait(timeout=5)
(root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
print(json.dumps(reports))
