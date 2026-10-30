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
  std/[base64, json, locks, math, monotimes, options, os, sets, strutils, sysrand, tables, times],
  bitworld/decision_trajectory,
  bitworld/runtime,
  bitworld/native_stop,
  bitworld/artifact_runtime,
  webby/httpheaders,
  mummy,
  mummy/routers,
  batch,
  llm,
  prompts,
  sim

const
  MaxPromptLen = 4000
  MaxPlayerMessageLen = 16 * 1024 * 1024
  ReplayVersion = 4
  ParleySourceRevision {.strdefine.} = ""
  ParleyGameVersion {.strdefine.} = ""

type
  DecisionRecord = ref object
    id: string
    seat: int
    issuedAt, deadline, receivedAt: MonoTime
    wantShot, awaiting, hasAction, rejected, completed: bool
    decision: Decision
    rawAction: JsonNode
    evidence: Option[JsonNode]
    observation, action: JsonNode
    attempts: seq[DecisionAttempt]
    selected: Option[string]
    status: ActionStatus
    fallback: Option[string]
  PolicyFailure = object
    seat: int
    decisionId: string
    reason: DecisionFailure
  PolicyKind = enum
    pkUnregistered, pkNative, pkScripted, pkExternal
  SeatPolicy = object
    kind: PolicyKind
    prompt: string
    baseline: Baseline
    latestDecision: string
  GameState = object
    policyFailure: Option[PolicyFailure]
    config: GameConfig
    inputConfig: JsonNode
    match: Match
    policies: seq[SeatPolicy]
    issued: Table[string, DecisionRecord]
    pending: DecisionRecord
    stoppedSlots: HashSet[int]
    staged: seq[DecisionRecord]
    stopping: bool
    stopId: string
    stopAckStart, stopAckDeadline: MonoTime
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

proc assetDir(name: string): string =
  let appDir = getAppDir()
  for candidate in [appDir / name, appDir / ".." / name, name]:
    if dirExists(candidate):
      return candidate
  name

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

proc decisionObservation(gs: GameState, sim: Sim, seat: int, prompt: string,
    wantShot: bool, header: string): JsonNode =
  let options = sim.actionOptions(seat, wantShot)
  let system = systemPrompt(sim, seat)
  let user = userPrompt(sim, seat, prompt, options, header)
  let view = gs.liveFrameJson(seat)
  view["prompt_template"] = promptMetadata(sim.config, system, user)
  %*{
    "phase": options["phase"],
    "observation": view,
    "input": {"system": system, "user": user},
    "legalActions": options["legalActions"],
    "actionSchema": actionSchema(options),
    "extras": options["extras"]}

proc registerExternal(gs: var GameState, slot: int, prompt: string) =
  if gs.started or gs.stopping or gs.finished:
    raise newException(ParleyError, "player control is frozen after gameplay begins")
  if prompt.len > MaxPromptLen:
    raise newException(ParleyError, "external operator prompt exceeds limit")
  gs.policies[slot] = SeatPolicy(kind: pkExternal, prompt: prompt)

