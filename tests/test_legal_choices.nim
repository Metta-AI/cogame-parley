import std/[json, strutils, unittest]
import parley/[legal_choices, model_routes, sim]

proc fixture(): Sim =
  var config = defaultGameConfig()
  config.sampled = true
  config.seed = 0
  config.maxSkips = 1
  for seat in 0 ..< 5:
    config.players.add(PlayerConfig(name: "policy-" & $seat))
  initSim(config)

proc binding(): ModelSeatBinding =
  ModelSeatBinding(seat: 0, actorId: "actor-0", policyId: "policy-0",
    model: "local-sha256:" & repeat('a', 64), tokenizerIdentity: repeat('b', 64),
    chatTemplateSha256: repeat('c', 64), actionMode: "legal_choice_ranking",
    assistanceId: "legal-private-actions-v1",
    assistanceSha256: sha256Text(canonicalJson(legalAssistanceProfile())))

proc scored(actions: JsonNode): ChoiceResponse =
  let identity = binding()
  result = ChoiceResponse(protocol: "parley.legal-choice-score-response.v1",
    provider_call_id: "12345678-1234-1234-1234-123456789abc",
    model_identity: identity.model, tokenizer_identity: identity.tokenizerIdentity,
    chat_template_sha256: identity.chatTemplateSha256,
    candidate_sha256: sha256Text(canonicalJson(actions)), score_rule: ChoiceScoreRule)
  for action in actions:
    result.candidates.add(ChoiceTokens(action_sha256: sha256Text(canonicalJson(action)),
      score: -3.0, full_input_token_ids: @[10, 20, 30, 40],
      scored_token_positions: @[2, 3], target_token_ids: @[30, 40],
      per_token_log_probs: @[-1.0, -2.0]))

suite "Native legal-choice assistance":
  test "enumeration follows living seat order, aim order and actual pass format":
    var sim = fixture()
    sim.seats[2].alive = false
    let actions = sim.legalCandidates(0, true)
    check actions.len == 7
    for index, target in [1, 3, 4]:
      check actions[index * 2] == %*{"say": "", "shoot": sim.seats[target].name, "aim": "head"}
      check actions[index * 2 + 1]["aim"] == %"hip"
    check actions[^1] == %*{"say": "", "shoot": "pass"}
    sim.skips = 1
    check sim.legalCandidates(0, true).len == 6
    check sim.legalCandidates(1, false) == %*[{"say": ""}]
    expect ValueError: discard sim.legalCandidates(2, false)
    expect ValueError: discard sim.legalCandidates(1, true)

  test "request retains exact canonical candidates and stable identity":
    let actions = fixture().legalCandidates(0, true)
    let request = choiceRequest(binding(), repeat('d', 64), "system", "user", actions)
    check request["model"] == %binding().model
    check request["candidate_sha256"] == %sha256Text(canonicalJson(actions))
    check request["candidates"][0] == %canonicalJson(actions[0])
    check not request.hasKey("max_tokens")

  test "finite score argmax uses lowest declared index on ties":
    let actions = fixture().legalCandidates(0, true)
    var response = scored(actions)
    let provider = response.provider_call_id
    check validateChoices(response, binding(), actions, provider).selectedIndex == 0
    response.candidates[2].score = -1
    response.candidates[2].per_token_log_probs = @[-0.5, -0.5]
    check validateChoices(response, binding(), actions, provider).selectedIndex == 2
    let initial = rejectedChoiceEvidence(binding(), repeat('d', 64), actions, "transport")
    let evidence = scoredChoiceEvidence(initial, %response, 2)
    check evidence["scoring_result"]["status"] == %"scored"
    check evidence["scoring_result"]["selected_action_sha256"] == %response.candidates[2].action_sha256
    check initial["scoring_result"]["status"] == %"rejected"

  test "identity, order, token masks, prefix, nonfinite and sum faults reject":
    let actions = fixture().legalCandidates(0, true)
    for fault in ["identity", "order", "mask", "prefix", "target", "nan", "sum", "provider"]:
      var response = scored(actions)
      case fault
      of "identity": response.model_identity = "foreign"
      of "order": response.candidates[0].action_sha256 = response.candidates[1].action_sha256
      of "mask": response.candidates[0].scored_token_positions = @[2, 2]
      of "prefix": response.candidates[1].full_input_token_ids[0] = 99
      of "target": response.candidates[0].target_token_ids[0] = 99
      of "nan": response.candidates[0].per_token_log_probs[0] = NaN
      of "sum": response.candidates[0].score = -2.9
      else: response.provider_call_id = "foreign"
      check not validateChoices(response, binding(), actions,
        "12345678-1234-1234-1234-123456789abc").valid
