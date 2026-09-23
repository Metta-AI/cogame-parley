# Parley training

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
