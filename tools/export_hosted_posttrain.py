"""Verify a Parley v3 replay against its private game log and export SFT rows."""

import argparse
import ast
import hashlib
import json
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--replay", required=True, type=Path)
parser.add_argument("--game-log", required=True, type=Path)
parser.add_argument("--episode-id", required=True)
parser.add_argument(
    "--output",
    type=Path,
    help="Write supervised JSONL only for a full, fallback-free episode",
)
parser.add_argument(
    "--seat", type=int, help="Export only this seat after verifying the whole episode"
)
args = parser.parse_args()

replay_bytes = args.replay.read_bytes()
replay = json.loads(replay_bytes)
if replay["protocol"] != "parley.replay.v3":
    raise ValueError("Hosted training requires a Parley v3 replay")
log = args.game_log.read_text()
if "===== container: game =====" in log:
    section = (
        log.split("===== container: game =====", 1)[1]
        .split("===== container:", 1)[0]
        .strip()
    )
    log = ast.literal_eval(section).decode()
evidence = [
    json.loads(line.removeprefix("parley training: "))
    for line in log.splitlines()
    if line.startswith("parley training: ")
]
references = replay["decisionRefs"]
if len(evidence) != len(references) or not references:
    raise ValueError("Decision evidence does not cover the replay")

rows = []
previous_end = 0
origins = {}
for decision_id, (record, reference) in enumerate(
    zip(evidence, references, strict=True), start=1
):
    if record["reference"] != reference or reference["id"] != decision_id:
        raise ValueError("Private decision evidence differs from the public replay")
    before, after = reference["eventBefore"], reference["eventAfter"]
    if not previous_end <= before <= after <= len(replay["events"]):
        raise ValueError("Decision event offsets overlap or exceed the replay")
    previous_end = after
    seat = reference["seat"]
    if not 0 <= seat < len(replay["names"]):
        raise ValueError("Decision seat is outside the table")
    action = reference["action"]
    events = replay["events"][before:after]
    speech = [event for event in events if event["kind"] == "say"]
    if [(event["seat"], event["text"]) for event in speech] != (
        [(seat, action["say"])] if action["say"] else []
    ):
        raise ValueError("Accepted speech differs from the replay")
    if reference["phase"] == "shot":
        expected = "skip" if action["shoot"] == "pass" else "shot"
        actions = [event for event in events if event["kind"] in ("shot", "skip")]
        if (
            len(actions) != 1
            or actions[0]["kind"] != expected
            or actions[0]["seat"] != seat
        ):
            raise ValueError("Accepted shot or pass differs from the replay")
        if expected == "shot" and (
            replay["names"][actions[0]["target"]] != action["shoot"]
            or actions[0].get("aim", "head") != action["aim"]
        ):
            raise ValueError("Accepted target or aim differs from the replay")
    elif reference["phase"] != "reaction" or any(
        event["kind"] != "say" for event in events
    ):
        raise ValueError("Accepted reaction differs from the replay")

    origin = reference["origin"]
    origins[origin] = origins.get(origin, 0) + 1
    if (
        reference["accepted"]
        and origin in ("model", "external")
        and (args.seat is None or seat == args.seat)
    ):
        if origin == "model":
            prompt = record["input"]
            messages = [
                {"role": "system", "content": prompt["system"], "step_loss_mask": 0},
                {"role": "user", "content": prompt["user"], "step_loss_mask": 0},
            ]
            if not record["response"]["raw"]:
                raise ValueError("Accepted model decision lacks its raw response")
            completion = record["response"]["raw"]
        else:
            prompt = record["input"]
            if json.loads(prompt["wire"]) != prompt["packet"]:
                raise ValueError(
                    "External observation wire differs from the captured packet"
                )
            messages = [
                {"role": "user", "content": prompt["wire"], "step_loss_mask": 0}
            ]
            submitted = json.loads(record["response"]["wire"])
            if (
                submitted["action"] != record["response"]["action"]
                or submitted["id"] != prompt["packet"]["id"]
            ):
                raise ValueError(
                    "External response wire differs from the submitted action"
                )
            completion = record["response"]["wire"]
        messages.append(
            {"role": "assistant", "content": completion, "step_loss_mask": 1}
        )
        rows.append(
            {
                "messages": messages,
                "metadata": {
                    "episode_id": args.episode_id,
                    "seat": seat,
                    "decision_id": decision_id,
                    "policy_name": replay["policyNames"][seat],
                    "replay_sha256": hashlib.sha256(replay_bytes).hexdigest(),
                },
            }
        )

full_schedule = replay["results"]["rounds"] == replay["config"]["plannedRounds"]
trainable = full_schedule and all(
    ref["accepted"] and ref["origin"] in ("model", "external") for ref in references
)
report = {
    "episode_id": args.episode_id,
    "decisions": len(references),
    "origins": origins,
    "full_schedule": full_schedule,
    "trainable": trainable,
    "selected_rows": len(rows),
}
if args.output is not None:
    if not trainable:
        raise ValueError(
            "Episode has fallback, rejected actions, or incomplete rounds; no SFT export"
        )
    args.output.write_text(
        "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows)
    )
    args.output.chmod(0o600)
print(json.dumps(report, indent=2))
