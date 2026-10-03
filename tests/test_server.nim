import std/unittest
include ../src/parley/server

suite "player state":
  test "registered external control remains accountable after gameplay begins":
    var game = GameState(prompts: newSeq[string](5), external: newSeq[bool](5),
      promptSet: newSeq[bool](5))
    game.registerExternal(0, "private operator")
    game.started = true
    expect ParleyError:
      game.registerExternal(0, "rewritten operator")
    check game.external[0] and game.prompts[0] == "private operator"
    game.started = false
    game.stopping = true
    expect ParleyError:
      game.registerExternal(1, "late owner")
    check not game.external[1]

  test "internal model actions reject prose around JSON":
    check parseJsonObject("  {\"say\": \"truce\"}  ")["say"].getStr() == "truce"
    expect JsonParsingError:
      discard parseJsonObject("I choose {\"say\": \"truce\"}")

  test "disconnected external seats never switch to the internal model":
    var config = defaultGameConfig()
    config.seed = 17
    for index in 0 ..< 5:
      config.players.add(PlayerConfig(name: "Policy" & $index))
    state = GameState(config: config, match: initMatch(config),
      prompts: newSeq[string](5), external: newSeq[bool](5),
      promptSet: newSeq[bool](5))
    let sim = state.match.decisionSim()
    let seat = sim.itSeat
    state.registerExternal(seat, "Protect my friend")
    let outcome = decideSeat(newLlmClient(config), sim, seat,
      state.prompts[seat], true, matchHeader(state.match), false, getMonoTime() + initDuration(seconds = 60))
    check outcome.origin == "scripted_after_external_disconnect"
    check outcome.input.kind == JNull
    check outcome.response.kind == JNull

  test "external decisions receive the same private prompt as hosted models":
    var config = defaultGameConfig()
    config.seed = 17
    config.rounds = 2
    for index in 0 ..< 5:
      config.players.add(PlayerConfig(name: "Policy" & $index))
    var game = GameState(config: config, match: initMatch(config),
      prompts: newSeq[string](5), external: newSeq[bool](5),
      promptSet: newSeq[bool](5))
    let sim = game.match.decisionSim()
    let seat = sim.itSeat
    let header = matchHeader(game.match)
    game.registerExternal(seat, "Protect my friend")
    check game.external[seat] and game.promptSet[seat]
    for wantShot in [true, false]:
      let packet = game.externalObservation(sim, seat, game.prompts[seat], wantShot,
        header)
      check packet["input"]["system"].getStr() == systemPrompt(sim, seat)
      check packet["input"]["user"].getStr() ==
        userPrompt(sim, seat, "Protect my friend", wantShot, header)
      check packet["observation"]["seats"][seat]["friend"].getInt() >= 0
      check not packet.hasKey("id") and not packet.hasKey("transport")

  test "foe points appear once before and after the final verdict":
    var config = defaultGameConfig()
    config.rounds = 1
    config.hitPoints = 1
    for index in 0 ..< 4:
      config.players.add(PlayerConfig(name: "P" & $index))
    var game = GameState(config: config, match: initMatch(config))
    let shooter = game.match.sim.itSeat
    game.match.sim.applyShot(shooter, game.match.sim.seats[shooter].enemy)
    check game.snapshotJson()["seats"][shooter]["score"].getFloat() == 1.0
    check game.match.totals[shooter] == 0.0
    while not game.match.sim.done:
      game.match.sim.applyShot(game.match.sim.itSeat,
        game.match.sim.validTargets(game.match.sim.itSeat)[0])
    let beforeVerdict = game.snapshotJson()
    for index in 0 ..< config.players.len:
      check beforeVerdict["seats"][index]["score"].getFloat() == float(game.match.sim.seats[index].enemyKill)
    game.match.finishRound()
    let snapshot = game.snapshotJson()
    for index, total in game.match.totals:
      check snapshot["seats"][index]["score"].getFloat() == total

  test "private player frames withhold hidden rules and other seats' secrets":
    var config = defaultGameConfig()
    config.roundsKnown = false
    config.survivorsKnown = false
    for index in 0 ..< 4:
      config.players.add(PlayerConfig(name: "Policy" & $index))
    let game = GameState(config: config, match: initMatch(config))
    let snapshot = game.liveFrameJson(0)
    check snapshot["rounds"].kind == JNull
    check snapshot["survivors"].kind == JNull
    check not snapshot.hasKey("policyNames")
    check snapshot["seats"][0]["friend"].getInt() >= 0
    for index in 1 ..< 4:
      check snapshot["seats"][index]["friend"].getInt() == -1
      check snapshot["seats"][index]["enemy"].getInt() == -1
    for event in snapshot["events"]:
      check event["kind"].getStr() != "deal" or event["seat"].getInt() == 0

  test "spectator state cannot bypass private player rules":
    var config = defaultGameConfig()
    config.roundsKnown = false
    config.survivorsKnown = false
    config.hitPoints = 3
    for index in 0 ..< 4:
      config.players.add(PlayerConfig(name: "Policy" & $index))
    var game = GameState(config: config, match: initMatch(config))
    game.match.sim.applyShot(game.match.sim.itSeat,
      game.match.sim.validTargets(game.match.sim.itSeat)[0], aimHip)
    let snapshot = game.liveFrameJson()
    check snapshot["rounds"].kind == JNull
    check snapshot["survivors"].kind == JNull
    check not snapshot.hasKey("policyNames")
    for seat in snapshot["seats"]:
      check seat["friend"].getInt() == -1
      check seat["enemy"].getInt() == -1
    for event in snapshot["events"]:
      check event["kind"].getStr() != "deal"
      check not event.hasKey("aim")
      if event["kind"].getStr() == "shot":
        check event.hasKey("hpAfter")
    let private = game.snapshotJson()
    check private.hasKey("policyNames")
    check private["seats"][0]["friend"].getInt() >= 0
    check private["events"][^2]["aim"].getStr() == "hip"

  test "replay joins accepted decisions without publishing private prompts":
    var config = defaultGameConfig()
    config.seed = 7
    config.rounds = 1
    for index in 0 ..< 5:
      config.players.add(PlayerConfig(name: "Policy" & $index))
    var game = GameState(config: config, match: initMatch(config))
    let seat = game.match.sim.itSeat
    let target = game.match.sim.validTargets(seat)[0]
    let before = game.match.allEvents().len
    let context = game.match.decisionSim()
    let privateObservation = game.liveFrameJson(seat)
    game.trajectory = some(newDecisionTrajectory("episode-1", $config.seed,
      "parley", "1.0.0", repeat('a', 40)))
    let outcome = DecisionResult(
      decision: Decision(say: "Truce?", target: target, aim: aimHip),
      origin: "model",
      input: %*{"system": "private rules", "user": "secret operator prompt"},
      response: %*{"raw": "model response"},
      nativeAttempts: @[DecisionAttempt(attemptId: "a0", policy: "model", origin: aoModel,
        prompt: %*[{"role": "user", "content": "secret operator prompt"}],
        request: %*{"messages": [{"role": "user", "content": "secret operator prompt"}]},
        response: %"model response", rawResponse: %*{"content": "model response"},
        decoder: %*{"temperature": 0},
        parsedAction: %*{"say": "Truce?", "shoot": game.match.sim.seats[target].name, "aim": "hip"},
        accepted: true)]
    )
    game.match.sim.recordSay(seat, outcome.decision.say)
    game.match.sim.applyShot(seat, target, outcome.decision.aim)
    game.recordDecision(context, seat, true, outcome, before, true, privateObservation)
    let replay = parseJson(game.replayPayload(game.match.resultsJson()))
    let reference = replay["decisionRefs"][0]
    check reference["eventBefore"].getInt() == before
    check reference["eventAfter"].getInt() == replay["events"].len
    check reference["action"]["aim"].getStr() == "hip"
    check "secret operator prompt" notin $replay
    let privateEvidence = game.staged[0]
    check privateEvidence.attempts[0].prompt[0]["content"].getStr() == "secret operator prompt"
    check privateEvidence.attempts[0].response.getStr() == "model response"
    check privateEvidence.action == privateEvidence.attempts[0].parsedAction
    check privateEvidence.observation == privateObservation

