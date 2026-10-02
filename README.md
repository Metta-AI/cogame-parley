# Parley

A talkative last-cog-standing party game for the Softmax Coworld platform.
Parley: negotiation before the paint flies.

Cogs sit around a table. One is **IT** and holds the paintgun. Each turn
IT speaks to the table, then shoots one other living cog or passes.

## Rules

- **Health:** every cog starts each round alive at full health. Hits remove
  exactly 1 hp. A cog at 0 hp is out for that round and returns next round.
- **Aim:** a headshot always hits. A hipshot hits with probability 1/3.
  Shots are unlimited. A surviving target takes the gun, hit or miss.
  A fatal hit leaves the gun with the shooter, including a fatal hipshot.
  The shooter knows its aim; everyone else sees only the outcome.
- **Passes:** IT can hold fire and keep the gun. The allowance is shared
  across the table and resets each round; it is not a per-cog allowance.
- **Cards:** each cog privately draws a friend and a different enemy,
  neither itself. Every cog appears on exactly one friend card and one
  enemy card. Cards reshuffle each round. Tables with two seats have no cards.
- **Round end:** the round ends when the configured number of cogs remains
  alive. Every survivor wins the round, regardless of remaining hp.
  There is no turn limit.
- **Points:** each survivor earns 3 points. A cog earns 1 point if its own
  shot eliminates its enemy and 1 point if its friend survives.
  Eliminated cogs still earn earned enemy and friend points.
- **Match winner:** raw points accumulate across rounds; the highest total
  wins, with ties allowed. Viewers show raw points. Platform scores divide
  raw points by `5 × completed rounds` so different matches are comparable.
- **Conversation:** table talk and shot outcomes remain in the match
  transcript across rounds. Health, cards, and pass allowances reset;
  previous bargains and grudges remain available to players.

Ordinary episodes sample 3–20 rounds, 2–5 hp, and 1–3 survivors from the seed.
The survivor count is capped below the seat count. Round and survivor counts
are independently announced or withheld from players. The Qwen training/evaluation/inference program uses this ordinary five-seat
`table5` environment. Fixed `sampled: true` fixtures are infrastructure diagnostics;
see [the shared training guide](TRAINING.md).

With the default talk configuration, matches of up to five rounds allow
three shared passes and three reactions between actions. Matches of six to
ten rounds allow at most one of each. Longer matches allow neither.
A match can stop after a completed round when 60% of the episode timeout
has elapsed, including round-ending pacing; it never truncates a round.
After that budget expires, the scripted fallback finishes the current round
without further model/player waits, reactions, or spectator pacing.
Results and replay report completed rounds.

Seats use **anonymous cog names** (Sprocket, Gizmo, …). Private player views
reveal only that seat's cards and aim, plus announced rules and public history.
The live spectator socket is accessible to player containers, so it receives
public information only: anonymous names, no cards or aim, and no hidden rules.
Completed replays reveal cards, aim, and policy names to spectators.
Replay v3 also carries decision IDs, accepted actions, origins, and event
offsets. Exact prompts and raw responses are retained in private trajectory artifacts;
see [training evidence](TRAINING.md#hosted-decision-evidence).
Results are reported under policy names.

**A policy can use a prompt, a scripted baseline, or the general external action interface.**
External players receive private seat views and submit complete speech, shot,
pass, and reaction actions. The game validates each action and owns results and replay.

## Layout

- `src/parley.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/parley/sim.nim` — pure rules; shared by server, tests, and wasm viewer
- `src/parley/llm.nim` — Sonnet client + scripted fallback
- `src/parley/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/parley_player.nim` — registers prompt or scripted policies
- `client/` — shared canvas renderer + global/player/replay pages
- `replay-viewer/` — CTF-style static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `data/` — cog sprites and art, borrowed from [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
bash tools/nim_local.sh r tests/test_sim.nim       # rules and replay tests
bash tools/nim_local.sh r tests/test_scripted.nim  # player prompts
bash tools/nim_local.sh r tests/test_server.nim    # private states and scoring
nim c -d:release -o:bin/parley src/parley.nim
nim c -d:release -o:bin/parley-player src/parley_player.nim
# Training, evaluation, and inference use the published five-seat table5 manifest.
# Fixed certification fixtures test infrastructure only; see TRAINING.md.
# Hosted games use COWORLD_LLM_ENDPOINT; local games can use ANTHROPIC_API_KEY.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
```

## Fielding a policy

```bash
uv run coworld upload-policy <parley image> --name my-parley \
  --run /bin/parley-player \
  --secret-env PLAYER_PROMPT="Your table-talk strategy here."
```

Set `PLAYER_SCRIPTED=1` for the no-model comparator. External action players
register over the ordinary player socket and use its private observation.

The canonical certification fixture seats four prompt players and the declared
scripted baseline. Its image and manifest passed all ten local Coworld checks
with `coworld[auth]==0.1.53`, including startup, results, and replay.
