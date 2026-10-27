# Parley

A talkative last-cog-standing party game for the Softmax Coworld platform.
Parley: negotiation before the paint flies.

Cogs sit around a table. One is **IT** and holds the paintgun. Each turn
IT speaks to the table, then shoots one other living cog or passes.

## Rules

- **Health:** every cog starts each round alive at full health. Hits remove
  exactly 1 hp. A cog at 0 hp is out for that round and returns next round.
- **Aim:** a headshot hits with probability 5/6. A hipshot hits with
  probability 1/3. Shots are unlimited. A surviving target takes the gun, hit
  or miss. A fatal hit leaves the gun with the shooter, including a fatal
  hipshot. The shooter knows its aim; everyone else sees only the outcome,
  so a miss alone does not prove a hipshot.
- **Passes:** IT can hold fire and keep the gun. The allowance is shared
  across the table and resets each round; it is not a per-cog allowance.
- **Cards:** each cog privately draws a friend and a different enemy,
  neither itself. Every cog appears on exactly one friend card and one
  enemy card. With four or more seats, at least one pair of cogs hold each
  other's friend card, and players are told so. Cards reshuffle each round.
  Tables with two seats have no cards.
- **Round end:** the round ends when the configured number of cogs remains
  alive. Every survivor wins the round, regardless of remaining hp.
  There is no turn limit.
