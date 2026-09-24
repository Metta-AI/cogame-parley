import std/[json, unittest]
import parley/[llm, sim]

proc fixture(): Sim =
  var config = defaultGameConfig()
  config.seed = 7
  config.sampled = true
  config.maxSkips = 2
  for seat in 0 ..< 4:
    config.players.add(PlayerConfig(name: "P" & $seat))
    config.tokens.add("token-" & $seat)
  initSim(config)

proc answer(criteria: JsonNode, choice: string): JsonNode =
  var probabilities = newJObject()
  for name, _ in criteria.pairs:
    probabilities[name] = %(if name == choice: 1.0 else: 0.0)
  %*{
    "answers": {"decision": {"type": "choice", "choice": choice,
      "confidence": 0.8, "probabilities": probabilities}},
    "usage": {"input_tokens": 12, "output_tokens": 2}
  }

suite "Jev bounded choices":
  test "the shooter can pass or choose either aim at a living opponent":
    let sim = fixture()
    let seat = sim.itSeat
    let target = sim.validTargets(seat)[0]
    let criteria = sim.jevCriteria(seat, true)
    check criteria.hasKey("pass")
    check criteria.hasKey($target & "-head")
    check criteria.hasKey($target & "-hip")
    check not criteria.hasKey($seat & "-head")
    var shotAnswer = answer(criteria, $target & "-hip")
    shotAnswer["answers"]["decision"]["choice"] = %"pass"
    let shot = sim.jevDecision(seat, shotAnswer, criteria, true)
    check shot.target == target
    check shot.aim == aimHip
    check shot.say.len > 0
    var applied = sim
    applied.recordSay(seat, shot.say)
    applied.applyShot(seat, shot.target, shot.aim)
    let hold = sim.jevDecision(seat, answer(criteria, "pass"),
      criteria, true)
    check hold.skip
    expect ParleyError:
      discard sim.jevDecision(seat, answer(criteria, "pass"),
        sim.jevCriteria(seat, false), true)

  test "the reaction choice uses a bounded table-talk template":
    let sim = fixture()
    let seat = sim.validTargets(sim.itSeat)[0]
    let criteria = sim.jevCriteria(seat, false)
    check criteria.len == 4
    let reaction = sim.jevDecision(seat, answer(criteria, "deflect"),
      criteria, false)
    check reaction.target == -1
    check reaction.say.len > 0
