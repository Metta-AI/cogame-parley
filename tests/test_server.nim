import std/unittest
include ../src/parley/server

suite "player state":
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
    let snapshot = game.playerFrameJson(0)
    check snapshot["rounds"].kind == JNull
    check snapshot["survivors"].kind == JNull
    check not snapshot.hasKey("policyNames")
    check snapshot["seats"][0]["friend"].getInt() >= 0
    for index in 1 ..< 4:
      check snapshot["seats"][index]["friend"].getInt() == -1
      check snapshot["seats"][index]["enemy"].getInt() == -1
    for event in snapshot["events"]:
      check event["kind"].getStr() != "deal" or event["seat"].getInt() == 0
