## Compile the same historical replay reader for the browser's JavaScript runtime.
import std/json
import parley/sim

proc loadReplay*(text: string): string =
  $enrichReplay(parseJson(text))

when defined(js):
  proc parleyLoadReplay(text: cstring): cstring {.exportc.} =
    cstring(loadReplay($text))
