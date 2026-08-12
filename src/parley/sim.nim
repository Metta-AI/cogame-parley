## Pure game rules for Parley. No IO, no networking, no LLM: the server, the
## tests, and the wasm replay viewer all drive this same module.
##
## Rules: N cogs sit around a table. One cog is "it" and holds the paintgun.
## Each turn "it" says something to the table and shoots another living cog.
## The shot cog loses 1 hp and becomes "it" — unless the shot kills it, in
## which case the shooter keeps the gun. Last cog standing wins.

import std/[json, strutils], types

export types

type
  Sim* = object
    config*: GameConfig
    seats*: seq[Seat]
    itSeat*: int
    turn*: int      ## completed shots
    done*: bool
    deathCount*: int
    events*: seq[GameEvent]

proc aliveCount*(sim: Sim): int =
  for seat in sim.seats:
    if seat.alive:
      inc result

proc validTargets*(sim: Sim, shooter: int): seq[int] =
  for index, seat in sim.seats:
    if seat.alive and index != shooter:
      result.add(index)

proc addEvent(
  sim: var Sim,
  kind: EventKind,
  seat: int,
  target = -1,
  text = "",
  hpAfter = -1
) =
  sim.events.add(GameEvent(
    kind: kind,
    turn: sim.turn,
    seat: seat,
    target: target,
    text: text,
    hpAfter: hpAfter
  ))

proc initSim*(config: GameConfig): Sim =
  if config.players.len < 2:
    raise newException(ParleyError, "parley needs at least 2 players")
  result = Sim(config: config, itSeat: 0)
  for player in config.players:
    result.seats.add(Seat(
      name: player.name,
      hp: config.hitPoints,
      alive: true,
      deathIndex: -1
    ))
  ## The seed picks who wakes up holding the paintgun.
  result.itSeat = ((config.seed mod result.seats.len) +
    result.seats.len) mod result.seats.len
  result.addEvent(evStart, result.itSeat)
  result.addEvent(evIt, result.itSeat)

proc scores*(sim: Sim): seq[float] =
  ## Placement scores: the first cog eliminated scores 0, the next 1, and so
  ## on. Survivors continue the sequence above every dead cog, ranked by
  ## remaining hp; survivors on equal hp share the same score.
  result = newSeq[float](sim.seats.len)
  for index, seat in sim.seats:
    if not seat.alive:
      result[index] = float(seat.deathIndex)
    else:
      var below = 0
      for other in sim.seats:
        if other.alive and other.hp < seat.hp:
          inc below
      result[index] = float(sim.deathCount + below)

proc winners*(sim: Sim): seq[bool] =
  ## Winners are the living cogs on maximal hp when the game ends. A sole
  ## survivor is always the unique winner; a max-turns stop can crown ties.
  result = newSeq[bool](sim.seats.len)
  var best = -1
  for seat in sim.seats:
    if seat.alive and seat.hp > best:
      best = seat.hp
  for index, seat in sim.seats:
    result[index] = seat.alive and seat.hp == best

proc finish(sim: var Sim) =
  sim.done = true
  sim.addEvent(evEnd, sim.itSeat)

proc recordSay*(sim: var Sim, seat: int, text: string) =
  if sim.done or text.len == 0:
    return
  sim.addEvent(evSay, seat, text = text)

proc applyShot*(sim: var Sim, shooter, target: int) =
  ## One turn: "it" shoots a living cog. Raises on illegal shots.
  if sim.done:
    raise newException(ParleyError, "game is over")
  if shooter != sim.itSeat:
    raise newException(ParleyError, "only \"it\" shoots")
  if target < 0 or target >= sim.seats.len:
    raise newException(ParleyError, "no such seat: " & $target)
  if target == shooter:
    raise newException(ParleyError, "cannot shoot yourself")
  if not sim.seats[target].alive:
    raise newException(ParleyError, "target is already out")

  inc sim.turn
  dec sim.seats[target].hp
  sim.addEvent(evShot, shooter, target, hpAfter = sim.seats[target].hp)

  if sim.seats[target].hp <= 0:
    sim.seats[target].alive = false
    sim.seats[target].deathIndex = sim.deathCount
    inc sim.deathCount
    inc sim.seats[shooter].kills
    sim.addEvent(evDeath, target)
    ## The gun stays with the shooter: a dead cog cannot be "it".
  else:
    sim.itSeat = target
    sim.addEvent(evIt, target)

  if sim.aliveCount() <= 1 or sim.turn >= sim.config.maxTurns:
    sim.finish()

proc resultsJson*(sim: Sim): JsonNode =
  let scoreValues = sim.scores()
  let winFlags = sim.winners()
  var names = newJArray()
  var scoresNode = newJArray()
  var winNode = newJArray()
  var hpNode = newJArray()
  var killsNode = newJArray()
  for index, seat in sim.seats:
    names.add(%seat.name)
    scoresNode.add(%scoreValues[index])
    winNode.add(%(sim.done and winFlags[index]))
    hpNode.add(%max(seat.hp, 0))
    killsNode.add(%seat.kills)
  %*{
    "names": names,
    "scores": scoresNode,
    "win": winNode,
    "hp": hpNode,
    "kills": killsNode,
    "turns": sim.turn
  }

proc seatStates*(sim: Sim): JsonNode =
  ## The seat panel every viewer draws: name, hp, alive, isIt.
  result = newJArray()
  for index, seat in sim.seats:
    result.add(%*{
      "name": seat.name,
      "hp": max(seat.hp, 0),
      "alive": seat.alive,
      "isIt": (not sim.done or sim.aliveCount() > 1 or seat.alive) and
        index == sim.itSeat and seat.alive
    })

proc replaySim*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log: one Sim snapshot
  ## per event prefix (states[i] = state after events[0..<i]). The replay
  ## viewers scrub through these.
  ## itSeat starts at -1 so the pre-"it"-event frame shows nobody armed.
  var sim = Sim(config: config, itSeat: -1)
  for player in config.players:
    sim.seats.add(Seat(
      name: player.name,
      hp: config.hitPoints,
      alive: true,
      deathIndex: -1
    ))
  result.add(sim)
  for event in events:
    sim.turn = event.turn
    case event.kind
    of evStart, evSay:
      discard
    of evIt:
      sim.itSeat = event.seat
    of evShot:
      sim.seats[event.target].hp = event.hpAfter
    of evDeath:
      sim.seats[event.seat].alive = false
      sim.seats[event.seat].deathIndex = sim.deathCount
      inc sim.deathCount
      ## The gun did not move on a lethal shot, so "it" is the shooter.
      inc sim.seats[sim.itSeat].kills
    of evEnd:
      sim.done = true
    result.add(sim)

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{
    "kind": $event.kind,
    "turn": event.turn,
    "seat": event.seat
  }
  if event.target >= 0:
    result["target"] = %event.target
  if event.text.len > 0:
    result["text"] = %event.text
  if event.hpAfter >= 0:
    result["hpAfter"] = %event.hpAfter

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    turn: node["turn"].getInt(),
    seat: node["seat"].getInt(),
    target: node{"target"}.getInt(-1),
    text: node{"text"}.getStr(""),
    hpAfter: node{"hpAfter"}.getInt(-1)
  )
