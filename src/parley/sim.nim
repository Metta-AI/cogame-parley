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

import std/[json, random, sequtils, strutils], types

export types

const
  ## Per-episode sample ranges. Rounds and survivor count are also either told
  ## to the table or withheld, which is itself drawn per episode.
  RoundsMin* = 3
  RoundsMax* = 20
  SurvivorsMin* = 1
  SurvivorsMax* = 3
  HitPointsMin* = 2
  HitPointsMax* = 5
  ## The most one seat can bank in a round: survive (3) + fatally shoot its
  ## enemy (1) + its friend survives (1).
  PointsPerRound* = 5.0
  ## An episode's whole model-call allowance. A hosted episode is killed if it
  ## outlives the platform's artifact timeout, so the budget has to sit on the
  ## EPISODE rather than the round: a 20-round draw would otherwise run ~7x a
  ## 3-round one and time out instead of finishing.
  ##
  ## Counted in CALLS, not turns, because a turn is not a fixed cost — it is
  ## one call for IT plus one per reacting cog. Budgeting turns alone left the
  ## expense hiding in the reactions and blew the ceiling at LOW round counts,
  ## where chatter is cheapest to allow and therefore most of it happens.
  EpisodeCallBudget* = 240
  MinRoundTurns* = 6
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000

type
  Sim* = object
    ## One round of play.
    config*: GameConfig
    round*: int
    seats*: seq[Seat]
    itSeat*: int
    turn*: int      ## completed shots this round
    skips*: int     ## times "it" has held fire this round
    done*: bool
    deathCount*: int
    events*: seq[GameEvent]

  Match* = object
    ## A full episode: `config.rounds` rounds with cumulative scoring.
    config*: GameConfig
    sim*: Sim                 ## the round in progress
    history: seq[GameEvent]   ## events of completed rounds
    totals*: seq[float]       ## summed round points
    roundWins*: seq[int]      ## rounds won per seat (3 pts each)
    friendPoints*: seq[int]   ## rounds where the seat's friend won (1 pt each)
    foePoints*: seq[int]      ## rounds where the seat fatally shot its enemy
    killsTotal*: seq[int]
    turnsTotal*: int
    roundsPlayed*: int   ## completed rounds; may fall short of config.rounds
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
  enemy = -1,
  points = 0
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
    enemy: enemy,
    points: points
  ))

proc derangement(rng: var Rand, n: int, avoid: seq[int] = @[]): seq[int] =
  ## A permutation of 0..<n where no seat maps to itself, nor to the seat at the
  ## same index in `avoid`. Rejection sampling: the constraints are loose enough
  ## at n >= 3 that a valid shuffle turns up in a handful of tries.
  for attempt in 0 .. 999:
    result = toSeq(0 ..< n)
    rng.shuffle(result)
    var ok = true
    for index in 0 ..< n:
      if result[index] == index or (avoid.len == n and result[index] == avoid[index]):
        ok = false
        break
    if ok:
      return
  ## Fall back to the rotation, which is a derangement by construction and
  ## distinct from `avoid` whenever `avoid` is the other rotation.
  result = newSeq[int](n)
  let step = if avoid.len == n: 2 else: 1
  for index in 0 ..< n:
    result[index] = (index + step) mod n

proc dealCards(sim: var Sim) =
  ## Deals every seat a friend and a distinct enemy (never itself),
  ## deterministically from the seed and round so replays and re-runs agree.
  ##
  ## Both hands are dealt as PERMUTATIONS of the table, not per-seat draws:
  ## every cog is exactly one cog's friend and exactly one cog's enemy. Drawing
  ## each seat's cards independently would let a cog be nobody's friend while
  ## carrying two cogs' enemy cards, which reads as a bug at the table and
  ## quietly skews the round's scoring toward whoever drew the popular target.
  let n = sim.seats.len
  if n < 3:
    ## A friend and a distinct enemy need at least two other cogs.
    return
  var rng = initRand(int64(sim.config.seed) * 7919 + int64(sim.round) * 104729 + 17)
  let friends = derangement(rng, n)
  let enemies = derangement(rng, n, friends)
  for index in 0 ..< n:
    sim.seats[index].friend = friends[index]
    sim.seats[index].enemy = enemies[index]
    sim.addEvent(evDeal, index, friend = friends[index], enemy = enemies[index])