proc decideSeat(client: LlmClient, sim: Sim, seat: int, policy: SeatPolicy,
    wantShot: bool, observation: JsonNode,
    playDeadline: MonoTime): DecisionResult =
  if getMonoTime() >= playDeadline:
    result.failure = some(dfEpisodeDeadline)
    return
  let decisionDeadline = min(playDeadline, getMonoTime() + initDuration(seconds = state.config.llmTimeoutSeconds))
  case policy.kind
  of pkUnregistered:
    result.failure = some(dfMissingPolicy)
    return
  of pkScripted:
    result.decision =
      if wantShot: client.scriptedShot(sim, seat, policy.baseline)
      else: client.scriptedReaction(sim, seat)
    result.origin = "scripted_policy"
    return
  of pkNative:
    return client.decide(sim, seat, observation, decisionDeadline)
  of pkExternal:
    discard

  withLock stateLock:
    if not state.playerSockets.hasKey(seat):
      result.failure = some(dfExternalDisconnect)
      return
    state.pending = DecisionRecord(id: $(state.decisionRefs.len + 1), seat: seat,
      observation: observation, issuedAt: getMonoTime(), deadline: decisionDeadline,
      wantShot: wantShot, awaiting: true)
    state.issued[state.pending.id] = state.pending
    state.policies[seat].latestDecision = state.pending.id
    state.playerSockets[seat].send($(%*{"type": "decision", "decision_id": state.pending.id,
      "observation": observation, "transport": {
        "budget_ms": max(1, (decisionDeadline - getMonoTime()).inMilliseconds),
        "cleanup_budget_ms": 5000}}))
  while getMonoTime() < decisionDeadline and not interruptionRequested():
    var ready = false
    withLock stateLock:
      ready = state.pending.hasAction or state.pending.rejected or
        not state.playerSockets.hasKey(seat)
    if ready:
      break
    sleep(20)
  withLock stateLock:
    state.pending.awaiting = false
    if state.pending.hasAction and state.pending.receivedAt < decisionDeadline and not interruptionRequested():
      return DecisionResult(decision: state.pending.decision,
        origin: "external",
        nativeAttempts: state.pending.attempts)
    result.failure = some(
      if state.pending.rejected: dfRejectedAction
      elif not state.playerSockets.hasKey(seat): dfExternalDisconnect
      elif decisionDeadline == playDeadline: dfEpisodeDeadline
      else: dfExternalTimeout)
    result.nativeAttempts = state.pending.attempts

proc retainExternalAttempt(gs: var GameState, seat: int, id: string,
    evidence: JsonNode, completed: bool) =
  if not gs.issued.hasKey(id) or gs.issued[id].seat != seat:
    raise newException(ParleyError, "attempt does not belong to authenticated issued seat")
  let issued = gs.issued[id]
  if not completed and issued.evidence.isNone:
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
  let input = issued.observation["input"]
  let prompt = %*[{"role": "system", "content": input["system"]},
    {"role": "user", "content": input["user"]}]
  if attempt.prompt != prompt or attempt.request.kind != JObject or
      attempt.request["messages"] != prompt:
    raise newException(ParleyError, "model call rewrites the exact private prompt")
  if completed and issued.evidence.isNone:
    raise newException(ParleyError, "completed model evidence lacks pre-request start")
  if issued.evidence.isSome:
    if (issued.evidence.get()["latency_ms"].kind != JNull or
        issued.evidence.get()["response_reader_joined"] == %true) and evidence != issued.evidence.get():
      raise newException(ParleyError, "finished native attempt evidence is immutable")
    for key in ["prompt", "request", "decoder", "policy", "model"]:
      if evidence[key] != issued.evidence.get()[key]:
        raise newException(ParleyError, "started model request evidence is immutable")
    let before = issued.evidence.get()
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
  if issued.completed and evidence != issued.evidence.get():
    raise newException(ParleyError, "completed native evidence is immutable")
  issued.evidence = some(copy(evidence))
  issued.completed = issued.completed or completed
  if issued.awaiting and not issued.hasAction and not issued.rejected:
    issued.attempts = @[attempt]

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
  if source == "fallback":
    raise newException(ParleyError, "external policy supplied a fallback instead of an action")
  let proposal = parseDecision(gs.match.sim, seat, payload["action"], gs.pending.wantShot)
  let canonical = decisionAction(gs.match.sim, proposal, gs.pending.wantShot)
  if source == "llm":
    var attempt = readAttemptEvidence(gs.issued[id].evidence.get())
    if attempt.response.kind != JString or attempt.rawResponse.kind != JString or
        attempt.responseComplete != some(true) or attempt.responseReaderJoined != some(true) or
        attempt.httpStatus != some(200) or
        attempt.rejectionReason.isSome:
      raise newException(ParleyError, "model action requires its complete successful native response")
    let served = parseJson(attempt.rawResponse.getStr())
    if attempt.model.isNone or served["model"] != %attempt.model.get() or
        served["choices"][0]["message"]["content"] != attempt.response:
      raise newException(ParleyError, "selected completion differs from actual received native body")
    if served["choices"][0]["finish_reason"].getStr() != "stop":
      raise newException(ParleyError, "model action requires a complete native generation")
    let generated = parseDecision(gs.match.sim, seat,
      parseJsonObject(attempt.response.getStr()), gs.pending.wantShot)
    attempt.parsedAction = decisionAction(gs.match.sim, generated, gs.pending.wantShot)
    if attempt.parsedAction != canonical:
      raise newException(ParleyError, "model response differs from submitted action")
    gs.pending.attempts = @[attempt]
  gs.pending.decision = proposal
  gs.pending.rawAction = %*{"wire": wire, "action": payload["action"]}
  gs.pending.receivedAt = receivedAt
  gs.pending.hasAction = true

