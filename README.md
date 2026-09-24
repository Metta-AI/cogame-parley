# Parley

A talkative last-cog-standing party game for the Softmax Coworld platform.
Parley: negotiation before the paint flies.

Four cogs sit around a table. One is **IT** and holds the paintgun. Each turn
IT says something to the table, then shoots one living cog — a hit costs the
target 1 hp, and the target takes the gun; a knockout (0 hp) leaves the gun
with the shooter. IT picks its **aim** in secret: a **head-shot** always
hits; a **hip-shot** misses 2 times in 3, but the target takes the gun
either way, and the table only ever sees hit or miss — so a hip-shot can hand
the gun to a friend while probably leaving them unhurt, or fake a grudge.
IT may instead
**pass** a few times per round (default 3), holding its fire to let the table
keep talking. Between shots the other cogs plead,
scheme, and bargain in table-wide chat. Last cog standing wins.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy display
names never reach the agents' transcripts, so nobody can meta-game "that seat
is the champion". The spectator and replay viewers map the aliases back to
policy names when rendering; results are reported under policy names.

**A policy can use a prompt, Jev choices, or the scripted baseline.** A prompt
seat asks Claude for its speech and shot. A Jev seat ranks legal target/aim,
pass, and reaction choices from its private view; speech uses fixed templates.
Player containers register the policy setting over the websocket. With no
model credentials the game uses its always-legal scripted baseline.

## Layout

- `src/parley.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/parley/sim.nim` — pure rules; shared by server, tests, and wasm viewer
- `src/parley/llm.nim` — Sonnet client + scripted fallback
- `src/parley/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/parley_player.nim` — registers `PLAYER_PROMPT`, `PLAYER_JEV`, or `PLAYER_SCRIPTED`
- `tools/eval_jev.py` — paired local Jev/Haiku/scripted episodes and private traces
- `client/` — shared canvas renderer + global/player/replay pages
- `replay-viewer/` — CTF-style static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `data/` — cog sprites and art, borrowed from [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nim r tests/test_sim.nim                      # rules tests
nim c -d:release -o:bin/parley src/parley.nim
nim c -d:release -o:bin/parley-player src/parley_player.nim
# See tmp/config.json for a 4-seat fixture; run with COGAME_* env + 4 players.
# Export ANTHROPIC_API_KEY for real Sonnet play; omit for the scripted baseline.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put parley anthropic_api_key <keyfile>   # hosted Sonnet
```

## Fielding a policy

```bash
uv run coworld upload-policy <parley image> --name my-parley \
  --run /bin/parley-player \
  --secret-env PLAYER_PROMPT="Your table-talk strategy here."
```

Set `PLAYER_JEV=1` to rank bounded choices with Jev. Its argument and reaction
lines are templates, so this does not test free-form persuasion. Set
`PLAYER_SCRIPTED=1` for the no-model comparator. The game server uses the
Coworld sidecar or a direct `TYPESAFE_API_KEY` for Jev.

## Local Jev comparison

Run `nimby --global sync nimby.lock`, compile the native game and player, then
run paired episodes with approved
`TYPESAFE_API_KEY` and `ANTHROPIC_API_KEY` environment variables:

```bash
tools/nim_local.sh c -d:release -o:/tmp/parley-eval-game src/parley.nim
tools/nim_local.sh c -d:release -o:/tmp/parley-eval-player src/parley_player.nim
uv run --with httpx python tools/eval_jev.py \
  --game-binary /tmp/parley-eval-game \
  --player-binary /tmp/parley-eval-player \
  --output-dir dist/parley-eval-new --seeds 5 6 8
```

Each arm uses seat 0, four scripted opponents, one round, three survivors,
one hit point, and the same seed. The evaluator holds the TypeSafe key in a
local proxy and writes owner-only SystemOne request/response traces. These are
research data, not approved training labels.

| Seed | Scripted score | Jev score / calls | Haiku 4.5 score / calls |
| --- | ---: | ---: | ---: |
| 5 | 0.8 | 1.0 / 2 | 1.0 / 2 |
| 6 | 0.8 | 0.2 / 1 | 0.2 / 1 |
| 8 | 0.8 | 0.6 / 1 | 0.6 / 1 |

All eight model calls succeeded without fallback. Jev used 4,784 input and
253 output tokens, with 210 ms mean proxy latency. Haiku used 3,409 input and
194 output tokens, with 1,157 ms mean API latency. At
[OpenRouter's Jev 1.13 list rate](https://openrouter.ai/typesafe/jev-1.13/api),
the Jev input implies $0.000201. At
[Anthropic's Haiku 4.5 list rate](https://www.anthropic.com/news/claude-haiku-4-5),
Haiku implies $0.004379. These are price proxies, not provider invoices.
Three short seeds cannot establish a win-rate or social-intelligence gain.

The `linux/amd64` Coworld package passed ten certification checks. A separate
local Coworld container episode at seed 5 made two accepted Jev calls, produced
results and replay, and passed replay verification. Reproduce it after
`coworld build --project . --version 0.1.5` with:

```bash
uv run --with httpx python tools/container_jev_smoke.py \
  --manifest dist/coworld_manifest.json \
  --output-dir dist/parley-container-new --seed 5
```
