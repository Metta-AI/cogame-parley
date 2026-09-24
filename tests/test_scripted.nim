import std/unittest
import parley/[llm, sim]

suite "scripted seat randomness":
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
