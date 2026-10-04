## Pure game rules for Parley. No IO, no networking, no LLM: the server, the
## tests, and the wasm replay viewer all drive this same module.
##
## Rules: N cogs sit around a table. One cog is "it" and holds the paintgun.
## Each turn "it" says something to the table and shoots another living cog.
## A hit costs the target 1 hp. A living target becomes "it" — unless it dies, in
## which case the shooter keeps the gun.
##
## Aim: a HEAD-SHOT lands five times in six. A HIP-SHOT misses two times in
## three, but the target takes the gun either way — so a hip-shot is how a cog
## hands the gun to a friend with a good chance of leaving them unhurt, or
## fakes a grudge. Which aim was chosen is the shooter's secret: the table sees
## only hit or miss, and because head-shots can miss too, a miss alone does
## not prove a gift. Every shot has a real chance of landing, so a round
## always ends — it just may take a few more turns.
##
## Cards: every round each cog is secretly dealt a FRIEND and an ENEMY
## (two distinct other cogs). Round points: 3 for surviving the round,
## 1 if your enemy goes out after one of YOUR shots landed on them, 1 if your
## friend survives. A round ends at the configured survivor count; every
## survivor earns the 3 points. The deal reshuffles every round and match
## scores are the round points summed. All seats return at full hp each round.
##
## Side actions: alongside any shot or reaction a cog may whisper to one cog,
## show one of its cards (verified by the game) to one cog, hand one banked
## point to a cog, or pledge publicly not to shoot a cog for the rest of the
## round. Breaking a pledge moves one point from the breaker to its victim.

import std/[json, random, sequtils, strutils], types

export types

const
  ## Per-episode sample ranges. Rounds and survivor count are also either told
  ## to the table or withheld, which is itself drawn per episode.
  ## Rounds and hit points are bounded so an ordinary table, talk included,
  ## fits the hosted episode clock.
  RoundsMin* = 3
  RoundsMax* = 6
  SurvivorsMin* = 1
  SurvivorsMax* = 3
  HitPointsMin* = 2
  HitPointsMax* = 3
  ## The most one seat can earn from one round's cards: survive (3) + its
  ## enemy goes out after its hit (1) + its friend survives (1).
  PointsPerRound* = 5.0
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 60_000
  ## A hip-shot lands one time in `HipShotOdds`.
  HipShotOdds* = 3
  ## A head-shot misses one time in `HeadMissOdds`.
  HeadMissOdds* = 6
  ## Whispers each cog may send per round.
  MaxWhispers* = 2

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
    banked*: seq[float]     ## match totals when this round was dealt
    transfers*: seq[float]  ## this round's gifts and pledge penalties, net
    rng: Rand       ## shot dice, seeded from seed + round so re-runs agree

  Match* = object
    ## A full episode: `config.rounds` rounds with cumulative scoring.
    config*: GameConfig
    sim*: Sim                 ## the round in progress
    history: seq[GameEvent]   ## events of completed rounds
    totals*: seq[float]       ## summed round points
    roundWins*: seq[int]      ## rounds won per seat (3 pts each)
    friendPoints*: seq[int]   ## rounds where the seat's friend won (1 pt each)
    foePoints*: seq[int]      ## rounds where the seat's enemy went out after its hit
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
  points = 0,
  aim = aimHead,
  miss = false
) =
  sim.events.add(GameEvent(
    kind: kind,
    round: sim.round,
    turn: sim.turn,
    seat: seat,
    target: target,
    text: text,
    hpAfter: hpAfter,
    aim: aim,
    miss: miss,
    friend: friend,
    enemy: enemy,
    points: points
  ))

proc derangement(rng: var Rand, n: int, avoid: seq[int] = @[],
    mutualPair = false): seq[int] =
  ## A permutation of 0..<n where no seat maps to itself, nor to the seat at the
  ## same index in `avoid`; with `mutualPair`, at least two seats map to each
  ## other. Rejection sampling: at n >= 3 a valid shuffle turns up in a
  ## handful of tries.
  for attempt in 0 .. 9999:
    result = toSeq(0 ..< n)
    rng.shuffle(result)
    var ok = true
    var paired = false
    for index in 0 ..< n:
      if result[index] == index or (avoid.len == n and result[index] == avoid[index]):
        ok = false
        break
      if result[result[index]] == index:
        paired = true
    if ok and (paired or not mutualPair):
      return
  raise newException(ParleyError, "no card deal satisfies the constraints")