const CogNames* = [
  "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
  "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
]

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays and
  ## the live table agree. A policy name at the table leaks strategy ("that's
  ## the champion", "those four are baseline clones") straight into the LLMs'
  ## transcripts; the viewers map seats back to policy names for spectators.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Draws this episode's table rules from the seed. Every seat plays the same
  ## table, and a replay carries the drawn values in its config, so the server,
  ## the tests and the wasm re-derivation all agree without re-rolling.
  ##
  ## Idempotent: a config that already carries a draw (a replay being re-read,
  ## or an operator pinning values by hand) is returned untouched.
  result = config
  if result.sampled:
    return
  var rng = initRand(int64(config.seed) * 2654435761 + 1013904223)
  result.rounds = rng.rand(RoundsMin .. RoundsMax)
  result.survivors = rng.rand(SurvivorsMin .. SurvivorsMax)
  result.hitPoints = rng.rand(HitPointsMin .. HitPointsMax)
  result.roundsKnown = rng.rand(1) == 1
  result.survivorsKnown = rng.rand(1) == 1
  ## A round has to be able to END: with N seats we can never get below one
  ## survivor per seat, and the cards need at least three cogs at the table.
  let seats = config.players.len
  if seats > 0:
    result.survivors = min(result.survivors, max(seats - 1, 1))

  ## Fit the drawn table into one episode's call budget.
  ##
  ## Reactions first, since they set what a turn costs. They are table flavour
  ## rather than the game itself, so a long match spends its allowance on
  ## playing more rounds instead of on more chatter per shot.
  result.maxReactions =
    if result.rounds <= 5: config.maxReactions
    elif result.rounds <= 10: min(config.maxReactions, 1)
    else: 0
  result.reactions = result.maxReactions > 0

  ## Passes are extra conversation turns, so they ladder down with the round
  ## count exactly like reactions do: chatter is cheapest to allow on a short
  ## table and priced out of a long one.
  result.maxSkips =
    if result.rounds <= 5: config.maxSkips
    elif result.rounds <= 10: min(config.maxSkips, 1)
    else: 0

  ## Then turns, from what those calls cost. A round also never needs more
  ## shots than it takes to knock the table down to its survivor count, so cap
  ## there too rather than burning the configured ceiling on a decided round.
  ## A pass costs a full turn's calls without advancing the round, so each
  ## round's pass allowance is paid for out of its shot turns.
  let callsPerTurn = 1 + result.maxReactions
  let affordable =
    EpisodeCallBudget div (result.rounds * callsPerTurn) - result.maxSkips
  let decisive = max(seats - result.survivors, 1) * max(result.hitPoints, 1) + 4
  result.maxTurns = max(
    min(min(config.maxTurns, decisive), affordable), MinRoundTurns)

  ## Spectator pacing is a fixed sleep per turn, so on a long table it stops
  ## being pacing and becomes most of the episode's wall clock. Spread a fixed
  ## allowance across the turns this table can actually play.
  let plannedTurns =
    max(result.rounds * (result.maxTurns + result.maxSkips), 1)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div plannedTurns)
  result.sampled = true

