## Request-scoped XP startup and decision authorization; turns advance independently.
import std/[httpclient, json, os, strutils]

proc batchControl*(kind: string, timeoutMs: int, decisionId = "", seat = -1,
    decisionBudgetMs = 45000) =
  let endpoint = getEnv("COWORLD_XP_BATCH_URL")
  if endpoint.len == 0: return
  if timeoutMs <= 0:
    raise newException(IOError, "XP batch exceeded the episode deadline")
  let client = newHttpClient(timeout = timeoutMs)
  defer: client.close()
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & getEnv("COWORLD_XP_BATCH_KEY")})
  var body = %*{"kind": kind, "game_id": getEnv("COWORLD_XP_BATCH_GAME_ID")}
  if kind == "turn":
    body["decision_id"] = %decisionId
    body["seat"] = %seat
    body["budget_ms"] = %decisionBudgetMs
  let response = client.request(endpoint.strip(chars = {'/'}, leading = false) & "/control",
    httpMethod = HttpPost, body = $body)
  if response.code != Http200:
    raise newException(IOError, "XP batch control failed: " & $response.code)
