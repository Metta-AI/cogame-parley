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
## Player protocol (parley.player.v3), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...}
##                   {"type":"state",...} after every event batch
##                   {"type":"final","scores":[...],"win":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":bool,
##                    "baseline":"random|finisher|retaliator|protector|hoarder"}
##                   (prompt max 4000 chars; baseline defaults to random)
##   player -> game: {"type":"register","control":"external","prompt":"..."}
##   game -> external player: decision {decision_id, observation, transport}
##     observation.extras lists the optional whisper/reveal/give/pledge
##     side actions the seat may attach to its action
##   player -> game: attempt_started/action {decision_id, training_attempt}
##   game -> external player: stop {decision_id, reason, cleanup_budget_ms}
##   player -> game: stopped {decision_id, worker_status, attempts}
##   Acceptance and engine actions are never player-owned evidence.

import
  std/[base64, json, locks, math, monotimes, options, os, oids, sets, strutils, sysrand, tables, times],
  bitworld/decision_trajectory,
  bitworld/runtime,
  bitworld/native_stop,
  bitworld/artifact_runtime,
  webby/httpheaders,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  MaxPlayerMessageLen = 16 * 1024 * 1024
  ReplayVersion = 4
  ParleySourceRevision {.strdefine.} = ""
  ParleyGameVersion {.strdefine.} = ""

type
  StagedDecision = object
    id, seat: string
    observation, action: JsonNode
    attempts: seq[DecisionAttempt]
    selected: Option[string]
    status: ActionStatus
    fallback: Option[string]
  GameState = object
    config: GameConfig
    inputConfig: JsonNode
    match: Match
    prompts: seq[string]
    external: seq[bool]
    scripted: seq[bool]
    baselines: seq[Baseline]
    promptSet: seq[bool]
    awaitingSeat: int
    awaitingId: string
    issuedWindows: Table[string, JsonNode]
    issuedSeats: Table[string, int]
    issuedAt: Table[string, MonoTime]
    latestDecisions: Table[int, string]
    startedAttempts, completedAttempts: Table[string, JsonNode]
    stoppedSlots: HashSet[int]
    staged: seq[StagedDecision]
    stopping: bool
    stopId: string
    pendingSource: string
    awaitingShot: bool
    pendingDecision: Decision
    pendingRawAction: JsonNode
    pendingRejected: seq[JsonNode]
    pendingAttempts: seq[DecisionAttempt]
    hasPendingDecision: bool
    awaitingDeadline, pendingReceived, stopAckStart, stopAckDeadline: MonoTime
    episodeStart, episodeDeadline: MonoTime
    episodeTimeoutSeconds: float
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
  ## Mid-round gifts and pledge payments show up in the scorebug as soon as
  ## they land (match.totals itself only folds them in at round end).
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
    wantShot: bool, header: string): JsonNode =
  var legalActions = newJArray()
  if wantShot:
    if sim.skipsLeft() > 0:
      legalActions.add(%*{"shoot": "pass"})
    for target in sim.validTargets(seat):
      for aim in ["head", "hip"]:
        legalActions.add(%*{"shoot": sim.seats[target].name, "aim": aim})
  ## Side actions combine freely with any legal action, so they are offered
  ## as allowances rather than multiplied into `legalActions`.
  let me = sim.seats[seat]
  var others = newJArray()
  var living = newJArray()
  for index, other in sim.seats:
    if index == seat: continue
    others.add(%other.name)
    if other.alive and me.alive and index notin me.pledges:
      living.add(%other.name)
  %*{
    "phase": (if wantShot: "shot" else: "reaction"),
    "observation": gs.liveFrameJson(seat),
    "input": {"system": systemPrompt(sim, seat),
              "user": userPrompt(sim, seat, prompt, wantShot, header)},
    "legalActions": legalActions,
    "extras": {
      "whisper": {"to": (if me.whispers < MaxWhispers: others else: newJArray()),
                  "left": MaxWhispers - me.whispers},
      "reveal": {"to": (if me.friend >= 0 and not me.revealed: others else: newJArray()),
                 "cards": ["friend", "enemy"]},
      "give": {"to": (if sim.banked[seat] + sim.transfers[seat] >= 1: others else: newJArray()),
               "banked": sim.banked[seat] + sim.transfers[seat]},
      "pledge": {"to": living}}}

