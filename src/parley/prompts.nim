## Model messages: versioned rules, private seat history, and action instructions.
import std/[json, strutils, tables]
import crunchy
import sim

const PromptBankVersion* = "parley-rules-v1"
const Templates: array[pvCanonical .. pvHeldoutReference, string] = [
  staticRead("prompts/canonical.txt"),
  staticRead("prompts/plain.txt"),
  staticRead("prompts/numbered.txt"),
  staticRead("prompts/questions.txt"),
  staticRead("prompts/reordered.txt"),
  staticRead("prompts/heldout-briefing.txt"),
  staticRead("prompts/heldout-reference.txt")
]

proc renderSystemPrompt*(config: GameConfig, name, tableRules: string, whispers: int): string =
  Templates[config.selectedPromptVariant] % [name, $config.hitPoints, tableRules, $whispers]

proc promptMetadata*(config: GameConfig, system, user: string): JsonNode =
  ## Hash each exact message separately: concatenation would lose message boundaries.
  %*{"bank": PromptBankVersion, "variant": $config.selectedPromptVariant,
     "selection": $config.promptVariant, "seed": config.promptSeed,
     "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc seatName(sim: Sim, seat: int): string =
  sim.seats[seat].name

proc renderHistory(sim: Sim, me: int): string =
  ## The public record of the table, in reading order, as `me` may see it.
  ## The current round is told in full. Earlier rounds keep every spoken line
  ## and everything private to `me`, and fold the shots into a summary, so the
  ## prompt stays bounded while bargains and grudges stay quotable. Shots
  ## read as hit or miss only — the aim is secret — except that a cog is
  ## reminded how IT aimed its own shots this round.
  var lines: seq[string]
  var isOut = newSeq[bool](sim.seats.len)
  var knockouts: seq[string]
  var winners: seq[string]
  var shotTally = initTable[(int, int), (int, int)]()
  proc flushSummary(round: int) =
    var tally: seq[string]
    for key, counts in shotTally:
      var part = sim.seatName(key[0]) & " -> " & sim.seatName(key[1]) & ": "
      part.add($counts[0] & " hit" & (if counts[0] == 1: "" else: "s"))
      if counts[1] > 0:
        part.add(", " & $counts[1] & " miss" & (if counts[1] == 1: "" else: "es"))
      tally.add(part)
    if tally.len > 0:
      lines.add("Round " & $(round + 1) & " shots: " & tally.join("; ") & ".")
    if knockouts.len > 0:
      lines.add("Round " & $(round + 1) & " knockouts: " & knockouts.join(", ") & ".")
    if winners.len > 0:
      lines.add("Round " & $(round + 1) & " survivors: " & winners.join(", ") & ".")
    shotTally.clear()
    knockouts.setLen(0)
    winners.setLen(0)
  var lastShooter = -1
  var summarizing = -1
  for event in sim.events:
    let past = event.round < sim.round
    if summarizing >= 0 and event.round != summarizing:
      flushSummary(summarizing)
      summarizing = -1
    if past:
      summarizing = event.round
    let speaker = sim.seatName(event.seat) &
      (if isOut[event.seat]: " (out)" else: "")
    case event.kind
    of evRoundStart:
      for index in 0 ..< isOut.len: isOut[index] = false
      lines.add("Round " & $(event.round + 1) & " begins; secret cards dealt.")
    of evDeal:
      discard  ## cards are secret; each seat is told only its own
    of evIt:
      if not past:
        lines.add(sim.seatName(event.seat) & " is now IT (holds the paintgun).")
    of evSay:
      lines.add(speaker & " says: \"" & event.text & "\"")
    of evWhisper:
      if event.seat == me:
        lines.add("You whisper to " & sim.seatName(event.target) & ": \"" &
          event.text & "\"")
      elif event.target == me:
        lines.add(speaker & " whispers to you: \"" & event.text & "\"")
      else:
        lines.add(speaker & " whispers something to " &
          sim.seatName(event.target) & ".")
    of evReveal:
      if event.seat == me:
        lines.add("You show " & sim.seatName(event.target) & " your " &
          (if event.friend >= 0: "FRIEND card (" & sim.seatName(event.friend)
           else: "ENEMY card (" & sim.seatName(event.enemy)) & ").")
      elif event.target == me:
        lines.add(speaker & " shows you their " &
          (if event.friend >= 0: "FRIEND card: " & sim.seatName(event.friend)
           else: "ENEMY card: " & sim.seatName(event.enemy)) &
          " (verified by the game).")
      else:
        lines.add(speaker & " shows " & sim.seatName(event.target) &
          " one of their cards.")
    of evPledge:
      lines.add(speaker & " PLEDGES not to shoot " & sim.seatName(event.target) &
        " for the rest of the round.")
    of evSkip:
      if not past:
        lines.add(sim.seatName(event.seat) &
          " holds fire and keeps the paintgun.")
    of evShot:
      lastShooter = event.seat
      if past:
        let key = (event.seat, event.target)
        var counts = shotTally.getOrDefault(key)
        if event.miss: inc counts[1] else: inc counts[0]
        shotTally[key] = counts
        continue
      let own =
        if event.seat == me:
          (if event.aim == aimHip: " [your hip-shot]" else: " [your head-shot]")
        else: ""
      if event.miss:
        lines.add(sim.seatName(event.seat) & " SHOOTS AT " &
          sim.seatName(event.target) & " and MISSES (still " &
          $max(event.hpAfter, 0) & " hp)." & own)
      else:
        lines.add(sim.seatName(event.seat) & " SHOOTS " &
          sim.seatName(event.target) & " (now " & $max(event.hpAfter, 0) &
          " hp)." & own)
    of evDeath:
      isOut[event.seat] = true
      if past:
        knockouts.add(sim.seatName(event.seat) & " by " & sim.seatName(lastShooter))
      else:
        lines.add(sim.seatName(event.seat) & " is OUT of the game.")
    of evScore:
      case event.text
      of "foe":
        lines.add(sim.seatName(event.seat) &
          " scored a point: their secret enemy went out after their hit.")
      of "gift":
        if event.points < 0:
          lines.add(sim.seatName(event.seat) & " GIVES 1 point to " &
            sim.seatName(event.target) & ".")
      of "pledge":
        if event.points < 0:
          lines.add(sim.seatName(event.seat) & " BROKE their pledge and pays 1 point to " &
            sim.seatName(event.target) & ".")
      else:
        ## survivor/friend deltas land after the round verdict; the round
        ## summary already covers them.
        discard
    of evRoundEnd:
      if past:
        winners.add(sim.seatName(event.seat))
      else:
        lines.add(sim.seatName(event.seat) & " WINS the round.")
  if summarizing >= 0:
    flushSummary(summarizing)
  if lines.len == 0:
    return "(nothing has happened yet)"
  lines.join("\n")

proc renderSeats(sim: Sim): string =
  var lines: seq[string]
  for index, seat in sim.seats:
    var line = "- " & seat.name & ": "
    if seat.alive:
      line.add($seat.hp & " hp")
      if index == sim.itSeat:
        line.add(", IT (holding the paintgun)")
    else:
      line.add("OUT")
    lines.add(line)
  lines.join("\n")

proc tableRules(sim: Sim): string =
  ## What this episode reveals about its own shape. Rounds and the survivor
  ## count are drawn per episode and each is independently either announced or
  ## withheld, so a cog may be playing a table whose length it cannot see.
  ## Saying "unknown" out loud matters: silence would read as "one survivor,
  ## three rounds" and quietly mislead.
  let survivorText =
    if sim.config.survivorsKnown:
      (if sim.config.survivors == 1: "A round ends when ONE cog is left standing."
       else: "A round ends when " & $sim.config.survivors &
         " cogs are left standing - they all survive it and all score.")
    else:
      "How many cogs must be left standing to end a round is NOT known to the table."
  let roundText =
    if sim.config.roundsKnown:
      "This match is " & $sim.config.rounds & " rounds, unless the table runs " &
        "out of time first (the match then ends after the round in play)."
    else:
      "How many rounds this match runs is NOT known to the table - it could " &
        "end after any round."
  result = survivorText & "\n- " & roundText
  if sim.seats.len >= 4:
    result.add("\n- At least one pair of cogs hold each other's FRIEND card this round.")

proc systemPrompt*(sim: Sim, seat: int): string =
  renderSystemPrompt(sim.config, sim.seatName(seat), tableRules(sim), MaxWhispers)

proc extrasInstruction(sim: Sim, seat: int): string =
  ## The optional side-action fields, listing only what this seat can use now.
  let me = sim.seats[seat]
  var fields: seq[string]
  if me.whispers < MaxWhispers:
    fields.add("\"whisper\": {\"to\": <cog>, \"text\": \"...\"} (" &
      $(MaxWhispers - me.whispers) & " left this round)")
  if me.friend >= 0 and not me.revealed:
    fields.add("\"reveal\": {\"to\": <cog>, \"card\": <\"friend\" or \"enemy\">}")
  if sim.banked[seat] + sim.transfers[seat] >= 1:
    fields.add("\"give\": <cog> (1 point; you have " &
      $(sim.banked[seat] + sim.transfers[seat]) & ")")
  var pledgeable: seq[string]
  for index, other in sim.seats:
    if index != seat and other.alive and index notin me.pledges:
      pledgeable.add(other.name)
  if me.alive and pledgeable.len > 0:
    fields.add("\"pledge\": <a cog you promise not to shoot this round; any of " &
      pledgeable.join(", ") & ">")
  if fields.len == 0:
    return ""
  "Optional extra fields, at most one of each: " & fields.join("; ") & ".\n"

proc shotInstruction(sim: Sim, seat: int): string =
  var names: seq[string]
  for target in sim.validTargets(seat):
    names.add("\"" & sim.seatName(target) & "\"")
  let passes = sim.skipsLeft()
  result = "You are IT. Choose exactly one living cog to shoot and say " &
    "something to the table first (max " & $MaxSayLen & " chars).\n" &
    "Choose your AIM: \"head\" hits 5 in 6; \"hip\" misses 2 in 3 but " &
    "the target takes the gun either way, and nobody learns which you " &
    "chose.\n"
  let aimField = ", \"aim\": <\"head\" or \"hip\">"
  result.add(sim.extrasInstruction(seat))
  if passes > 0:
    result.add("You may instead PASS: hold your fire and let the table " &
      "keep talking (" & $passes &
      (if passes == 1: " pass" else: " passes") & " left this round).\n" &
      "Respond with JSON: {\"say\": \"...\", \"shoot\": <one of " &
      names.join(", ") & ", or \"pass\">" & aimField & "}")
  else:
    result.add("Respond with JSON: {\"say\": \"...\", \"shoot\": <one of " &
      names.join(", ") & ">" & aimField & "}")

proc reactionInstruction(sim: Sim, seat: int): string =
  (if sim.seats[seat].alive: "You are not IT right now. "
   else: "You are OUT this round, but you can still talk and your cards still score. ") &
    "Say one short line to the table (max " &
    $MaxSayLen & " chars) - plead, deflect, scheme, or stir the pot.\n" &
    sim.extrasInstruction(seat) &
    "Respond with JSON: {\"say\": \"...\"}"

proc matchHeader*(match: Match): string =
  ## Share standings without revealing a withheld match length.
  var standings: seq[string]
  for index, seat in match.sim.seats:
    ## Banked totals plus this round's gifts and pledge payments: what each
    ## cog holds right now, the same figure a gift is checked against.
    standings.add(seat.name & "=" & $(match.totals[index] + match.sim.transfers[index]) &
      " (" & $match.roundWins[index] & " round wins)")
  result = "Round " & $(match.sim.round + 1)
  if match.config.roundsKnown:
    result.add(" of " & $match.config.rounds)
  result.add(". Match standings so far: " & standings.join(", ") & ".")

proc userPrompt*(
  sim: Sim, seat: int, prompt: string, wantShot: bool, header: string
): string =
  if header.len > 0:
    result.add(header & "\n\n")
  result.add("Seats at the table:\n" & sim.renderSeats() &
    "\n\nWhat has happened at the table:\n" & sim.renderHistory(seat) & "\n\n")
  let me = sim.seats[seat]
  if me.friend >= 0 and me.enemy >= 0:
    result.add("Your SECRET cards this round: FRIEND = " &
      sim.seatName(me.friend) & " (1 pt to you if they survive the round)" &
      ", ENEMY = " & sim.seatName(me.enemy) &
      " (1 pt to you if they go out after at least one of YOUR shots lands on them)." &
      " Nobody else sees these cards unless you show one.\n\n")
  if prompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always pick a legal action):\n" & prompt & "\n\n")
  if wantShot:
    result.add(sim.shotInstruction(seat))
  else:
    result.add(sim.reactionInstruction(seat))