- **Points:** each survivor earns 3 points. A cog earns 1 point if its enemy
  goes out after at least one of its own shots landed on them (the final hit
  can be anyone's), and 1 point if its friend survives. Eliminated cogs still
  earn enemy and friend points. Enemy and friend points are announced with
  the round's verdict, so they never expose a live card.
- **Talk:** IT speaks with every shot or pass. Between actions, up to
  `maxReactions` other cogs speak, chosen in a seeded shuffle. Cogs that are
  out this round can be chosen too.
- **Side actions:** any shot, pass, or reaction may also carry, at most one
  of each:
  - **whisper** one private line to one cog (2 per cog per round); the rest
    of the table sees only that a whisper happened;
  - **reveal** its friend or enemy card to one cog (once per round); the
    game verifies it, and the rest of the table sees only that a card was shown;
  - **give** one point to any cog (banked points plus this round's gifts
    and pledge payments, which the standings in every prompt show);
  - **pledge**, publicly, not to shoot a living cog for the rest of the
    round. Shooting a pledged cog, hit or miss, moves 1 point from the
    shooter to that cog.
- **Match winner:** raw points (round points plus gifts and pledge
  penalties) accumulate across rounds; the highest total wins, with ties
  allowed. Viewers show raw points. Platform scores are within-table
  placings: the share of the other seats a seat finished ahead of, ties
  counting half. Results also report each raw total's share of
  `5 × completed rounds`.
- **Conversation:** the current round's full transcript is in every prompt.
  Earlier rounds keep every spoken line and every private line the seat
  sent or received, with shots folded into per-pair hit/miss tallies,
  knockouts, and survivors. Health, cards, and allowances reset; previous
  bargains and grudges remain available to players.

Ordinary episodes sample 3–6 rounds, 2–3 hp, and 1–3 survivors from the seed.
The survivor count is capped below the seat count. Round and survivor counts
are independently announced or withheld from players. The Qwen training/evaluation/inference program
uses this ordinary five-seat `table5` environment. Fixed `sampled: true`
fixtures are infrastructure diagnostics; see [the shared training guide](TRAINING.md).

Every table gets the configured passes (default three) and reactions (default
two in `table5`). After each completed round, the game deals another only if
the longest round so far would still finish inside 60% of the episode
timeout. Ending at that completed-round boundary is a completed game, with the
same terminal status in its private trajectory and published results. Interruptions,
policy errors, and unresolved player cleanup are failed games without scores.
Prompts say that running out of time can end the match early. A
policy failure terminates the episode: rejected actions, disconnects, timeouts,
missing inference, and exhausted budgets never select substitute actions.
Private failure evidence is saved with no selected or executed action for the
failed decision. The process exits nonzero and publishes no results or replay.
Before exiting, it writes `{"failed_policy_index", "message"}` to
`COGAME_PLAYER_FAILURE_URI`, naming the failed seat. The platform scores that
seat as the loss and the episode still counts; an undeclared failure gives no
scoring evidence, which aborts a one-episode league round. Native inference transport interruptions, HTTP 429 without a spend-limit marker,
and HTTP 5xx add `"kind": "episode_inconclusive"` to that declaration. Supporting
runners emit no policy blame, so those episodes contribute no rating or failure-streak
evidence. Invalid model actions, authentication errors, and exhausted seat budgets
remain player failures. The game's own episode deadline is not declared as a seat fault.

Deploy runner support for `kind` before publishing this game version. Older runners
reject the additional field; existing declarations without it retain player-failure semantics.
Explicitly selected scripted baselines remain valid policies.

Seats use **anonymous cog names** (Sprocket, Gizmo, …). Private player views
reveal only that seat's cards and aim, plus announced rules and public history.
The live spectator socket is accessible to player containers, so it receives
public information only: anonymous names, no cards or aim, and no hidden rules.
Completed replays reveal cards, aim, and policy names to spectators.
Replay v4 also carries decision IDs, accepted actions, origins, and event
offsets, plus whisper, reveal, and pledge events. Exact prompts and raw responses are retained in private trajectory artifacts;
see [training evidence](TRAINING.md#hosted-decision-evidence).
Results are reported under policy names.

### Inspect model input in a replay

Choose **Model input → Load private trace** and open the game's private `trajectory.jsonl`
or a player's extracted `inference.jsonl`. Files stay in browser memory.
Select a decision to see the original request messages, response, executed action, and any saved reasoning.
Messages retain their exact text, whitespace, and anonymous cog names. The viewer reads the captured
request; it never reconstructs a prompt from replay events. API messages do not include the backend's
chat-template expansion or tokenization.

The game can trim speech and normalize actions, so model responses and executed actions appear separately.
Decision IDs, seats, and executed actions match traces to replay v4. Confirm the source episode;
these checks do not prove file authenticity. Public replay files contain no private prompts or responses.
Rebuild the Coworld viewer to make these controls available in a published release.

**A policy can use a prompt, a scripted baseline, or the general external action interface.**
External players receive private seat views and submit complete speech, shot,
pass, reaction, and side actions. The game validates each action and owns results and replay.

## Layout

- `src/parley.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/parley/sim.nim` — pure rules; shared by server, tests, and JavaScript viewer
- `src/parley/llm.nim` — native model client + explicit scripted baselines
- `src/parley/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/parley_player.nim` — registers prompt or scripted policies
- `client/` — shared canvas renderer + global/player/replay pages
- `replay-viewer/` — CTF-style static JavaScript replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `data/` — cog sprites and art, borrowed from [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
node --test tests/test*.cjs              # replay chat and seek behavior (Node 22+)
bash tools/nim_local.sh r tests/test_sim.nim       # rules and replay tests
bash tools/nim_local.sh r tests/test_scripted.nim  # player prompts
bash tools/nim_local.sh r tests/test_server.nim    # private states and scoring
nim c -d:release -o:bin/parley src/parley.nim
nim c -d:release -o:bin/parley-player src/parley_player.nim
# Training, evaluation, and inference use the published five-seat table5 manifest.
# Fixed certification fixtures test infrastructure only; see TRAINING.md.
# Hosted and local native games use COWORLD_LLM_ENDPOINT; no provider fallback.
```

Coworld packaging (from a metta checkout):

```bash
PARLEY_SOURCE_REVISION=$(git rev-parse HEAD) PARLEY_GAME_VERSION=0.4.0 \
  uv run coworld build --project <this dir> --version 0.4.0
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
```

Native model seats use `/v1/chat/completions`, matching external training players:
system and user messages, JSON-object responses, no thinking, and `top_p=1`.
`COWORLD_LLM_TEMPERATURE` retains its default of 1; `maxOutputTokens` retains
its manifest default of 300. Only `finish_reason=stop` can produce an action.
Truncation and refusal retain the received response and fail the seat without
executing a partial action. This does not guarantee a policy fits its token budget.

## Fielding a policy

```bash
uv run coworld upload-policy <parley image> --name my-parley \
  --run /bin/parley-player \
  --secret-env PLAYER_PROMPT="Your table-talk strategy here."
```

Set `PLAYER_SCRIPTED` to a no-model baseline: `random` (or `1`), `finisher`
(lowest-hp non-friend), `retaliator` (whoever last hit it), `protector`
(whoever last hit its friend, else its enemy), or `hoarder` (passes while
the table can, else `finisher`). External action players
register over the ordinary player socket and use its private observation.

The offline certification fixture explicitly seats five scripted players.
It checks game startup, results, and replay without requiring model access.

The offline-certified bundle declares the explicit `parley-scripted` baseline.
Prompt policies require a native inference endpoint and must be registered as
custom players using `/bin/parley-player` and `PLAYER_PROMPT`; they are not
advertised as an offline-certified bundled player.

Native prompt seats request strict structured output for the currently legal action schema, with a default
1024-token output budget. This prevents explanatory prose and the former 300-token cutoff from corrupting action JSON.
External action players still own generation and must submit a legal action; model failures remain explicit failures.
