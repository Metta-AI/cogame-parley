import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

binary, output = sys.argv[1:3]
root = Path(output)
root.mkdir(mode=0o700)
for mode in sys.argv[3:] or ("missing-seats", "pacing-term", "pacing-int"):
    folder = root / mode
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = {
        "seed": 17,
        "sampled": True,
        "rounds": 1,
        "hitPoints": 1,
        "survivors": 1,
        "reactions": True,
        "maxReactions": 1,
        "players": [{"name": f"fixture-{i}"} for i in range(5)],
        "tokens": [str(i) for i in range(5)],
        "episodeTimeoutSeconds": 2 if mode == "missing-seats" else 60,
        "player_connect_timeout_seconds": 30 if mode == "missing-seats" else 0.05,
        "turnDelayMs": 30000,
    }
    config_path = folder / "config.json"
    config_path.write_text(json.dumps(config))
    env = dict(os.environ)
    env.pop("COWORLD_LLM_ENDPOINT", None)
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=config_path.as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
    )
    log_path = folder / "game.log"
    with log_path.open("w") as log:
        started = time.monotonic()
        process = subprocess.Popen(
            [binary], env=env, stdout=log, stderr=subprocess.STDOUT
        )
        try:
            if mode != "missing-seats":
                wait_deadline = time.monotonic() + 3
                while "parley: starting" not in log_path.read_text():
                    assert process.poll() is None and time.monotonic() < wait_deadline
                    time.sleep(0.01)
                time.sleep(0.1)
                started = time.monotonic()
                process.send_signal(
                    signal.SIGTERM if mode == "pacing-term" else signal.SIGINT
                )
            deadline = started + 4
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            assert process.poll() == 0, (
                f"{mode}: process exceeded four-second original bound"
            )
            elapsed = time.monotonic() - started
            events = [
                json.loads(line)
                for line in (folder / "trajectory.jsonl").read_text().splitlines()
            ]
            assert events[-1]["event_type"] == "episode"
            if mode != "missing-seats":
                assert elapsed < 1
                assert events[-1]["status"] == "truncated"
                assert (
                    not (folder / "results.json").exists()
                    and not (folder / "replay.json").exists()
                )
            print(
                json.dumps(
                    {
                        "mode": mode,
                        "elapsed_seconds": elapsed,
                        "status": events[-1]["status"],
                        "private_evidence": True,
                    }
                )
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
