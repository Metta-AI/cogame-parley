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
  MaxSayLen = 240

type
  Decision* = object
    say*: string
    target*: int      ## seat index; -1 for pure table talk

  LlmClient* = ref object
    curl: Curly
    apiKey: string
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

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    apiKey: resolveApiKey(),
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    rand: initRand(config.seed xor 0x5EED)
  )
  result.disabled = result.apiKey.len == 0
  if result.disabled:
    echo "parley llm: no Anthropic credentials; using scripted fallback"
  else:
    result.curl = newCurly()
    echo "parley llm: using model ", result.model

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
  let targets = sim.validTargets(seat)
  Decision(
    say: CannedTaunts[client.rand.rand(CannedTaunts.high)],
    target: targets[client.rand.rand(targets.high)]
  )

proc scriptedReaction*(client: LlmClient, sim: Sim, seat: int): Decision =
  Decision(
    say: CannedReactions[client.rand.rand(CannedReactions.high)],
    target: -1
  )

proc seatName(sim: Sim, seat: int): string =
  sim.seats[seat].name

proc renderHistory(sim: Sim): string =
  ## The full public record of the table so far, in reading order.
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
    of evShot:
      lines.add(sim.seatName(event.seat) & " SHOOTS " &
        sim.seatName(event.target) & " (now " & $max(event.hpAfter, 0) &
        " hp).")
    of evDeath:
      lines.add(sim.seatName(event.seat) & " is OUT of the game.")
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

proc systemPrompt(sim: Sim, seat: int): string =
  """You are """ & sim.seatName(seat) &
    """, a cog seated at a round table in a game of Parley.

Rules of Parley:
- One cog is IT and holds the paintgun.
- On its turn, IT says something to the table and then shoots one other
  living cog. The shot cog loses 1 hp and becomes IT.
- If the shot knocks a cog to 0 hp, that cog is OUT and the shooter keeps
  the paintgun.
- CARDS: every round each cog is secretly dealt a FRIEND and an ENEMY
  (never itself, never the same cog). Nobody else knows your cards, and
  the deal reshuffles every round.
- Round scoring: 3 points for being the last cog standing, 1 point for
  fatally shooting your ENEMY, 1 point if your FRIEND is last standing.
- A match is several rounds; points accumulate and the highest match
  total wins.
- Talk, plead, threaten, bargain, form and betray alliances - anything
  said is heard by the whole table, and grudges carry across rounds. Use
  the table talk to steer shots toward your enemy and away from your
  friend without giving your cards away.

Respond with a single JSON object and nothing else."""

proc shotInstruction(sim: Sim, seat: int): string =
  var names: seq[string]
  for target in sim.validTargets(seat):
    names.add("\"" & sim.seatName(target) & "\"")
  "You are IT. Choose exactly one living cog to shoot and say something " &
    "to the table first (max " & $MaxSayLen & " chars).\n" &
    "Respond with JSON: {\"say\": \"...\", \"shoot\": <one of " &
    names.join(", ") & ">}"

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
    "\n\nWhat has happened this round:\n" & sim.renderHistory() & "\n\n")
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
  let body = %*{
    "model": client.model,
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "output_config": {"effort": "low"},
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  headers["x-api-key"] = client.apiKey
  headers["anthropic-version"] = AnthropicVersion
  let response = client.curl.post(
    AnthropicUrl, headers, $body, client.timeoutSeconds
  )
  if response.code == 401 or response.code == 403:
    ## Credentials are bad; stop trying for the rest of the episode.
    client.disabled = true
    raise newException(ParleyError,
      "anthropic auth failed (" & $response.code & ")")
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
  if result.len > MaxSayLen:
    result = result[0 ..< MaxSayLen]

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
        decision.target = sim.seatByName(targetName)
        if decision.target < 0 or decision.target == seat or
            not sim.seats[decision.target].alive:
          raise newException(ParleyError,
            "illegal target: " & targetName)
      return decision
    except CatchableError as error:
      echo "parley llm: seat ", seat, " attempt ", attempt, " failed: ",
        error.msg
      if client.disabled:
        break
  echo "parley llm: seat ", seat, " falling back to scripted decision"
  if wantShot: client.scriptedShot(sim, seat)
  else: client.scriptedReaction(sim, seat)
