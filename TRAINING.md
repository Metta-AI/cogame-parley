# Five-seat Coworld Parley training and evaluation

Use the Coworld manifest's five-seat `table5` variant for collection, training data, held-out evaluation, and saved-model
inference. Publish and qualify a new release before collecting under this ID; older immutable releases retain `table4`.
The manifest is the authoritative configuration;
`src/parley/sim.nim`, `server.nim`, and `llm.nim` own rules, prompts, action validation, and score semantics.

Use ordinary seed-driven sampling (`sampled: false`): 3–6 rounds, 2–3 hit points, 1–3 survivors, and independently
announced or hidden round/survivor counts. Preserve speech, passes, reactions, side actions (whispers, card reveals,
gifts, pledges), private cards, persistent conversation,
and manifest defaults for pacing, output limits, deadlines, and episode timeout. Certification's fixed two-round fixture
is an infrastructure smoke, not the training or evaluation environment. Do not substitute a four-seat bridge,
head-shot-only action menu, or shortened rules to fit a compute budget.

Pin the published Coworld ID, manifest and image digests, source revision, resolved configuration, player images,
operator prompt, model identities, tokenizer, and decoding settings. Move collection, evaluation, and inference together
when qualifying another release. Base and trained players share the same settings and rotate through all five seats;
freeze the remaining four opponents. Different opponent panels are separate cohorts in this same environment.