proc dealCards(sim: var Sim) =
  ## Deals every seat a friend and a distinct enemy (never itself),
  ## deterministically from the seed and round so replays and re-runs agree.
  ##
  ## Both hands are dealt as PERMUTATIONS of the table, not per-seat draws:
  ## every cog is exactly one cog's friend and exactly one cog's enemy. Drawing
  ## each seat's cards independently would let a cog be nobody's friend while
  ## carrying two cogs' enemy cards, which reads as a bug at the table and
  ## quietly skews the round's scoring toward whoever drew the popular target.
  ##
  ## From four seats up, at least one pair of cogs hold each other's FRIEND
  ## card, and the table is told so: finding your mutual friend is a puzzle
  ## worth talking about. Three seats only admit 3-cycles.
  let n = sim.seats.len
  if n < 3:
    ## A friend and a distinct enemy need at least two other cogs.
    return
  var rng = initRand(int64(sim.config.seed) * 7919 + int64(sim.round) * 104729 + 17)
  let friends = derangement(rng, n, mutualPair = n >= 4)
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

  ## Rounds are exactly what was drawn. A round is never cut off part-way and
  ## there is no turn ceiling of any kind: it runs until the table is down to
  ## `survivors`, however long that takes. The only thing that shortens a
  ## match is the hosted deadline, checked between rounds by the server.
  ## Talk is the game, so every table gets the same reactions and passes.
  result.maxReactions = if config.reactions: config.maxReactions else: 0
  result.reactions = result.maxReactions > 0

  ## Spectator pacing is a fixed sleep per turn, so on a long table it stops
  ## being pacing and becomes most of the episode's wall clock. Spread a fixed
  ## allowance across a rough guess at the turns this table will play — a
  ## pacing estimate only, never a limit on anything.
  let roughTurns = max(result.rounds * max(seats, 2) * result.hitPoints, 1)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div roughTurns)
  result.sampled = true

proc initSim*(config: GameConfig, round = 0, banked: seq[float] = @[]): Sim =
  if config.players.len < 2:
    raise newException(ParleyError, "parley needs at least 2 players")
  result = Sim(config: config, round: round,
    banked: (if banked.len > 0: banked else: newSeq[float](config.players.len)),
    transfers: newSeq[float](config.players.len))
  ## Separate stream from the deal so the cards and the dice never correlate.
  result.rng = initRand(int64(config.seed) * 3571 + int64(round) * 15485863 + 101)
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
  ## Card scoring for one round: 3 points for surviving the round, 1 point if
  ## your enemy went out after one of your shots landed on them, 1 point if
  ## your friend survived. Every survivor takes the full 3, so a round played
  ## to three survivors pays out more than one played to a sole winner.
  ## Gifts and pledge penalties are transfers, not round points.
  result = newSeq[float](sim.seats.len)
  let winFlags = sim.winners()
  for index, seat in sim.seats:
    if winFlags[index]:
      result[index] += 3
    if seat.foeScored:
      result[index] += 1
    if seat.friend >= 0 and winFlags[seat.friend]:
      result[index] += 1

proc winners*(sim: Sim): seq[bool] =
  ## Round winners: the cogs left standing. Every survivor won it outright,
  ## however much paint they took — the survivor count IS the win condition,
  ## and a finished round has always reached it.
  ##
  ## Asked of a round still in progress (the live viewer's "who is ahead"),
  ## there are more cogs alive than the table is playing for and no verdict
  ## yet, so it ranks the living on hp instead and may show ties.
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

proc transfer(sim: var Sim, source, target: int, reason: string) =
  ## One point moves from `source` to `target` at once; both sides are logged.
  sim.transfers[source] -= 1
  sim.transfers[target] += 1
  sim.addEvent(evScore, source, target, points = -1, text = reason)
  sim.addEvent(evScore, target, source, points = 1, text = reason)