proc registerExternal(gs: var GameState, slot: int, prompt: string) =
  if gs.started or gs.stopping or gs.finished:
    raise newException(ParleyError, "player control is frozen after gameplay begins")
  if prompt.len > MaxPromptLen:
    raise newException(ParleyError, "external operator prompt exceeds limit")
  gs.prompts[slot] = prompt
  gs.external[slot] = true
  gs.promptSet[slot] = true

proc decideSeat(client: LlmClient, sim: Sim, seat: int, prompt: string,
    wantShot: bool, header: string, scripted: bool, baseline: Baseline,
    playDeadline: MonoTime): DecisionResult =
  ## Finish the current round without more model/player waits after the play budget.
  if getMonoTime() >= playDeadline:
    result.decision =
      if wantShot: client.scriptedShot(sim, seat)
      else: client.scriptedReaction(sim, seat)
    result.origin = "scripted_after_deadline"
    result.input = newJNull()
    result.response = newJNull()
    return
  let decisionDeadline = min(playDeadline, getMonoTime() + initDuration(seconds = state.config.llmTimeoutSeconds))
  var external = false
  var registeredExternal = false
  var observation: JsonNode
  withLock stateLock:
    registeredExternal = state.external[seat]
    external = registeredExternal and state.playerSockets.hasKey(seat)
    if external:
      state.awaitingSeat = seat
      state.awaitingId = $(state.decisionRefs.len + 1)
      state.awaitingShot = wantShot
      state.awaitingDeadline = decisionDeadline
      state.hasPendingDecision = false
      state.pendingRejected = @[]
      state.pendingAttempts = @[]
      observation = state.externalObservation(sim, seat, prompt, wantShot, header)
      state.issuedWindows[state.awaitingId] = observation
      state.issuedSeats[state.awaitingId] = seat
      state.issuedAt[state.awaitingId] = getMonoTime()
      state.latestDecisions[seat] = state.awaitingId
      state.playerSockets[seat].send($(%*{"type": "decision", "decision_id": state.awaitingId,
        "observation": observation, "transport": {
          "budget_ms": max(1, (decisionDeadline - getMonoTime()).inMilliseconds),
          "cleanup_budget_ms": 5000}}))
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
        if wantShot: client.scriptedShot(sim, seat, baseline)
        else: client.scriptedReaction(sim, seat)
      result.origin = "scripted_policy"
      result.input = newJNull()
      result.response = newJNull()
      return
    return client.decide(sim, seat, prompt, wantShot, decisionDeadline, header)
  while getMonoTime() < decisionDeadline and not interruptionRequested():
    var ready = false
    withLock stateLock:
      ready = state.hasPendingDecision
    if ready:
      break
    sleep(20)
  withLock stateLock:
    state.awaitingSeat = -1
    if state.hasPendingDecision and state.pendingReceived < decisionDeadline and not interruptionRequested():
      return DecisionResult(decision: state.pendingDecision,
        origin: (if state.pendingSource == "fallback": "scripted_external_fallback" else: "external"), input: %*{
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

proc retainExternalAttempt(gs: var GameState, seat: int, id: string,
    evidence: JsonNode, completed: bool) =
  if not gs.issuedSeats.hasKey(id) or gs.issuedSeats[id] != seat:
    raise newException(ParleyError, "attempt does not belong to authenticated issued seat")
  if not completed and not gs.startedAttempts.hasKey(id):
    for key in ["response", "raw_response", "platform_call_id", "provider_request_id",
        "response_headers", "response_headers_b64", "response_body_b64", "response_complete",
        "response_reader_joined", "http_status", "latency_ms", "input_tokens", "output_tokens",
        "prompt_token_ids", "sampled_token_ids", "behavior_logprobs", "stop_reason",
        "model_identity", "tokenizer_identity", "chat_template_sha256", "rejection_reason"]:
      if evidence[key].kind != JNull:
        raise newException(ParleyError, "initial attempt start already contains response facts")
  let attempt = readAttemptEvidence(evidence)
  if attempt.attemptId != id & "-model" or attempt.origin != aoModel:
    raise newException(ParleyError, "external attempt must identify its issued model call")
  let input = gs.issuedWindows[id]["input"]
  let prompt = %*[{"role": "system", "content": input["system"]},
    {"role": "user", "content": input["user"]}]
  if attempt.prompt != prompt or attempt.request.kind != JObject or
      attempt.request["messages"] != prompt:
    raise newException(ParleyError, "model call rewrites the exact private prompt")
  if completed and not gs.startedAttempts.hasKey(id):
    raise newException(ParleyError, "completed model evidence lacks pre-request start")
  if gs.startedAttempts.hasKey(id):
    if (gs.startedAttempts[id]["latency_ms"].kind != JNull or
        gs.startedAttempts[id]["response_reader_joined"] == %true) and evidence != gs.startedAttempts[id]:
      raise newException(ParleyError, "finished native attempt evidence is immutable")
    for key in ["prompt", "request", "decoder", "policy", "model"]:
      if evidence[key] != gs.startedAttempts[id][key]:
        raise newException(ParleyError, "started model request evidence is immutable")
    let before = gs.startedAttempts[id]
    for key in ["response_body_b64", "response_headers_b64"]:
      if before[key].kind != JNull:
        if evidence[key].kind != JString or
            not decode(evidence[key].getStr()).startsWith(decode(before[key].getStr())):
          raise newException(ParleyError, "received native bytes cannot be rewritten")
    if before["response_complete"] == %true and
        (evidence["response_complete"] != %true or evidence["response_body_b64"] != before["response_body_b64"] or
          evidence["response_headers_b64"] != before["response_headers_b64"]):
      raise newException(ParleyError, "complete native response cannot be rewritten")
    for key in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
        "model_identity", "tokenizer_identity", "chat_template_sha256"]:
      if before[key].kind != JNull and evidence[key] != before[key]:
        raise newException(ParleyError, "received native identity cannot be rewritten")
  if gs.completedAttempts.hasKey(id) and evidence != gs.completedAttempts[id]:
    raise newException(ParleyError, "completed native evidence is immutable")
  gs.startedAttempts[id] = copy(evidence)
  if completed: gs.completedAttempts[id] = copy(evidence)
  if gs.awaitingSeat == seat and gs.awaitingId == id:
    gs.pendingAttempts = @[attempt]

proc acceptExternalAction(gs: var GameState, seat: int, payload: JsonNode,
    wire: string, receivedAt: MonoTime) =
  let source = payload["source"].getStr()
  if source notin ["llm", "fallback", "scripted"]:
    raise newException(ParleyError, "unknown external action source")
  let id = payload["decision_id"].getStr()
  let evidence = payload["training_attempt"]
  if evidence.kind != JNull:
    if source == "scripted":
      raise newException(ParleyError, "scripted action cannot assert model evidence")
    gs.retainExternalAttempt(seat, id, evidence, completed = true)
  elif source == "llm":
    raise newException(ParleyError, "model action requires native attempt evidence")
  let proposal = parseDecision(gs.match.sim, seat, payload["action"], gs.awaitingShot)
  let canonical = decisionAction(gs.match.sim, proposal, gs.awaitingShot)
  if source == "llm":
    var attempt = readAttemptEvidence(evidence)
    if attempt.response.kind != JString or attempt.rawResponse.kind != JString or
        attempt.responseComplete != some(true) or attempt.responseReaderJoined != some(true) or
        attempt.httpStatus != some(200) or
        attempt.rejectionReason.isSome:
      raise newException(ParleyError, "model action requires its complete successful native response")
    let served = parseJson(attempt.rawResponse.getStr())
    if attempt.model.isNone or served["model"] != %attempt.model.get() or
        served["choices"][0]["message"]["content"] != attempt.response:
      raise newException(ParleyError, "selected completion differs from actual received native body")
    let generated = parseDecision(gs.match.sim, seat,
      parseJsonObject(attempt.response.getStr()), gs.awaitingShot)
    attempt.parsedAction = decisionAction(gs.match.sim, generated, gs.awaitingShot)
    if attempt.parsedAction != canonical:
      raise newException(ParleyError, "model response differs from submitted action")
    gs.pendingAttempts = @[attempt]
  gs.pendingDecision = proposal
  gs.pendingSource = source
  gs.pendingRawAction = %*{"wire": wire, "action": payload["action"]}
  gs.pendingReceived = receivedAt
  gs.hasPendingDecision = true

proc recordDecision(gs: var GameState, sim: Sim, seat: int,
    wantShot: bool, outcome: DecisionResult, beforeEvent: int,
    accepted: bool, observation: JsonNode) =
  let action = appliedDecisionAction(sim, gs.match.allEvents(), beforeEvent, seat, wantShot)
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
        attempts.add(external)
      if attempts[^1].origin != aoModel:
        attempts[^1].parsedAction = decisionAction(sim, outcome.decision, wantShot)
      attempts[^1].accepted = true
    if proposalAccepted:
      selected = some(attempts[^1].attemptId)
    elif attempts.len > 0 and attempts[^1].accepted:
      attempts[^1].accepted = false
      attempts[^1].rejectionReason = some("engine rejected proposal")
    gs.staged.add(StagedDecision(id: $reference["id"].getInt(), seat: $seat,
      observation: observation, attempts: attempts, selected: selected, action: action,
      status: (if proposalAccepted: asAccepted else: asFallback),
      fallback: (if proposalAccepted: none(string) else: some(outcome.origin))))


proc recordInterruptedDecision(gs: var GameState, seat: int,
    outcome: DecisionResult, observation: JsonNode) =
  ## No interrupted proposal is applied; keep every started/received attempt.
  if gs.trajectory.isSome:
    var attempts = outcome.nativeAttempts
    for attempt in attempts.mitems:
      attempt.accepted = false
      if attempt.rejectionReason.isNone:
        attempt.rejectionReason = some("interrupted before engine acceptance")
    gs.staged.add(StagedDecision(id: $(gs.decisionRefs.len + 1), seat: $seat,
      observation: observation, attempts: attempts, selected: none(string),
      action: newJNull(), status: asMissing))

proc broadcast() =
  withLock stateLock:
    state.broadcastLocked()

proc writeArtifact(uri, data, contentType, methodEnv: string, cleanupDeadline: MonoTime) =
  if uri.len == 0:
    return
  let httpMethod = parseEnum[ArtifactHttpMethod](getEnv(methodEnv, "PUT").toUpperAscii())
  writeCogameArtifact(uri, data, contentType, methodEnv, cleanupDeadline, httpMethod)

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

proc waitUntil(deadline: MonoTime) =
  ## Spectator and connection waits share the original lifetime and stop signal.
  while getMonoTime() < deadline and not interruptionRequested():
    sleep(int(min(20'i64, max(1'i64, (deadline - getMonoTime()).inMilliseconds))))