suite "external training authority":
  test "player assertions cannot create teacher labels":
    for origin in [aoTeacher, aoHuman]:
      var config = defaultGameConfig()
      config.seed = 17
      for index in 0 ..< 5: config.players.add(PlayerConfig(name: "Policy" & $index))
      var game = GameState(config: config, match: initMatch(config), awaitingShot: true)
      let seat = game.match.sim.itSeat
      let target = game.match.sim.validTargets(seat)[0]
      let action = %*{"shoot": game.match.sim.seats[target].name, "say": "public"}
      var attempt = newDecisionAttempt("asserted-teacher", "external", origin)
      attempt.response = %($action)
      game.issuedSeats["1"] = seat
      expect ParleyError:
        game.acceptExternalAction(seat, %*{"decision_id": "1", "source": "llm", "action": action,
          "training_attempt": attempt.attemptEvidenceJson()}, "wire", getMonoTime())
      check not game.hasPendingDecision

  test "model response and separately submitted action must agree":
    var config = defaultGameConfig()
    config.seed = 17
    for index in 0 ..< 5: config.players.add(PlayerConfig(name: "Policy" & $index))
    var game = GameState(config: config, match: initMatch(config), awaitingShot: true)
    let seat = game.match.sim.itSeat
    let targets = game.match.sim.validTargets(seat)
    let response = %*{"shoot": game.match.sim.seats[targets[0]].name, "say": "public"}
    let submitted = %*{"shoot": game.match.sim.seats[targets[1]].name, "say": "public"}
    game.awaitingId = "1"
    game.awaitingSeat = seat
    game.issuedSeats["1"] = seat
    game.issuedWindows["1"] = game.externalObservation(game.match.sim, seat, "prompt", true, matchHeader(game.match))
    let input = game.issuedWindows["1"]["input"]
    var attempt = newDecisionAttempt("1-model", "model", aoModel)
    attempt.prompt = %*[{"role": "system", "content": input["system"]},
      {"role": "user", "content": input["user"]}]
    attempt.request = %*{"messages": attempt.prompt}
    attempt.response = %($response)
    attempt.model = some("fixture-model")
    attempt.rawResponse = %($(%*{"model": "fixture-model", "choices": [{"message": {"content": $response}}]}))
    attempt.responseComplete = some(true)
    attempt.responseReaderJoined = some(true)
    attempt.httpStatus = some(200)
    game.retainExternalAttempt(seat, "1", attempt.attemptEvidenceJson(), completed = false)
    expect ParleyError:
      game.acceptExternalAction(seat, %*{"decision_id": "1", "source": "llm", "action": submitted,
        "training_attempt": attempt.attemptEvidenceJson()}, "wire", getMonoTime())
    check not game.hasPendingDecision
    check not game.pendingAttempts[0].accepted
    check game.pendingAttempts[0].parsedAction.kind == JNull

  test "external transport progress preserves issued owner prompt and received facts":
    var config = defaultGameConfig()
    config.seed = 17
    for index in 0 ..< 5: config.players.add(PlayerConfig(name: "Policy" & $index))
    var game = GameState(config: config, match: initMatch(config))
    let seat = game.match.sim.itSeat
    game.issuedSeats["issued"] = seat
    game.issuedWindows["issued"] = game.externalObservation(game.match.sim, seat, "operator", true, matchHeader(game.match))
    let input = game.issuedWindows["issued"]["input"]
    var attempt = newDecisionAttempt("issued-model", "native", aoModel)
    attempt.prompt = %*[{"role": "system", "content": input["system"]},
      {"role": "user", "content": input["user"]}]
    attempt.request = %*{"messages": attempt.prompt}
    attempt.httpStatus = some(200)
    attempt.responseBodyB64 = some(encode("actual-prefix"))
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\n"))
    attempt.responseComplete = some(false)
    let evidence = attempt.attemptEvidenceJson()
    game.retainExternalAttempt(seat, "issued", evidence, completed = false)
    expect ParleyError:
      game.retainExternalAttempt((seat + 1) mod 5, "issued", evidence, completed = false)
    for (key, changed) in [("response_body_b64", %encode("rewritten")),
        ("response_headers_b64", %encode("HTTP/1.1 503 Error\r\n")), ("http_status", %400),
        ("prompt", newJArray()), ("request", %*{"messages": []})]:
      var altered = copy(evidence)
      altered[key] = changed
      expect ParleyError:
        game.retainExternalAttempt(seat, "issued", altered, completed = false)
    check game.startedAttempts["issued"] == evidence
    attempt.responseBodyB64 = some(encode("actual-prefix-more"))
    attempt.responseHeadersB64 = some(encode("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"))
    attempt.responseComplete = some(true)
    attempt.responseReaderJoined = some(true)
    attempt.latencyMs = some(20.0)
    let completed = attempt.attemptEvidenceJson()
    game.retainExternalAttempt(seat, "issued", completed, completed = true)
    var rewrite = copy(completed)
    rewrite["latency_ms"] = %21.0
    expect ParleyError:
      game.retainExternalAttempt(seat, "issued", rewrite, completed = true)
    check game.completedAttempts["issued"] == completed

  test "queued disconnected older stop keeps native facts without current acknowledgement":
    var config = defaultGameConfig()
    config.seed = 17
    for index in 0 ..< 5: config.players.add(PlayerConfig(name: "Policy" & $index))
    state = GameState(config: config, match: initMatch(config), external: newSeq[bool](5), awaitingSeat: -1)
    let socket = default(WebSocket)
    let seat = 0
    state.external[seat] = true
    state.socketSlots[socket] = seat
    state.playerSockets[seat] = socket
    state.issuedSeats["older"] = seat
    state.issuedAt["older"] = getMonoTime() - initDuration(seconds = 1)
    state.issuedWindows["older"] = state.externalObservation(state.match.sim, seat, "operator", true, matchHeader(state.match))
    state.latestDecisions[seat] = "newer"
    state.awaitingId = "newer"
    state.awaitingSeat = seat
    state.pendingAttempts = @[newDecisionAttempt("newer-model", "native", aoModel)]
    let active = state.pendingAttempts
    let input = state.issuedWindows["older"]["input"]
    var attempt = newDecisionAttempt("older-model", "native", aoModel)
    attempt.prompt = %*[{"role": "system", "content": input["system"]},
      {"role": "user", "content": input["user"]}]
    attempt.request = %*{"messages": attempt.prompt}
    state.retainExternalAttempt(seat, "older", attempt.attemptEvidenceJson(), completed = false)
    attempt.responseBodyB64 = some(encode("partial received bytes"))
    attempt.responseComplete = some(false)
    attempt.responseReaderJoined = some(true)
    websocketHandler(socket, CloseEvent, Message())
    check not state.playerSockets.hasKey(seat)
    check state.socketSlots[socket] == seat
    let evidence = attempt.attemptEvidenceJson()
    let stop = %*{"type": "stopped", "decision_id": "older", "stop_id": "unissued-stop",
      "worker_status": "joined", "attempts": [evidence]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $stop))
    check state.completedAttempts["older"] == evidence
    check state.pendingAttempts == active and state.pendingRejected.len == 0
    check seat notin state.stoppedSlots
    state.finished = true
    attempt.responseBodyB64 = some(encode("rewritten"))
    let late = %*{"type": "stopped", "decision_id": "older", "stop_id": "unissued-stop",
      "worker_status": "joined", "attempts": [attempt.attemptEvidenceJson()]}
    websocketHandler(socket, MessageEvent, Message(kind: TextMessage, data: $late))
    check state.completedAttempts["older"] == evidence

  test "executed action comes from engine events even after fallback":
    var config = defaultGameConfig()
    config.seed = 17
    for index in 0 ..< 5: config.players.add(PlayerConfig(name: "Policy" & $index))
    var game = GameState(config: config, match: initMatch(config))
    let before = game.match.sim
    let seat = before.itSeat
    let targets = before.validTargets(seat)
    game.trajectory = some(newDecisionTrajectory("engine-fallback", "parley-17", "parley",
      "source-test", repeat('a', 40)))
    let start = game.match.allEvents().len
    game.match.sim.recordSay(seat, "actually spoken")
    game.match.sim.applyShot(seat, targets[1], aimHip)
    let outcome = DecisionResult(origin: "scripted_after_rejected_action",
      decision: Decision(target: targets[0], say: "unused proposal", aim: aimHead))
    game.recordDecision(before, seat, true, outcome, start, false, newJObject())
    let executed = game.staged[0].action
    check executed["shoot"].getStr() == before.seats[targets[1]].name
    check executed["say"].getStr() == "actually spoken"
    check executed["aim"].getStr() == $aimHip
