import std/[json, strutils, unittest]
import parley/model_routes

proc fixtureRoster(): ModelRoster =
  for seat in 0 ..< 5:
    result.bindings.add(ModelSeatBinding(seat: seat, actorId: "actor-" & $seat,
      policyId: "policy-" & $seat, role: (if seat == 0: "learner" else: "opponent"),
      model: "local-sha256:" & repeat($seat, 64),
      tokenizerIdentity: "local-sha256:" & repeat('b', 64), chatTemplateSha256: repeat('a', 64),
      promptSha256: sha256Text("prompt-" & $seat), actionMode: "generated-json",
      assistanceId: "none", assistanceSha256: sha256Text("{\"id\":\"none\",\"version\":1}"),
      temperature: 0.0, maxOutputTokens: 300))
  result.sha256 = sha256Text(canonicalJson(result.rosterPayload()))

suite "Frozen native model routing":
  test "seat identities and prompt hashes survive canonical round trip":
    let roster = fixtureRoster()
    let parsed = parseModelRoster(roster.rosterJson())
    check parsed.rosterJson() == roster.rosterJson()
    check sha256Text("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    for seat in 0 ..< 5:
      check parsed.bindings[seat].seat == seat
      check parsed.bindings[seat].policyId == "policy-" & $seat
      parsed.bindings[seat].validatePrompt("prompt-" & $seat)
    expect ValueError:
      parsed.bindings[4].validatePrompt("prompt-0")

  test "wrong seat, changed model, duplicate actor and unimplemented ranking fail closed":
    let roster = fixtureRoster()
    for fault in ["seat", "model", "actor", "ranking", "decoder", "extra"]:
      var node = roster.rosterJson()
      case fault
      of "seat": node["bindings"][1]["seat"] = %0
      of "model": node["bindings"][1]["model"] = %"foreign-model"
      of "actor": node["bindings"][1]["actor_id"] = %"actor-0"
      of "ranking": node["bindings"][1]["action_mode"] = %"legal-choice-ranking"
      of "decoder": node["bindings"][1]["decoder"]["temperature"] = %2.0
      else: node["bindings"][1]["hidden_model_override"] = %"other"
      expect ValueError:
        discard parseModelRoster(node)

  test "roster order and exactly one learner are explicit":
    var roster = fixtureRoster()
    roster.bindings[1].role = "learner"
    roster.sha256 = sha256Text(canonicalJson(roster.rosterPayload()))
    expect ValueError:
      discard parseModelRoster(roster.rosterJson())
