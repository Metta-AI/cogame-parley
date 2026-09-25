## Parley player: prompt, scripted, or external action policy.
##
## Prompt policies deliver PLAYER_PROMPT to the game's Sonnet adapter.
## PLAYER_JEV=1 receives a seat-private observation and legal shots, calls
## System One here, and returns a normal action to the game.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <parley-image> --name my-parley \
##     --run /bin/parley-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  parley/jev_policy,
  whisky

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
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let jevRequested = getEnv("PLAYER_JEV") == "1"
  let jev = jevRequested and (
    getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("METTA_CAPTURE_URL").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0)
  let scripted = getEnv("PLAYER_SCRIPTED") == "1" or
    (jevRequested and not jev)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0 and not jev and not scripted:
    prompt = DefaultPrompt

  echo "parley player: connecting to game"
  let socket = newWebSocket(url)
  proc registration(): string =
    if jev: $ %*{"type": "register", "control": "external"}
    else: $ %*{"type": "prompt", "prompt": prompt,
      "scripted": scripted}
  socket.send(registration())
  echo "parley player: prompt delivered (", prompt.len, " chars)"

  while true:
    let received = socket.receiveMessage()
    if received.isNone:
      echo "parley player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "parley player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(registration())
      of "observation":
        if jev:
          let action = chooseAction(payload["observation"],
            payload["legalActions"], payload["phase"].getStr(), prompt)
          socket.send($ %*{"type": "action", "id": payload["id"],
            "action": action})
      of "final":
        echo "parley player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "parley player: ignoring bad frame: ", error.msg
  socket.close()
