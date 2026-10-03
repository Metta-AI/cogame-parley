import std/unittest
include ../src/parley/server

suite "player state":
  test "game waits for every connected player to register control":
    var config = defaultGameConfig()
    for index in 0 ..< 5:
      config.players.add(PlayerConfig(name: "Policy" & $index))
      config.tokens.add("token" & $index)
    var game = GameState(config: config, promptSet: newSeq[bool](5))
    check not game.playersReady()
    for index in 0 ..< 5:
      game.playerSockets[index] = default(WebSocket)
    check not game.playersReady()
    for index in 0 ..< 5:
      game.promptSet[index] = true
    check game.playersReady()
    game.playerSockets.del(4)
    check not game.playersReady()

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
      state.prompts[seat], true, matchHeader(state.match), false, 0.0)
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
        header, 7)
      check packet["input"]["system"].getStr() == systemPrompt(sim, seat)
      check packet["input"]["user"].getStr() ==
        userPrompt(sim, seat, "Protect my friend", wantShot, header)
      check packet["observation"]["seats"][seat]["friend"].getInt() >= 0
      check packet["id"].getInt() == 7

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
    game.trajectory.get().finish(esCompleted, game.match.resultsJson(), newJNull())
    let privateEvidence = parseJson(game.trajectory.get().eventsJsonl().splitLines()[0])
    check privateEvidence["attempts"][0]["prompt"][0]["content"].getStr() == "secret operator prompt"
    check privateEvidence["attempts"][0]["response"].getStr() == "model response"
    check privateEvidence["executed_action"] == privateEvidence["attempts"][0]["parsed_action"]
    check privateEvidence["observation"] == privateObservation

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
      game.acceptExternalAction(seat, %*{"action": action,
        "attempts": [attempt.attemptEvidenceJson()]}, "wire")
      check game.pendingAttempts[0].origin == aoUnknown
      check game.hasPendingDecision

  test "model response and separately submitted action must agree":
    var config = defaultGameConfig()
    config.seed = 17
    for index in 0 ..< 5: config.players.add(PlayerConfig(name: "Policy" & $index))
    var game = GameState(config: config, match: initMatch(config), awaitingShot: true)
    let seat = game.match.sim.itSeat
    let targets = game.match.sim.validTargets(seat)
    let response = %*{"shoot": game.match.sim.seats[targets[0]].name, "say": "public"}
    let submitted = %*{"shoot": game.match.sim.seats[targets[1]].name, "say": "public"}
    var attempt = newDecisionAttempt("native-model", "model", aoModel)
    attempt.response = %($response)
    expect ParleyError:
      game.acceptExternalAction(seat, %*{"action": submitted,
        "attempts": [attempt.attemptEvidenceJson()]}, "wire")
    check not game.hasPendingDecision
    check not game.pendingAttempts[0].accepted
    check game.pendingAttempts[0].parsedAction["shoot"] == response["shoot"]

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
    game.trajectory.get().finish(esCompleted, newJObject(), newJObject())
    let executed = parseJson(game.trajectory.get().eventsJsonl().splitLines()[0])["executed_action"]
    check executed["shoot"].getStr() == before.seats[targets[1]].name
    check executed["say"].getStr() == "actually spoken"
    check executed["aim"].getStr() == $aimHip
