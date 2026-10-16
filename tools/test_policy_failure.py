"""Real five-seat policies fail without executing replacement actions."""

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
    mode = sys.argv[3] if len(sys.argv) > 3 else "rejected"
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
    if mode == "missing-endpoint":
        env.update(
            ANTHROPIC_API_KEY="retired-test-key",
            AWS_ENDPOINT_URL_BEDROCK_RUNTIME="http://127.0.0.1:1",
        )
    env.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        COGAME_PLAYER_FAILURE_URI=(root / "player_failure.json").as_uri(),
    )
    rejected = []
    following = []
    stop_reasons = []
    rejection_to_stop = []
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
                            (
                                {
                                    "type": "prompt",
                                    "prompt": "",
                                    "scripted": mode == "baseline",
                                }
                                if mode in {"missing-endpoint", "baseline"}
                                else {
                                    "type": "register",
                                    "control": "external",
                                    "prompt": "",
                                }
                            )
                        )
                    )
                    if mode in {"missing-endpoint", "baseline"}:
                        await process.wait()
                        return
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
                            invalid = not rejected and observation["phase"] == (
                                "reaction" if mode == "reaction" else "shot"
                            )
                            if invalid:
                                rejected.append((latest, time.monotonic()))
                                if mode == "disconnect":
                                    await connection.close()
                                    return
                                if mode == "timeout":
                                    continue
                                action = (
                                    {"give": "not-a-cog"}
                                    if mode == "reaction"
                                    else {"shoot": "not-a-cog", "aim": "head"}
                                )
                            if invalid and mode == "fallback":
                                action = next(
                                    a for a in actions if a["shoot"] != "pass"
                                )
                            frame = {
                                "type": "action",
                                "decision_id": latest,
                                "source": "fallback"
                                if mode == "fallback"
                                else "scripted",
                                "training_attempt": None,
                                "action": action,
                            }
                            await connection.send(json.dumps(frame))
                            if invalid and mode == "duplicate":
                                # A duplicate proposal cannot replace the terminal rejection.
                                frame["action"] = next(
                                    a for a in actions if a["shoot"] != "pass"
                                )
                                await connection.send(json.dumps(frame))
                        elif packet["type"] == "stop":
                            stop_reasons.append(packet["reason"])
                            if rejected:
                                rejection_to_stop.append(
                                    time.monotonic() - rejected[0][1]
                                )
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
                status = await process.wait()
                assert (status == 0) == (mode == "baseline")
            events = [
                json.loads(line)
                for line in (root / "trajectory.jsonl").read_text().splitlines()
            ]
            decisions = [event for event in events if event["event_type"] == "decision"]
            episode = events[-1]
            report = {
                "mode": mode,
                "exit_code": status,
                "decisions": len(decisions),
                "post_failure_decisions": len(following),
                "episode": episode,
            }
            (root / "report.json").write_text(json.dumps(report, indent=2))
            if mode == "baseline":
                assert episode["status"] == "completed"
                assert (root / "results.json").exists() and (
                    root / "replay.json"
                ).exists()
                assert not (root / "player_failure.json").exists()
            else:
                assert episode["status"] == "failed"
                assert episode["participant_outcomes"] is None
                assert episode["outcome"]["termination"] == "policy_failure"
                assert (
                    not (root / "results.json").exists()
                    and not (root / "replay.json").exists()
                )
                assert not following, (
                    "game issued another decision after policy failure"
                )
                failed = decisions[-1]
                assert failed["action_status"] == "rejected"
                assert failed["selected_attempt_id"] is None
                assert failed["executed_action"] is None
                assert failed["fallback_origin"] is None
                assert all(not attempt["accepted"] for attempt in failed["attempts"])
                if mode in {"rejected", "duplicate", "reaction", "fallback"}:
                    assert min(rejection_to_stop) < 5, (
                        "policy rejection waited for its decision timeout"
                    )
                    assert len(failed["attempts"]) == 1
                    assert failed["attempts"][0]["rejection_reason"]
                expected = {
                    "missing-endpoint": "missing_native_endpoint",
                    "disconnect": "external_disconnect",
                    "timeout": "external_timeout",
                }.get(mode, "rejected_action")
                assert episode["outcome"]["policy_failure"]["reason"] == expected
                # The platform scores only a declared seat; otherwise the round is discarded.
                declared = json.loads((root / "player_failure.json").read_text())
                assert set(declared) == {"failed_policy_index", "message"}
                assert declared["failed_policy_index"] == (
                    episode["outcome"]["policy_failure"]["seat"]
                )
                assert expected in declared["message"]
                assert all(reason == "terminal" for reason in stop_reasons)
            print(json.dumps({k: v for k, v in report.items() if k != "episode"}))
        finally:
            for player in players:
                player.cancel()
            await asyncio.gather(*players, return_exceptions=True)
            if process.returncode is None:
                process.kill()
                await process.wait()


asyncio.run(main())
