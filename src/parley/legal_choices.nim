## Restricted speech is declared assistance, never ordinary generated dialogue.
import std/[json, math]
import model_routes, sim

type
  ChoiceTokens* = object
    action_sha256*: string
    score*: float
    full_input_token_ids*, scored_token_positions*, target_token_ids*: seq[int]
    per_token_log_probs*: seq[float]
  ChoiceResponse* = object
    protocol*, provider_call_id*, model_identity*, tokenizer_identity*: string
    chat_template_sha256*, candidate_sha256*, score_rule*: string
    candidates*: seq[ChoiceTokens]
  ChoiceFault* = enum
    cfIdentity = "identity", cfCandidate = "candidate", cfTokenContract = "token-contract",
    cfNonfinite = "nonfinite", cfScoreSum = "score-sum", cfProviderId = "missing-provider-id"
  ChoiceValidation* = object
    case valid*: bool
    of true: selectedIndex*: int
    of false: fault*: ChoiceFault

proc legalCandidates*(sim: Sim, seat: int, wantShot: bool): JsonNode =
  if sim.done or seat < 0 or seat >= sim.seats.len or not sim.seats[seat].alive or
      (wantShot and seat != sim.itSeat):
    raise newException(ValueError, "Legal choices require a living acting seat")
  result = newJArray()
  if wantShot:
    for target in sim.validTargets(seat):
      for aim in ["head", "hip"]:
        result.add(%*{"say": "", "shoot": sim.seats[target].name, "aim": aim})
    if sim.skipsLeft() > 0:
      # Engine action serialization omits aim on a pass; retain exact action parity.
      result.add(%*{"say": "", "shoot": "pass"})
  else:
    result.add(%*{"say": ""})
  if result.len == 0 or result.len > 128:
    raise newException(ValueError, "Legal candidate count outside scoring contract")

proc choiceRequest*(binding: ModelSeatBinding, rosterHash, system, user: string,
    actions: JsonNode): JsonNode =
  var candidates = newJArray()
  for action in actions: candidates.add(%canonicalJson(action))
  %*{"protocol": "parley.legal-choice-score-request.v1", "model": binding.model,
    "seat": binding.seat, "actor_id": binding.actorId, "policy_id": binding.policyId,
    "model_roster_sha256": rosterHash, "assistance_sha256": binding.assistanceSha256,
    "candidate_sha256": sha256Text(canonicalJson(actions)), "system": system,
    "messages": [{"role": "user", "content": user}], "candidates": candidates,
    "score_rule": ChoiceScoreRule}

proc rejectedChoiceEvidence*(binding: ModelSeatBinding, rosterHash: string,
    actions: JsonNode, fault: string): JsonNode =
  %*{"protocol": "parley.native-legal-choice.v1", "action_mode": "legal_choice_ranking",
    "assistance_id": binding.assistanceId, "assistance_version": 1,
    "assistance_sha256": binding.assistanceSha256, "model_roster_sha256": rosterHash,
    "seat": binding.seat, "actor_id": binding.actorId, "policy_id": binding.policyId,
    "candidate_actions": actions, "candidate_sha256": sha256Text(canonicalJson(actions)),
    "score_rule": ChoiceScoreRule, "tie_break": "lowest-declared-index",
    "scoring_result": {"status": "rejected", "fault_kind": fault}}

proc validateChoices*(response: ChoiceResponse, binding: ModelSeatBinding,
    actions: JsonNode, providerId: string): ChoiceValidation =
  if response.provider_call_id != providerId or not isProviderCallId(providerId):
    return ChoiceValidation(valid: false, fault: cfProviderId)
  if response.model_identity != binding.model or
      response.tokenizer_identity != binding.tokenizerIdentity or
      response.chat_template_sha256 != binding.chatTemplateSha256:
    return ChoiceValidation(valid: false, fault: cfIdentity)
  if response.protocol != "parley.legal-choice-score-response.v1" or
      response.score_rule != ChoiceScoreRule or
      response.candidate_sha256 != sha256Text(canonicalJson(actions)) or
      response.candidates.len != actions.len:
    return ChoiceValidation(valid: false, fault: cfCandidate)
  var prefix: seq[int]
  var selected = 0
  for index, candidate in response.candidates:
    if candidate.action_sha256 != sha256Text(canonicalJson(actions[index])):
      return ChoiceValidation(valid: false, fault: cfCandidate)
    if candidate.score.classify in {fcNan, fcInf, fcNegInf}:
      return ChoiceValidation(valid: false, fault: cfNonfinite)
    let positions = candidate.scored_token_positions
    if positions.len == 0 or positions[0] <= 0 or
        positions[0] >= candidate.full_input_token_ids.len or
        positions.len != candidate.full_input_token_ids.len - positions[0] or
        positions.len != candidate.target_token_ids.len or
        positions.len != candidate.per_token_log_probs.len:
      return ChoiceValidation(valid: false, fault: cfTokenContract)
    for token in candidate.full_input_token_ids:
      if token < 0: return ChoiceValidation(valid: false, fault: cfTokenContract)
    let candidatePrefix = candidate.full_input_token_ids[0 ..< positions[0]]
    if index == 0: prefix = candidatePrefix
    elif prefix != candidatePrefix:
      return ChoiceValidation(valid: false, fault: cfTokenContract)
    var total, correction: float
    for offset, position in positions:
      if position != positions[0] + offset or
          candidate.target_token_ids[offset] != candidate.full_input_token_ids[position]:
        return ChoiceValidation(valid: false, fault: cfTokenContract)
      let probability = candidate.per_token_log_probs[offset]
      if probability.classify in {fcNan, fcInf, fcNegInf}:
        return ChoiceValidation(valid: false, fault: cfNonfinite)
      let updated = total + probability
      correction += (if abs(total) >= abs(probability):
          (total - updated) + probability else: (probability - updated) + total)
      total = updated
    total += correction
    if total.classify in {fcNan, fcInf, fcNegInf} or
        abs(candidate.score - total) > 1e-6 + 1e-7 * abs(total):
      return ChoiceValidation(valid: false, fault: cfScoreSum)
    if candidate.score > response.candidates[selected].score: selected = index
  ChoiceValidation(valid: true, selectedIndex: selected)

proc scoredChoiceEvidence*(initial, response: JsonNode, selected: int): JsonNode =
  result = copy(initial)
  var scored = copy(response)
  scored["status"] = %"scored"
  scored["selected_index"] = %selected
  scored["selected_action_sha256"] = %sha256Text(canonicalJson(initial["candidate_actions"][selected]))
  result["scoring_result"] = scored