proc recordDecision(gs: var GameState, sim: Sim, seat: int,
    wantShot: bool, outcome: DecisionResult, beforeEvent: int,
    observation: JsonNode) =
  let action = appliedDecisionAction(sim, gs.match.allEvents(), beforeEvent, seat, wantShot)
  let reference = %*{
    "id": gs.decisionRefs.len + 1,
    "seat": seat,
    "phase": (if wantShot: "shot" else: "reaction"),
    "origin": outcome.origin,
    "accepted": true,
    "eventBefore": beforeEvent,
    "eventAfter": gs.match.allEvents().len,
    "action": action
  }
  gs.decisionRefs.add(reference)
  if gs.trajectory.isSome:
    var attempts = outcome.nativeAttempts
    var selected = none(string)
    let proposalAccepted = outcome.origin in ["model", "external"]
    if outcome.origin == "external":
      if attempts.len == 0 or attempts[^1].rejectionReason.isSome:
        var external = newDecisionAttempt("external-action", "external", aoUnknown)
        external.prompt = %*{"packet": observation, "wire": $observation}
        external.response = gs.pending.rawAction
        attempts.add(external)
      if attempts[^1].origin != aoModel:
        attempts[^1].parsedAction = decisionAction(sim, outcome.decision, wantShot)
      attempts[^1].accepted = true
    if proposalAccepted:
      selected = some(attempts[^1].attemptId)
    let id = $reference["id"].getInt()
    let record = if gs.issued.hasKey(id): gs.issued[id]
      else: DecisionRecord(id: id, seat: seat, observation: observation)
    record.attempts = attempts
    record.selected = selected
    record.action = action
    record.status = if proposalAccepted: asAccepted else: asFallback
    record.fallback = if proposalAccepted: none(string) else: some(outcome.origin)
    gs.staged.add(record)


proc recordUnexecutedDecision(gs: var GameState, seat: int,
    outcome: DecisionResult, observation: JsonNode) =
  ## No failed or interrupted proposal is applied; retain every received attempt.
  let id = $(gs.decisionRefs.len + 1)
  if outcome.failure.isSome and not interruptionRequested():
    gs.policyFailure = some(PolicyFailure(seat: seat, decisionId: id, reason: outcome.failure.get()))
  if gs.trajectory.isSome:
    var attempts = outcome.nativeAttempts
    for attempt in attempts.mitems:
      attempt.accepted = false
      if attempt.rejectionReason.isNone:
        attempt.rejectionReason = some(if outcome.failure.isSome: $outcome.failure.get()
          else: "interrupted before engine acceptance")
    let record = if gs.issued.hasKey(id): gs.issued[id]
      else: DecisionRecord(id: id, seat: seat, observation: observation)
    record.attempts = attempts
    record.action = newJNull()
    record.status = if gs.policyFailure.isSome: asRejected else: asMissing
    gs.staged.add(record)