proc applyShot*(sim: var Sim, shooter, target: int, aim = aimHead) =
  ## One turn: "it" shoots a living cog. Raises on illegal shots.
  ##
  ## A head-shot misses one time in `HeadMissOdds`; a hip-shot misses
  ## `HipShotOdds - 1` times in `HipShotOdds`. A miss still spends the turn
  ## and still hands the gun to the target.
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
  let miss =
    if aim == aimHip: sim.rng.rand(HipShotOdds - 1) != 0
    else: sim.rng.rand(HeadMissOdds - 1) == 0
  if not miss:
    dec sim.seats[target].hp
    if target == sim.seats[shooter].enemy:
      sim.seats[shooter].hitEnemy = true
  sim.addEvent(evShot, shooter, target, hpAfter = sim.seats[target].hp,
    aim = aim, miss = miss)
  if target in sim.seats[shooter].pledges:
    sim.transfer(shooter, target, "pledge")

  if sim.seats[target].hp <= 0:
    sim.seats[target].alive = false
    sim.seats[target].deathIndex = sim.deathCount
    inc sim.deathCount
    inc sim.seats[shooter].kills
    sim.addEvent(evDeath, target)
    ## The FOE point is earned the moment the enemy goes out, by the one cog
    ## holding that enemy card if any of its shots landed on them this round.
    ## It is announced with the round's verdict: a mid-round announcement
    ## would tell the table whose enemy card named the fallen cog.
    for index in 0 ..< sim.seats.len:
      if sim.seats[index].enemy == target and sim.seats[index].hitEnemy:
        sim.seats[index].foeScored = true
    ## The gun stays with the shooter: a dead cog cannot be "it".
  else:
    sim.itSeat = target
    sim.addEvent(evIt, target)

  ## The survivor count is the ONLY thing that ends a round. There is no turn
  ## ceiling of any kind: every shot has a real chance of removing an hp and
  ## hp is finite, so the round terminates with probability one.
  if sim.aliveCount() <= max(sim.config.survivors, 1):
    sim.done = true

proc seatByName*(sim: Sim, name: string): int =
  for index, seat in sim.seats:
    if seat.name == name:
      return index
  -1

proc validateExtras*(sim: Sim, seat: int, extras: Extras) =
  ## Raises on any side action this seat may not take right now.
  proc other(sim: Sim, seat: int, target: Option[int], what: string) =
    if target.get < 0 or target.get >= sim.seats.len or target.get == seat:
      raise newException(ParleyError, what & " needs another cog at the table")
  if sim.done:
    raise newException(ParleyError, "round is over")
  if extras.whisperTo.isSome:
    sim.other(seat, extras.whisperTo, "whisper")
    if extras.whisperText.len == 0:
      raise newException(ParleyError, "whisper needs text")
    if sim.seats[seat].whispers >= MaxWhispers:
      raise newException(ParleyError, "no whispers left this round")
  if extras.revealTo.isSome:
    sim.other(seat, extras.revealTo, "reveal")
    if sim.seats[seat].friend < 0:
      raise newException(ParleyError, "no cards to reveal at this table")
    if sim.seats[seat].revealed:
      raise newException(ParleyError, "already revealed a card this round")
  if extras.giveTo.isSome:
    sim.other(seat, extras.giveTo, "give")
    if sim.banked[seat] + sim.transfers[seat] < 1:
      raise newException(ParleyError, "no banked point to give")
  if extras.pledgeTo.isSome:
    sim.other(seat, extras.pledgeTo, "pledge")
    if not sim.seats[seat].alive or not sim.seats[extras.pledgeTo.get].alive:
      raise newException(ParleyError, "pledges are between living cogs")
    if extras.pledgeTo.get in sim.seats[seat].pledges:
      raise newException(ParleyError, "already pledged")

proc applyExtras*(sim: var Sim, seat: int, extras: Extras) =
  ## Validates every side action first, so an illegal one changes nothing.
  sim.validateExtras(seat, extras)
  if extras.whisperTo.isSome:
    inc sim.seats[seat].whispers
    sim.addEvent(evWhisper, seat, extras.whisperTo.get, text = extras.whisperText)
  if extras.revealTo.isSome:
    sim.seats[seat].revealed = true
    if extras.revealCard == cardFriend:
      sim.addEvent(evReveal, seat, extras.revealTo.get, friend = sim.seats[seat].friend)
    else:
      sim.addEvent(evReveal, seat, extras.revealTo.get, enemy = sim.seats[seat].enemy)
  if extras.pledgeTo.isSome:
    sim.seats[seat].pledges.add(extras.pledgeTo.get)
    sim.addEvent(evPledge, seat, extras.pledgeTo.get)
  if extras.giveTo.isSome:
    sim.transfer(seat, extras.giveTo.get, "gift")

