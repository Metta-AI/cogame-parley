## One synthetic HTTP decision, followed by real engine validation and native wire.
## This is a truncated CPU fixture, not a completed game or a teacher label.
import std/[json, options, os, strutils]
import bitworld/decision_trajectory
import parley/[llm, model_routes, sim]

let mode = paramStr(1)
let seat = if mode.startsWith("seat-"): parseInt(mode[5 .. ^1]) else: 2
var config = defaultGameConfig()
config.sampled = true
config.seed = seat
config.maxSkips = 1
config.llmTimeoutSeconds = 2
let generated = mode.startsWith("generated-")
var roster: ModelRoster
for index in 0 ..< 5:
  config.players.add(PlayerConfig(name: "policy-" & $index))
  roster.bindings.add(ModelSeatBinding(seat: index, actorId: "actor-" & $index,
    policyId: "policy-" & $index, role: (if index == seat: "learner" else: "opponent"),
    model: "local-sha256:" & repeat($index, 64), tokenizerIdentity: repeat('b', 64),
    chatTemplateSha256: repeat('c', 64), promptSha256: sha256Text("operator-" & $index),
    actionMode: (if generated: "generated-json" else: "legal_choice_ranking"),
    assistanceId: (if generated: "none" else: "legal-private-actions-v1"),
    assistanceSha256: (if generated: sha256Text("{\"id\":\"none\",\"version\":1}")
      else: sha256Text(canonicalJson(legalAssistanceProfile()))),
    temperature: 0, maxOutputTokens: 300))
roster.sha256 = sha256Text(canonicalJson(roster.rosterPayload()))
config.modelRoster = some(parseModelRoster(roster.rosterJson()))
var game = initSim(config)
let wantShot = mode != "reaction"
let outcome = newLlmClient(config).decide(game, seat, "operator-" & $seat, wantShot)
if mode in ["shot", "pass", "reaction"] or mode.startsWith("seat-"):
  doAssert outcome.origin == "model"
  doAssert outcome.nativeAttempts.len == 1
  doAssert outcome.nativeAttempts[0].response.kind == JNull
  doAssert outcome.nativeAttempts[0].sampledTokenIds.isNone
  doAssert outcome.nativeAttempts[0].behaviorLogprobs.isNone
  if mode == "pass": doAssert outcome.decision.skip
else:
  doAssert outcome.origin == "scripted_after_model_failure"
  doAssert outcome.nativeAttempts.len == 2
  for attempt in outcome.nativeAttempts:
    doAssert not attempt.accepted
    doAssert attempt.parsedAction.kind == JNull
    if generated:
      doAssert attempt.response == %""
      doAssert attempt.actionEvidence.isNone
    else:
      doAssert attempt.response.kind == JNull
      doAssert attempt.actionEvidence.get()["scoring_result"]["status"].getStr() == "rejected"
    if mode.endsWith("malformed-provider"):
      doAssert attempt.platformCallId.isNone
      doAssert attempt.decoder["transport"]["response_headers"]["x-softmax-llm-call-id"] == %"not-a-uuid"

game.recordSay(seat, outcome.decision.say)
if wantShot:
  if outcome.decision.skip: game.applySkip(seat)
  else: game.applyShot(seat, outcome.decision.target, outcome.decision.aim)
let action = decisionAction(game, outcome.decision, wantShot)
let accepted = outcome.origin == "model"
let trajectory = newDecisionTrajectory("synthetic-" & mode, "cpu-fixture", "parley",
  "legal-choice-producer-fixture", "source-under-test")
trajectory.recordDecision("decision-0", $seat, %*{"fixture": true}, outcome.nativeAttempts,
  (if accepted: some(outcome.nativeAttempts[^1].attemptId) else: none(string)), action,
  (if accepted: asAccepted else: asFallback),
  fallbackOrigin = (if accepted: none(string) else: some(outcome.origin)))
trajectory.finish(esTruncated, %*{"fixture": true}, newJArray())
trajectory.writeEvents(paramStr(2))
