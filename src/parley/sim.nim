## Pure game rules for Parley. No IO, no networking, no LLM: the server, the
## tests, and the wasm replay viewer all drive this same module.
##
## Rules: N cogs sit around a table. One cog is "it" and holds the paintgun.
## Each turn "it" says something to the table and shoots another living cog.
## The shot cog loses 1 hp and becomes "it" — unless the shot kills it, in
## which case the shooter keeps the gun.
##
## Cards: every round each cog is secretly dealt a FRIEND and an ENEMY
## (two distinct other cogs). Round points: 3 for being last cog standing,
## 1 for fatally shooting your enemy, 1 if your friend is last standing.
## A match is `rounds` rounds; the deal reshuffles every round and match
## scores are the round points summed.

import std/[json, random, strutils], types

export types

type
  Sim* = object
    ## One round of play.
    config*: GameConfig
    round*: int
    seats*: seq[Seat]
    itSeat*: int
    turn*: int      ## completed shots this round
    done*: bool
    deathCount*: int
    events*: seq[GameEvent]

  Match* = object
    ## A full episode: `config.rounds` rounds with cumulative scoring.
    config*: GameConfig
    sim*: Sim                 ## the round in progress
    history: seq[GameEvent]   ## events of completed rounds
    totals*: seq[float]       ## summed placement scores
    roundWins*: seq[int]      ## rounds won per seat
    killsTotal*: seq[int]
    turnsTotal*: int
    done*: bool

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
  hpAfter = -1,
  friend = -1,
  enemy = -1
) =
  sim.events.add(GameEvent(
    kind: kind,
    round: sim.round,
    turn: sim.turn,
    seat: seat,
    target: target,
    text: text,
    hpAfter: hpAfter,
    friend: friend,
    enemy: enemy
  ))

proc dealCards(sim: var Sim) =
  ## Deals every seat a friend and a distinct enemy (never itself),
  ## deterministically from the seed and round so replays and re-runs agree.
  let n = sim.seats.len
  if n < 3:
    ## A friend and a distinct enemy need at least two other cogs.
    return
  var rng = initRand(int64(sim.config.seed) * 7919 + int64(sim.round) * 104729 + 17)
  for index in 0 ..< n:
    var others: seq[int]
    for other in 0 ..< n:
      if other != index:
        others.add(other)
    let friend = others[rng.rand(others.high)]
    var enemies: seq[int]
    for other in others:
      if other != friend:
        enemies.add(other)
    let enemy = enemies[rng.rand(enemies.high)]
    sim.seats[index].friend = friend
    sim.seats[index].enemy = enemy
    sim.addEvent(evDeal, index, friend = friend, enemy = enemy)

proc initSim*(config: GameConfig, round = 0): Sim =
  if config.players.len < 2:
    raise newException(ParleyError, "parley needs at least 2 players")
  result = Sim(config: config, round: round)
  for player in config.players:
    result.seats.add(Seat(
      name: player.name,
      hp: config.hitPoints,
      alive: true,
      deathIndex: -1,
      friend: -1,
      enemy: -1
    ))
  ## The seed (stepped per round) picks who wakes up holding the paintgun.
  result.itSeat = (((config.seed + round) mod result.seats.len) +
    result.seats.len) mod result.seats.len
  result.addEvent(evRoundStart, result.itSeat)
  result.dealCards()
  result.addEvent(evIt, result.itSeat)

proc winners*(sim: Sim): seq[bool]

proc scores*(sim: Sim): seq[float] =
  ## Card scoring for one round: 3 points for being last cog standing,
  ## 1 point for having fatally shot your enemy, 1 point if your friend is
  ## last cog standing. (A max-turns stop crowns the surviving cogs on top
  ## hp as "last standing".)
  result = newSeq[float](sim.seats.len)
  let winFlags = sim.winners()
  for index, seat in sim.seats:
    if winFlags[index]:
      result[index] += 3
    if seat.enemyKill:
      result[index] += 1
    if seat.friend >= 0 and winFlags[seat.friend]:
      result[index] += 1