proc finishEpisode(runtimeConfig: RuntimeConfig, status: EpisodeStatus) =
  let cleanupDeadline = min(state.episodeDeadline, getMonoTime() + initDuration(seconds = 10))
  var targets: seq[int]
  withLock stateLock:
    if state.finished: return
    state.stopping = true
    var stopToken: array[16, byte]
    doAssert urandom(stopToken), "OS entropy unavailable for stop identity"
    for value in stopToken: state.stopId.add(value.toHex(2))
    state.stopAckStart = getMonoTime()
    state.stopAckDeadline = cleanupDeadline - initDuration(seconds = 1)
    for slot in 0 ..< state.external.len:
      if not state.external[slot]: continue
      targets.add(slot)
      if state.playerSockets.hasKey(slot):
        let id = if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()
        state.playerSockets[slot].send($(%*{"type": "stop", "stop_id": state.stopId, "decision_id": id,
          "reason": (if interruptionRequested(): "interrupted" elif status == esCompleted: "terminal" else: "episode_deadline"),
          "cleanup_budget_ms": max(0, (state.stopAckDeadline - getMonoTime()).inMilliseconds)}))
  let ackDeadline = cleanupDeadline - initDuration(seconds = 1)
  while getMonoTime() < ackDeadline:
    var acknowledged = true
    withLock stateLock:
      for slot in targets:
        if slot notin state.stoppedSlots: acknowledged = false
    if acknowledged: break
    sleep(10)
  var unresolved = false
  var cleanup = newJObject()
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    for slot in targets:
      let joined = slot in state.stoppedSlots
      cleanup[$slot] = %(if joined: "acknowledged" else: "unresolved")
      if not joined: unresolved = true
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
    if status != esFailed and not interruptionRequested() and not unresolved:
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

  if not interruptionRequested():
    waitUntil(min(cleanupDeadline, getMonoTime() + initDuration(milliseconds = 500)))
  echo "parley: writing private episode evidence"
  if state.trajectory.isSome:
    let trajectory = state.trajectory.get()
    withLock stateLock:
      for staged in state.staged:
        var attempts = staged.attempts
        if staged.selected.isNone:
          var late = newJNull()
          if state.completedAttempts.hasKey(staged.id): late = state.completedAttempts[staged.id]
          elif state.startedAttempts.hasKey(staged.id): late = state.startedAttempts[staged.id]
          if late.kind == JObject:
            var received = readAttemptEvidence(late)
            if attempts.len > 0:
              received.accepted = attempts[0].accepted
              received.parsedAction = attempts[0].parsedAction
              received.rejectionReason = attempts[0].rejectionReason
            else:
              received.rejectionReason = some("native evidence arrived after engine decision")
            attempts = @[received]
        trajectory.recordDecision(staged.id, staged.seat, staged.observation,
          attempts, staged.selected, staged.action, staged.status, fallbackOrigin = staged.fallback)
    if interruptionRequested() or status == esFailed or unresolved:
      trajectory.finish((if interruptionRequested() or unresolved: esTruncated else: esFailed),
        %*{"protocol": "parley.native-outcome.v1", "player_cleanup": cleanup,
          "termination": (if interruptionRequested(): "interrupted" elif unresolved: "unresolved-player-cleanup" else: "runtime-failure"),
          "partial_results": results, "input_config": state.inputConfig,
          "selected_seed": state.config.seed}, newJNull())
    else:
      trajectory.finish(
        status,
        %*{"protocol": "parley.native-outcome.v1", "results": results,
           "player_cleanup": cleanup, "input_config": state.inputConfig, "selected_seed": state.config.seed},
        results["scores"])
    writeTrajectoryArtifact(trajectory, getEnv(CogameSaveTrajectoryUriEnv), cleanupDeadline,
      parseEnum[ArtifactHttpMethod](getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()))
  if status != esFailed and not interruptionRequested() and not unresolved:
    writeArtifact(
      runtimeConfig.resultsUri, $results, "application/json",
      "COGAME_RESULTS_METHOD", cleanupDeadline
    )
    writeArtifact(
      runtimeConfig.replayUri, replayData, "application/octet-stream",
      "COGAME_SAVE_REPLAY_METHOD", cleanupDeadline
    )
    waitUntil(min(cleanupDeadline, getMonoTime() + initDuration(milliseconds = 500)))
    echo "parley: episode complete, shutting down"
  gameServer.close()

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    defer:
      if not state.finished:
        finishEpisode(runtimeConfig, esFailed)
    let config = state.config
    let gameStart = state.episodeStart
    let timeoutSeconds = state.episodeTimeoutSeconds
    let playDeadline = gameStart + initDuration(nanoseconds = int64(timeoutSeconds * PlayBudgetFraction * 1_000_000_000))
    let deadline = min(playDeadline, gameStart + initDuration(nanoseconds = int64(config.playerConnectTimeoutSeconds * 1_000_000_000)))

    while getMonoTime() < deadline and not interruptionRequested():
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
        for registered in state.promptSet:
          allConnected = allConnected and registered
      if allConnected:
        break
      waitUntil(min(deadline, getMonoTime() + initDuration(milliseconds = 200)))

    withLock stateLock:
      state.started = true
      echo "parley: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    echo "parley: episode timeout ", timeoutSeconds.int, "s; playing until ",
      (timeoutSeconds * PlayBudgetFraction).int, "s"
    ## Rounds are dealt only while the longest round so far would still fit,
    ## so a match ends between rounds rather than finishing one on fallbacks.
    var roundStartedAt = getMonoTime()
    var longestRound = initDuration()

    while not interruptionRequested():
      var simCopy: Sim
      var itSeat: int
      var itPrompt: string
      var itScripted: bool
      var itBaseline: Baseline
      var header: string
      var shotObservation: JsonNode
      withLock stateLock:
        if state.match.done:
          break
        simCopy = state.match.decisionSim()
        itSeat = state.match.sim.itSeat
        itPrompt = state.prompts[itSeat]
        itScripted = state.scripted[itSeat]
        itBaseline = state.baselines[itSeat]
        header = state.match.matchHeader()
        shotObservation = state.liveFrameJson(itSeat)

      ## The slow part (Sonnet) runs outside the lock on a snapshot; only
      ## this thread mutates the match, so the snapshot cannot go stale.
      var shot = client.decideSeat(simCopy, itSeat, itPrompt,
        wantShot = true, header = header, scripted = itScripted, baseline = itBaseline,
        playDeadline = playDeadline)

      if interruptionRequested():
        withLock stateLock:
          state.recordInterruptedDecision(itSeat, shot, shotObservation)
        break

      var roundEnded = false
      withLock stateLock:
        let beforeEvent = state.match.allEvents().len
        state.match.sim.recordSay(itSeat, shot.decision.say)
        var accepted = true
        try:
          state.match.sim.applyExtras(itSeat, shot.decision.extras)
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
          getMonoTime() < playDeadline:
        waitUntil(min(playDeadline, getMonoTime() + initDuration(milliseconds = config.turnDelayMs)))

      if roundEnded:
        ## Let the last shot land before deciding whether to deal another round.
        ## This includes deadlines reached during spectator pacing.
        let roundEndedAt = getMonoTime()
        longestRound = max(longestRound, roundEndedAt - roundStartedAt)
        roundStartedAt = roundEndedAt
        withLock stateLock:
          let timedOut = roundEndedAt + longestRound >= playDeadline
          state.match.finishRound(endMatch = timedOut)
          if timedOut and state.match.roundsPlayed < config.rounds:
            echo "parley: episode deadline reached after ",
              state.match.roundsPlayed, "/", config.rounds, " rounds"
          state.broadcastLocked()
        continue

      if config.reactions and getMonoTime() < playDeadline:
        ## Table talk between shots: the new "it" acts next turn, so a few
        ## other cogs speak first, eliminated ones included, in seeded order.
        var speakers: seq[int]
        withLock stateLock:
          speakers = state.match.sim.reactionSpeakers()
        for seat in speakers:
          if getMonoTime() >= playDeadline or interruptionRequested():
            break
          var reactionCopy: Sim
          var reactionPrompt: string
          var reactionScripted: bool
          var reactionBaseline: Baseline
          var reactionObservation: JsonNode
          withLock stateLock:
            reactionCopy = state.match.decisionSim()
            reactionPrompt = state.prompts[seat]
            reactionScripted = state.scripted[seat]
            reactionBaseline = state.baselines[seat]
            header = state.match.matchHeader()
            reactionObservation = state.liveFrameJson(seat)
          let reaction = client.decideSeat(reactionCopy, seat, reactionPrompt,
            wantShot = false, header = header, scripted = reactionScripted,
            baseline = reactionBaseline, playDeadline = playDeadline)
          if interruptionRequested():
            withLock stateLock:
              state.recordInterruptedDecision(seat, reaction, reactionObservation)
            break
          withLock stateLock:
            let beforeEvent = state.match.allEvents().len
            state.match.sim.recordSay(seat, reaction.decision.say)
            state.match.sim.applyExtras(seat, reaction.decision.extras)
            if state.match.allEvents().len > beforeEvent:
              state.broadcastLocked()
            state.recordDecision(reactionCopy, seat, false, reaction, beforeEvent, true, reactionObservation)
          if config.turnDelayMs > 0 and
              getMonoTime() < playDeadline:
            waitUntil(min(playDeadline, getMonoTime() + initDuration(milliseconds = config.turnDelayMs div 2)))

    finishEpisode(runtimeConfig,
      (if state.match.roundsPlayed == state.match.config.rounds: esCompleted else: esTruncated))

