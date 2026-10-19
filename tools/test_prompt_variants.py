"""Complete ordinary five-seat games across wording variants using real scripted socket players.

Arguments: compiled game binary, fresh private output directory.
No inference service is substituted: these are explicitly scripted policies.
"""

import asyncio
import hashlib
import json
import os
from pathlib import Path
import socket
import sys

import websockets


async def play(binary, folder, seed, variant, prompt_seed):
    folder.mkdir(mode=0o700)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config = {
        "seed": seed,
        "promptVariant": variant,
        "promptSeed": prompt_seed,
        "turnDelayMs": 0,
        "episodeTimeoutSeconds": 120,
        "player_connect_timeout_seconds": 20,
        "tokens": [str(i) for i in range(5)],
        "players": [{"name": f"scripted-{i}"} for i in range(5)],
    }
    (folder / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ)
    environment.pop("LLM_REQUEST_METADATA", None)
    environment.pop("COWORLD_LLM_ENDPOINT", None)
    environment.update(
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(folder / "config.json").as_uri(),
        COGAME_RESULTS_URI=(folder / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(folder / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(folder / "trajectory.jsonl").as_uri(),
    )
    observations = []
    metadata = []
    systems = {}
    phases = set()
    extras_used = set()
    with (folder / "game.log").open("w") as log:
        process = await asyncio.create_subprocess_exec(binary, env=environment, stdout=log, stderr=log)
        players = []
        try:
            async with asyncio.timeout(20):
                while "serving on" not in (folder / "game.log").read_text():
                    assert process.returncode is None, (folder / "game.log").read_text()
                    await asyncio.sleep(0.02)

            async def player(seat):
                latest = None
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={seat}", max_size=2**24
                ) as connection:
                    await connection.send(json.dumps({
                        "type": "register", "control": "external", "prompt": "Keep all rules unchanged."
                    }))
                    async for raw in connection:
                        frame = json.loads(raw)
                        if frame["type"] == "decision":
                            latest = frame["decision_id"]
                            observation = frame["observation"]
                            messages = observation["input"]
                            identity = observation["observation"]["prompt_template"]
                            assert identity["seed"] == prompt_seed
                            for role in ("system", "user"):
                                assert identity[f"{role}_sha256"].lower() == hashlib.sha256(
                                    messages[role].encode()
                                ).hexdigest()
                            assert systems.setdefault(seat, messages["system"]) == messages["system"]
                            metadata.append(identity)
                            phases.add(observation["phase"])
                            assert all(
                                other == seat or (view["friend"] == -1 and view["enemy"] == -1)
                                for other, view in enumerate(observation["observation"]["seats"])
                            )
                            # Compare every non-system input across equivalent episodes, including private views.
                            observations.append({
                                **observation,
                                "input": {"user": messages["user"]},
                                "observation": {**observation["observation"], "prompt_template": None},
                            })
                            action = dict(next(
                                (a for a in observation["legalActions"] if a["shoot"] != "pass"), {}
                            ))
                            action["say"] = "scripted prompt-variation check"
                            extras = observation["extras"]
                            if extras["whisper"]["to"]:
                                action["whisper"] = {"to": extras["whisper"]["to"][0], "text": "private check"}
                            if extras["reveal"]["to"]:
                                action["reveal"] = {"to": extras["reveal"]["to"][0], "card": "friend"}
                            if extras["give"]["to"]:
                                action["give"] = extras["give"]["to"][0]
                            if extras["pledge"]["to"]:
                                action["pledge"] = extras["pledge"]["to"][0]
                            # Exercise the shared pass allowance before shooting.
                            if any(a["shoot"] == "pass" for a in observation["legalActions"]):
                                action["shoot"] = "pass"
                            extras_used.update(set(action) & {"whisper", "reveal", "give", "pledge"})
                            await connection.send(json.dumps({
                                "type": "action", "decision_id": latest, "source": "scripted",
                                "training_attempt": None, "action": action,
                            }))
                        elif frame["type"] == "stop":
                            await connection.send(json.dumps({
                                "type": "stopped", "decision_id": latest, "stop_id": frame["stop_id"],
                                "worker_status": "no_active_call", "attempts": [],
                            }))
                        elif frame["type"] == "evidence_received":
                            return

            players = [asyncio.create_task(player(seat)) for seat in range(5)]
            async with asyncio.timeout(130):
                await asyncio.gather(*players)
                assert await process.wait() == 0, (folder / "game.log").read_text()
        finally:
            for task in players:
                task.cancel()
            await asyncio.gather(*players, return_exceptions=True)
            if process.returncode is None:
                process.terminate()
                await process.wait()
    trajectory = [json.loads(line) for line in (folder / "trajectory.jsonl").read_text().splitlines()]
    assert trajectory[-1]["status"] == "completed"
    assert len(observations) == len(trajectory) - 1
    assert phases == {"shot", "reaction"}
    assert extras_used == {"whisper", "reveal", "give", "pledge"}
    selected = {m["variant"] for m in metadata}
    assert len(selected) == 1
    for event, expected in zip(trajectory[:-1], metadata, strict=True):
        assert event["observation"]["observation"]["prompt_template"] == expected
    return {
        "observations": observations,
        "results": json.loads((folder / "results.json").read_text()),
        "systems": systems,
        "selected": selected.pop(),
        "decisions": len(observations),
    }


async def main():
    binary, destination = sys.argv[1:]
    root = Path(destination).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    variants = ["canonical", "plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference"]
    reports = []
    for seed in [17, 946001]:
        canonical = await play(binary, root / f"{seed}-canonical", seed, "canonical", 0)
        gate = asyncio.Semaphore(1)

        async def run_variant(variant, prompt_seed):
            async with gate:
                run = await play(binary, root / f"{seed}-{variant}-{prompt_seed}", seed, variant, prompt_seed)
            assert run["observations"] == canonical["observations"], "Wording changed state, actions or private visibility"
            assert run["results"] == canonical["results"], "Wording changed game outcomes"
            return run

        direct = await asyncio.gather(*(run_variant(variant, index) for index, variant in enumerate(variants[1:], 1)))
        runs = [canonical, *direct]
        assert [run["selected"] for run in runs] == variants
        assert len({run["systems"][0] for run in runs}) == len(variants)
        mixed = await asyncio.gather(*(run_variant("mixed", index) for index in range(5)))
        for expected, run in zip(runs[:5], mixed, strict=True):
            assert run["selected"] == expected["selected"]
            assert run["systems"] == expected["systems"]
        reports.extend({"seed": seed, "variant": run["selected"], "decisions": run["decisions"]} for run in runs)
    (root / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
    print(json.dumps({"completed_games": 24, "templates": 7, "output": str(root)}))


asyncio.run(main())
