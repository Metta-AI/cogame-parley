import std/[json, strutils, unittest]
from std/unicode import runeLen, validateUtf8
import parley/[llm, sim]

suite "scripted seat randomness":
  test "speech clipping preserves UTF8 and the advertised character cap":
    let sim = default(Sim)
    let shortSpeech = repeat("界", 60)
    check sim.parseDecision(0, %*{"say": shortSpeech}, false).say == shortSpeech
    for speech in [repeat("界", 170), repeat("é", 170), repeat("a", 170),
        repeat("界", 100) & " " & repeat("é", 70)]:
      let clipped = sim.parseDecision(0, %*{"say": speech}, false).say
      check clipped.validateUtf8 == -1
      check clipped.runeLen <= 160
      check clipped.endsWith("…")
    let words = repeat("界", 100) & " " & repeat("é", 70)
    check sim.parseDecision(0, %*{"say": words}, false).say == repeat("界", 100) & "…"

  test "structured actions preserve visible targets, both aims, passes, and reactions":
    var config = defaultGameConfig()
    config.sampled = true
    for seat in 0 ..< 5:
      config.players.add(PlayerConfig(name: "P" & $seat))
    var sim = initSim(config)
    let schema = sim.actionSchema(sim.itSeat, true)
    var names = newJArray()
    for target in sim.validTargets(sim.itSeat):
      names.add(%sim.seats[target].name)
    names.add(%"pass")
    check schema["properties"]["shoot"]["enum"] == names
    check schema["properties"]["aim"]["enum"] == %*["head", "hip"]
    let reaction = sim.actionSchema(sim.itSeat, false)
    check reaction["properties"].len == 1
    check reaction["properties"]["say"]["type"].getStr() == "string"
    check reaction["required"] == %*["say"]
    while sim.skipsLeft() > 0:
      sim.applySkip(sim.itSeat)
    check "pass" notin $sim.actionSchema(sim.itSeat, true)["properties"]["shoot"]["enum"]
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
