## Parley static replay viewer, wasm side.
##
## JS hands the raw replay bytes to par_load_replay; this module parses them
## with the SAME sim code the game server runs, re-derives the per-event seat
## states, and exposes the enriched payload (identical shape to the game's
## /replay websocket message) for the shared renderer.js to draw.

import
  std/json,
  parley/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc ctgLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "par_load_replay", cdecl.} =
  try:
    lastError = ""
    payload = $enrichReplay(parseJson(bytesFromPointer(data, int(length))))
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc ctgPayloadPointer(): ptr uint8 {.exportc: "par_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc ctgPayloadLength(): cint {.exportc: "par_payload_len", cdecl.} =
  cint(payload.len)

proc ctgErrorPointer(): ptr uint8 {.exportc: "par_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc ctgErrorLength(): cint {.exportc: "par_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
