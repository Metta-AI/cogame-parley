# Parley

A talkative last-cog-standing party game for the Softmax Coworld platform.
Parley: negotiation before the paint flies.

Four cogs sit around a table. One is **IT** and holds the paintgun. Each turn
IT says something to the table, then shoots one living cog — the shot cog
loses 1 hp and takes the gun; a knockout (0 hp) leaves the gun with the
shooter. Between shots the other cogs plead, scheme, and bargain in
table-wide chat. Last cog standing wins.

**The game is LLM-driven and a policy is just a prompt.** Every turn the game
server sends the acting seat's policy prompt plus the full public transcript
to Claude Sonnet, which answers with what the cog says (and, for IT, who it
shoots). Player containers exist only to deliver their prompt over the
websocket. With no LLM credentials the game degrades to an always-legal
scripted baseline so episodes (and offline certification) always complete.

## Layout

- `src/parley.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/parley/sim.nim` — pure rules; shared by server, tests, and wasm viewer
- `src/parley/llm.nim` — Sonnet client + scripted fallback
- `src/parley/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/parley_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` env)
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
