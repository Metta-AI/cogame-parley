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
## Player protocol (parley.player.v2), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...}
##                   {"type":"state",...} after every event batch
##                   {"type":"final","scores":[...],"win":[...]}
##   player -> game: {"type":"prompt","prompt":"..."} (max 4000 chars)
##   player -> game: {"type":"register","control":"external","prompt":"..."}
##   game -> external player: {"type":"observation","id":N,
##                   "observation":<seat-private state>,"phase":"shot"|"reaction",
##                   "input":{"system":...,"user":...},"legalActions":[...]}
##   external player -> game: {"type":"action","id":N,"action":{...}}

import
  std/[json, locks, options, os, oids, sets, strutils, tables, times],
  bitworld/decision_trajectory,
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 3
  ParleySourceRevision {.strdefine.} = ""
  ParleyGameVersion {.strdefine.} = ""

type
  GameState = object
    config: GameConfig
    match: Match
    prompts: seq[string]
    external: seq[bool]
    scripted: seq[bool]
    promptSet: seq[bool]
    nextDecisionId: int
    awaitingSeat: int
    awaitingId: int
    awaitingShot: bool
    pendingDecision: Decision
    pendingRawAction: JsonNode
    pendingRejected: seq[JsonNode]
    pendingAttempts: seq[DecisionAttempt]
    hasPendingDecision: bool
    decisionRefs: seq[JsonNode]
    trajectory: Option[DecisionTrajectory]
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
  var liveTotals = newSeq[float](gs.config.players.len)
  for event in gs.match.allEvents():
    if event.kind == evScore:
      liveTotals[event.seat] += float(event.points)
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
    "hitPoints": gs.config.hitPoints,
    "started": gs.started,
    "done": gs.match.done,
    "connected": connected
  }

proc liveFrameJson(gs: GameState, slot = -1): JsonNode =
  ## The spectator socket is reachable by players, so it gets the public view.
  result = gs.snapshotJson()
  result["slot"] = %slot
  result.redactSecrets(slot)
  result.delete("policyNames")
  if not gs.config.roundsKnown:
    result["rounds"] = newJNull()
  if not gs.config.survivorsKnown:
    result["survivors"] = newJNull()

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock.
  let payload = $gs.liveFrameJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.liveFrameJson(slot))

proc externalObservation(gs: GameState, sim: Sim, seat: int, prompt: string,
    wantShot: bool, header: string, id: int): JsonNode =
  var legalActions = newJArray()
  if wantShot:
    if sim.skipsLeft() > 0:
      legalActions.add(%*{"shoot": "pass"})
    for target in sim.validTargets(seat):
      for aim in ["head", "hip"]:
        legalActions.add(%*{"shoot": sim.seats[target].name, "aim": aim})
  %*{
    "type": "observation", "id": id,
    "phase": (if wantShot: "shot" else: "reaction"),
    "observation": gs.liveFrameJson(seat),
    "input": {"system": systemPrompt(sim, seat),
              "user": userPrompt(sim, seat, prompt, wantShot, header)},
    "legalActions": legalActions}

proc registerExternal(gs: var GameState, slot: int, prompt: string) =
  if prompt.len > MaxPromptLen:
    raise newException(ParleyError, "external operator prompt exceeds limit")
  gs.prompts[slot] = prompt
  gs.external[slot] = true
  gs.promptSet[slot] = true