The [Metta five-seat guide](https://github.com/Metta-AI/metta/blob/main/packages/metta-training/docs/parley.md)
owns Qwen3.5-4B training commands, upstream SLIME pins, review, dataset splits, and promotion gates.
Bound complete-game count and optimizer updates instead of changing game rules. Report invalid responses, rejected
attempts, fallback origins, terminal scores, latency, tokens, and cost alongside paired game-family uncertainty.

## Player and model boundary

Hosted prompt players call the Coworld LLM sidecar using the configured teacher and attribute each call to its seat.
The game uses `COWORLD_LLM_ENDPOINT`; do not put provider secrets in the hosted manifest.
Saved-model external players receive the exact game-rendered `input.system` and `input.user`, register the same operator
prompt, generate full actions including speech, reactions, and side actions, and submit them over the ordinary player
socket.
The game remains the sole parser and rule owner. Record structured decoding, thinking mode, token limits, and deadlines;
use identical inference settings for base and trained evaluation. A supported platform model route is required for
hosted Qwen. Local endpoint transport does not establish hosted inference parity.

Hosted prompt players use the injected `COWORLD_LLM_ENDPOINT`. Set
`COWORLD_LLM_MODEL` to a registered `checkpoint/<identity>` for a frozen learner,
or a platform-supported provider model. Hosted games need no provider secret.
Local games use the same native endpoint protocol. Retired provider credentials never activate inference.
`COWORLD_LLM_TEMPERATURE` selects temperature from zero to one; default one.
The private evidence records the actual model and native request settings.

## Hosted decision evidence

The engine writes canonical private decision JSONL to
`COGAME_SAVE_TRAJECTORY_URI` before uploading results. Release images embed immutable source and game-version pins. Hosted episode identity comes from the runtime’s
`LLM_REQUEST_METADATA.episode_request_id`; local runs generate an explicitly local identity from 128 bits of OS entropy.
Local identity must be independent of startup time and game seed: parallel games can start within the same second.
Retain colliding historical trajectories as evidence, but do not publish them under ambiguous episode joins.
Verify concurrent five-seat games with `python3 tools/test_local_episode_identity.py /absolute/path/to/parley /fresh/private/output`. The artifact contains
seat-private observations, every native attempt, exact prompts and requests,
raw responses, platform response call IDs, parsed and executed actions,
rejections, explicit scripted policies, and the completed or failed terminal outcome.
A legal budget stop between rounds is completed, even when fewer rounds were played than planned.
Interrupted or failed games publish no scores. Historical releases retain their original `truncated` records;
do not rewrite hash-bound research evidence. Qualify a new release and start a fresh training campaign.
The private outcome uses `parley.native-outcome.v1`: `results` contains the unchanged game results,
`input_config` preserves the original game input with seat authentication tokens removed, and
`selected_seed` records the actual seed selected before rule sampling. An unpinned input keeps its seed absent;
the selected seed is separate evidence, not a reconstructed input. This private envelope never enters replay,
player observations, or model prompts. Update native consumers and qualify the rebuilt release before collection;
the previous published source retains its original outcome format.
Local files are created privately with mode 0600.

Replay v4 carries decision IDs, origins, canonical actions, event offsets,
round settings, and terminal scores. Operator guidance and model responses stay
out of public replay bytes and standard output. Download the elevated
`trajectory` artifact separately; public replay alone is insufficient for
training.

The production renderer and parser serve both prompt players and external
players. External observations include `input.system`, `input.user`, and the native decoder's `actionSchema`.
Register with `{"type":"register","control":"external","prompt":"..."}`
and receive `decision` frames with a string `decision_id`, the unchanged private `observation`, and a separate
`transport` budget. Send `attempt_started` before native inference, then an `action` frame carrying that same identity,
`source`, structured action, and one private `training_attempt`. The engine owns acceptance and execution.
On `stop`, join the owned inference reader before returning `stopped` with the same decision identity, engine-issued
`stop_id`, and actual attempts. Older issued operations may deliver final private transport facts without acknowledging
a newer stop window. Received bytes and identities remain immutable.
Wait for `evidence_received` with the same `decision_id` and `stop_id` before closing the socket, within the original
cleanup deadline. This confirms private fact retention, not stop credit or model receipt authority.
An unsolicited final evidence delivery uses a null `stop_id` and cannot acknowledge an engine-issued stop.
All registered external seats must acknowledge engine-issued stops, including seats that disconnect. Missing or late
acknowledgements seal a private incomplete episode and prevent public results or replay publication. Earlier unsolicited
stop evidence can preserve received bytes but cannot acknowledge a later engine stop.
The private decision observation retains the exact issued external window, including its rendered input and legal
action allowances, even when every proposal is rejected. The top-level prompt identifies only the selected attempt
and is null for failed decisions. Final attempt policy attribution comes from the authenticated seat roster.
Unattested external frames have unknown origin and do not become model labels.
A failed policy terminates the episode immediately: invalid actions, native inference failures,
missing endpoints, timeouts, disconnects, and exhausted budgets never invoke a substitute policy.
The failed decision retains its attempts with no selected or executed action; the private episode
is marked failed, the process exits nonzero, and no public scores or replay are published.
The game declares the failed seat in `COGAME_PLAYER_FAILURE_URI` so the platform charges that policy, not the table.
The terminal stop handshake still joins readers and retains their original evidence.
Explicitly selected scripted baselines remain supported. Preserve failed attempts for audits;
train only on accepted model or approved teacher targets.

Use Metta’s `metta-posttrain prepare-data` command to convert reviewed complete five-seat episodes into SLIME
inputs. Supply the published manifest, private trajectories containing the original token-free input and selected seed,
independent provider archive, and content-bound decision approvals. No separate runtime configuration or authentication
tokens are required. The converter checks ordinary settings, episode/source pins, selected
parsed actions against execution, exact native prompts and responses, provider call joins, and complete-family splits.
Keep all attempts and fallbacks in private evidence; only explicitly approved model or teacher completions become labels.
The pinned Coworld CLI does not supply `coworld training qualify` or `coworld training export`.

Native SFT export does not qualify learner reinforcement learning. That requires saved-weight, tokenizer, and chat-template
identities plus actual sampled-token likelihoods. Greedy completions do not supply sampled likelihoods.

Native prompt policies and external training players use Chat Completions with
the same system/user messages, JSON response format, and disabled thinking.
Freeze temperature and output limits explicitly when comparing policies; native
manifest defaults remain temperature 1 and 300 output tokens. A non-`stop`
completion is failed evidence, even when its partial content parses as JSON.
Earlier Anthropic Messages receipts remain historical evidence in their original format.

Evaluate with the same native renderer, parser, rules, and decoder. Split by
complete episode; reserve fresh seeds and frozen opponents. Record validity,
fallback rate, terminal scores, latency, and token cost. A lower imitation
loss does not establish stronger play.

New exports require the canonical private trajectory and content-bound review through the shared importer.
Archived logs and previous exports remain historical evidence; they cannot qualify current training labels.

## Scripted diagnostic collection

Run the native game with explicitly registered scripted baseline players and
`COGAME_SAVE_TRAJECTORY_URI` to collect infrastructure diagnostics. This uses the
same round progression, seeded reaction order, and evidence writer as model play.
Scripted actions remain scripted evidence and do not become approved teacher labels.

Convert reviewed model episodes with Metta's `metta-posttrain prepare-data` command.
The game no longer maintains a separate simulated-game exporter. Preserve earlier
exports as historical evidence; they do not qualify current training labels.

## Shared environment checks

### Comparing supervised and reward-based learning

The [game-learning study](https://github.com/Metta-AI/posttraining-research/tree/relh/game-learning-roadmap/users/relh/game-learning-roadmap)
compares a frozen supervised parent, continued imitation, and native-reward learning.
Freeze one published release for each comparison. Source changes to completion, prompts, or private outcome records require a newly qualified cohort.
Do not combine newly rebuilt main with historical 0.4.5 training or evaluation records.

The game's score is within-table placement: the fraction of other seats beaten, with half credit for ties.
Keep raw points and completed/planned rounds alongside that score.
A learner's rejected sampled action remains a failed native episode without a game score.
A trainer may define an explicit failure utility, but it must not write that utility back as a native result.
Opponent, transport, and infrastructure failures are separate from learner-action failures.
Retain all attempted episodes when comparing reliability and report any unavailable paired score panel.

All five learner seats, frozen opponents, and ordinary sampled rules remain part of evaluation.
Group every seat and wording of the same physical rule family into one split.
Preserve historical exposure when auditing new splits; a new seed or family hash does not establish an untouched scenario.
Record action acceptance separately from strategic reward: learning to produce legal actions does not alone demonstrate stronger play.
The research runner owns optimization and checkpoint selection; the game remains the sole owner of legal actions and native scores.

### Release and observation parity

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

## Rules wording augmentation

The game owns seven reviewed rule templates under `src/parley/prompts/`:
`canonical`, `plain`, `numbered`, `questions`, `reordered`,
`heldout-briefing`, and `heldout-reference`. The canonical template preserves
existing message bytes. The other templates paraphrase the same mechanics,
including aim probabilities, eliminated-seat scoring, side actions, and
existing strategic hints. Sampled table rules are inserted by the same
renderer; hidden round and survivor counts remain hidden. Player guidance,
private cards, history, legal actions, and reply grammar are unchanged.

The default is `"promptVariant": "canonical"`. For balanced augmentation,
add `"promptVariant": "mixed", "promptSeed": N` to the game configuration.
Nonnegative consecutive prompt seeds cycle through the five training templates.
This seed is independent of the game seed and never advances game randomness.
Every seat uses the same selected template throughout the episode. Randomize
the schedule before collection when balancing across scenarios, seats, and
opponents; do not associate one wording exclusively with a particular role.
Mixed mode requires an explicit prompt seed and never selects held-out wording.
Pin an individual template by setting `promptVariant` to its name. Both held-out
templates are evaluation-only by convention; selecting them explicitly allows
confirmation evaluation, not admission to training data.

Private decision observations include `prompt_template` with bank version
`parley-rules-v1`, selected variant, requested selection, independent seed, and
SHA-256 hashes of the exact system and user messages. External decisions carry
this inside the extensible private `observation` object, retaining the player
protocol shape. Native trajectory evidence retains it alongside exact prompts.
The public spectator view and public replay do not gain prompt metadata.

Collect new responses under the actual selected wording. Never rewrite the
prompt attached to an old response. Group all prompt versions of a scenario
into the same training/validation family. Freeze game/source/model identities,
opponents, inference settings, seeds, and seats for matched comparisons.
Compare base, canonical-only training, and mixed-template training on canonical,
seen-paraphrase, and held-out-paraphrase panels. Report failures alongside mean,
worst-template, and between-template scores; aggregate uncertainty by game seed.
Wording robustness and repeated-action failures are separate from training loss.

Run `python tools/test_prompt_variants.py /absolute/parley /fresh/private/output`
with `websockets==15.0.1`. It plays 16 complete ordinary five-seat games through
real scripted socket players. It checks unchanged state, scoring, private
visibility, and legal side actions across all seven templates and one mixed
selection, using two scenario seeds. Games run sequentially. This proves the
protocol and game invariants, not improved model play.