var
  gameThread: Thread[RuntimeConfig]
  gameThreadStarted: bool

proc startGameThread(server: Server) {.gcsafe, raises: [ResourceExhaustedError].} =
  {.gcsafe.}:
    createThread(gameThread, runGame, runtimeConfigGlobal)
    gameThreadStarted = true

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
    withLock stateLock:
      if slot < 0 or slot >= state.config.tokens.len or state.config.tokens[slot] != token:
        request.respond(401)
        return
      if state.started or state.stopping or state.finished or state.playerSockets.hasKey(slot):
        request.respond(409)
        return
      let websocket = request.upgradeToWebSocket()
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "parley: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "parley.player.v3",
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
      let receivedAt = getMonoTime()
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
      var payload = newJNull()
      try:
        payload = parseJson(message.data)
        if payload{"type"}.getStr() == "register":
          if payload["control"].getStr() != "external":
            raise newException(ParleyError, "unknown player control")
          withLock stateLock:
            state.registerExternal(slot, payload{"prompt"}.getStr())
          return
        if payload["type"].getStr() in ["attempt_started", "action"]:
          let id = payload["decision_id"].getStr()
          withLock stateLock:
            if state.finished: return
            if not state.external[slot] or not state.issuedSeats.hasKey(id) or state.issuedSeats[id] != slot or receivedAt < state.issuedAt[id]:
              raise newException(ParleyError, "decision does not belong to authenticated issued seat")
            if payload["type"].getStr() == "attempt_started":
              state.retainExternalAttempt(slot, id, payload["training_attempt"], completed = false)
            elif state.awaitingSeat == slot and state.awaitingId == id and
                not state.hasPendingDecision and not interruptionRequested() and receivedAt < state.awaitingDeadline:
              state.acceptExternalAction(slot, payload, message.data, receivedAt)
            elif payload["training_attempt"].kind != JNull:
              state.retainExternalAttempt(slot, id, payload["training_attempt"], completed = true)
          return
        if payload["type"].getStr() == "stopped":
          withLock stateLock:
            if state.finished: return
            if not state.external[slot]:
              raise newException(ParleyError, "acknowledgement does not belong to external owner")
            let id = payload["decision_id"]
            if payload["worker_status"].getStr() notin ["joined", "no_active_call"] or payload["attempts"].kind != JArray:
              raise newException(ParleyError, "stop must carry owned worker status and attempt array")
            if id.kind == JString:
              if not state.issuedSeats.hasKey(id.getStr()) or state.issuedSeats[id.getStr()] != slot or
                  receivedAt < state.issuedAt[id.getStr()]:
                raise newException(ParleyError, "stop evidence does not belong to authenticated issued seat")
              for evidence in payload["attempts"]:
                state.retainExternalAttempt(slot, id.getStr(), evidence, completed = true)
            elif id.kind != JNull or payload["attempts"].len > 0:
              raise newException(ParleyError, "unissued stop has native attempt evidence")
            if state.playerSockets.hasKey(slot) and state.playerSockets[slot] == websocket:
              websocket.send($(%*{"type": "evidence_received", "decision_id": id,
                "stop_id": payload["stop_id"]}))
            let expected = if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()
            if id != expected or not state.stopping or receivedAt < state.stopAckStart or
                receivedAt >= state.stopAckDeadline or payload["stop_id"] != %state.stopId:
              raise newException(ParleyError, "acknowledgement is outside its engine-issued stop window")
            for issuedId, evidence in state.startedAttempts:
              if state.issuedSeats[issuedId] == slot and
                  readAttemptEvidence(evidence).responseReaderJoined != some(true):
                raise newException(ParleyError, "stop retains an unjoined native response reader")
            state.stoppedSlots.incl(slot)
          return
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          let scripted = payload{"scripted"}.getBool()
          ## Images built before baselines existed send no baseline: random.
          let baseline = parseEnum[Baseline](payload{"baseline"}.getStr($blRandom))
          if prompt.len > MaxPromptLen:
            prompt = prompt[0 ..< MaxPromptLen]
          withLock stateLock:
            if state.started or state.stopping or state.finished or state.external[slot]:
              raise newException(ParleyError, "player control is frozen after registration or gameplay begins")
            state.prompts[slot] = prompt
            state.external[slot] = false
            state.scripted[slot] = scripted
            state.baselines[slot] = baseline
            state.promptSet[slot] = true
          echo "parley: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted: ", scripted " & $baseline else: ""), ")"
      except CatchableError as error:
        withLock stateLock:
          if state.awaitingSeat == slot and not state.hasPendingDecision and
              payload.kind == JObject and payload{"type"}.getStr() == "action" and
              payload{"decision_id"}.getStr() == state.awaitingId and
              receivedAt >= state.issuedAt[state.awaitingId] and receivedAt < state.awaitingDeadline:
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
          ## Keep authenticated ownership for queued final progress until seal.
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
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "parley: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  installNativeStopHandlers()
  let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
  let timeoutSeconds = if hostedTimeout.len > 0: parseFloat(hostedTimeout) else: config.episodeTimeoutSeconds
  if timeoutSeconds <= 0.0 or classify(timeoutSeconds) in {fcNan, fcInf, fcNegInf}:
    raise newException(ParleyError, "episode timeout must be finite and positive")
  state.episodeStart = getMonoTime()
  state.episodeTimeoutSeconds = timeoutSeconds
  state.episodeDeadline = state.episodeStart + initDuration(nanoseconds = int64(timeoutSeconds * 1_000_000_000))
  if config.tokens.len != config.players.len:
    raise newException(ParleyError, "tokens and players must align")
  state.config = config
  state.inputConfig = parseJson(runtimeConfig.config)
  state.inputConfig.delete("tokens")
  state.match = initMatch(config)
  state.prompts = newSeq[string](config.players.len)
  state.external = newSeq[bool](config.players.len)
  state.awaitingSeat = -1
  state.scripted = newSeq[bool](config.players.len)
  state.baselines = newSeq[Baseline](config.players.len)
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
  gameServer = newServer(router, websocketHandler, workerThreads = 4,
    maxMessageLen = MaxPlayerMessageLen)
  echo "parley: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host, onReady = startGameThread)
  finally:
    requestNativeStop()
    if gameThreadStarted:
      joinThread(gameThread)
