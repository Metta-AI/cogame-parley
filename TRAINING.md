# Parley training

Hosted prompt players use the injected `COWORLD_LLM_ENDPOINT`. Set
`COWORLD_LLM_MODEL` to a registered `checkpoint/<identity>` for a frozen learner,
or a platform-supported provider model. Hosted games need no provider secret.
Local games can use Anthropic or Bedrock credentials outside hosted execution.
`COWORLD_LLM_TEMPERATURE` selects temperature from zero to one; default one.
The private evidence records the actual model and native request settings.

## Hosted decision evidence

The engine writes canonical private decision JSONL to
`COGAME_SAVE_TRAJECTORY_URI` before uploading results. Capture requires
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and immutable
`COWORLD_SOURCE_REVISION`, injected by the runtime. The artifact contains
seat-private observations, every native attempt, exact prompts and requests,
raw responses, platform response call IDs, parsed and executed actions,
rejections, scripted fallbacks, and the completed or truncated terminal outcome.
Local files are created privately with mode 0600.

Replay v3 carries decision IDs, origins, canonical actions, event offsets,
round settings, and terminal scores. Operator guidance and model responses stay
out of public replay bytes and standard output. Download the elevated
`trajectory` artifact separately; public replay alone is insufficient for
training.

The production renderer and parser serve both prompt players and external
players. External observations include `input.system` and `input.user`.
Register with `{"type":"register","control":"external","prompt":"..."}`
and submit the ordinary structured action frame. External players may include
private native `attempts` evidence; the engine owns acceptance and execution.
Unattested external frames have unknown origin and do not become model labels.
Two invalid prompt responses invoke the scripted fallback. Preserve failed
attempts for audits; train only on accepted model or approved teacher targets.

With the training-enabled Coworld SDK, qualify a downloaded artifact:

```bash
coworld training qualify /private/trajectory.jsonl --transport hosted
coworld training export /private/trajectory.jsonl /private/qualified --transport hosted
```

The gate validates record evidence, including selected parsed-action equality
with the executed action. Independently join platform call IDs against the
private provider archive before claiming hosted provenance. Export keeps
complete episodes; the application trainer selects policy and seat labels.
Learner reinforcement learning also requires saved-weight, tokenizer, and
chat-template identities plus actual sampled token likelihoods. Use
`--objective rl` to reject missing sampling evidence. Greedy completions do not
supply sampled likelihoods.

Evaluate with the same native renderer, parser, rules, and decoder. Split by
complete episode; reserve fresh seeds and frozen opponents. Record validity,
fallback rate, terminal scores, latency, and token cost. A lower imitation
loss does not establish stronger play.

`tools/export_hosted_posttrain.py` reads archived `parley training:` game logs
from older releases. Current games emit the private trajectory artifact instead.
Keep historical exports separate from current canonical trajectories.

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
