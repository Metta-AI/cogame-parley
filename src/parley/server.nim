## Parley game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared table renderer
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (parley.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...}
##                   {"type":"state",...} after every event batch
##                   {"type":"final","scores":[...],"win":[...]}
##   player -> game: {"type":"prompt","prompt":"..."} (max 4000 chars)

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 2

type
  GameState = object
    config: GameConfig
    match: Match
    prompts: seq[string]
    promptSet: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.match.allEvents():
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  ## Mid-round foe points show up in the scorebug as soon as they land
  ## (match.totals itself only folds them in at round end).
  var liveTotals = gs.match.totals
  for index in 0 ..< gs.match.sim.seats.len:
    if gs.match.sim.seats[index].enemyKill:
      liveTotals[index] += 1
  return %*{
    "type": "state",
    "game": "parley",
    "seats": gs.match.sim.seatStates(liveTotals, gs.match.roundWins),
    "policyNames": gs.policyNamesJson(),
    "events": events,
    "turn": gs.match.sim.turn,
    "round": gs.match.sim.round,
    "rounds": gs.config.rounds,
    "survivors": gs.config.survivors,
    "roundsKnown": gs.config.roundsKnown,
    "survivorsKnown": gs.config.survivorsKnown,
    "maxTurns": gs.config.maxTurns,
    "hitPoints": gs.config.hitPoints,
    "started": gs.started,
    "done": gs.match.done,
    "connected": connected
  }

proc redactCards(snapshot: JsonNode, slot: int) =
  ## Cards are secret: a player sees only its own friend/enemy pair. The
  ## global viewer keeps the full deal (that is the spectator's edge).
  for index, seat in snapshot["seats"].getElems():
    if index != slot:
      seat["friend"] = %(-1)
      seat["enemy"] = %(-1)
  var visible = newJArray()
  for event in snapshot["events"]:
    if event{"kind"}.getStr() == "deal" and event{"seat"}.getInt() != slot:
      continue
    visible.add(event)
  snapshot["events"] = visible

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    var observation = gs.snapshotJson()
    observation["type"] = %"state"
    observation["slot"] = %slot
    observation.redactCards(slot)
    ## Players never learn who is behind a seat — that is the whole point of
    ## the aliases — so the policy-name map is spectator-only.
    observation.delete("policyNames")
    socket.send($observation)