proc writeArtifact(uri, data, contentType, methodEnv: string, cleanupDeadline: MonoTime) =
  if uri.len == 0:
    return
  let httpMethod = parseEnum[ArtifactHttpMethod](getEnv(methodEnv, "PUT").toUpperAscii())
  writeCogameArtifact(uri, data, contentType, methodEnv, cleanupDeadline, httpMethod)

proc writePlayerFailure(gs: GameState, failure: PolicyFailure, cleanupDeadline: MonoTime) =
  ## Keep unavailable inference distinct from a completed but invalid action.
  ## The game's own play deadline is not a seat fault.
  if failure.reason == dfEpisodeDeadline:
    return
  let message = "Parley seat " & $failure.seat & " (" & gs.config.players[failure.seat].name &
    ") failed: " & $failure.reason
  var declaration = %*{"failed_policy_index": failure.seat, "message": message}
  if failure.reason == dfInferenceUnavailable:
    declaration["kind"] = %"episode_inconclusive"
  writeArtifact(
    getEnv("COGAME_PLAYER_FAILURE_URI"),
    $declaration,
    "application/json", "COGAME_PLAYER_FAILURE_METHOD", cleanupDeadline
  )

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

proc waitUntil(deadline: MonoTime) =
  ## Spectator and connection waits share the original lifetime and stop signal.
  while getMonoTime() < deadline and not interruptionRequested():
    sleep(int(min(20'i64, max(1'i64, (deadline - getMonoTime()).inMilliseconds))))

