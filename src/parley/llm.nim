## Native-sidecar decisions through the same private seat prompts and parser.
## Without COWORLD_LLM_ENDPOINT, offline diagnostics use unsupervised scripted
## fallback; provider credentials never select a transport.

import
  std/[base64, json, monotimes, options, os, random, sets, strutils, tables],
  bitworld/decision_trajectory,
  bitworld/[native_http, native_stop],
  sim
from std/unicode import validateUtf8

const
  AnthropicVersion = "2023-06-01"
  ## What the viewer's speech bubble can actually show (~4 wrapped lines).
  ## Anything longer would render cut off mid-sentence at the table.
  MaxSayLen = 160

type
  Decision* = object
    say*: string
    target*: int      ## seat index; -1 for pure table talk
    skip*: bool       ## "it" holds fire this turn instead of shooting
    aim*: ShotAim     ## head (lands 5 in 6) or hip (lands 1 in 3, gun still moves)
    extras*: Extras   ## whisper / reveal / give / pledge alongside the action

  Baseline* = enum
    ## Scripted no-model policies, selectable per seat for evaluation cohorts.
    blRandom = "random"         ## random living target; hip-shot at its friend
    blFinisher = "finisher"     ## lowest-hp non-friend, its enemy on ties
    blRetaliator = "retaliator" ## whoever last landed a hit on it, else random
    blProtector = "protector"   ## whoever last hit its friend, else its enemy
    blHoarder = "hoarder"       ## passes while the table has passes, else finisher

  DecisionResult* = object
    decision*: Decision
    origin*: string
    input*: JsonNode
    response*: JsonNode
    attempts*: seq[JsonNode]
    nativeAttempts*: seq[DecisionAttempt]

  LlmClient* = ref object
    sidecarEndpoint: string
    model: string
    maxOutputTokens: int
    temperature: float
    disabled: bool    ## true without a native endpoint or after auth rejection
    budgetExhausted: seq[bool] ## platform spend limits belong to individual seats
    rand: seq[Rand]         ## independent scripted stream per seat

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "1")),
    rand: newSeq[Rand](config.players.len),
    budgetExhausted: newSeq[bool](config.players.len)
  )
  if not (result.temperature >= 0 and result.temperature <= 1):
    raise newException(ValueError, "COWORLD_LLM_TEMPERATURE must be finite and between 0 and 1")
  for seat in 0 ..< config.players.len:
    result.rand[seat] = initRand(config.seed xor 0x5EED xor
      ((seat + 1) shl 16))
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", config.model)
    echo "parley llm: hosted sidecar transport, model ", result.model
    return
  result.disabled = true
  echo "parley llm: no native endpoint; using unsupervised scripted fallback"

const CannedTaunts = [
  "Nothing personal.",
  "Sorry, table rules.",
  "The gun chose you.",
  "Statistically, it had to be you.",
  "Don't take it personally. Take it in the chest.",
  "Splat happens."
]

const CannedReactions = [
  "Hey, easy with that thing!",
  "Not me, not me!",
  "Bold move.",
  "You'll regret this.",
  "I'm just here for the snacks.",
  "Remember who your friends are."
]

proc lastHitter(sim: Sim, victim: int): int =
  ## The cog whose shot most recently landed on `victim` this round, or -1.
  result = -1
  for event in sim.events:
    if event.round == sim.round and event.kind == evShot and
        event.target == victim and not event.miss:
      result = event.seat

proc scriptedShot*(client: LlmClient, sim: Sim, seat: int,
    baseline = blRandom): Decision =
  ## Always-legal baselines with canned taunts. Each knows the one thing about
  ## aim that matters: a shot at its own FRIEND goes from the hip, so the gun
  ## moves on with a good chance of no harm done; everything else is a
  ## head-shot.
  let me = sim.seats[seat]
  let targets = sim.validTargets(seat)
  var foes: seq[int]
  for target in targets:
    if target != me.friend:
      foes.add(target)
  if foes.len == 0:
    foes = targets
  proc finisher(): int =
    result = foes[0]
    for target in foes:
      let seatHp = sim.seats[target].hp
      if seatHp < sim.seats[result].hp or
          (seatHp == sim.seats[result].hp and target == me.enemy):
        result = target
  let say = CannedTaunts[client.rand[seat].rand(CannedTaunts.high)]
  let randomTarget = targets[client.rand[seat].rand(targets.high)]
  if baseline == blHoarder and sim.skipsLeft() > 0:
    return Decision(say: say, target: -1, skip: true)
  let target =
    case baseline
    of blRandom: randomTarget
    of blFinisher, blHoarder: finisher()
    of blRetaliator:
      let hitter = sim.lastHitter(seat)
      if hitter in targets: hitter else: randomTarget
    of blProtector:
      let hitter = if me.friend >= 0: sim.lastHitter(me.friend) else: -1
      if hitter in targets: hitter
      elif me.enemy in targets: me.enemy
      else: randomTarget
  Decision(
    say: say,
    target: target,
    aim: (if target == me.friend: aimHip else: aimHead)
  )

