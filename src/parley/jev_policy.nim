## Jev ranks normal player actions from a private Parley observation.

import std/[json, os, strutils]
import curly

proc chooseAction*(observation, legalActions: JsonNode, phase,
    guidance: string): JsonNode =
  var criteria = newJObject()
  if phase == "shot":
    for index, action in legalActions.elems:
      criteria[$(index + 1)] = %($action)
  elif phase == "reaction":
    criteria["plead"] = %"Ask the table not to shoot you"
    criteria["deflect"] = %"Suggest they question the current shooter"
    criteria["warn"] = %"Warn that attacking you will create an enemy"
    criteria["silence"] = %"Say nothing this turn"
  else:
    raise newException(ValueError, "unknown Parley decision phase")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Jev player has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Parley. Survive, protect your secret friend, " &
      "and eliminate your secret enemy when possible. Your own secrets, " &
      "public standings, and table talk are in this seat observation:\n" &
      $observation & "\nStrategy guidance: " & guidance,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the action that maximizes your match points.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Parley Jev player: phase ", phase, " choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  if phase == "shot":
    result = legalActions[parseInt(selected) - 1]
    result["say"] = %(if result["shoot"].getStr() == "pass":
      "Let's hear the table first." else:
      "Your turn, " & result["shoot"].getStr() & ".")
  else:
    result = %*{"say": (case selected
      of "plead": "Keep me in the game; there are bigger threats here."
      of "deflect": "Ask who benefits from the shooter's next move."
      of "warn": "Shoot me and you make an enemy of the table."
      else: "")}
