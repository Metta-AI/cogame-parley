"""Real five-seat game: a rejected action closes its decision without a timeout."""

import asyncio
import json
import os
import socket
import sys
import time
from pathlib import Path

import websockets


async def main():
    binary, output = sys.argv[1:3]
    duplicate = sys.argv[3:] == ["duplicate"]
    root = Path(output).resolve()
    root.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = {
        "seed": 17,
        "sampled": False,
        "tokens": [str(i) for i in range(5)],
        "players": [{"name": f"diagnostic-{i}"} for i in range(5)],
    }
    (root / "config.json").write_text(json.dumps(config))
    env = dict(os.environ)
    env.pop("COWORLD_LLM_ENDPOINT", None)
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
    )
    rejected = []
    following = []
    players = []
    with (root / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(
            binary, env=env, stdout=log, stderr=asyncio.subprocess.STDOUT
        )
        try:
            async with asyncio.timeout(10):
                while "serving on" not in (root / "game.log").read_text():
                    assert process.returncode is None
                    await asyncio.sleep(0.02)

            async def play(seat):
                latest = None
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}"
                ) as connection:
                    await connection.send(
                        json.dumps(
                            {"type": "register", "control": "external", "prompt": ""}
                        )
                    )
                    async for raw in connection:
                        packet = json.loads(raw)
                        if packet["type"] == "decision":
                            latest = packet["decision_id"]
                            if rejected and not following:
                                following.append(time.monotonic() - rejected[0][1])
                            observation = packet["observation"]
                            actions = observation["legalActions"]
                            action = next(
                                (a for a in actions if a["shoot"] != "pass"), {}
                            )
                            invalid = not rejected and observation["phase"] == "shot"
                            if invalid:
                                rejected.append((latest, time.monotonic()))
                                action = {"shoot": f"diagnostic-{seat}", "aim": "head"}
                            frame = {
                                "type": "action",
                                "decision_id": latest,
                                "source": "scripted",
                                "training_attempt": None,
                                "action": action,
                            }
                            await connection.send(json.dumps(frame))
                            if invalid and duplicate:
                                # A duplicate proposal cannot replace the terminal rejection.
                                frame["action"] = next(
                                    a for a in actions if a["shoot"] != "pass"
                                )
                                await connection.send(json.dumps(frame))
                        elif packet["type"] == "stop":
                            await connection.send(
                                json.dumps(
                                    {
                                        "type": "stopped",
                                        "decision_id": latest,
                                        "stop_id": packet["stop_id"],
                                        "worker_status": "no_active_call",
                                        "attempts": [],
                                    }
                                )
                            )
                        elif packet["type"] == "evidence_received":
                            return

            players = [asyncio.create_task(play(seat)) for seat in range(5)]
            async with asyncio.timeout(1300):
                await asyncio.gather(*players)
                assert await process.wait() == 0
            events = [
                json.loads(line)
                for line in (root / "trajectory.jsonl").read_text().splitlines()
            ]
            decisions = [event for event in events if event["event_type"] == "decision"]
            first = decisions[0]
            report = {
                "rejection_to_next_decision_seconds": following[0],
                "decisions": len(decisions),
                "first_decision": first,
                "episode": events[-1],
            }
            (root / "report.json").write_text(json.dumps(report, indent=2))
            print(
                json.dumps(
                    {
                        "rejection_to_next_decision_seconds": following[0],
                        "decisions": len(decisions),
                    }
                )
            )
            assert following[0] < 5, "rejected action waited for the 45-second deadline"
            assert first["fallback_origin"] == "scripted_after_rejected_action"
            assert first["action_status"] == "fallback"
            assert first["selected_attempt_id"] is None
            assert any(attempt["rejection_reason"] for attempt in first["attempts"])
            assert events[-1]["status"] == "completed"
            assert (root / "results.json").exists() and (root / "replay.json").exists()
        finally:
            for player in players:
                player.cancel()
            await asyncio.gather(*players, return_exceptions=True)
            if process.returncode is None:
                process.kill()
                await process.wait()


asyncio.run(main())
