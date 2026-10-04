import std/[monotimes, times]
import std/[json, os, strutils, unittest]
import parley/[llm, sim]

suite "scripted seat randomness":
  test "retired provider credentials cannot activate inference":
    putEnv("COWORLD_LLM_ENDPOINT", "")
    putEnv("ANTHROPIC_API_KEY", "retired-test-key")
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:1")
    defer:
      delEnv("COWORLD_LLM_ENDPOINT")
      delEnv("ANTHROPIC_API_KEY")
      delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    var config = defaultGameConfig()
    for seat in 0 ..< 4:
      config.players.add(PlayerConfig(name: "P" & $seat))
    let sim = initSim(config)
    let outcome = newLlmClient(config).decide(sim, sim.itSeat, "", true, getMonoTime() + initDuration(seconds = 1))
    check outcome.origin == "scripted_no_native_endpoint"
    check outcome.nativeAttempts.len == 0

  test "one seat's reactions do not change another seat's shots":
    var config = defaultGameConfig()
    config.seed = 6
    config.sampled = true
    for seat in 0 ..< 5:
      config.players.add(PlayerConfig(name: "P" & $seat))
      config.tokens.add("token-" & $seat)
    let sim = initSim(config)
    let direct = newLlmClient(config)
    let interleaved = newLlmClient(config)
    for _ in 0 ..< 10:
      let expected = direct.scriptedShot(sim, 1)
      discard interleaved.scriptedReaction(sim, 0)
      let actual = interleaved.scriptedShot(sim, 1)
      check actual.target == expected.target
      check actual.aim == expected.aim
      check actual.say == expected.say

  test "hidden match length stays out of the model prompt":
    var config = defaultGameConfig()
    config.rounds = 17
    config.roundsKnown = false
    config.survivorsKnown = false
    for seat in 0 ..< 4:
      config.players.add(PlayerConfig(name: "P" & $seat))
    let match = initMatch(config)
    let prompt = userPrompt(match.sim, match.sim.itSeat, "", true, match.matchHeader())
    check "17" notin prompt
    check "17" notin systemPrompt(match.sim, match.sim.itSeat)
    config.roundsKnown = true
    check "of 17" in initMatch(config).matchHeader()

  test "model context remembers earlier rounds without revealing another shooter's aim":
    var config = defaultGameConfig()
    config.rounds = 2
    config.hitPoints = 1
    for seat in 0 ..< 4:
      config.players.add(PlayerConfig(name: "P" & $seat))
    var match = initMatch(config)
    let shooter = match.sim.itSeat
    match.sim.recordSay(shooter, "Our alliance lasts until the next round.")
    match.sim.applyShot(shooter, match.sim.validTargets(shooter)[0], aimHip)
    while not match.sim.done:
      match.sim.applyShot(match.sim.itSeat, match.sim.validTargets(match.sim.itSeat)[0])
    match.finishRound()
    let context = match.decisionSim()
    let own = userPrompt(context, shooter, "", true, match.matchHeader())
    let other = userPrompt(context, (shooter + 1) mod 4, "", false, match.matchHeader())
    check "Our alliance lasts until the next round." in own
    check "Our alliance lasts until the next round." in other
    ## Earlier rounds fold their shots into a tally that never names an aim.
    check "Round 1 shots:" in own and "Round 1 shots:" in other
    check "Round 1 survivors:" in own
    for prompt in [own, other]:
      check "hip-shot]" notin prompt and "head-shot]" notin prompt
    check match.sim.events.len < context.events.len
    for seat in context.seats:
      check seat.hp == 1 and seat.alive

  test "side actions round-trip from model JSON through the engine":
    var config = defaultGameConfig()
    config.rounds = 2
    for seat in 0 ..< 4:
      config.players.add(PlayerConfig(name: "P" & $seat))
    var match = initMatch(config)
    match.totals = @[1.0, 0.0, 0.0, 0.0]
    match.sim = initSim(config, 0, match.totals)
    let seat = match.sim.itSeat
    let other = (seat + 1) mod 4
    let name = match.sim.seats[other].name
    let payload = %*{"say": "deal?", "shoot": "pass",
      "whisper": {"to": name, "text": "spare me"},
      "reveal": {"to": name, "card": "enemy"},
      "pledge": name, "give": (if seat == 0: %name else: newJNull())}
    let decision = parseDecision(match.sim, seat, payload, true)
    let proposed = decisionAction(match.sim, decision, true)
    let before = match.allEvents().len
    match.sim.recordSay(seat, decision.say)
    match.sim.applyExtras(seat, decision.extras)
    match.sim.applySkip(seat)
    check appliedDecisionAction(match.sim, match.allEvents(), before, seat, true) == proposed
    expect ParleyError:
      discard parseDecision(match.sim, seat, %*{"say": "", "shoot": "pass",
        "whisper": {"to": "Nobody", "text": "hi"}}, true)
    ## A third cog sees that a whisper and a reveal happened, never their content.
    let third = (seat + 2) mod 4
    let view = userPrompt(match.decisionSim(), third, "", false, "")
    check "spare me" notin view
    check "whispers something to " & name in view
    check "shows " & name & " one of their cards" in view
    check "spare me" in userPrompt(match.decisionSim(), other, "", false, "")

  test "scripted baselines aim where they say":
    var config = defaultGameConfig()
    config.seed = 4
    config.hitPoints = 3
    for seat in 0 ..< 5:
      config.players.add(PlayerConfig(name: "P" & $seat))
    var sim = initSim(config)
    let client = newLlmClient(config)
    let me = sim.itSeat
    check client.scriptedShot(sim, me, blHoarder).skip
    var finisherTarget = -1
    for target in sim.validTargets(me):
      if target != sim.seats[me].friend:
        finisherTarget = target
        break
    sim.seats[finisherTarget].hp = 1
    check client.scriptedShot(sim, me, blFinisher).target == finisherTarget
    check client.scriptedShot(sim, me, blProtector).target == sim.seats[me].enemy
    for _ in 0 ..< 20:
      let shot = client.scriptedShot(sim, me, blRandom)
      check shot.target in sim.validTargets(me)
      check (shot.aim == aimHip) == (shot.target == sim.seats[me].friend)
