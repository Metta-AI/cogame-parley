import std/[os, strutils, unittest]
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
    let outcome = newLlmClient(config).decide(sim, sim.itSeat, "", true)
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
    check "[your hip-shot]" in own
    check "[your hip-shot]" notin other
    check match.sim.events.len < context.events.len
    for seat in context.seats:
      check seat.hp == 1 and seat.alive
