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
    aim*: ShotAim     ## head (always lands) or hip (gamble, gun still moves)

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

proc scriptedShot*(client: LlmClient, sim: Sim, seat: int): Decision =
  ## Always-legal baseline: shoot a random living opponent, canned taunt.
  ## It knows the one thing about aim that matters: a shot at its own FRIEND
  ## goes from the hip, so the gun moves on with a good chance of no harm
  ## done; everything else is a head-shot.
  let targets = sim.validTargets(seat)
  let target = targets[client.rand[seat].rand(targets.high)]
  Decision(
    say: CannedTaunts[client.rand[seat].rand(CannedTaunts.high)],
    target: target,
    aim: (if target == sim.seats[seat].friend: aimHip else: aimHead)
  )

proc scriptedReaction*(client: LlmClient, sim: Sim, seat: int): Decision =
  Decision(
    say: CannedReactions[client.rand[seat].rand(CannedReactions.high)],
    target: -1
  )

proc seatName(sim: Sim, seat: int): string =
  sim.seats[seat].name

proc renderHistory(sim: Sim, me: int): string =
  ## The full public record of the table so far, in reading order. Shots
  ## read as hit or miss only — the aim is secret — except that a cog is
  ## reminded how IT aimed its own shots.
  var lines: seq[string]
  for event in sim.events:
    case event.kind
    of evRoundStart:
      lines.add("Round " & $(event.round + 1) & " begins; secret cards dealt.")
    of evDeal:
      discard  ## cards are secret; each seat is told only its own
    of evIt:
      lines.add(sim.seatName(event.seat) & " is now IT (holds the paintgun).")
    of evSay:
      lines.add(sim.seatName(event.seat) & " says: \"" & event.text & "\"")
    of evSkip:
      lines.add(sim.seatName(event.seat) &
        " holds fire and keeps the paintgun.")
    of evShot:
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
      lines.add(sim.seatName(event.seat) & " is OUT of the game.")
    of evScore:
      if event.text == "foe":
        lines.add(sim.seatName(event.seat) &
          " scored a point for taking out their secret enemy.")
      ## survivor/friend deltas land after the round verdict; the round
      ## summary already covers them.
    of evRoundEnd:
      lines.add(sim.seatName(event.seat) & " WINS the round.")
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
      "This match is " & $sim.config.rounds & " rounds."
    else:
      "How many rounds this match runs is NOT known to the table - it could end after any round."
  survivorText & "\n- " & roundText

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
- AIM: a HEAD-SHOT always hits. A HIP-SHOT misses 2 times in 3 (no damage,
  but the target still takes the gun). Nobody is told which aim a shooter
  chose - the table sees only
  whether the shot landed - so a hip-shot can pass the gun to a friend
  while probably leaving them unhurt, or fake a grudge.
- IT may PASS instead of shooting, a limited number of times per round:
  the gun stays put and the table keeps talking. The allowance is shared
  by the whole table and resets each round.
- HEALTH: all cogs return alive with """ & $sim.config.hitPoints & """ hp at the
  start of every round.
- CARDS: every round each cog is secretly dealt a FRIEND and an ENEMY
  (never itself, never the same cog). Nobody else knows your cards, and
  the deal reshuffles every round.
- Round scoring: 3 points for SURVIVING the round, 1 point for fatally
  shooting your ENEMY, 1 point if your FRIEND survives.
- """ & tableRules(sim) & """
- Points accumulate across rounds and the highest match total wins.
- Talk, plead, threaten, bargain, form and betray alliances - anything
  said is heard by the whole table, and grudges carry across rounds. Use
  the table talk to steer shots toward your enemy and away from your
  friend without giving your cards away.

Respond with a single JSON object and nothing else."""

proc shotInstruction(sim: Sim, seat: int): string =
  var names: seq[string]
  for target in sim.validTargets(seat):
    names.add("\"" & sim.seatName(target) & "\"")
  let passes = sim.skipsLeft()
  result = "You are IT. Choose exactly one living cog to shoot and say " &
    "something to the table first (max " & $MaxSayLen & " chars).\n" &
    "Choose your AIM: \"head\" always hits; \"hip\" misses 2 in 3 but " &
    "the target takes the gun either way, and nobody learns which you " &
    "chose.\n"
  let aimField = ", \"aim\": <\"head\" or \"hip\">"
  if passes > 0:
    result.add("You may instead PASS: hold your fire and let the table " &
      "keep talking (" & $passes &
      (if passes == 1: " pass" else: " passes") & " left this round).\n" &
      "Respond with JSON: {\"say\": \"...\", \"shoot\": <one of " &
      names.join(", ") & ", or \"pass\">" & aimField & "}")
  else:
    result.add("Respond with JSON: {\"say\": \"...\", \"shoot\": <one of " &
      names.join(", ") & ">" & aimField & "}")

proc reactionInstruction(): string =
  "You are not IT right now. Say one short line to the table (max " &
    $MaxSayLen & " chars) - plead, deflect, scheme, or stir the pot.\n" &
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
    result.add(reactionInstruction())

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

proc seatByName(sim: Sim, name: string): int =
  for index, seat in sim.seats:
    if seat.name == name:
      return index
  -1

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

proc parseDecision*(sim: Sim, seat: int, payload: JsonNode,
    wantShot: bool): Decision =
  result = Decision(say: cleanSay(payload{"say"}.getStr()), target: -1)
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