proc reactionSpeakers*(sim: Sim): seq[int] =
  ## Who talks before IT's next decision: every cog but IT, eliminated ones
  ## included, in a seeded shuffle so no seat is structurally silenced.
  for index in 0 ..< sim.seats.len:
    if index != sim.itSeat:
      result.add(index)
  var rng = initRand(int64(sim.config.seed) * 92821 + int64(sim.round) * 7867 +
    int64(sim.turn) * 337 + int64(sim.skips) * 29 + 5)
  rng.shuffle(result)
  if result.len > sim.config.maxReactions:
    result.setLen(sim.config.maxReactions)

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

proc appliedDecisionAction*(sim: Sim, events: seq[GameEvent], beforeEvent: int,
    seat: int, wantShot: bool): JsonNode =
  ## Recover the applied language action from authoritative engine events.
  result = %*{"say": ""}
  var shotApplied = false
  for index in beforeEvent ..< events.len:
    let event = events[index]
    if event.seat != seat: continue
    case event.kind
    of evSay: result["say"] = %event.text
    of evSkip:
      result["shoot"] = %"pass"
      shotApplied = true
    of evShot:
      result["shoot"] = %sim.seats[event.target].name
      result["aim"] = %($event.aim)
      shotApplied = true
    of evWhisper:
      result["whisper"] = %*{"to": sim.seats[event.target].name, "text": event.text}
    of evReveal:
      result["reveal"] = %*{"to": sim.seats[event.target].name,
        "card": (if event.friend >= 0: $cardFriend else: $cardEnemy)}
    of evPledge:
      result["pledge"] = %sim.seats[event.target].name
    of evScore:
      if event.text == "gift" and event.points < 0:
        result["give"] = %sim.seats[event.target].name
    else: discard
  doAssert not wantShot or shotApplied, "engine emitted no applied shot or skip"

proc allEvents*(match: Match): seq[GameEvent] =
  match.history & match.sim.events

proc decisionSim*(match: Match): Sim =
  ## Current table and the full match transcript, so past bargains survive resets.
  result = match.sim
  result.events = match.allEvents()

proc finishRound*(match: var Match, endMatch = false) =
  ## Scores the finished round, emits its winner events, and either deals
  ## the next round or ends the match. Call when `match.sim.done`.
  ## A deadline stop scores this round without dealing an unplayed next one.
  if not match.sim.done or match.done:
    raise newException(ParleyError, "no finished round to score")
  let roundScores = match.sim.scores()
  let roundWinners = match.sim.winners()
  for index in 0 ..< match.totals.len:
    match.totals[index] += roundScores[index] + match.sim.transfers[index]
    match.killsTotal[index] += match.sim.seats[index].kills
    if match.sim.seats[index].foeScored:
      inc match.foePoints[index]
    let friend = match.sim.seats[index].friend
    if friend >= 0 and roundWinners[friend]:
      inc match.friendPoints[index]
    if roundWinners[index]:
      inc match.roundWins[index]
      match.sim.addEvent(evRoundEnd, index)
  ## Round-end score deltas, after the verdict lines: foe points, survivor
  ## points for the winners, friend points for everyone whose friend made it.
  for index in 0 ..< match.totals.len:
    if match.sim.seats[index].foeScored:
      match.sim.addEvent(evScore, index, match.sim.seats[index].enemy, points = 1,
        text = "foe")
  for index in 0 ..< match.totals.len:
    if roundWinners[index]:
      match.sim.addEvent(evScore, index, points = 3, text = "survivor")
  for index in 0 ..< match.totals.len:
    let friend = match.sim.seats[index].friend
    if friend >= 0 and roundWinners[friend]:
      match.sim.addEvent(evScore, index, friend, points = 1, text = "friend")
  match.turnsTotal += match.sim.turn
  match.roundsPlayed.inc

  if not endMatch and match.sim.round + 1 < match.config.rounds:
    match.history.add(match.sim.events)
    match.sim = initSim(match.config, match.sim.round + 1, match.totals)
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