proc finishEpisode(runtimeConfig: RuntimeConfig, status: EpisodeStatus) =
  let cleanupDeadline = min(state.episodeDeadline, getMonoTime() + initDuration(seconds = 10))
  let execution = %*{"full_match": getEnv("COWORLD_XP_FULL_MATCH") == "true",
    "episode_timeout_seconds": state.episodeTimeoutSeconds}
  var targets: seq[int]
  withLock stateLock:
    if state.finished: return
    state.stopping = true
    var stopToken: array[16, byte]
    doAssert urandom(stopToken), "OS entropy unavailable for stop identity"
    for value in stopToken: state.stopId.add(value.toHex(2))
    state.stopAckStart = getMonoTime()
    state.stopAckDeadline = cleanupDeadline - initDuration(seconds = 1)
    for slot, policy in state.policies:
      if policy.kind != pkExternal: continue
      targets.add(slot)
      if state.playerSockets.hasKey(slot):
        let id = if state.policies[slot].latestDecision.len > 0: %state.policies[slot].latestDecision else: newJNull()
        state.playerSockets[slot].send($(%*{"type": "stop", "stop_id": state.stopId, "decision_id": id,
          "reason": (if interruptionRequested(): "interrupted"
            elif status == esCompleted or state.policyFailure.isSome: "terminal" else: "episode_deadline"),
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
  var completed = false
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
    completed = status == esCompleted and not interruptionRequested() and not unresolved
    if completed:
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
        if staged.selected.isNone and staged.evidence.isSome:
          var received = readAttemptEvidence(staged.evidence.get())
          if attempts.len > 0:
            received.accepted = attempts[0].accepted
            received.parsedAction = attempts[0].parsedAction
            received.rejectionReason = attempts[0].rejectionReason
          else:
            received.rejectionReason = some("native evidence arrived after engine decision")
          attempts = @[received]
        for attempt in attempts.mitems:
          attempt.policy = state.config.players[staged.seat].name
        trajectory.recordDecision(staged.id, $staged.seat, staged.observation,
          attempts, staged.selected, staged.action, staged.status, fallbackOrigin = staged.fallback)
    if not completed:
      trajectory.finish(esFailed,
        %*{"protocol": "parley.native-outcome.v1", "player_cleanup": cleanup,
          "termination": (if interruptionRequested(): "interrupted" elif state.policyFailure.isSome: "policy_failure"
            elif unresolved: "unresolved-player-cleanup" else: "runtime-failure"),
          "policy_failure": (if state.policyFailure.isSome: %state.policyFailure.get() else: newJNull()),
          "partial_results": results, "input_config": state.inputConfig,
          "selected_seed": state.config.seed, "execution": execution}, newJNull())
    else:
      trajectory.finish(
        status,
        %*{"protocol": "parley.native-outcome.v1", "results": results,
           "player_cleanup": cleanup, "input_config": state.inputConfig, "selected_seed": state.config.seed,
           "execution": execution},
        results["scores"])
    writeTrajectoryArtifact(trajectory, getEnv(CogameSaveTrajectoryUriEnv), cleanupDeadline,
      parseEnum[ArtifactHttpMethod](getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()))
  if state.policyFailure.isSome and not interruptionRequested():
    state.writePlayerFailure(state.policyFailure.get(), cleanupDeadline)
  if completed:
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

proc playDecision(client: LlmClient, seat: int, wantShot: bool,
    playDeadline, episodeDeadline: MonoTime): bool =
  ## One engine-owned lifecycle for native, external, and scripted policies.
  ## Only the game thread mutates the match; inference runs without its lock.
  var sim: Sim
  var policy: SeatPolicy
  var observation: JsonNode
  if getMonoTime() < playDeadline:
    batchControl("turn", int((episodeDeadline - getMonoTime()).inMilliseconds),
      $(state.decisionRefs.len + 1), seat,
      max(1, min(state.config.llmTimeoutSeconds * 1000,
        int((playDeadline - getMonoTime()).inMilliseconds))))
  withLock stateLock:
    sim = state.match.decisionSim()
    policy = state.policies[seat]
    observation = state.decisionObservation(sim, seat, policy.prompt, wantShot, state.match.matchHeader())
  let outcome = client.decideSeat(sim, seat, policy, wantShot, observation, playDeadline)
  if policy.kind != pkExternal:
    observation = observation["observation"]
  withLock stateLock:
    if interruptionRequested() or outcome.failure.isSome:
      state.recordUnexecutedDecision(seat, outcome, observation)
      return false
    let beforeEvent = state.match.allEvents().len
    state.match.sim.recordSay(seat, outcome.decision.say)
    state.match.sim.applyExtras(seat, outcome.decision.extras)
    if wantShot:
      if outcome.decision.skip:
        state.match.sim.applySkip(seat)
      else:
        state.match.sim.applyShot(seat, outcome.decision.target, outcome.decision.aim)
    state.recordDecision(sim, seat, wantShot, outcome, beforeEvent, observation)
    state.broadcastLocked()
  if getEnv("COWORLD_XP_BATCH_URL").len == 0:
    let delay = if wantShot: state.config.turnDelayMs else: state.config.turnDelayMs div 2
    if delay > 0:
      waitUntil(min(playDeadline, getMonoTime() + initDuration(milliseconds = delay)))
  true

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    var status = esFailed
    defer:
      # Leave the cohort before stop acknowledgements and artifact publication.
      try:
        batchControl("finish", 5000)
      finally:
        finishEpisode(runtimeConfig, status)
    let config = state.config
    let gameStart = state.episodeStart
    let timeoutSeconds = state.episodeTimeoutSeconds
    let fullMatch = getEnv("COWORLD_XP_FULL_MATCH") == "true"
    let episodeDeadline = gameStart + initDuration(nanoseconds = int64(timeoutSeconds * 1_000_000_000))
    let playSeconds = if fullMatch: timeoutSeconds - 10.0 else: timeoutSeconds * PlayBudgetFraction
    let playDeadline = gameStart + initDuration(nanoseconds = int64(playSeconds * 1_000_000_000))
    let deadline = min(playDeadline, gameStart + initDuration(nanoseconds = int64(config.playerConnectTimeoutSeconds * 1_000_000_000)))

    while getMonoTime() < deadline and not interruptionRequested():
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
        for policy in state.policies:
          allConnected = allConnected and policy.kind != pkUnregistered
      if allConnected:
        break
      waitUntil(min(deadline, getMonoTime() + initDuration(milliseconds = 200)))

    withLock stateLock:
      state.started = true
      echo "parley: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    withLock stateLock:
      for seat, policy in state.policies:
        if policy.kind == pkUnregistered:
          state.policyFailure = some(PolicyFailure(seat: seat, reason: dfMissingPolicy))
          return

    batchControl("start", int((episodeDeadline - getMonoTime()).inMilliseconds))
    let client = newLlmClient(config)

    echo "parley: episode timeout ", timeoutSeconds.int, "s; playing until ",
      playSeconds.int, "s; full match=", fullMatch
    ## Rounds are dealt only while the longest round so far would still fit,
    ## so the episode budget normally ends play at a completed-round boundary.
    var roundStartedAt = getMonoTime()
    var longestRound = initDuration()

    while not interruptionRequested():
      var shooter: int
      withLock stateLock:
        if state.match.done: break
        shooter = state.match.sim.itSeat
      if not client.playDecision(shooter, wantShot = true, playDeadline, episodeDeadline):
        return

      var roundEnded: bool
      withLock stateLock:
        roundEnded = state.match.sim.done
      if roundEnded:
        ## Pacing is included when deciding whether the next round fits.
        let roundEndedAt = getMonoTime()
        longestRound = max(longestRound, roundEndedAt - roundStartedAt)
        roundStartedAt = roundEndedAt
        withLock stateLock:
          let timedOut = not fullMatch and roundEndedAt + longestRound >= playDeadline
          state.match.finishRound(endMatch = timedOut)
          if timedOut and state.match.roundsPlayed < config.rounds:
            echo "parley: episode deadline reached after ",
              state.match.roundsPlayed, "/", config.rounds, " rounds"
          state.broadcastLocked()
        continue

      if config.reactions and getMonoTime() < playDeadline:
        var speakers: seq[int]
        withLock stateLock:
          speakers = state.match.sim.reactionSpeakers()
        for seat in speakers:
          if getMonoTime() >= playDeadline or interruptionRequested(): break
          if not client.playDecision(seat, wantShot = false, playDeadline, episodeDeadline):
            return

    status = esCompleted

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

proc clientFileHandler(name, contentType: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, assetDir("client") / name, contentType)
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
    serveFile(request, assetDir("data") / name, contentType)

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
            if state.policies[slot].kind != pkExternal or not state.issued.hasKey(id) or state.issued[id].seat != slot or receivedAt < state.issued[id].issuedAt:
              raise newException(ParleyError, "decision does not belong to authenticated issued seat")
            if payload["type"].getStr() == "attempt_started":
              state.retainExternalAttempt(slot, id, payload["training_attempt"], completed = false)
            elif state.issued[id].awaiting and
                not state.pending.hasAction and not state.pending.rejected and
                not interruptionRequested() and receivedAt < state.pending.deadline:
              state.acceptExternalAction(slot, payload, message.data, receivedAt)
            elif payload["training_attempt"].kind != JNull:
              state.retainExternalAttempt(slot, id, payload["training_attempt"], completed = true)
          return
        if payload["type"].getStr() == "stopped":
          withLock stateLock:
            if state.finished: return
            if state.policies[slot].kind != pkExternal:
              raise newException(ParleyError, "acknowledgement does not belong to external owner")
            let id = payload["decision_id"]
            if payload["worker_status"].getStr() notin ["joined", "no_active_call"] or payload["attempts"].kind != JArray:
              raise newException(ParleyError, "stop must carry owned worker status and attempt array")
            if id.kind == JString:
              if not state.issued.hasKey(id.getStr()) or state.issued[id.getStr()].seat != slot or
                  receivedAt < state.issued[id.getStr()].issuedAt:
                raise newException(ParleyError, "stop evidence does not belong to authenticated issued seat")
              for evidence in payload["attempts"]:
                state.retainExternalAttempt(slot, id.getStr(), evidence, completed = true)
            elif id.kind != JNull or payload["attempts"].len > 0:
              raise newException(ParleyError, "unissued stop has native attempt evidence")
            if state.playerSockets.hasKey(slot) and state.playerSockets[slot] == websocket:
              websocket.send($(%*{"type": "evidence_received", "decision_id": id,
                "stop_id": payload["stop_id"]}))
            let expected = if state.policies[slot].latestDecision.len > 0: %state.policies[slot].latestDecision else: newJNull()
            if id != expected or not state.stopping or receivedAt < state.stopAckStart or
                receivedAt >= state.stopAckDeadline or payload["stop_id"] != %state.stopId:
              raise newException(ParleyError, "acknowledgement is outside its engine-issued stop window")
            for issued in state.issued.values:
              if issued.seat == slot and issued.evidence.isSome and
                  issued.evidence.get()["response_reader_joined"] != %true:
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
            if state.started or state.stopping or state.finished or state.policies[slot].kind == pkExternal:
              raise newException(ParleyError, "player control is frozen after registration or gameplay begins")
            state.policies[slot] = SeatPolicy(
              kind: (if scripted: pkScripted else: pkNative),
              prompt: prompt, baseline: baseline)
          echo "parley: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted: ", scripted " & $baseline else: ""), ")"
      except CatchableError as error:
        withLock stateLock:
          if state.pending.awaiting and state.pending.seat == slot and not state.pending.hasAction and not state.pending.rejected and
              payload.kind == JObject and payload{"type"}.getStr() == "action" and
              payload{"decision_id"}.getStr() == state.pending.id and
              receivedAt >= state.pending.issuedAt and receivedAt < state.pending.deadline:
            state.pending.rejected = true
            if state.pending.attempts.len == 0 or state.pending.attempts[^1].rejectionReason.isSome:
              var rejected = newDecisionAttempt("external-rejected-1",
                "external", aoUnknown)
              let issued = state.pending.observation["input"]
              rejected.prompt = %*[{"role": "system", "content": issued["system"]},
                {"role": "user", "content": issued["user"]}]
              rejected.response = %message.data
              rejected.rejectionReason = some(error.msg)
              state.pending.attempts.add(rejected)
            else:
              state.pending.attempts[^1].accepted = false
              state.pending.attempts[^1].rejectionReason = some(error.msg)
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
  for name in ["global", "player", "replay"]:
    result.get("/client/" & name, clientFileHandler(name & ".html", "text/html; charset=utf-8"))
  for name in ["renderer", "reasoning", "replay"]:
    result.get("/client/" & name & ".js", clientFileHandler(name & ".js", "application/javascript; charset=utf-8"))
  result.get("/client/chrome.css", clientFileHandler("chrome.css", "text/css; charset=utf-8"))
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  replayPayloadGlobal = $enrichReplay(parseJson(runtimeConfig.replay))

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
  state.policies = newSeq[SeatPolicy](config.players.len)
  state.pending = DecisionRecord()
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    let metadata = getEnv("LLM_REQUEST_METADATA")
    let episodeId = if metadata.len > 0:
        parseJson(metadata)["episode_request_id"].getStr()
      else:
        var identity: array[16, byte]
        if not urandom(identity):
          raise newException(ParleyError, "OS entropy unavailable for episode identity")
        var localId = "local-"
        for value in identity: localId.add(value.toHex(2))
        localId
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

  if state.policyFailure.isSome:
    raise newException(ParleyError, "policy failed: " & $state.policyFailure.get().reason)
