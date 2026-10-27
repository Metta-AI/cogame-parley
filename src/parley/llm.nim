## Native-sidecar decisions through the same private seat prompts and parser.
## Model failures retain their evidence and never substitute a scripted action.

import
  std/[base64, json, monotimes, options, os, random, sets, strutils, tables],
  bitworld/decision_trajectory,
  bitworld/[native_http, native_stop],
  sim
from std/unicode import validateUtf8

type
  Decision* = object
    say*: string
    target*: int      ## seat index; -1 for pure table talk
    skip*: bool       ## "it" holds fire this turn instead of shooting
    aim*: ShotAim     ## head (lands 5 in 6) or hip (lands 1 in 3, gun still moves)
    extras*: Extras   ## whisper / reveal / give / pledge alongside the action

  DecisionFailure* = enum
    dfRejectedAction = "rejected_action"
    dfExternalTimeout = "external_timeout"
    dfExternalDisconnect = "external_disconnect"
    dfMissingEndpoint = "missing_native_endpoint"
    dfModelFailure = "model_failure"
    dfInferenceUnavailable = "inference_unavailable"
    dfBudgetExhausted = "budget_exhausted"
    dfEpisodeDeadline = "episode_deadline"
    dfMissingPolicy = "missing_policy"

  DecisionResult* = object
    failure*: Option[DecisionFailure]
    decision*: Decision
    origin*: string
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
  echo "parley llm: no native endpoint; model policies cannot run"

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

proc parseJsonObject*(text: string): JsonNode =
  ## Training labels must contain only the requested action object.
  result = parseJson(text)
  if result.kind != JObject:
    raise newException(ParleyError, "response must be a JSON object")

proc actionSchema*(sim: Sim, seat: int, wantShot: bool): JsonNode =
  ## Constrain native generation to the same currently legal actions as the parser.
  let me = sim.seats[seat]
  var others, targets, pledgeable: seq[string]
  for index, other in sim.seats:
    if index != seat:
      others.add(other.name)
      if other.alive:
        targets.add(other.name)
        if index notin me.pledges: pledgeable.add(other.name)
  if sim.skipsLeft() > 0: targets.add("pass")
  var properties = %*{"say": {"type": "string"}}
  if wantShot:
    properties["shoot"] = %*{"type": "string", "enum": targets}
    properties["aim"] = %*{"type": "string", "enum": ["head", "hip"]}
  if me.whispers < MaxWhispers:
    properties["whisper"] = %*{"anyOf": [{"type": "null"},
      {"type": "object", "additionalProperties": false, "required": ["to", "text"],
       "properties": {"to": {"type": "string", "enum": others}, "text": {"type": "string"}}}]}
  if me.friend >= 0 and not me.revealed:
    properties["reveal"] = %*{"anyOf": [{"type": "null"},
      {"type": "object", "additionalProperties": false, "required": ["to", "card"],
       "properties": {"to": {"type": "string", "enum": others},
                      "card": {"type": "string", "enum": ["friend", "enemy"]}}}]}
  if sim.banked[seat] + sim.transfers[seat] >= 1:
    properties["give"] = %*{"anyOf": [{"type": "null"}, {"type": "string", "enum": others}]}
  if me.alive and pledgeable.len > 0:
    properties["pledge"] = %*{"anyOf": [{"type": "null"}, {"type": "string", "enum": pledgeable}]}
  var required = newJArray()
  for key, value in properties: required.add(%key)
  %*{"type": "object", "properties": properties, "required": required, "additionalProperties": false}

proc completeText(client: LlmClient, seat: int, observation: JsonNode,
    evidence: var DecisionAttempt, failure: var DecisionFailure, deadline: MonoTime): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": client.temperature,
    "top_p": 1,
    "reasoning": {"effort": "none"},
    "chat_template_kwargs": {"enable_thinking": false},
    "response_format": {"type": "json_schema",
      "json_schema": {"name": "parley_action", "strict": true, "schema": observation["actionSchema"]}},
    "messages": [{"role": "system", "content": observation["input"]["system"]},
      {"role": "user", "content": observation["input"]["user"]}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  body["model"] = %client.model
  headers["x-coworld-player-slot"] = $seat
  let url = client.sidecarEndpoint & "/v1/chat/completions"
  evidence.request = body
  evidence.prompt = body["messages"]
  evidence.model = some(client.model)
  evidence.decoder = copy(body)
  evidence.decoder.delete("model")
  evidence.decoder.delete("messages")
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
    failure = dfInferenceUnavailable
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
    failure = dfInferenceUnavailable
    raise newException(ParleyError, "llm throttled (429)")
  if status >= 500:
    failure = dfInferenceUnavailable
  if status < 200 or status >= 300:
    raise newException(ParleyError,
      "native inference error " & $status)
  if validateUtf8(response.bodyBytes) != -1:
    raise newException(ParleyError, "native response is not valid UTF-8")
  let payload = parseJson(response.bodyBytes)
  evidence.model = some(payload["model"].getStr())
  let choice = payload["choices"][0]
  let stopReason = choice["finish_reason"].getStr()
  evidence.stopReason = some(stopReason)
  evidence.inputTokens = some(payload["usage"]["prompt_tokens"].getInt())
  evidence.outputTokens = some(payload["usage"]["completion_tokens"].getInt())
  evidence.response = choice["message"]["content"]
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
  echo "parley llm: usage model ", evidence.model.get(),
    " input_tokens ", evidence.inputTokens.get(),
    " output_tokens ", evidence.outputTokens.get()
  if stopReason != "stop":
    raise newException(ParleyError, "native inference stopped without a complete action: " & stopReason)
  if evidence.response.kind != JString:
    raise newException(ParleyError, "native inference returned no text action")
  result = evidence.response.getStr()

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
    let name = node.getStr().strip()
    let seat = sim.seatByName(name)
    if seat < 0:
      raise newException(ParleyError, field & " names no cog: " & name)
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
  observation: JsonNode,
  deadline: MonoTime
): DecisionResult =
  ## Keep a failed policy's original evidence; no retries or substitute actions.
  if client.disabled or client.budgetExhausted[seat]:
    result.failure = some(if client.budgetExhausted[seat]: dfBudgetExhausted else: dfMissingEndpoint)
    return
  if interruptionRequested() or getMonoTime() >= deadline:
    result.failure = some(dfEpisodeDeadline)
    return

  let wantShot = observation["phase"].getStr() == "shot"
  var raw = ""
  var failure = dfModelFailure
  var evidence = newDecisionAttempt("attempt-0", client.model, aoModel)
  try:
    raw = client.completeText(seat, observation, evidence, failure, deadline)
    let payload = parseJsonObject(raw)
    result.decision = parseDecision(sim, seat, payload, wantShot)
    evidence.response = %raw
    evidence.parsedAction = decisionAction(sim, result.decision, wantShot)
    if interruptionRequested() or getMonoTime() >= deadline:
      raise newException(ParleyError, "native response arrived after decision deadline")
    evidence.accepted = true
    result.nativeAttempts.add(evidence)
    result.origin = "model"
  except CatchableError as error:
    if evidence.response.kind == JNull:
      evidence.response = %raw
    evidence.rejectionReason = some(error.msg)
    result.nativeAttempts.add(evidence)
    result.failure = some(if client.budgetExhausted[seat]: dfBudgetExhausted else: failure)
    echo "parley llm: seat ", seat, " policy failed"