proc placings*(match: Match): seq[float] =
  ## The platform score: the share of the other seats this seat finished
  ## ahead of, ties counting half. Raw totals swing with the survivor count
  ## (a three-survivor table pays out more than twice a sole-winner one), so
  ## only the order within the table is comparable across episodes.
  let n = match.totals.len
  result = newSeq[float](n)
  if n < 2:
    return
  for index in 0 ..< n:
    var beaten = 0.0
    for other in 0 ..< n:
      if other == index: continue
      if match.totals[index] > match.totals[other]: beaten += 1
      elif match.totals[index] == match.totals[other]: beaten += 0.5
    result[index] = beaten / float(n - 1)

proc resultsJson*(match: Match): JsonNode =
  let winFlags = match.matchWinners()
  let available = match.pointsAvailable()
  let placing = match.placings()
  var names = newJArray()
  var scoresNode = newJArray()
  var winNode = newJArray()
  var hpNode = newJArray()
  var killsNode = newJArray()
  var roundWinsNode = newJArray()
  var friendNode = newJArray()
  var foeNode = newJArray()
  var rawNode = newJArray()
  var shareNode = newJArray()
  for index, seat in match.sim.seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%match.config.players[index].name)
    ## `scores` is the within-table placing so the league can rank across
    ## differently-shaped tables; raw points and their share of the
    ## per-seat ceiling ride along.
    scoresNode.add(%placing[index])
    rawNode.add(%match.totals[index])
    shareNode.add(%(match.totals[index] / available))
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
    "pointShares": shareNode,
    "pointsAvailable": available,
    "rounds": match.roundsPlayed,
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
      "enemyDone": seat.foeScored
    })

proc redactSecrets*(snapshot: JsonNode, slot: int) =
  ## What a PLAYER may see of a snapshot. Cards are secret: a player sees only
  ## its own friend/enemy pair. So is the AIM of a shot: a player sees hit or
  ## miss, and how IT aimed only for its own shots. The global viewer keeps
  ## everything only in the replay. A live spectator uses slot -1 and sees
  ## no private cards or aim.
  for index, seat in snapshot["seats"].getElems():
    if index != slot:
      seat["friend"] = %(-1)
      seat["enemy"] = %(-1)
  var visible = newJArray()
  for event in snapshot["events"]:
    if event{"kind"}.getStr() == "deal" and event{"seat"}.getInt() != slot:
      continue
    if event{"kind"}.getStr() == "shot" and event{"seat"}.getInt() != slot:
      var public = event.copy()
      if public.hasKey("aim"):
        public.delete("aim")
      visible.add(public)
      continue
    ## Whispers and card reveals are private to the two cogs involved; the
    ## rest of the table sees only that one happened.
    if event{"kind"}.getStr() in ["whisper", "reveal"] and
        slot notin [event{"seat"}.getInt(), event{"target"}.getInt()]:
      var public = event.copy()
      for key in ["text", "friend", "enemy"]:
        if public.hasKey(key):
          public.delete(key)
      visible.add(public)
      continue
    visible.add(event)
  snapshot["events"] = visible

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
        frame.sim.seats[index].foeScored = false
      frame.sim.deathCount = 0
      frame.sim.skips = 0
      frame.sim.done = false
      frame.sim.itSeat = -1
    of evDeal:
      frame.sim.seats[event.seat].friend = event.friend
      frame.sim.seats[event.seat].enemy = event.enemy
    of evSay, evWhisper, evReveal, evPledge:
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
    of evScore:
      frame.totals[event.seat] += float(event.points)
      if event.text == "foe":
        frame.sim.seats[event.seat].foeScored = true
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
  if event.aim != aimHead:
    result["aim"] = %($event.aim)
  if event.miss:
    result["miss"] = %true
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
    aim: (if node{"aim"}.getStr("head") == "hip": aimHip else: aimHead),
    miss: node{"miss"}.getBool(false),
    friend: node{"friend"}.getInt(-1),
    enemy: node{"enemy"}.getInt(-1),
    points: node{"points"}.getInt(0)
  )