proc initSim*(config: GameConfig, round = 0): Sim =
  if config.players.len < 2:
    raise newException(ParleyError, "parley needs at least 2 players")
  result = Sim(config: config, round: round)
  let names = tableNames(config.players, config.seed)
  for index, player in config.players:
    result.seats.add(Seat(
      name: names[index],
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
  ## Card scoring for one round: 3 points for surviving the round, 1 point for
  ## having fatally shot your enemy, 1 point if your friend survived. Every
  ## survivor takes the full 3, so a round played to three survivors pays out
  ## more than one played to a sole winner.
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
  ## Round winners: the cogs left standing. When the round ran to its natural
  ## end every survivor won it outright, however much paint they took — the
  ## survivor count IS the win condition. Only a max-turns stop, which leaves
  ## more cogs alive than the table was playing for, falls back to ranking the
  ## living on hp (and can crown ties).
  result = newSeq[bool](sim.seats.len)
  let living = sim.aliveCount()
  if living <= max(sim.config.survivors, 1):
    for index, seat in sim.seats:
      result[index] = seat.alive
    return
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

proc skipsLeft*(sim: Sim): int =
  max(sim.config.maxSkips - sim.skips, 0)

proc applySkip*(sim: var Sim, shooter: int) =
  ## "It" holds its fire to buy the table another exchange of words. The gun
  ## stays put and no turn elapses, so the allowance is bounded per round
  ## (config.maxSkips) — talk can never stall the round out.
  if sim.done:
    raise newException(ParleyError, "round is over")
  if shooter != sim.itSeat:
    raise newException(ParleyError, "only \"it\" can pass")
  if sim.skipsLeft() <= 0:
    raise newException(ParleyError, "no passes left this round")
  inc sim.skips
  sim.addEvent(evSkip, shooter)

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
    sim.addEvent(evDeath, target)
    if target == sim.seats[shooter].enemy:
      sim.seats[shooter].enemyKill = true
      ## The FOE point lands the moment the fatal shot does.
      sim.addEvent(evScore, shooter, target, points = 1, text = "foe")
    ## The gun stays with the shooter: a dead cog cannot be "it".
  else:
    sim.itSeat = target
    sim.addEvent(evIt, target)

  if sim.aliveCount() <= max(sim.config.survivors, 1) or
      sim.turn >= sim.config.maxTurns:
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
    friendPoints: newSeq[int](normalized.players.len),
    foePoints: newSeq[int](normalized.players.len),
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
    if match.sim.seats[index].enemyKill:
      inc match.foePoints[index]
    let friend = match.sim.seats[index].friend
    if friend >= 0 and roundWinners[friend]:
      inc match.friendPoints[index]
    if roundWinners[index]:
      inc match.roundWins[index]
      match.sim.addEvent(evRoundEnd, index)
  ## Round-end score deltas, after the verdict lines: survivor points for
  ## the winners, friend points for everyone whose friend made it.
  for index in 0 ..< match.totals.len:
    if roundWinners[index]:
      match.sim.addEvent(evScore, index, points = 3, text = "survivor")
  for index in 0 ..< match.totals.len:
    let friend = match.sim.seats[index].friend
    if friend >= 0 and roundWinners[friend]:
      match.sim.addEvent(evScore, index, friend, points = 1, text = "friend")
  match.turnsTotal += match.sim.turn
  match.roundsPlayed.inc

  if match.sim.round + 1 < match.config.rounds:
    match.history.add(match.sim.events)
    match.sim = initSim(match.config, match.sim.round + 1)
  else:
    match.done = true

proc endMatchEarly*(match: var Match) =
  ## Stop after the round just scored. The hosted platform kills an episode
  ## that outlives its timeout and keeps NOTHING — no results, no replay — so
  ## a short honest match always beats a long one that never lands.
  match.done = true

proc matchWinners*(match: Match): seq[bool] =
  result = newSeq[bool](match.totals.len)
  var best = -1.0
  for total in match.totals:
    if total > best:
      best = total
  for index, total in match.totals:
    result[index] = total == best

proc pointsAvailable*(match: Match): float =
  ## Every point one seat could have banked this episode. Episodes no longer
  ## play the same table — rounds and the survivor count are drawn per episode
  ## — so raw totals are not comparable between them: a 20-round table simply
  ## pays out more than a 3-round one. Dividing by this ceiling is what makes
  ## an episode's result mean the same thing as any other episode's.
  ##
  ## Measured against the rounds actually PLAYED. A match cut short by the
  ## episode deadline banked points over fewer rounds than it drew, and
  ## dividing those by the drawn count would score the table as though it had
  ## thrown away rounds it never got to play.
  PointsPerRound * float(max(match.roundsPlayed, 1))

proc resultsJson*(match: Match): JsonNode =
  let winFlags = match.matchWinners()
  let available = match.pointsAvailable()
  var names = newJArray()
  var scoresNode = newJArray()
  var winNode = newJArray()
  var hpNode = newJArray()
  var killsNode = newJArray()
  var roundWinsNode = newJArray()
  var friendNode = newJArray()
  var foeNode = newJArray()
  var rawNode = newJArray()
  for index, seat in match.sim.seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%match.config.players[index].name)
    ## `scores` is the normalized share of the episode's ceiling so the league
    ## can rank across differently-shaped tables; the raw points ride along.
    scoresNode.add(%(match.totals[index] / available))
    rawNode.add(%match.totals[index])
    winNode.add(%(match.done and winFlags[index]))
    hpNode.add(%max(seat.hp, 0))
    killsNode.add(%match.killsTotal[index])
    roundWinsNode.add(%match.roundWins[index])
    friendNode.add(%match.friendPoints[index])
    foeNode.add(%match.foePoints[index])
  %*{
    "names": names,
    "scores": scoresNode,
    "win": winNode,
    "hp": hpNode,
    "kills": killsNode,
    "roundWins": roundWinsNode,
    "friendPoints": friendNode,
    "foePoints": foeNode,
    "rawScores": rawNode,
    "pointsAvailable": available,
    "rounds": match.config.rounds,
    "survivors": match.config.survivors,
    "hitPoints": match.config.hitPoints,
    "roundsKnown": match.config.roundsKnown,
    "survivorsKnown": match.config.survivorsKnown,
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
      "enemy": seat.enemy,
      "enemyDone": seat.enemyKill
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
      frame.sim.skips = 0
      frame.sim.done = false
      frame.sim.itSeat = -1
    of evDeal:
      frame.sim.seats[event.seat].friend = event.friend
      frame.sim.seats[event.seat].enemy = event.enemy
    of evSay:
      discard
    of evSkip:
      inc frame.sim.skips
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
    of evScore:
      frame.totals[event.seat] += float(event.points)
    of evRoundEnd:
      frame.sim.done = true
      inc frame.roundWins[event.seat]
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
  if event.points != 0:
    result["points"] = %event.points

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
    enemy: node{"enemy"}.getInt(-1),
    points: node{"points"}.getInt(0)
  )