proc scriptedReaction*(client: LlmClient, sim: Sim, seat: int): Decision =
  Decision(
    say: CannedReactions[client.rand[seat].rand(CannedReactions.high)],
    target: -1
  )

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
      "This match runs " & $RoundsMin & " to " & $RoundsMax & " rounds; the " &
        "exact count is NOT known to the table, and running out of time can " &
        "also end it after any round."
  result = survivorText & "\n- " & roundText
  if sim.seats.len >= 4:
    result.add("\n- At least one pair of cogs hold each other's FRIEND card this round.")

proc systemPrompt*(sim: Sim, seat: int): string =
  """You are """ & sim.seatName(seat) &
    """, a cog seated at a round table in a game of Parley.

Rules of Parley:
- One cog is IT and holds the paintgun.
- On its turn, IT says something to the table and then shoots one other
  living cog. A hit costs the target 1 hp. The target becomes IT, hit
  or miss.
- If a hit knocks a cog to 0 hp, that cog is OUT and the shooter keeps
  the paintgun.
- AIM: a HEAD-SHOT hits 5 times in 6. A HIP-SHOT misses 2 times in 3 (no
  damage, but the target still takes the gun). Nobody is told which aim a
  shooter chose - the table sees only whether the shot landed - so a
  hip-shot can pass the gun to a friend while probably leaving them unhurt,
  or fake a grudge, and a miss alone proves nothing.
- IT may PASS instead of shooting, a limited number of times per round:
  the gun stays put and the table keeps talking. The allowance is shared
  by the whole table and resets each round.
- HEALTH: all cogs return alive with """ & $sim.config.hitPoints & """ hp at the
  start of every round.
- CARDS: every round each cog is secretly dealt a FRIEND and an ENEMY
  (never itself, never the same cog). Nobody else knows your cards, and
  the deal reshuffles every round.
- Round scoring: 3 points for SURVIVING the round, 1 point if your ENEMY
  goes out after at least one of YOUR shots landed on them (anyone may land
  the final hit), 1 point if your FRIEND survives. Cogs that are out keep
  scoring their enemy and friend points.
- """ & tableRules(sim) & """
- Points accumulate across rounds and the highest match total wins.
- Talk, plead, threaten, bargain, form and betray alliances - anything
  said aloud is heard by the whole table, and grudges carry across rounds.
  Cogs that are out can still talk. Any cog may also, alongside its action:
  WHISPER one private line to one cog (""" & $MaxWhispers & """ per round; the table
  sees only that you whispered); SHOW one of its cards to one cog (once per
  round; the game verifies it, the table sees only that you showed one);
  GIVE one banked point to a cog; or PLEDGE, publicly, not to shoot a living
  cog for the rest of the round - shooting a cog you pledged to spare moves
  1 of your points to them.

Respond with a single JSON object and nothing else."""

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
    standings.add(seat.name & "=" & $match.totals[index] &
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
      " (1 pt to you if YOUR shot takes them out). Keep them secret.\n\n")
  if prompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always pick a legal action):\n" & prompt & "\n\n")
  if wantShot:
    result.add(sim.shotInstruction(seat))
  else:
    result.add(sim.reactionInstruction(seat))

proc parseJsonObject*(text: string): JsonNode =
  ## Training labels must contain only the requested action object.
  result = parseJson(text)
  if result.kind != JObject:
    raise newException(ParleyError, "response must be a JSON object")

