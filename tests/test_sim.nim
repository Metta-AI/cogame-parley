import std/[json, unittest]
import parley/sim

proc fixtureConfig(players: int, hp = 3, maxTurns = 60, rounds = 1): GameConfig =
  result = defaultGameConfig()
  result.hitPoints = hp
  result.maxTurns = maxTurns
  result.rounds = rounds
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
    check sim.events[0].kind == evRoundStart

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
    # Card scoring: 3 for last standing, +1 per fatal enemy shot, +1 for a
    # winning friend.
    let w = sim.winners()
    for i in 0 ..< 3:
      var expected = 0.0
      if w[i]: expected += 3
      if sim.seats[i].enemyKill: expected += 1
      if sim.seats[i].friend >= 0 and w[sim.seats[i].friend]: expected += 1
      check sim.scores()[i] == expected

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

  test "max turns ends the round with hp ranking":
    var sim = initSim(fixtureConfig(3, hp = 9, maxTurns = 2))
    sim.applyShot(0, 1)
    sim.applyShot(1, 2)
    check sim.done
    # hp: P1 9, P2 8, P3 8 -> P1 alone on top hp is "last standing".
    check sim.winners() == @[true, false, false]
    check sim.scores()[0] >= 3.0

  test "match plays rounds and accumulates":
    var match = initMatch(fixtureConfig(2, hp = 1, rounds = 3))
    var roundsPlayed = 0
    while not match.done:
      let shooter = match.sim.itSeat
      let target = match.sim.validTargets(shooter)[0]
      match.sim.applyShot(shooter, target)
      check match.sim.done
      match.finishRound()
      inc roundsPlayed
    check roundsPlayed == 3
    # Seeds 0,1,2 alternate the starting shooter: P1 shoots first in rounds
    # 1 and 3, P2 in round 2 -> P1 wins twice. Two players deal no cards,
    # so scoring is 3 points per round win.
    check match.roundWins == @[2, 1]
    check match.totals == @[6.0, 3.0]
    check match.killsTotal == @[2, 1]
    check match.turnsTotal == 3
    check match.matchWinners() == @[true, false]

  test "results json shape":
    var match = initMatch(fixtureConfig(2, hp = 1, rounds = 2))
    while not match.done:
      match.sim.applyShot(match.sim.itSeat,
        match.sim.validTargets(match.sim.itSeat)[0])
      match.finishRound()
    let results = match.resultsJson()
    check results["names"].len == 2
    check results["scores"][0].getFloat() == 3.0
    check results["scores"][1].getFloat() == 3.0
    check results["win"][0].getBool()
    check results["win"][1].getBool()
    check results["roundWins"][0].getInt() == 1
    check results["rounds"].getInt() == 2
    check results["turns"].getInt() == 2

  test "replay re-derivation matches the live match":
    var config = fixtureConfig(4, hp = 2, maxTurns = 30, rounds = 2)
    config.seed = 1
    var match = initMatch(config)
    while not match.done:
      let shooter = match.sim.itSeat
      match.sim.recordSay(shooter, "round " & $match.sim.round & " talk")
      let targets = match.sim.validTargets(shooter)
      match.sim.applyShot(shooter, targets[targets.len - 1])
      if match.sim.done:
        match.finishRound()
    let frames = replayMatch(config, match.allEvents())
    check frames.len == match.allEvents().len + 1
    let last = frames[^1]
    check last.totals == match.totals
    check last.roundWins == match.roundWins
    for index in 0 ..< 4:
      check last.sim.seats[index].hp == match.sim.seats[index].hp
      check last.sim.seats[index].alive == match.sim.seats[index].alive

  test "cards deal a friend and a distinct enemy every round":
    let config = fixtureConfig(4, rounds = 2)
    for round in 0 .. 1:
      let sim = initSim(config, round)
      for index, seat in sim.seats:
        check seat.friend != index
        check seat.enemy != index
        check seat.friend != seat.enemy
        check seat.friend in 0 .. 3
        check seat.enemy in 0 .. 3
      ## Deterministic: the same seed and round deal the same cards.
      let again = initSim(config, round)
      for index in 0 ..< 4:
        check again.seats[index].friend == sim.seats[index].friend
        check again.seats[index].enemy == sim.seats[index].enemy

  test "every cog is exactly one friend card and one enemy card":
    ## Both hands are permutations of the table, so no cog is dealt to two
    ## seats as an enemy while being nobody's friend.
    for seats in 3 .. 6:
      let config = fixtureConfig(seats, rounds = 3)
      for round in 0 .. 2:
        let sim = initSim(config, round)
        var friendCount = newSeq[int](seats)
        var enemyCount = newSeq[int](seats)
        for seat in sim.seats:
          friendCount[seat.friend].inc
          enemyCount[seat.enemy].inc
        for index in 0 ..< seats:
          check friendCount[index] == 1
          check enemyCount[index] == 1

  test "filler seats get distinct cog names, entrants keep theirs":
    ## The shape a hosted league round actually delivers: one real entrant and
    ## four seats sharing the baseline policy.
    let roster = @[
      PlayerConfig(name: "daveey"),
      PlayerConfig(name: "Baseline"),
      PlayerConfig(name: "Baseline (2)"),
      PlayerConfig(name: "Baseline (3)"),
      PlayerConfig(name: "Baseline (4)")
    ]
    let named = tableNames(roster, 42)
    check named[0] == "daveey"
    for index in 1 .. 4:
      check named[index] != roster[index].name
      check named[index] in CogNames
    ## Every seat at the table is distinguishable.
    for a in 0 ..< named.len:
      for b in a + 1 ..< named.len:
        check named[a] != named[b]
    ## Stable for a given seed, so replays and the live table agree.
    check tableNames(roster, 42) == named

  test "a table of named entrants is left alone":
    let roster = @[
      PlayerConfig(name: "daveey"),
      PlayerConfig(name: "rival"),
      PlayerConfig(name: "third")
    ]
    check tableNames(roster, 7) == @["daveey", "rival", "third"]

  test "fatally shooting your enemy scores the bonus":
    var sim = initSim(fixtureConfig(4, hp = 1))
    ## Play the round out: each "it" shoots its enemy when alive, else the
    ## first legal target.
    while not sim.done:
      let shooter = sim.itSeat
      let enemy = sim.seats[shooter].enemy
      let target =
        if sim.seats[enemy].alive and enemy != shooter: enemy
        else: sim.validTargets(shooter)[0]
      sim.applyShot(shooter, target)
    let w = sim.winners()
    var sawEnemyKill = false
    for i in 0 ..< 4:
      var expected = 0.0
      if w[i]: expected += 3
      if sim.seats[i].enemyKill:
        expected += 1
        sawEnemyKill = true
      if sim.seats[i].friend >= 0 and w[sim.seats[i].friend]: expected += 1
      check sim.scores()[i] == expected
    check sawEnemyKill

  test "events round-trip through json":
    var sim = initSim(fixtureConfig(2), round = 1)
    sim.recordSay(sim.itSeat, "bang bang")
    sim.applyShot(sim.itSeat, sim.validTargets(sim.itSeat)[0])
    for event in sim.events:
      let roundTripped = eventFromJson(event.eventToJson())
      check roundTripped == event
      check roundTripped.round == 1
