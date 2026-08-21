## Sonnet-backed decision making for Parley. Each seat's policy is just a
## prompt: the game server composes the table state plus that seat's prompt
## and asks Claude what the cog says and (for "it") who it shoots.
##
## Credentials, in order of preference:
##   ANTHROPIC_API_KEY      - the key itself.
##   ANTHROPIC_API_KEY_URI  - a URI holding the key. Hosted episodes set this
##     to a `secret://` reference that the platform resolves to a presigned
##     HTTPS URL at dispatch time; locally a file:// path works.
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing.

import
  std/[json, options, os, random, strutils],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## What the viewer's speech bubble can actually show (~4 wrapped lines).
  ## Anything longer would render cut off mid-sentence at the table.
  MaxSayLen = 160

type
  Decision* = object
    say*: string
    target*: int      ## seat index; -1 for pure table talk
    skip*: bool       ## "it" holds fire this turn instead of shooting
    aim*: ShotAim     ## head (always lands) or hip (gamble, gun still moves)

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public runtime host
    bedrockModels: seq[string]  ## candidates, tried in order on model-access denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled: bool    ## true once credentials are known-unavailable
    rand: Rand

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "parley llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins a
  ## single id (the platform's player convention); the game container is not
  ## given that env, so it falls back to this list. Bedrock model access is a
  ## per-account Marketplace subscription, so an id that works in one account
  ## 403s in another - hence a list rather than one hardcoded id.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the sonnet
  ## profiles run out of daily tokens first, and table talk does not need a
  ## bigger model than the round can spend.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  ## Bedrock rejects a model per-account (no Marketplace subscription) and
  ## per-day (shared capacity exhausted) with different statuses but the same
  ## remedy: this model is unusable right now, so move to the next candidate.
  if client.transport != ltBedrock or client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "parley llm: ", client.bedrockModels[client.bedrockModel - 1], " unusable (", why,
    "); falling back to ", client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" & client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    rand: initRand(config.seed xor 0x5EED)
  )
  ## Preferred transport: Bedrock. Hosted pods get a platform sidecar
  ## (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + a dummy bearer token it re-signs);
  ## a real AWS_BEARER_TOKEN_BEDROCK against the public endpoint also works.
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "parley llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "parley llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "parley llm: no LLM credentials; using scripted fallback"

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
  let target = targets[client.rand.rand(targets.high)]
  Decision(
    say: CannedTaunts[client.rand.rand(CannedTaunts.high)],
    target: target,
    aim: (if target == sim.seats[seat].friend: aimHip else: aimHead)
  )

proc scriptedReaction*(client: LlmClient, sim: Sim, seat: int): Decision =
  Decision(
    say: CannedReactions[client.rand.rand(CannedReactions.high)],
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

proc systemPrompt(sim: Sim, seat: int): string =
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
  the gun stays put and the table keeps talking.
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

proc userPrompt(
  sim: Sim, seat: int, prompt: string, wantShot: bool, header: string
): string =
  if header.len > 0:
    result.add(header & "\n\n")
  result.add("Seats at the table:\n" & sim.renderSeats() &
    "\n\nWhat has happened this round:\n" & sim.renderHistory(seat) & "\n\n")
  let me = sim.seats[seat]
  if me.friend >= 0 and me.enemy >= 0:
    result.add("Your SECRET cards this round: FRIEND = " &
      sim.seatName(me.friend) & " (1 pt to you if they are last standing)" &
      ", ENEMY = " & sim.seatName(me.enemy) &
      " (1 pt to you if YOUR shot takes them out). Keep them secret.\n\n")
  if prompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always pick a legal action):\n" & prompt & "\n\n")
  if wantShot:
    result.add(sim.shotInstruction(seat))
  else:
    result.add(reactionInstruction())

proc extractJsonObject(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    raise newException(ParleyError, "no JSON object in response")
  parseJson(text[start .. stop])

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(
    url, headers, $body, client.timeoutSeconds
  )
  if response.code == 401 or response.code == 403:
    ## Bedrock answers "this account has no Marketplace subscription for that
    ## model" with the same 403 it uses for bad credentials, so distinguish
    ## them: an unsubscribed model means try the next candidate, whereas bad
    ## credentials mean every further call would fail too. Carry the body -
    ## without it a hosted 403 is undiagnosable from the episode log.
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and client.tryNextBedrockModel("no model access"):
      raise newException(ParleyError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(ParleyError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    ## Shared hosted capacity, not our quota: another model may still have room.
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(ParleyError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(ParleyError,
      "anthropic error " & $response.code & ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(ParleyError, "anthropic refusal")
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

proc decide*(
  client: LlmClient,
  sim: Sim,
  seat: int,
  prompt: string,
  wantShot: bool,
  header = ""
): Decision =
  ## One decision for one seat. Never raises: any failure falls back to the
  ## scripted baseline so the game always advances.
  if client.disabled:
    return
      if wantShot: client.scriptedShot(sim, seat)
      else: client.scriptedReaction(sim, seat)

  let system = systemPrompt(sim, seat)
  for attempt in 0 .. 1:
    var user = userPrompt(sim, seat, prompt, wantShot, header)
    if attempt > 0:
      user.add("\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object and a legal target.")
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      var decision = Decision(
        say: cleanSay(payload{"say"}.getStr()),
        target: -1
      )
      if wantShot:
        let targetName = payload{"shoot"}.getStr().strip()
        if targetName.toLowerAscii() == "pass" and sim.skipsLeft() > 0:
          decision.skip = true
          return decision
        decision.target = sim.seatByName(targetName)
        if decision.target < 0 or decision.target == seat or
            not sim.seats[decision.target].alive:
          raise newException(ParleyError,
            "illegal target: " & targetName)
        ## Aim defaults to the head: a model that omits the field still
        ## fires a legal shot.
        if payload{"aim"}.getStr().strip().toLowerAscii() == "hip":
          decision.aim = aimHip
      return decision
    except CatchableError as error:
      echo "parley llm: seat ", seat, " attempt ", attempt, " failed: ",
        error.msg
      if client.disabled:
        break
  echo "parley llm: seat ", seat, " falling back to scripted decision"
  if wantShot: client.scriptedShot(sim, seat)
  else: client.scriptedReaction(sim, seat)
