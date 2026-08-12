## Parley player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default table-talk personality), then idles until the final frame. All of
## the actual decision making happens inside the game server, which sends
## this seat's prompt to Sonnet each turn.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <parley-image> --name my-parley \
##     --run /bin/parley-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os],
  whisky

const DefaultPrompt = """
Play to win, but make it fun. Shoot whoever is currently the biggest threat:
healthy cogs who have taken shots at you, or whoever the table seems to be
rallying behind. Keep your table talk short, funny, and a little scheming -
propose truces you may or may not honor, and never waste a shot on a cog
that is about to be someone else's problem.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt

  echo "parley player: connecting to game"
  let socket = newWebSocket(url)
  socket.send($ %*{"type": "prompt", "prompt": prompt})
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
        socket.send($ %*{"type": "prompt", "prompt": prompt})
      of "final":
        echo "parley player: final scores ", payload{"scores"}
        break
      else:
        discard
    except CatchableError as error:
      echo "parley player: ignoring bad frame: ", error.msg
  socket.close()
