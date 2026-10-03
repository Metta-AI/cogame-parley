"""Owned CPU integration diagnostic: ordinary five-seat game plus shipped player."""

import asyncio
import json
import os
import re
import runpy
import signal
import socket
import sys
from pathlib import Path
from types import SimpleNamespace

import httpx
import websockets


async def main():
    binary, player_source, output, mode = sys.argv[1:]
    root = Path(output)
    root.mkdir(mode=0o700)
    module = SimpleNamespace(**runpy.run_path(player_source))
    entered = asyncio.Event()
    calls = []
    handlers = set()

    async def native(reader, writer):
        task = asyncio.current_task()
        handlers.add(task)
        try:
            headers = await reader.readuntil(b"\r\n\r\n")
            size = int(re.search(rb"(?i)content-length: (\d+)", headers)[1])
            request = json.loads(await reader.readexactly(size))
            assert set(request) == {
                "model",
                "messages",
                "temperature",
                "top_p",
                "max_tokens",
            }
            user = request["messages"][1]["content"]
            target = re.search(r'<one of "([^"]+)"', user)
            action = {"say": "ordinary five-seat CPU diagnostic"}
            if target:
                action.update(shoot=target[1], aim="head")
            response = {
                "model": request["model"],
                "choices": [
                    {
                        "message": {"content": json.dumps(action)},
                        "finish_reason": "stop",
                    }
                ],
            }
            if mode == "large-metadata":
                response["sampling_evidence"] = {
                    "policy_revision": "fixture-checkpoint",
                    "tokenizer_revision": "fixture-tokenizer",
                    "chat_template": "fixture-template",
                    "sampling": "full_softmax_temperature_one",
                    "enable_thinking": False,
                    "max_new_tokens": request["max_tokens"],
                    "max_sequence_length": 32768 + request["max_tokens"],
                    "sampling_seed": 17,
                    "eos_token_ids": [2],
                    "prompt_token_ids": list(range(32768)),
                    "completion_token_ids": [3, 2],
                    "behavior_log_probs": [-1.0, -0.5],
                    "stop_reason": "eos",
                    "response": json.dumps(action),
                }
            raw = json.dumps(response).encode()
            calls.append({"request": request, "raw_response": raw.decode()})
            if mode.startswith("signal-"):
                writer.write(
                    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n"
                )
                prefix = b'{"content":"\xe2\x82'
                writer.write(hex(len(prefix))[2:].encode() + b"\r\n" + prefix + b"\r\n")
                await writer.drain()
                entered.set()
                await reader.read()
                return
            writer.write(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                + str(len(raw)).encode()
                + b"\r\n\r\n"
                + raw
            )
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()
            handlers.remove(task)

    server = await asyncio.start_server(native, "127.0.0.1", 0)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    config = {
        "seed": 17,
        "sampled": False,
        "tokens": ["owned-private-seat-" + str(i) for i in range(5)],
        "players": [{"name": "diagnostic-" + str(i)} for i in range(5)],
    }
    if mode == "large-metadata":
        config.update(
            sampled=True,
            rounds=1,
            hitPoints=1,
            survivors=1,
            reactions=True,
            maxReactions=1,
            turnDelayMs=0,
            episodeTimeoutSeconds=30,
            player_connect_timeout_seconds=3,
        )
    (root / "config.json").write_text(json.dumps(config))
    env = dict(
        os.environ,
        COGAME_HOST="127.0.0.1",
        COGAME_PORT=str(port),
        COGAME_CONFIG_URI=(root / "config.json").as_uri(),
        COGAME_RESULTS_URI=(root / "results.json").as_uri(),
        COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
        COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
        LLM_REQUEST_METADATA=json.dumps(
            {"episode_request_id": "local-five-seat-external-v3"}
        ),
    )
    log = (root / "game.log").open("w")
    process = await asyncio.create_subprocess_exec(
        binary, env=env, stdout=log, stderr=asyncio.subprocess.STDOUT
    )
    owned_players = []
    try:
        async with asyncio.timeout(10):
            while True:
                if process.returncode is not None:
                    raise RuntimeError((root / "game.log").read_text())
                async with httpx.AsyncClient() as probe:
                    check = asyncio.create_task(
                        probe.get(f"http://127.0.0.1:{port}/healthz")
                    )
                    done, _ = await asyncio.wait({check}, timeout=0.15)
                    if (
                        done
                        and check.exception() is None
                        and check.result().status_code == 200
                    ):
                        break
                    if not check.done():
                        check.cancel()
                    await asyncio.gather(check, return_exceptions=True)
                await asyncio.sleep(0.02)
        os.environ.update(
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{server.sockets[0].getsockname()[1]}",
            COWORLD_LLM_MODEL="checkpoint/diagnostic-fixture",
            PARLEY_OPERATOR_PROMPT="PRIVATE FIVE-SEAT OPERATOR",
            PARLEY_TEMPERATURE="1" if mode == "large-metadata" else "0",
        )

        async def play(seat):
            async with httpx.AsyncClient(timeout=None) as client:
                async with websockets.connect(
                    f"ws://127.0.0.1:{port}/player?slot={seat}&token={config['tokens'][seat]}"
                ) as connection:
                    player = module.Player(connection, client)
                    owned_players.append(player)
                    await player.run()

        async def interrupt():
            await asyncio.wait_for(entered.wait(), 10)
            await asyncio.sleep(0.1)
            requested = signal.SIGINT if mode == "signal-int" else signal.SIGTERM
            process.send_signal(requested)
            process.send_signal(requested)

        async with asyncio.timeout(1300):
            controls = (
                []
                if not mode.startswith("signal-")
                else [asyncio.create_task(interrupt())]
            )
            results = await asyncio.gather(
                *(play(seat) for seat in range(5)), return_exceptions=True
            )
            await asyncio.gather(*controls)
            assert not any(isinstance(result, BaseException) for result in results), (
                results
            )
            assert await process.wait() == 0
        if handlers:
            await asyncio.wait_for(asyncio.gather(*handlers), 2)
        records = [
            json.loads(line)
            for line in (root / "trajectory.jsonl").read_text().splitlines()
        ]
        episode = records[-1]
        decisions = records[:-1]
        if mode.startswith("signal-"):
            assert (
                episode["status"] == "truncated"
                and episode["participant_outcomes"] is None
            )
            assert (
                not (root / "results.json").exists()
                and not (root / "replay.json").exists()
            )
            assert all(
                player.worker is None or player.worker.done()
                for player in owned_players
            )
            assert set(episode["outcome"]["player_cleanup"].values()) == {
                "acknowledged"
            }
            attempts = [
                attempt
                for decision in decisions
                for attempt in decision["attempts"]
                if attempt["origin"] == "model"
            ]
            assert attempts and all(
                attempt["response_reader_joined"] is True
                and attempt["response_complete"] is False
                for attempt in attempts
            )
            proof = {
                "mode": mode,
                "source_revision": episode["source_revision"],
                "status": "truncated",
                "registered_players": 5,
                "native_partial_attempts": len(attempts),
                "all_registered_players_joined": True,
                "all_player_runs_clean": True,
                "public_artifacts": False,
                "authentic_platform_receipts": 0,
                "scope": "ordinary five-seat CPU signal diagnostic",
            }
            (root / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
            print(json.dumps(proof))
            return
        assert episode["status"] == "completed"
        assert len(episode["participant_outcomes"]) == 5
        attempts = [
            attempt
            for decision in decisions
            for attempt in decision["attempts"]
            if attempt["origin"] == "model"
        ]
        assert len(attempts) == len(calls) > 0
        if mode == "large-metadata":
            assert all(
                attempt["prompt_token_ids"] == list(range(32768))
                for attempt in attempts
            )
            assert all(
                attempt["sampled_token_ids"] == [3, 2]
                and attempt["behavior_logprobs"] == [-1.0, -0.5]
                for attempt in attempts
            )
            assert all(
                65536 < len(json.dumps(attempt).encode()) < 16 * 1024 * 1024
                for attempt in attempts
            )
            assert all(
                attempt["raw_response"] == call["raw_response"]
                for attempt, call in zip(attempts, calls, strict=True)
            )
            for decision in decisions:
                selected = next(
                    attempt
                    for attempt in decision["attempts"]
                    if attempt["attempt_id"] == decision["selected_attempt_id"]
                )
                assert (
                    selected["accepted"]
                    and selected["parsed_action"] == decision["executed_action"]
                )
        assert all(
            attempt["response_complete"] is True
            and attempt["response_reader_joined"] is True
            for attempt in attempts
        )
        assert all(
            player.worker is None or player.worker.done() for player in owned_players
        )
        assert len(
            [decision for decision in decisions if decision["selected_attempt_id"]]
        ) == len(decisions)
        public = (root / "replay.json").read_text() + (
            root / "results.json"
        ).read_text()
        assert "PRIVATE FIVE-SEAT OPERATOR" not in public and all(
            token not in public for token in config["tokens"]
        )
        replay = json.loads((root / "replay.json").read_text())
        proof = {
            "source_revision": episode["source_revision"],
            "game_version": episode["game_version"],
            "ordinary_config": config | {"tokens": "redacted"},
            "resolved_config": replay["config"],
            "whole_episodes": 1,
            "decisions": len(decisions),
            "native_http_calls": len(calls),
            "mode": mode,
            "prompt_token_metadata_count": 32768 if mode == "large-metadata" else None,
            "all_registered_players_joined": True,
            "all_player_runs_clean": True,
            "authentic_platform_receipts": 0,
            "scope": "CPU synthetic HTTP diagnostic; no image/release/strength qualification",
        }
        (root / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
        print(json.dumps(proof))
    finally:
        if process.returncode is None:
            process.send_signal(signal.SIGTERM)
            await asyncio.wait_for(process.wait(), 15)
        server.close()
        await server.wait_closed()
        if handlers:
            await asyncio.wait_for(asyncio.gather(*handlers), 2)
        log.close()
        for path in root.iterdir():
            if path.is_file():
                path.chmod(0o600)


asyncio.run(main())
