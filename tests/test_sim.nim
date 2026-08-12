import std/[json, unittest]
import parley/sim

proc fixtureConfig(players: int, hp = 3, maxTurns = 60): GameConfig =
  result = defaultGameConfig()
  result.hitPoints = hp
  result.maxTurns = maxTurns
  for index in 0 ..< players:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

suite "parley sim":
  test "seed picks the starting it":
    var config = fixtureConfig(4)
    config.seed = 6
    let sim = initSim(config)
    check sim.itSeat == 2
    check sim.aliveCount() == 4

  test "shot passes the gun to the target":
    var sim = initSim(fixtureConfig(3))
    sim.applyShot(0, 1)
    check sim.seats[1].hp == 2
    check sim.itSeat == 1
    check sim.turn == 1
    check not sim.done

  test "kill keeps the gun with the shooter":
    var sim = initSim(fixtureConfig(3, hp = 1))
    sim.applyShot(0, 1)
    check not sim.seats[1].alive
    check sim.seats[1].deathIndex == 0
    check sim.seats[0].kills == 1
    check sim.itSeat == 0
    check not sim.done  # two cogs still standing
    sim.applyShot(0, 2)
    check sim.done
    check sim.winners() == @[true, false, false]
    check sim.scores() == @[2.0, 0.0, 1.0]

  test "illegal shots raise":
    var sim = initSim(fixtureConfig(3))
    expect ParleyError:
      sim.applyShot(1, 0)  # not it
    expect ParleyError:
      sim.applyShot(0, 0)  # self
    var killer = initSim(fixtureConfig(3, hp = 1))
    killer.applyShot(0, 1)
    expect ParleyError:
      killer.applyShot(0, 1)  # already dead

  test "max turns ends the game with hp ranking":
    var sim = initSim(fixtureConfig(3, hp = 9, maxTurns = 2))
    sim.applyShot(0, 1)
    sim.applyShot(1, 2)
    check sim.done
    # hp: P1 9, P2 8, P3 8 -> P1 wins; P2/P3 share the lower placement.
    check sim.winners() == @[true, false, false]
    check sim.scores() == @[2.0, 0.0, 0.0]

  test "results json shape":
    var sim = initSim(fixtureConfig(2, hp = 1))
    sim.recordSay(0, "any last words?")
    sim.applyShot(0, 1)
    let results = sim.resultsJson()
    check results["names"].len == 2
    check results["scores"][0].getFloat() == 1.0
    check results["win"][0].getBool()
    check not results["win"][1].getBool()
    check results["kills"][0].getInt() == 1
    check results["turns"].getInt() == 1

  test "replay re-derivation matches the live sim":
    var config = fixtureConfig(4, hp = 2, maxTurns = 30)
    config.seed = 1
    var sim = initSim(config)
    sim.recordSay(1, "not me, shoot P3!")
    sim.applyShot(1, 2)
    sim.recordSay(2, "traitors, all of you")
    sim.applyShot(2, 3)
    sim.applyShot(3, 2)  # kills P3
    let states = replaySim(config, sim.events)
    check states.len == sim.events.len + 1
    let last = states[^1]
    check last.itSeat == sim.itSeat
    check last.deathCount == sim.deathCount
    for index in 0 ..< 4:
      check last.seats[index].hp == sim.seats[index].hp
      check last.seats[index].alive == sim.seats[index].alive

  test "events round-trip through json":
    var sim = initSim(fixtureConfig(2))
    sim.recordSay(0, "bang bang")
    sim.applyShot(0, 1)
    for event in sim.events:
      let roundTripped = eventFromJson(event.eventToJson())
      check roundTripped == event
