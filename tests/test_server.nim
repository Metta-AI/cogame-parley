import std/unittest
include ../src/parley/server

suite "player state":
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
    let outcome = DecisionResult(
      decision: Decision(say: "Truce?", target: target, aim: aimHip),
      origin: "model",
      input: %*{"system": "private rules", "user": "secret operator prompt"},
      response: %*{"raw": "model response"}
    )
    game.match.sim.recordSay(seat, outcome.decision.say)
    game.match.sim.applyShot(seat, target, outcome.decision.aim)
    game.recordDecision(context, seat, true, outcome, before, true)
    let replay = parseJson(game.replayPayload(game.match.resultsJson()))
    let reference = replay["decisionRefs"][0]
    check reference["eventBefore"].getInt() == before
    check reference["eventAfter"].getInt() == replay["events"].len
    check reference["action"]["aim"].getStr() == "hip"
    check "secret operator prompt" notin $replay
    let privateEvidence = evidenceJson(reference, outcome)
    check privateEvidence["input"]["user"].getStr() == "secret operator prompt"
    check privateEvidence["response"]["raw"].getStr() == "model response"
