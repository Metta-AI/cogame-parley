# Parley training

## Hosted decision evidence

Replay protocol v3 records each decision's seat, phase, origin, canonical
action, and before/after event offsets in `decisionRefs`. The replay also
records planned rounds, reaction and pass settings, and terminal scores. These
fields identify the exact game rules and the actions the server executed.

The exact player-facing input and response live in the **team-only game log**,
as JSON lines prefixed `parley training: `. Prompt seats record the system and
user messages of the successful attempt, the raw response, and any failed
attempts. External seats record the exact observation packet and submitted
wire frame. Scripted and timeout decisions record their origin. A training
export must join these private records to the public replay by decision ID,
verify the event offsets and action, and exclude fallback or rejected actions.
Supervised completions are the exact accepted raw response for prompt players
or the submitted action frame for external players. A model trained on external
frames must use that same frame format during evaluation.
Operator prompts and raw model responses are deliberately absent from the
public replay URL.

Use the same `src/parley/sim.nim` rules and sampled configuration for held-out
evaluation. Split by complete episode and reserve fresh seeds and frozen
opponents; leaderboard games used for SFT cannot be evaluation games. A replay
alone is insufficient as a supervised label until its private log has been
joined and verified.

## Scripted local export

Parley has a local simulator and hosted text players. Export complete matches
for Metta post-training with the hosted player prompts and reply parser:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/parley-table4 10 1
```

The exporter reads the certified `table4` game config from
`coworld_manifest_template.json`, samples ten seeded matches, and writes
`train.jsonl`, `validation.jsonl`, and `manifest.json`. Seeds divisible by five
go to validation, keeping each match entirely in one split. The published
scripted shot and reaction policies provide teacher replies. Each reply passes
through the hosted parser before it advances the native simulator. The exporter
refuses an existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/parley-table4 \
  --output /tmp/parley-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset is imitation of scripted play; its loss does not measure competitive
strength. Parley's free-form table talk is outside the fixed discrete action
space supported by the current Metta RL and PufferLib bridges.
