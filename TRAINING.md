# Five-seat Coworld Parley training and evaluation

Use the published Coworld manifest's `table4` variant for collection, training data, held-out evaluation, and saved-model
inference. Despite its historical name, `table4` has five seats. The manifest is the authoritative configuration;
`src/parley/sim.nim`, `server.nim`, and `llm.nim` own rules, prompts, action validation, and score semantics.

Use ordinary seed-driven sampling (`sampled: false`): 3–20 rounds, 2–5 hit points, 1–3 survivors, and independently
announced or hidden round/survivor counts. Preserve speech, passes, reactions, private cards, persistent conversation,
and manifest defaults for pacing, output limits, deadlines, and episode timeout. Certification's fixed two-round fixture
is an infrastructure smoke, not the training or evaluation environment. Do not substitute a four-seat bridge,
head-shot-only action menu, or shortened rules to fit a compute budget.

Pin the published Coworld ID, manifest and image digests, source revision, resolved configuration, player images,
operator prompt, model identities, tokenizer, and decoding settings. Move collection, evaluation, and inference together
when qualifying another release. Base and trained players share the same settings and rotate through all five seats;
freeze the remaining four opponents. Different opponent panels are separate cohorts in this same environment.

The [Metta five-seat guide](https://github.com/Metta-AI/metta/blob/main/packages/metta-posttrain/docs/slime-parley-hosted-sft.md)
owns Qwen3.5-4B training commands, upstream SLIME pins, review, dataset splits, and promotion gates.
Bound complete-game count and optimizer updates instead of changing game rules. Report invalid responses, rejected
attempts, fallback origins, terminal scores, latency, tokens, and cost alongside paired game-family uncertainty.

## Player and model boundary

Hosted prompt players call the Coworld LLM sidecar using the configured teacher and attribute each call to its seat.
The game uses `COWORLD_LLM_ENDPOINT`; do not put provider secrets in the hosted manifest.
Saved-model external players receive the exact game-rendered `input.system` and `input.user`, register the same operator
prompt, generate full actions including speech and reactions, and submit them over the ordinary player socket.
The game remains the sole parser and rule owner. Record structured decoding, thinking mode, token limits, and deadlines;
use identical inference settings for base and trained evaluation. A supported platform model route is required for
hosted Qwen. Local endpoint transport does not establish hosted inference parity.

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
Internal prompt-player responses must be a single JSON object. Prose or code
fences trigger the existing retry, and two failed attempts trigger a scripted
fallback. External players still submit structured action frames over the
socket.
Supervised completions are the exact accepted raw response for prompt players
or the submitted action frame for external players. A model trained on external
frames must use that same frame format during evaluation.
External player observations now include `input.system` and `input.user`,
rendered by the same server functions as hosted prompt-player calls. A Qwen
player registers with `{"type":"register","control":"external","prompt":"..."}`,
where `prompt` is the operator guidance used for the SFT comparison. The
player can then use those messages directly and submit its parsed action frame.
This preserves the training prompt without reimplementing the game rules in
the player. Compare captured external packets to hosted prompt logs before
claiming end-to-end inference parity.
Operator prompts and raw model responses are deliberately absent from the
public replay URL.

Use the same `src/parley/sim.nim` rules and sampled configuration for held-out
evaluation. Split by complete episode and reserve fresh seeds and frozen
opponents; leaderboard games used for SFT cannot be evaluation games. A replay
alone is insufficient as a supervised label until its private log has been
joined and verified.

After downloading one hosted replay and its elevated game-log artifact, run:

```bash
python tools/export_hosted_posttrain.py --replay /private/replay.json \
  --game-log /private/game.log --episode-id ereq_... \
  --output /private/sft.jsonl
```

The exporter verifies the whole episode before writing rows. A completed game
may contain a scripted fallback; its accepted model decisions still become
rows, while fallback actions never enter the loss mask. The report keeps origin
counts and original decision IDs so training can audit the mixed game. Omit
`--output` to inspect origins and schedule completion without creating data.

## Scripted diagnostic collection

`tools/export_posttrain.nim` reads the manifest's five-seat `table4` configuration and exercises the native rules and
hosted reply parser with scripted players. Its data establishes simulator execution and scripted imitation;
it is not approved model-teacher data for the Qwen program. The retired `metta_posttrain.train` command and the
four-seat Metta bridge are not program entry points. Use reviewed accepted model decisions from the shared Coworld
runtime and the Metta five-seat guide for new training.

## Shared environment checks

Before collecting a corpus, compare the published manifest with the pinned source and verify five player/token slots,
ordinary sampling, and the same resolved configuration in collection and evaluation. Match private external observation
messages to the game-rendered prompt; retain full generated actions and their accepted effects.
Use the published game and player images for local Coworld execution and the same socket protocol for hosted play.
Retain the engine's termination reason and fallback attribution; an engine-written score is not proof of unassisted play.

Keep all seats, retries, mutations, and forks from a game family in one dataset partition. Reserve evaluation families
before selecting labels or checkpoints. Review winning and losing decisions; legal JSON alone does not approve a label.
Do not train fallback actions. Report fallback-influenced histories even when their accepted model responses are retained.

Every experiment ends with a few paragraphs stating the question and pinned setup, measured findings or failures,
and the next decision. Keep raw private prompts, logs, receipts, and checkpoint weights outside Git.