proc broadcast() =
  withLock stateLock:
    state.broadcastLocked()

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for seat in gs.match.sim.seats:
    names.add(%seat.name)
  var events = newJArray()
  for event in gs.match.allEvents():
    events.add(event.eventToJson())
  $ %*{
    "protocol": "parley.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "hitPoints": gs.config.hitPoints,
      "maxTurns": gs.config.maxTurns,
      "rounds": gs.config.rounds,
      "survivors": gs.config.survivors,
      "roundsKnown": gs.config.roundsKnown,
      "survivorsKnown": gs.config.survivorsKnown,
      "sampled": true,
      "seed": gs.config.seed
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One seat-state array per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.sim.seatStates(frame.totals, frame.roundWins))

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.match.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the table aliases instead, or the
    ## last message of the match would leak the seat-to-policy mapping the
    ## aliases exist to hide.
    var aliasNames = newJArray()
    for seat in state.match.sim.seats:
      aliasNames.add(%seat.name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "win": results["win"],
      "names": aliasNames,
      "kills": results["kills"],
      "roundWins": results["roundWins"],
      "friendPoints": results["friendPoints"],
      "foePoints": results["foePoints"],
      "rounds": results["rounds"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "parley: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  sleep(500)
  echo "parley: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "parley: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform hands the container its own kill time. Play inside a
    ## fraction of it so results and the replay are written with room to
    ## spare — an episode that overruns is discarded whole, so the deadline
    ## has to be the game's problem, not the platform's.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    let timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "parley: episode timeout ", timeoutSeconds.int, "s; playing until ",
        (timeoutSeconds * PlayBudgetFraction).int, "s"

    proc matchHeader(): string =
      ## Cross-round context for the model: standings and round position.
      var standings: seq[string]
      for index, seat in state.match.sim.seats:
        standings.add(seat.name & "=" & $state.match.totals[index] &
          " (" & $state.match.roundWins[index] & " round wins)")
      "Round " & $(state.match.sim.round + 1) & " of " &
        $state.config.rounds & ". Match standings so far: " &
        standings.join(", ") & "."

    while true:
      var simCopy: Sim
      var itSeat: int
      var itPrompt: string
      var header: string
      withLock stateLock:
        if state.match.done:
          break
        simCopy = state.match.sim
        itSeat = state.match.sim.itSeat
        itPrompt = state.prompts[itSeat]
        header = matchHeader()

      ## The slow part (Sonnet) runs outside the lock on a snapshot; only
      ## this thread mutates the match, so the snapshot cannot go stale.
      let shot = client.decide(simCopy, itSeat, itPrompt, wantShot = true,
        header = header)

      var roundEnded = false
      withLock stateLock:
        state.match.sim.recordSay(itSeat, shot.say)
        try:
          if shot.skip:
            ## "It" holds fire: the gun stays put, the reaction chatter below
            ## still runs, and the same seat decides again next loop.
            state.match.sim.applySkip(itSeat)
          else:
            state.match.sim.applyShot(itSeat, shot.target)
        except ParleyError as error:
          echo "parley: llm action rejected (", error.msg, "); using fallback"
          let fallback = client.scriptedShot(state.match.sim, itSeat)
          state.match.sim.applyShot(itSeat, fallback.target)
        if state.match.sim.done:
          state.match.finishRound()
          roundEnded = true
        state.broadcastLocked()

      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

      var done = false
      withLock stateLock:
        done = state.match.done
      if done:
        break
      if roundEnded:
        ## The platform kills an episode that outruns its timeout and keeps
        ## nothing at all, so give up rounds rather than the whole result.
        ## Checked between rounds: a part-played round has no verdict to score.
        if playDeadline > 0.0 and epochTime() > playDeadline:
          withLock stateLock:
            if not state.match.done:
              echo "parley: episode deadline reached after ",
                state.match.roundsPlayed, "/", config.rounds,
                " rounds; ending the match here"
              state.match.endMatchEarly()
              state.broadcastLocked()
          break
        ## Let the round verdict land before the next deal starts talking.
        if config.turnDelayMs > 0:
          sleep(config.turnDelayMs)
        continue

      if config.reactions:
        ## Table talk between shots: the new "it" acts next turn, so let a
        ## few of the other cogs get a word in - victims first.
        var speakers: seq[int]
        withLock stateLock:
          let nextIt = state.match.sim.itSeat
          for offset in 1 ..< state.match.sim.seats.len:
            let seat = (nextIt + offset) mod state.match.sim.seats.len
            if state.match.sim.seats[seat].alive and seat != nextIt:
              speakers.add(seat)
        if speakers.len > config.maxReactions:
          speakers.setLen(config.maxReactions)
        for seat in speakers:
          var reactionCopy: Sim
          var reactionPrompt: string
          withLock stateLock:
            reactionCopy = state.match.sim
            reactionPrompt = state.prompts[seat]
            header = matchHeader()
          let reaction = client.decide(
            reactionCopy, seat, reactionPrompt, wantShot = false,
            header = header
          )
          if reaction.say.len > 0:
            withLock stateLock:
              state.match.sim.recordSay(seat, reaction.say)
              state.broadcastLocked()
          if config.turnDelayMs > 0:
            sleep(config.turnDelayMs div 2)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "parley: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "parley.player.v1",
        "slot": slot,
        "name": state.match.sim.seats[slot].name,
        "hitPoints": state.config.hitPoints,
        "rounds": (if state.config.roundsKnown: %state.config.rounds
                   else: newJNull()),
        "survivors": (if state.config.survivorsKnown: %state.config.survivors
                      else: newJNull()),
        "roundsKnown": state.config.roundsKnown,
        "survivorsKnown": state.config.survivorsKnown,
        "maxTurns": state.config.maxTurns
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.len > MaxPromptLen:
            prompt = prompt[0 ..< MaxPromptLen]
          withLock stateLock:
            state.prompts[slot] = prompt
            state.promptSet[slot] = true
          echo "parley: slot ", slot, " delivered a prompt (",
            prompt.len, " chars)"
      except CatchableError as error:
        echo "parley: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  var config = defaultGameConfig()
  config.hitPoints = payload["config"]{"hitPoints"}.getInt(3)
  config.maxTurns = payload["config"]{"maxTurns"}.getInt(60)
  config.rounds = payload["config"]{"rounds"}.getInt(1)
  config.survivors = payload["config"]{"survivors"}.getInt(1)
  config.roundsKnown = payload["config"]{"roundsKnown"}.getBool(true)
  config.survivorsKnown = payload["config"]{"survivorsKnown"}.getBool(true)
  ## The replay carries the episode's drawn table; never re-roll it.
  config.sampled = true
  for name in payload["names"]:
    config.players.add(PlayerConfig(name: name.getStr()))
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("parley.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "parley: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(ParleyError, "tokens and players must align")
  state.config = config
  state.match = initMatch(config)
  state.prompts = newSeq[string](config.players.len)
  state.promptSet = newSeq[bool](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "parley: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