proc winners*(sim: Sim): seq[bool] =
  ## Round winners: the living cogs on maximal hp when the round ends. A
  ## sole survivor is always the unique winner; a max-turns stop can crown
  ## ties.
  result = newSeq[bool](sim.seats.len)
  var best = -1
  for seat in sim.seats:
    if seat.alive and seat.hp > best:
      best = seat.hp
  for index, seat in sim.seats:
    result[index] = seat.alive and seat.hp == best

proc recordSay*(sim: var Sim, seat: int, text: string) =
  if sim.done or text.len == 0:
    return
  sim.addEvent(evSay, seat, text = text)

proc applyShot*(sim: var Sim, shooter, target: int) =
  ## One turn: "it" shoots a living cog. Raises on illegal shots.
  if sim.done:
    raise newException(ParleyError, "round is over")
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
    if target == sim.seats[shooter].enemy:
      sim.seats[shooter].enemyKill = true
    sim.addEvent(evDeath, target)
    ## The gun stays with the shooter: a dead cog cannot be "it".
  else:
    sim.itSeat = target
    sim.addEvent(evIt, target)

  if sim.aliveCount() <= 1 or sim.turn >= sim.config.maxTurns:
    sim.done = true

# ---- Match ------------------------------------------------------------------

proc initMatch*(config: GameConfig): Match =
  var normalized = config
  if normalized.rounds < 1:
    normalized.rounds = 1
  result = Match(
    config: normalized,
    sim: initSim(normalized, 0),
    totals: newSeq[float](normalized.players.len),
    roundWins: newSeq[int](normalized.players.len),
    killsTotal: newSeq[int](normalized.players.len)
  )

proc allEvents*(match: Match): seq[GameEvent] =
  match.history & match.sim.events

proc finishRound*(match: var Match) =
  ## Scores the finished round, emits its winner events, and either deals
  ## the next round or ends the match. Call when `match.sim.done`.
  if not match.sim.done or match.done:
    raise newException(ParleyError, "no finished round to score")
  let roundScores = match.sim.scores()
  let roundWinners = match.sim.winners()
  for index in 0 ..< match.totals.len:
    match.totals[index] += roundScores[index]
    match.killsTotal[index] += match.sim.seats[index].kills
    if roundWinners[index]:
      inc match.roundWins[index]
      match.sim.addEvent(evRoundEnd, index)
  match.turnsTotal += match.sim.turn

  if match.sim.round + 1 < match.config.rounds:
    match.history.add(match.sim.events)
    match.sim = initSim(match.config, match.sim.round + 1)
  else:
    match.done = true

proc matchWinners*(match: Match): seq[bool] =
  result = newSeq[bool](match.totals.len)
  var best = -1.0
  for total in match.totals:
    if total > best:
      best = total
  for index, total in match.totals:
    result[index] = total == best

proc resultsJson*(match: Match): JsonNode =
  let winFlags = match.matchWinners()
  var names = newJArray()
  var scoresNode = newJArray()
  var winNode = newJArray()
  var hpNode = newJArray()
  var killsNode = newJArray()
  var roundWinsNode = newJArray()
  for index, seat in match.sim.seats:
    names.add(%seat.name)
    scoresNode.add(%match.totals[index])
    winNode.add(%(match.done and winFlags[index]))
    hpNode.add(%max(seat.hp, 0))
    killsNode.add(%match.killsTotal[index])
    roundWinsNode.add(%match.roundWins[index])
  %*{
    "names": names,
    "scores": scoresNode,
    "win": winNode,
    "hp": hpNode,
    "kills": killsNode,
    "roundWins": roundWinsNode,
    "rounds": match.config.rounds,
    "turns": match.turnsTotal
  }

