# Five-seat Coworld Parley training and evaluation

Use the Coworld manifest's five-seat `table5` variant for collection, training data, held-out evaluation, and saved-model
inference. Publish and qualify a new release before collecting under this ID; older immutable releases retain `table4`.
The manifest is the authoritative configuration;
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

Hosted prompt players use the injected `COWORLD_LLM_ENDPOINT`. Set
`COWORLD_LLM_MODEL` to a registered `checkpoint/<identity>` for a frozen learner,
or a platform-supported provider model. Hosted games need no provider secret.
Local games can use Anthropic or Bedrock credentials outside hosted execution.
`COWORLD_LLM_TEMPERATURE` selects temperature from zero to one; default one.
The private evidence records the actual model and native request settings.
Native requests explicitly disable thinking and carry `output_config.format` with `type: json_schema`.
The schema retains speech, both aim choices, public living targets, and passes while available; reactions contain speech.
Provider routing must support these parameters. Parser validation, rejection, retry, and fallback evidence remain intact.
Do not strip prose, repair JSON, or discard failed attempts. Unsupported providers and truncated responses fail qualification.

This staged request contract requires coordinated gateway and external-player decoding support before publication.
Current published releases retain their recorded decoder settings. Native request fields follow the
[Anthropic structured-output API](https://platform.claude.com/docs/en/build-with-claude/structured-outputs).
[OpenRouter routing](https://openrouter.ai/docs/guides/features/structured-outputs) requires checking endpoint support;
model identity alone does not prove schema enforcement. Live provider/gameplay proof remains required.

## Hosted decision evidence

The engine writes canonical private decision JSONL to
`COGAME_SAVE_TRAJECTORY_URI` before uploading results. Release images embed immutable source and game-version pins. Hosted episode identity comes from the runtime’s
`LLM_REQUEST_METADATA.episode_request_id`; local runs generate an explicitly local identity. The artifact contains
seat-private observations, every native attempt, exact prompts and requests,
raw responses, platform response call IDs, parsed and executed actions,
rejections, scripted fallbacks, and the completed or truncated terminal outcome.
The private outcome uses `parley.native-outcome.v1`: `results` contains the unchanged game results,
`input_config` preserves the original game input with seat authentication tokens removed, and
`selected_seed` records the actual seed selected before rule sampling. An unpinned input keeps its seed absent;
the selected seed is separate evidence, not a reconstructed input. This private envelope never enters replay,
player observations, or model prompts. Update native consumers and qualify the rebuilt release before collection;
the previous published source retains its original outcome format.
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

Use Metta’s `metta-posttrain export-parley-native` command to convert reviewed complete five-seat episodes into SLIME
inputs. Supply the published manifest, private trajectories containing the original token-free input and selected seed,
independent provider archive, and content-bound decision approvals. No separate runtime configuration or authentication
tokens are required. The converter checks ordinary settings, episode/source pins, selected
parsed actions against execution, exact native prompts and responses, provider call joins, and complete-family splits.
Keep all attempts and fallbacks in private evidence; only explicitly approved model or teacher completions become labels.
The pinned Coworld CLI does not supply `coworld training qualify` or `coworld training export`.

Native SFT export does not qualify learner reinforcement learning. That requires saved-weight, tokenizer, and chat-template
identities plus actual sampled-token likelihoods. Greedy completions do not supply sampled likelihoods.

Evaluate with the same native renderer, parser, rules, and decoder. Split by
complete episode; reserve fresh seeds and frozen opponents. Record validity,
fallback rate, terminal scores, latency, and token cost. A lower imitation
loss does not establish stronger play.

`tools/export_hosted_posttrain.py` reads archived `parley training:` game logs
from older releases. Current games emit the private trajectory artifact instead.
Keep historical exports separate from current canonical trajectories.

## Scripted diagnostic collection

`tools/export_posttrain.nim` reads the manifest's five-seat `table5` configuration and exercises the native rules and
hosted reply parser with scripted players. It writes private canonical complete episodes, with engine-event actions, exact prompts, outcomes, and source/mode pins. The shared importer owns family splits and explicit teacher selection. Its data establishes simulator execution and scripted imitation;
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
