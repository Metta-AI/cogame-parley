## Frozen native seat identity. Never resolve model identity from player registration.
import std/[algorithm, json, sets, strutils, sequtils]
import checksums/sha2

type
  ModelSeatBinding* = object
    seat*: int
    actorId*, policyId*, role*: string
    model*, tokenizerIdentity*, chatTemplateSha256*: string
    promptSha256*, actionMode*, assistanceId*, assistanceSha256*: string
    temperature*: float
    maxOutputTokens*: int

  ModelRoster* = object
    sha256*: string
    bindings*: seq[ModelSeatBinding]

proc canonicalJson*(node: JsonNode): string =
  case node.kind
  of JObject:
    var keys: seq[string]
    for key in node.keys: keys.add(key)
    keys.sort()
    var fields: seq[string]
    for key in keys: fields.add($(%key) & ":" & canonicalJson(node[key]))
    "{" & fields.join(",") & "}"
  of JArray:
    var values: seq[string]
    for value in node: values.add(canonicalJson(value))
    "[" & values.join(",") & "]"
  else: $node

proc sha256Text*(text: string): string =
  var state = initSha_256()
  state.update(text)
  ($state.digest()).toLowerAscii()

proc bindingJson*(binding: ModelSeatBinding): JsonNode =
  %*{"seat": binding.seat, "actor_id": binding.actorId,
    "policy_id": binding.policyId, "role": binding.role,
    "model": binding.model, "tokenizer_identity": binding.tokenizerIdentity,
    "chat_template_sha256": binding.chatTemplateSha256,
    "prompt_sha256": binding.promptSha256, "action_mode": binding.actionMode,
    "assistance_id": binding.assistanceId,
    "assistance_sha256": binding.assistanceSha256,
    "decoder": {"temperature": binding.temperature,
      "max_tokens": binding.maxOutputTokens, "thinking": {"type": "disabled"}}}

proc rosterPayload*(roster: ModelRoster): JsonNode =
  var bindings = newJArray()
  for binding in roster.bindings: bindings.add(binding.bindingJson())
  %*{"protocol": "parley.model-roster.v1", "bindings": bindings}

proc rosterJson*(roster: ModelRoster): JsonNode =
  result = roster.rosterPayload()
  result["sha256"] = %roster.sha256

proc parseModelRoster*(node: JsonNode): ModelRoster =
  if node["protocol"].getStr() != "parley.model-roster.v1" or
      node["bindings"].kind != JArray or node["bindings"].len != 5:
    raise newException(ValueError, "Native model roster requires exactly five declared seats")
  var actors, policies: HashSet[string]
  var learners = 0
  for seat, row in node["bindings"].getElems():
    let binding = ModelSeatBinding(seat: row["seat"].getInt(),
      actorId: row["actor_id"].getStr(), policyId: row["policy_id"].getStr(),
      role: row["role"].getStr(), model: row["model"].getStr(),
      tokenizerIdentity: row["tokenizer_identity"].getStr(),
      chatTemplateSha256: row["chat_template_sha256"].getStr(),
      promptSha256: row["prompt_sha256"].getStr(),
      actionMode: row["action_mode"].getStr(), assistanceId: row["assistance_id"].getStr(),
      assistanceSha256: row["assistance_sha256"].getStr(),
      temperature: row["decoder"]["temperature"].getFloat(),
      maxOutputTokens: row["decoder"]["max_tokens"].getInt())
    if binding.seat != seat or binding.role notin ["learner", "opponent"] or
        binding.actorId.len == 0 or binding.policyId.len == 0 or
        binding.actorId in actors or binding.policyId in policies or
        not binding.model.startsWith("local-sha256:") or
        binding.model.len != 77 or
        binding.model[13 .. ^1].anyIt(it notin {'0'..'9', 'a'..'f'}) or
        not (binding.tokenizerIdentity.len == 64 or
          (binding.tokenizerIdentity.startsWith("sha256:") and binding.tokenizerIdentity.len == 71) or
          (binding.tokenizerIdentity.startsWith("local-sha256:") and binding.tokenizerIdentity.len == 77)) or
        not (binding.temperature >= 0 and binding.temperature <= 1) or
        binding.maxOutputTokens < 1 or binding.maxOutputTokens > 2000 or
        row["decoder"]["thinking"] != %*{"type": "disabled"}:
      raise newException(ValueError, "Native seat identity or decoder differs from roster contract")
    for identity in [binding.actorId, binding.policyId, binding.tokenizerIdentity]:
      if identity.anyIt(it < ' ' or it == '\x7f'):
        raise newException(ValueError, "Native identities cannot contain HTTP control characters")
    let tokenizerDigest = binding.tokenizerIdentity.split(':')[^1]
    for digest in [tokenizerDigest, binding.chatTemplateSha256, binding.promptSha256, binding.assistanceSha256]:
      if digest.len != 64 or digest.anyIt(it notin {'0'..'9', 'a'..'f'}):
        raise newException(ValueError, "Native roster requires lowercase SHA256 identities")
    if binding.actionMode != "generated-json" or binding.assistanceId != "none":
      raise newException(ValueError, "Legal-choice scoring needs its distinct qualified producer protocol")
    if binding.assistanceSha256 != sha256Text("{\"id\":\"none\",\"version\":1}"):
      raise newException(ValueError, "Generated-json assistance identity must describe no assistance")
    actors.incl(binding.actorId)
    policies.incl(binding.policyId)
    learners += int(binding.role == "learner")
    result.bindings.add(binding)
  if learners != 1:
    raise newException(ValueError, "Native roster requires one learner and four opponents")
  result.sha256 = sha256Text(canonicalJson(result.rosterPayload()))
  if node["sha256"].getStr() != result.sha256 or canonicalJson(node) != canonicalJson(result.rosterJson()):
    raise newException(ValueError, "Native roster hash or declared fields differ from immutable binding")

proc validatePrompt*(binding: ModelSeatBinding, prompt: string) =
  if sha256Text(prompt) != binding.promptSha256:
    raise newException(ValueError, "Player prompt differs from frozen seat identity")