proc decideSeat(client: LlmClient, sim: Sim, seat: int, prompt: string,
    wantShot: bool, header: string, scripted: bool, playDeadline: float): DecisionResult =
  ## Finish the current round without more model/player waits after the play budget.
  if playDeadline > 0.0 and epochTime() >= playDeadline:
    result.decision =
      if wantShot: client.scriptedShot(sim, seat)
      else: client.scriptedReaction(sim, seat)
    result.origin = "scripted_after_deadline"
    result.input = newJNull()
    result.response = newJNull()
    return
  var external = false
  var registeredExternal = false
  var observation: JsonNode
  withLock stateLock:
    registeredExternal = state.external[seat]
    external = registeredExternal and state.playerSockets.hasKey(seat)
    if external:
      inc state.nextDecisionId
      state.awaitingSeat = seat
      state.awaitingId = state.nextDecisionId
      state.awaitingShot = wantShot
      state.hasPendingDecision = false
      state.pendingRejected = @[]
      state.pendingAttempts = @[]
      observation = state.externalObservation(sim, seat, prompt, wantShot,
        header, state.awaitingId)
      state.playerSockets[seat].send($observation)
  if not external:
    if registeredExternal:
      result.decision =
        if wantShot: client.scriptedShot(sim, seat)
        else: client.scriptedReaction(sim, seat)
      result.origin = "scripted_after_external_disconnect"
      result.input = newJNull()
      result.response = newJNull()
      return
    if scripted:
      result.decision =
        if wantShot: client.scriptedShot(sim, seat)
        else: client.scriptedReaction(sim, seat)
      result.origin = "scripted_policy"
      result.input = newJNull()
      result.response = newJNull()
      return
    return client.decide(sim, seat, prompt, wantShot, header)
  let deadline = epochTime() + state.config.llmTimeoutSeconds.float
  while epochTime() < deadline:
    var ready = false
    withLock stateLock:
      ready = state.hasPendingDecision
    if ready:
      break
    sleep(20)
  withLock stateLock:
    state.awaitingSeat = -1
    if state.hasPendingDecision:
      return DecisionResult(decision: state.pendingDecision,
        origin: "external", input: %*{
          "packet": observation, "wire": $observation},
        response: state.pendingRawAction,
        attempts: state.pendingRejected, nativeAttempts: state.pendingAttempts)
  result.decision =
    if wantShot: client.scriptedShot(sim, seat)
    else: client.scriptedReaction(sim, seat)
  result.origin = "scripted_after_external_timeout"
  result.input = %*{"packet": observation, "wire": $observation}
  result.response = newJNull()
  result.attempts = state.pendingRejected
  result.nativeAttempts = state.pendingAttempts

