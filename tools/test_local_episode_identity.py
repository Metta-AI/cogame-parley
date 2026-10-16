"""Run concurrent five-seat games and verify distinct, stable native episode IDs.

Arguments: compiled game binary, fresh private output directory.
"""

import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time

from websockets.sync.client import connect

binary, destination = sys.argv[1:]
root = Path(destination)
root.mkdir(mode=0o700, parents=True, exist_ok=False)
start = threading.Barrier(8)


def play(index):
    folder = root / str(index)
    folder.mkdir()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = {
        "seed": 946001 + index,
        "turnDelayMs": 0,
        "episodeTimeoutSeconds": 120,
        "player_connect_timeout_seconds": 20,
        "tokens": [f"fixture-{seat}" for seat in range(5)],
        "players": [{"name": f"Player{seat}"} for seat in range(5)],
    }
    config_path = folder / "config.json"
    config_path.write_text(json.dumps(config))
    environment = dict(os.environ)
    environment.pop("LLM_REQUEST_METADATA", None)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=config_path.as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
    )
    start.wait(timeout=10)
    with (folder / "game.log").open("w") as log:
        process = subprocess.Popen([binary], env=environment, stdout=log, stderr=subprocess.STDOUT)
        seats = []
        try:
            deadline = time.monotonic() + 20
            while True:
                probe = subprocess.run(
                    ["curl", "--fail", "--silent", "--max-time", "1", f"http://127.0.0.1:{port}/healthz"],
                    capture_output=True,
                )
                if probe.returncode == 0:
                    break
                assert process.poll() is None, (folder / "game.log").read_text()
                assert time.monotonic() < deadline, "Game did not become ready"
                threading.Event().wait(0.01)
            for seat in range(5):
                player = connect(f"ws://127.0.0.1:{port}/player?slot={seat}&token=fixture-{seat}", close_timeout=1)
                seats.append(player)
                player.send(json.dumps({"type": "prompt", "scripted": True, "baseline": "finisher", "prompt": ""}))
            assert process.wait(timeout=120) == 0, (folder / "game.log").read_text()
        finally:
            for player in seats:
                player.close()
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    events = [json.loads(line) for line in (folder / "trajectory.jsonl").read_text().splitlines()]
    terminal = events[-1]
    assert terminal["status"] == "completed"
    assert terminal["seed_family"] == str(config["seed"])
    assert {event["episode_id"] for event in events} == {terminal["episode_id"]}
    assert terminal["episode_id"].startswith("local-")
    assert (folder / "results.json").is_file() and (folder / "replay.json").is_file()
    return {"seed": config["seed"], "episode_id": terminal["episode_id"], "decisions": len(events) - 1}


with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(play, range(8)))
(root / "report.json").write_text(json.dumps(results, indent=2) + "\n")
assert len({result["episode_id"] for result in results}) == len(results), "Concurrent games reused native episode identity"
print(json.dumps({"completed_games": len(results), "unique_episode_ids": len(results), "output": str(root)}))
