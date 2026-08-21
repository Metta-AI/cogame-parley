import std/[json, random, unittest]
import parley/sim

proc fixtureConfig(players: int, hp = 3, rounds = 1,
    survivors = 1): GameConfig =
  result = defaultGameConfig()
  result.hitPoints = hp
  result.rounds = rounds
  result.survivors = survivors
  ## Pinned, so these tests exercise the rules rather than the per-episode draw.
  result.sampled = true
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

  test "no turn count ends a round: only the survivor count does":
    ## A deep-hp table used to stop on the turn ceiling and crown whoever was
    ## least shot. Now it plays out, however long that takes.
    var sim = initSim(fixtureConfig(3, hp = 9))
    sim.applyShot(0, 1)
    sim.applyShot(1, 2)
    check not sim.done
    check sim.aliveCount() == 3
    while not sim.done:
      sim.applyShot(sim.itSeat, sim.validTargets(sim.itSeat)[0])
    ## The round ended because the table reached one survivor, and that
    ## survivor is the winner outright — no hp ranking involved.
    check sim.aliveCount() == 1
    var crowned = 0
    for index, won in sim.winners():
      if won:
        crowned.inc
        check sim.seats[index].alive
    check crowned == 1

  test "a round never outruns its turn bound":
    ## roundTurnBound is what the episode budget is priced off, so it has to
    ## hold for every table shape, not just the common one.
    for seats in 3 .. 5:
      for hp in 1 .. 5:
        for survivors in 1 .. seats - 1:
          var sim = initSim(fixtureConfig(seats, hp = hp, survivors = survivors))
          while not sim.done:
            sim.applyShot(sim.itSeat, sim.validTargets(sim.itSeat)[^1])
          check sim.turn <= roundTurnBound(seats, hp, survivors)
          check sim.aliveCount() <= survivors

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
    ## Scores are the share of the episode ceiling (5 points x 2 rounds).
    check results["pointsAvailable"].getFloat() == 10.0
    check results["rawScores"][0].getFloat() == 3.0
    check results["scores"][0].getFloat() == 0.3
    check results["scores"][1].getFloat() == 0.3
    check results["win"][0].getBool()
    check results["win"][1].getBool()
    check results["roundWins"][0].getInt() == 1
    check results["rounds"].getInt() == 2
    check results["turns"].getInt() == 2

  test "replay re-derivation matches the live match":
    var config = fixtureConfig(4, hp = 2, rounds = 2)
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

  test "every seat plays under an anonymous cog name":
    ## Policy names must never reach the table: a name like "daveey" or
    ## "Baseline (3)" leaks who is behind a seat into the LLM transcripts.
    let roster = @[
      PlayerConfig(name: "daveey"),
      PlayerConfig(name: "Baseline"),
      PlayerConfig(name: "Baseline (2)"),
      PlayerConfig(name: "rival"),
      PlayerConfig(name: "third")
    ]
    let named = tableNames(roster, 42)
    for index in 0 ..< roster.len:
      check named[index] != roster[index].name
      check named[index] in CogNames
    ## Every seat at the table is distinguishable.
    for a in 0 ..< named.len:
      for b in a + 1 ..< named.len:
        check named[a] != named[b]
    ## Stable for a given seed, so replays and the live table agree.
    check tableNames(roster, 42) == named

  test "results carry policy names, not the table aliases":
    ## The league attributes scores by policy name; the aliases are in-game
    ## only.
    var match = initMatch(fixtureConfig(2, hp = 1, rounds = 1))
    while not match.done:
      match.sim.applyShot(match.sim.itSeat,
        match.sim.validTargets(match.sim.itSeat)[0])
      match.finishRound()
    let results = match.resultsJson()
    check results["names"][0].getStr() == "P1"
    check results["names"][1].getStr() == "P2"
    check match.sim.seats[0].name != "P1"

  test "it can pass up to maxSkips times, then must shoot":
    var config = fixtureConfig(3)
    config.maxSkips = 2
    var sim = initSim(config)
    let it = sim.itSeat
    check sim.skipsLeft() == 2
    sim.applySkip(it)
    check sim.itSeat == it       # the gun stays put
    check sim.turn == 0          # no turn elapses
    check not sim.done
    check sim.events[^1].kind == evSkip
    sim.applySkip(it)
    check sim.skipsLeft() == 0
    expect ParleyError:
      sim.applySkip(it)          # allowance spent
    ## A shot still works and the round proceeds normally.
    let target = sim.validTargets(it)[0]
    sim.applyShot(it, target)
    check sim.turn == 1

  test "only it can pass, and never after the round ends":
    var sim = initSim(fixtureConfig(3))
    for seat in 0 ..< 3:
      if seat != sim.itSeat:
        expect ParleyError:
          sim.applySkip(seat)
    var over = initSim(fixtureConfig(2, hp = 1))
    over.applyShot(over.itSeat, over.validTargets(over.itSeat)[0])
    check over.done
    expect ParleyError:
      over.applySkip(over.itSeat)

  test "the pass allowance resets every round":
    var config = fixtureConfig(2, hp = 1, rounds = 2)
    config.maxSkips = 1
    var match = initMatch(config)
    match.sim.applySkip(match.sim.itSeat)
    check match.sim.skipsLeft() == 0
    match.sim.applyShot(match.sim.itSeat,
      match.sim.validTargets(match.sim.itSeat)[0])
    match.finishRound()
    check match.sim.skipsLeft() == 1

  test "skip events replay and round-trip":
    var config = fixtureConfig(3, hp = 2)
    var sim = initSim(config)
    sim.recordSay(sim.itSeat, "let's talk first")
    sim.applySkip(sim.itSeat)
    sim.applyShot(sim.itSeat, sim.validTargets(sim.itSeat)[0])
    for event in sim.events:
      check eventFromJson(event.eventToJson()) == event
    let frames = replayMatch(config, sim.events)
    check frames[^1].sim.skips == 1
    for index in 0 ..< 3:
      check frames[^1].sim.seats[index].hp == sim.seats[index].hp

  test "long tables price the pass allowance out":
    for seed in 0 .. 60:
      var config = fixtureConfig(5)
      config.sampled = false
      config.seed = seed
      let drawn = sampleEpisode(config)
      check drawn.maxSkips <= config.maxSkips
      if drawn.rounds > 10:
        check drawn.maxSkips == 0

  test "every drawn episode fits the call budget":
    ## The budget is what stops a hosted episode outliving the platform's
    ## timeout. Rounds are now what it buys, so it has to hold on the ROUND
    ## COUNT for every seed - there is no per-round cut-off left to fall back
    ## on if the arithmetic is wrong.
    for seats in 3 .. 6:
      for seed in 0 .. 120:
        var config = fixtureConfig(seats)
        config.sampled = false
        config.seed = seed
        let drawn = sampleEpisode(config)
        check drawn.rounds >= 1
        check episodeCallCost(drawn.rounds, seats, drawn.hitPoints,
          drawn.survivors, drawn.maxReactions, drawn.maxSkips) <=
          EpisodeCallBudget

  test "the budget buys as many whole rounds as it can afford":
    ## Spending down to one round when a longer table fits would quietly throw
    ## away the variety the draw asked for, so `affordRounds` has to return the
    ## LARGEST affordable count, never merely an affordable one.
    for drawnRounds in RoundsMin .. RoundsMax:
      for hp in HitPointsMin .. HitPointsMax:
        for survivors in 1 .. 3:
          let got = affordRounds(drawnRounds, 5, hp, survivors, 3, 3)
          ## What it picked is affordable, and never more than was drawn.
          check got.rounds >= 1
          check got.rounds <= drawnRounds
          check episodeCallCost(got.rounds, 5, hp, survivors,
            got.reactions, got.skips) <= EpisodeCallBudget
          ## ...and nothing larger, up to the drawn count, was affordable.
          for candidate in got.rounds + 1 .. drawnRounds:
            let (reactions, skips) =
              if candidate <= 5: (3, 3)
              elif candidate <= 10: (1, 1)
              else: (0, 0)
            check episodeCallCost(candidate, 5, hp, survivors,
              reactions, skips) > EpisodeCallBudget

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


  test "the survivor count ends the round and crowns everyone left":
    ## Two survivors: the round stops with two cogs standing and both win it.
    var match = initMatch(fixtureConfig(4, hp = 1, survivors = 2))
    while not match.sim.done:
      match.sim.applyShot(match.sim.itSeat,
        match.sim.validTargets(match.sim.itSeat)[0])
    check match.sim.aliveCount() == 2
    let winFlags = match.sim.winners()
    var winners = 0
    for index, seat in match.sim.seats:
      if winFlags[index]:
        winners.inc
        check seat.alive
    check winners == 2

  test "a whole sampled episode plays every round to a verdict":
    ## End to end on real draws: sample the table the way an episode does,
    ## play it out, and check that no round ended on anything but the survivor
    ## count - and that every crowned cog is one that was actually standing.
    for seed in 0 .. 80:
      var config = fixtureConfig(5)
      config.sampled = false
      config.seed = seed
      let drawn = sampleEpisode(config)
      var match = initMatch(drawn)
      var rng = initRand(seed)
      var guard = 0
      while not match.done:
        let shooter = match.sim.itSeat
        let targets = match.sim.validTargets(shooter)
        match.sim.applyShot(shooter, targets[rng.rand(targets.len - 1)])
        guard.inc
        check guard <= drawn.rounds *
          roundTurnBound(5, drawn.hitPoints, drawn.survivors)
        if match.sim.done:
          ## The round stopped because the table reached its survivor count,
          ## never because a turn counter ran out.
          check match.sim.aliveCount() == max(drawn.survivors, 1)
          for index, won in match.sim.winners():
            if won: check match.sim.seats[index].alive
          match.finishRound()
      check match.roundsPlayed == drawn.rounds
      let results = match.resultsJson()
      check results["turns"].getInt() > 0
      check results["pointsAvailable"].getFloat() ==
        PointsPerRound * float(drawn.rounds)

  test "every episode draws a table inside the published ranges":
    for seed in 0 .. 60:
      var config = fixtureConfig(5)
      config.sampled = false
      config.seed = seed
      let drawn = sampleEpisode(config)
      check drawn.rounds in RoundsMin .. RoundsMax
      check drawn.survivors in SurvivorsMin .. SurvivorsMax
      check drawn.hitPoints in HitPointsMin .. HitPointsMax
      ## A round must be able to end while cogs are still standing.
      check drawn.survivors < config.players.len
      check drawn.sampled
      ## Same seed, same table - a replay re-reads rather than re-rolls.
      check sampleEpisode(config) == drawn

  test "a drawn table is never re-drawn":
    var config = fixtureConfig(5)
    config.sampled = false
    config.seed = 3
    let once = sampleEpisode(config)
    ## Feeding a drawn config back through leaves every value alone, which is
    ## what keeps a replay's header honest.
    check sampleEpisode(once) == once

  test "both known flags get drawn over a spread of seeds":
    var sawKnown, sawHidden: bool
    for seed in 0 .. 60:
      var config = fixtureConfig(5)
      config.sampled = false
      config.seed = seed
      let drawn = sampleEpisode(config)
      if drawn.roundsKnown: sawKnown = true else: sawHidden = true
    check sawKnown
    check sawHidden

  test "normalization makes differently-shaped episodes comparable":
    ## The ceiling tracks the rounds actually PLAYED, so a table that ran its
    ## full length and one cut short by the deadline are both scored against
    ## what they had the chance to win.
    for rounds in [3, 11, 20]:
      var match = initMatch(fixtureConfig(2, hp = 1, rounds = rounds))
      while not match.done:
        match.sim.applyShot(match.sim.itSeat,
          match.sim.validTargets(match.sim.itSeat)[0])
        match.finishRound()
      check match.roundsPlayed == rounds
      check match.pointsAvailable() == float(rounds) * PointsPerRound
      for score in match.resultsJson()["scores"]:
        check score.getFloat() <= 1.0

  test "a match cut short is scored over the rounds it played":
    var match = initMatch(fixtureConfig(2, hp = 1, rounds = 12))
    for _ in 0 ..< 3:
      match.sim.applyShot(match.sim.itSeat,
        match.sim.validTargets(match.sim.itSeat)[0])
      match.finishRound()
    match.endMatchEarly()
    check match.done
    check match.roundsPlayed == 3
    ## Three rounds played, so the ceiling is three rounds - not the twelve
    ## drawn. Dividing by the draw would punish a table for rounds the
    ## deadline took away from it.
    check match.pointsAvailable() == 3.0 * PointsPerRound
    for score in match.resultsJson()["scores"]:
      check score.getFloat() <= 1.0

  test "events round-trip through json":
    var sim = initSim(fixtureConfig(2), round = 1)
    sim.recordSay(sim.itSeat, "bang bang")
    sim.applyShot(sim.itSeat, sim.validTargets(sim.itSeat)[0])
    for event in sim.events:
      let roundTripped = eventFromJson(event.eventToJson())
      check roundTripped == event
      check roundTripped.round == 1