proc seatStates*(sim: Sim, totals: seq[float], roundWins: seq[int]): JsonNode =
  ## The seat panel every viewer draws: per-round state plus the cumulative
  ## match score and round wins for the scorebug.
  result = newJArray()
  for index, seat in sim.seats:
    result.add(%*{
      "name": seat.name,
      "hp": max(seat.hp, 0),
      "alive": seat.alive,
      "isIt": index == sim.itSeat and seat.alive and not sim.done,
      "score": if index < totals.len: totals[index] else: 0.0,
      "roundWins": if index < roundWins.len: roundWins[index] else: 0,
      "friend": seat.friend,
      "enemy": seat.enemy
    })

type
  ReplayFrame* = object
    ## One scrub position: the reconstructed round state plus cumulative
    ## match totals as of that event prefix.
    sim*: Sim
    totals*: seq[float]
    roundWins*: seq[int]

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[ReplayFrame] =
  ## Re-derives the state timeline from a recorded event log: one frame per
  ## event prefix (frames[i] = state after events[0..<i]). The replay
  ## viewers scrub through these.
  let n = config.players.len
  var frame = ReplayFrame(
    totals: newSeq[float](n),
    roundWins: newSeq[int](n)
  )
  ## itSeat starts at -1 so the pre-"it"-event frame shows nobody armed.
  frame.sim = Sim(config: config, itSeat: -1)
  for player in config.players:
    frame.sim.seats.add(Seat(
      name: player.name,
      hp: config.hitPoints,
      alive: true,
      deathIndex: -1
    ))
  result.add(frame)
  var scoredRound = -1
  for event in events:
    frame.sim.turn = event.turn
    frame.sim.round = event.round
    case event.kind
    of evRoundStart:
      ## Fresh deal: reset the per-round state, keep the match totals.
      for index in 0 ..< frame.sim.seats.len:
        frame.sim.seats[index].hp = config.hitPoints
        frame.sim.seats[index].alive = true
        frame.sim.seats[index].deathIndex = -1
        frame.sim.seats[index].kills = 0
        frame.sim.seats[index].friend = -1
        frame.sim.seats[index].enemy = -1
        frame.sim.seats[index].enemyKill = false
      frame.sim.deathCount = 0
      frame.sim.done = false
      frame.sim.itSeat = -1
    of evDeal:
      frame.sim.seats[event.seat].friend = event.friend
      frame.sim.seats[event.seat].enemy = event.enemy
    of evSay:
      discard
    of evIt:
      frame.sim.itSeat = event.seat
    of evShot:
      frame.sim.seats[event.target].hp = event.hpAfter
    of evDeath:
      frame.sim.seats[event.seat].alive = false
      frame.sim.seats[event.seat].deathIndex = frame.sim.deathCount
      inc frame.sim.deathCount
      ## The gun did not move on a lethal shot, so "it" is the shooter.
      inc frame.sim.seats[frame.sim.itSeat].kills
      if event.seat == frame.sim.seats[frame.sim.itSeat].enemy:
        frame.sim.seats[frame.sim.itSeat].enemyKill = true
    of evRoundEnd:
      frame.sim.done = true
      inc frame.roundWins[event.seat]
      if scoredRound < event.round:
        ## Fold this round's placements into the totals exactly once, even
        ## when a max-turns tie emits several roundEnd events.
        scoredRound = event.round
        let roundScores = frame.sim.scores()
        for index in 0 ..< frame.totals.len:
          frame.totals[index] += roundScores[index]
    result.add(frame)

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{
    "kind": $event.kind,
    "round": event.round,
    "turn": event.turn,
    "seat": event.seat
  }
  if event.target >= 0:
    result["target"] = %event.target
  if event.text.len > 0:
    result["text"] = %event.text
  if event.hpAfter >= 0:
    result["hpAfter"] = %event.hpAfter
  if event.friend >= 0:
    result["friend"] = %event.friend
  if event.enemy >= 0:
    result["enemy"] = %event.enemy

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(0),
    turn: node["turn"].getInt(),
    seat: node["seat"].getInt(),
    target: node{"target"}.getInt(-1),
    text: node{"text"}.getStr(""),
    hpAfter: node{"hpAfter"}.getInt(-1),
    friend: node{"friend"}.getInt(-1),
    enemy: node{"enemy"}.getInt(-1)
  )