proc recordDecision(gs: var GameState, sim: Sim, seat: int,
    wantShot: bool, outcome: DecisionResult, beforeEvent: int,
    accepted: bool, observation: JsonNode) =
  let action = decisionAction(sim, outcome.decision, wantShot)
  let reference = %*{
    "id": gs.decisionRefs.len + 1,
    "seat": seat,
    "phase": (if wantShot: "shot" else: "reaction"),
    "origin": outcome.origin,
    "accepted": accepted,
    "eventBefore": beforeEvent,
    "eventAfter": gs.match.allEvents().len,
    "action": action
  }
  gs.decisionRefs.add(reference)
  if gs.trajectory.isSome:
    var attempts = outcome.nativeAttempts
    var selected = none(string)
    let proposalAccepted = accepted and outcome.origin in ["model", "external"]
    if proposalAccepted and outcome.origin == "external":
      if attempts.len == 0 or attempts[^1].rejectionReason.isSome:
        var external = newDecisionAttempt("external-action", "external", aoUnknown)
        external.prompt = outcome.input
        external.response = outcome.response
        external.rawResponse = outcome.response
        attempts.add(external)
      attempts[^1].parsedAction = action
      attempts[^1].accepted = true
    if proposalAccepted:
      selected = some(attempts[^1].attemptId)
    elif attempts.len > 0 and attempts[^1].accepted:
      attempts[^1].accepted = false
      attempts[^1].rejectionReason = some("engine rejected proposal")
    gs.trajectory.get().recordDecision($reference["id"].getInt(), $seat,
      observation, attempts, selected, action,
      (if proposalAccepted: asAccepted else: asFallback),
      fallbackOrigin = (if proposalAccepted: none(string) else: some(outcome.origin)))

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
      "rounds": results["rounds"],
      "plannedRounds": gs.config.rounds,
      "survivors": gs.config.survivors,
      "roundsKnown": gs.config.roundsKnown,
      "survivorsKnown": gs.config.survivorsKnown,
      "reactions": gs.config.reactions,
      "maxReactions": gs.config.maxReactions,
      "maxSkips": gs.config.maxSkips,
      "sampled": true,
      "seed": gs.config.seed
    },
    "events": events,
    "decisionRefs": gs.decisionRefs,
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
      "rawScores": results["rawScores"],
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
  if state.trajectory.isSome:
    let trajectory = state.trajectory.get()
    trajectory.finish(
      (if state.match.roundsPlayed == state.match.config.rounds: esCompleted else: esTruncated),
      results, results["scores"])
    trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
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

    ## The platform kills the episode at its wall clock and keeps NOTHING of
    ## one that overruns, so the deadline has to be the game's problem. The
    ## platform does not tell the game container that clock (it only sets
    ## COWORLD_TIMEOUT_SECONDS on its own worker), so the config carries it;
    ## the env still wins whenever it is present.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    let timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: config.episodeTimeoutSeconds
      else: config.episodeTimeoutSeconds
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "parley: episode timeout ", timeoutSeconds.int, "s; playing until ",
        (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var itSeat: int
      var itPrompt: string
      var itScripted: bool
      var header: string
      var shotObservation: JsonNode
      withLock stateLock:
        if state.match.done:
          break
        simCopy = state.match.decisionSim()
        itSeat = state.match.sim.itSeat
        itPrompt = state.prompts[itSeat]
        itScripted = state.scripted[itSeat]
        header = state.match.matchHeader()
        shotObservation = state.liveFrameJson(itSeat)

      ## The slow part (Sonnet) runs outside the lock on a snapshot; only
      ## this thread mutates the match, so the snapshot cannot go stale.
      var shot = client.decideSeat(simCopy, itSeat, itPrompt,
        wantShot = true, header = header, scripted = itScripted, playDeadline = playDeadline)

      var roundEnded = false
      withLock stateLock:
        let beforeEvent = state.match.allEvents().len
        state.match.sim.recordSay(itSeat, shot.decision.say)
        var accepted = true
        try:
          if shot.decision.skip:
            ## "It" holds fire: the gun stays put, the reaction chatter below
            ## still runs, and the same seat decides again next loop.
            state.match.sim.applySkip(itSeat)
          else:
            state.match.sim.applyShot(itSeat, shot.decision.target, shot.decision.aim)
        except ParleyError as error:
          echo "parley: llm action rejected (", error.msg, "); using fallback"
          let fallback = client.scriptedShot(state.match.sim, itSeat)
          state.match.sim.applyShot(itSeat, fallback.target, fallback.aim)
          shot.decision = fallback
          shot.origin = "scripted_after_rejected_action"
          accepted = false
        state.recordDecision(simCopy, itSeat, true, shot, beforeEvent, accepted, shotObservation)
        roundEnded = state.match.sim.done
        state.broadcastLocked()

      if config.turnDelayMs > 0 and
          (playDeadline == 0.0 or epochTime() < playDeadline):
        sleep(config.turnDelayMs)

      if roundEnded:
        ## Let the last shot land before deciding whether to deal another round.
        ## This includes deadlines reached during spectator pacing.
        withLock stateLock:
          let timedOut = playDeadline > 0.0 and epochTime() >= playDeadline
          state.match.finishRound(endMatch = timedOut)
          if timedOut:
            echo "parley: episode deadline reached after ",
              state.match.roundsPlayed, "/", config.rounds, " rounds"
          state.broadcastLocked()
        continue

      if config.reactions and (playDeadline == 0.0 or epochTime() < playDeadline):
        ## Table talk between shots: the new "it" acts next turn, so let a
        ## few of the other living cogs speak, in seat order after the new IT.
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
          if playDeadline > 0.0 and epochTime() >= playDeadline:
            break
          var reactionCopy: Sim
          var reactionPrompt: string
          var reactionScripted: bool
          var reactionObservation: JsonNode
          withLock stateLock:
            reactionCopy = state.match.decisionSim()
            reactionPrompt = state.prompts[seat]
            reactionScripted = state.scripted[seat]
            header = state.match.matchHeader()
            reactionObservation = state.liveFrameJson(seat)
          let reaction = client.decideSeat(reactionCopy, seat, reactionPrompt,
            wantShot = false, header = header, scripted = reactionScripted, playDeadline = playDeadline)
          withLock stateLock:
            let beforeEvent = state.match.allEvents().len
            if reaction.decision.say.len > 0:
              state.match.sim.recordSay(seat, reaction.decision.say)
              state.broadcastLocked()
            state.recordDecision(reactionCopy, seat, false, reaction, beforeEvent, true, reactionObservation)
          if config.turnDelayMs > 0 and
              (playDeadline == 0.0 or epochTime() < playDeadline):
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
        "protocol": "parley.player.v2",
        "slot": slot,
        "name": state.match.sim.seats[slot].name,
        "hitPoints": state.config.hitPoints,
        "rounds": (if state.config.roundsKnown: %state.config.rounds
                   else: newJNull()),
        "survivors": (if state.config.survivorsKnown: %state.config.survivors
                      else: newJNull()),
        "roundsKnown": state.config.roundsKnown,
        "survivorsKnown": state.config.survivorsKnown
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.liveFrameJson())

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
        if payload{"type"}.getStr() == "register":
          if payload["control"].getStr() != "external":
            raise newException(ParleyError, "unknown player control")
          withLock stateLock:
            state.registerExternal(slot, payload{"prompt"}.getStr())
          return
        if payload{"type"}.getStr() == "action":
          withLock stateLock:
            if state.external[slot] and state.awaitingSeat == slot and
                state.awaitingId == payload["id"].getInt() and
                not state.hasPendingDecision:
              if payload.hasKey("attempts"):
                for evidence in payload["attempts"]:
                  state.pendingAttempts.add(readAttemptEvidence(evidence))
              state.pendingDecision = parseDecision(state.match.sim, slot,
                payload["action"], state.awaitingShot)
              state.pendingRawAction = %*{
                "wire": message.data, "action": payload["action"]}
              state.hasPendingDecision = true
          return
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          let scripted = payload{"scripted"}.getBool()
          if prompt.len > MaxPromptLen:
            prompt = prompt[0 ..< MaxPromptLen]
          withLock stateLock:
            state.prompts[slot] = prompt
            state.external[slot] = false
            state.scripted[slot] = scripted
            state.promptSet[slot] = true
          echo "parley: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted: ", scripted" else: ""), ")"
      except CatchableError as error:
        withLock stateLock:
          if state.awaitingSeat == slot:
            state.pendingRejected.add(%*{
              "wire": message.data, "error": error.msg})
            if state.pendingAttempts.len == 0 or state.pendingAttempts[^1].rejectionReason.isSome:
              var rejected = newDecisionAttempt("external-rejected-" & $state.pendingRejected.len,
                "external", aoUnknown)
              rejected.response = %message.data
              rejected.rejectionReason = some(error.msg)
              state.pendingAttempts.add(rejected)
            else:
              state.pendingAttempts[^1].accepted = false
              state.pendingAttempts[^1].rejectionReason = some(error.msg)
        echo "parley: rejected player frame for seat ", slot
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
  state.external = newSeq[bool](config.players.len)
  state.awaitingSeat = -1
  state.scripted = newSeq[bool](config.players.len)
  state.promptSet = newSeq[bool](config.players.len)
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    let metadata = getEnv("LLM_REQUEST_METADATA")
    let episodeId = if metadata.len > 0:
        parseJson(metadata)["episode_request_id"].getStr()
      else:
        "local-" & $genOid()
    state.trajectory = some(newDecisionTrajectory(episodeId,
      $config.seed, "parley", ParleyGameVersion, ParleySourceRevision))
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "parley: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