proc completeText(client: LlmClient, seat: int, system, user: string,
    evidence: var DecisionAttempt, deadline: MonoTime): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": client.temperature,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  body["model"] = %client.model
  headers["anthropic-version"] = AnthropicVersion
  headers["x-coworld-player-slot"] = $seat
  let url = client.sidecarEndpoint & "/v1/messages"
  evidence.request = copy(body)
  evidence.model = some(client.model)
  evidence.decoder = %*{"temperature": client.temperature,
    "max_tokens": client.maxOutputTokens}
  let response = performNativePost(url, headers, $body, deadline)
  evidence.latencyMs = response.latencyMs
  evidence.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    evidence.responseBodyB64 = some(encode(response.bodyBytes))
    evidence.responseHeadersB64 = some(encode(response.headerBytes))
    evidence.responseComplete = some(response.transferComplete)
    evidence.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      evidence.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(ParleyError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(ParleyError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(ParleyError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    evidence.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(ParleyError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      evidence.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call": evidence.platformCallId = some(responseHeaders[header])
      of "model": evidence.modelIdentity = some(responseHeaders[header])
      of "tokenizer": evidence.tokenizerIdentity = some(responseHeaders[header])
      else: evidence.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(ParleyError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(ParleyError,
      "native inference auth failed (" & $status & ")")
  if responseHeaders["x-softmax-llm-error-category"] == "spend_limit":
    client.budgetExhausted[seat] = true
    raise newException(ParleyError, "seat LLM spend limit exhausted")
  if status == 429:
    raise newException(ParleyError, "llm throttled (429)")
  if status < 200 or status >= 300:
    raise newException(ParleyError,
      "native inference error " & $status)
  if validateUtf8(response.bodyBytes) != -1:
    raise newException(ParleyError, "native response is not valid UTF-8")
  let payload = parseJson(response.bodyBytes)
  evidence.model = some(payload["model"].getStr())
  evidence.stopReason = some(payload["stop_reason"].getStr())
  evidence.inputTokens = some(payload["usage"]["input_tokens"].getInt())
  evidence.outputTokens = some(payload["usage"]["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampled = payload["sampling_evidence"]
    var promptTokens, completionTokens: seq[int]
    var probabilities: seq[float]
    for token in sampled["prompt_token_ids"]: promptTokens.add(token.getInt())
    for token in sampled["completion_token_ids"]: completionTokens.add(token.getInt())
    if sampled["behavior_log_probs"].kind != JNull:
      for probability in sampled["behavior_log_probs"]: probabilities.add(probability.getFloat())
    evidence.promptTokenIds = some(promptTokens)
    evidence.sampledTokenIds = some(completionTokens)
    if sampled["behavior_log_probs"].kind != JNull:
      evidence.behaviorLogprobs = some(probabilities)
    evidence.stopReason = some(sampled["stop_reason"].getStr())
  echo "parley llm: usage model ", payload["model"].getStr(),
    " input_tokens ", payload["usage"]["input_tokens"].getInt(),
    " output_tokens ", payload["usage"]["output_tokens"].getInt()
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(ParleyError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())

proc cleanSay(text: string): string =
  result = text.strip()
  if result.len <= MaxSayLen:
    return
  ## A model that overshoots the stated cap gets cut at a word boundary with
  ## the cut marked — a silent mid-word slice reads as a bug at the table.
  result = result[0 ..< MaxSayLen - 3]
  ## Never leave a UTF-8 code point split by the byte slice.
  while result.len > 0 and (result[^1].ord and 0xC0) == 0x80:
    result.setLen(result.len - 1)
  let space = result.rfind(' ')
  if space > MaxSayLen div 2:
    result.setLen(space)
  result.add("…")

proc parseExtras(sim: Sim, seat: int, payload: JsonNode): Extras =
  ## Absent or null fields are unused; present ones must name a cog.
  proc cog(node: JsonNode, field: string): Option[int] =
    let seat = sim.seatByName(node.getStr().strip())
    if seat < 0:
      raise newException(ParleyError, field & " names no cog: " & $node)
    some(seat)
  let whisper = payload{"whisper"}
  if whisper != nil and whisper.kind != JNull:
    result.whisperTo = cog(whisper{"to"}, "whisper")
    result.whisperText = cleanSay(whisper{"text"}.getStr())
  let reveal = payload{"reveal"}
  if reveal != nil and reveal.kind != JNull:
    result.revealTo = cog(reveal{"to"}, "reveal")
    result.revealCard = parseEnum[CardKind](reveal{"card"}.getStr().strip().toLowerAscii())
  let give = payload{"give"}
  if give != nil and give.kind != JNull:
    result.giveTo = cog(give, "give")
  let pledge = payload{"pledge"}
  if pledge != nil and pledge.kind != JNull:
    result.pledgeTo = cog(pledge, "pledge")
  sim.validateExtras(seat, result)

proc parseDecision*(sim: Sim, seat: int, payload: JsonNode,
    wantShot: bool): Decision =
  result = Decision(say: cleanSay(payload{"say"}.getStr()), target: -1,
    extras: sim.parseExtras(seat, payload))
  if wantShot:
    let targetName = payload{"shoot"}.getStr().strip()
    if targetName.toLowerAscii() == "pass" and sim.skipsLeft() > 0:
      result.skip = true
      return
    result.target = sim.seatByName(targetName)
    if result.target < 0 or result.target == seat or
        not sim.seats[result.target].alive:
      raise newException(ParleyError, "illegal target: " & targetName)
    if payload{"aim"}.getStr().strip().toLowerAscii() == "hip":
      result.aim = aimHip

proc decisionAction*(sim: Sim, decision: Decision, wantShot: bool): JsonNode =
  result = %*{"say": decision.say}
  if wantShot:
    if decision.skip:
      result["shoot"] = %"pass"
    else:
      result["shoot"] = %sim.seats[decision.target].name
      result["aim"] = %($decision.aim)
  let extras = decision.extras
  if extras.whisperTo.isSome:
    result["whisper"] = %*{"to": sim.seats[extras.whisperTo.get].name,
      "text": extras.whisperText}
  if extras.revealTo.isSome:
    result["reveal"] = %*{"to": sim.seats[extras.revealTo.get].name,
      "card": $extras.revealCard}
  if extras.pledgeTo.isSome:
    result["pledge"] = %sim.seats[extras.pledgeTo.get].name
  if extras.giveTo.isSome:
    result["give"] = %sim.seats[extras.giveTo.get].name

proc decide*(
  client: LlmClient,
  sim: Sim,
  seat: int,
  prompt: string,
  wantShot: bool,
  deadline: MonoTime,
  header = ""
): DecisionResult =
  ## One decision for one seat. Never raises: any failure falls back to the
  ## scripted baseline so the game always advances.
  if client.disabled or client.budgetExhausted[seat]:
    result.decision =
      if wantShot: client.scriptedShot(sim, seat)
      else: client.scriptedReaction(sim, seat)
    result.origin =
      if client.budgetExhausted[seat]: "scripted_after_budget_exhausted"
      else: "scripted_no_native_endpoint"
    result.input = newJNull()
    result.response = newJNull()
    return

  let system = systemPrompt(sim, seat)
  for attempt in 0 .. 1:
    if interruptionRequested() or getMonoTime() >= deadline:
      break
    var user = userPrompt(sim, seat, prompt, wantShot, header)
    if attempt > 0:
      user.add("\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object and a legal target.")
    var raw = ""
    var evidence = newDecisionAttempt("attempt-" & $attempt, client.model, aoModel)
    evidence.prompt = %*[{"role": "system", "content": system},
      {"role": "user", "content": user}]
    try:
      raw = client.completeText(seat, system, user, evidence, deadline)
      let payload = parseJsonObject(raw)
      result.decision = parseDecision(sim, seat, payload, wantShot)
      evidence.response = %raw
      evidence.parsedAction = decisionAction(sim, result.decision, wantShot)
      if interruptionRequested() or getMonoTime() >= deadline:
        raise newException(ParleyError, "native response arrived after decision deadline")
      evidence.accepted = true
      result.nativeAttempts.add(evidence)
      result.origin = "model"
      result.input = %*{"system": system, "user": user}
      result.response = %*{"raw": raw, "parsed": payload}
      return
    except CatchableError as error:
      evidence.response = %raw
      evidence.rejectionReason = some(error.msg)
      result.nativeAttempts.add(evidence)
      result.attempts.add(%*{"system": system, "user": user,
        "raw": raw, "error": error.msg})
      echo "parley llm: seat ", seat, " attempt ", attempt, " failed"
      if client.disabled or client.budgetExhausted[seat]:
        break
  echo "parley llm: seat ", seat, " falling back to scripted decision"
  result.decision =
    if wantShot: client.scriptedShot(sim, seat)
    else: client.scriptedReaction(sim, seat)
  result.origin =
    if client.budgetExhausted[seat]: "scripted_after_budget_exhausted"
    else: "scripted_after_model_failure"
  result.input = newJNull()
  result.response = newJNull()
