## Parley prompt and scripted player.
##
## Prompt policies deliver PLAYER_PROMPT to the game's Sonnet adapter.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <parley-image> --name my-parley \
##     --run /bin/parley-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, math, monotimes, os, strutils, times],
  bitworld/[native_stop, native_websocket]

const DefaultPrompt = """
Play to win, but make it fun. Your secret cards run the round: steer shots
toward your ENEMY without being obvious about it (a point for the fatal
shot yourself is even better), quietly keep your FRIEND alive, and never
reveal either card. Shoot whoever threatens you or your friend most, and
aim for the head when you mean it. Shoot from the hip when you want the gun
to move without the damage - handing it to your friend, or staging a grudge
the table will believe - since nobody learns how you aimed, only whether it
landed. Keep your table talk short, funny, and a little scheming - propose
truces you may or may not honor, and let the table do your dirty work when
it will.
"""

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let timeout = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "1200"))
  if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
    quit("player timeout must be finite and positive", 1)
  let started = getMonoTime()
  let deadline = started + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
  let connection = connectNativeWebSocket(url,
    min(deadline, started + initDuration(seconds = 30)), 16 * 1024 * 1024)
  case connection.kind
  of wsInterrupted, wsDeadline: quit(0)
  of wsReady: discard
  else: quit("player connection failed", 1)
  let socket = connection.socket
  let scripted = getEnv("PLAYER_SCRIPTED") == "1"
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0 and not scripted:
    prompt = DefaultPrompt
  var registered = false
  try:
    while true:
      let received = receiveNativeText(socket, deadline)
      case received.kind
      of wsClosed, wsInterrupted, wsDeadline: break
      of wsMessage: discard
      else: raise newException(ValueError, "player transport failed")
      let payload = parseJson(received.data)
      if payload.kind != JObject or not payload.hasKey("type") or payload["type"].kind != JString:
        raise newException(ValueError, "invalid player protocol packet")
      case payload["type"].getStr()
      of "welcome":
        if registered:
          raise newException(ValueError, "duplicate player welcome")
        let registration = $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}
        let sent = sendNativeText(socket, registration, deadline)
        case sent.kind
        of wsInterrupted, wsDeadline: break
        of wsReady: registered = true
        else: raise newException(ValueError, "player registration failed")
      of "state": discard
      of "final": break
      else: raise newException(ValueError, "unexpected player protocol packet")
  finally:
    closeNativeWebSocket(socket)
