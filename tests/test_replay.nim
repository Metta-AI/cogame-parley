import std/unittest
include "../replay-viewer/parley_replay.nim"

suite "static replay payload":
  test "decision references survive state derivation for private trace joins":
    let references = %*[{"id": 10, "seat": 1, "phase": "reaction",
      "eventBefore": 0, "eventAfter": 1, "action": {"say": "A bargain"}}]
    var replay = %*{"protocol": "parley.replay.v4", "names": ["Sprocket", "Gizmo"],
      "config": {"hitPoints": 3, "rounds": 1, "survivors": 1},
      "policyNames": ["Sprocket", "Gizmo"], "results": {}, "events": [], "decisionRefs": references}
    var encoded = $replay
    check ctgLoadReplay(cast[ptr uint8](encoded[0].addr), cint(encoded.len)) == 1
    check parseJson(payload)["decisionRefs"] == references
    check parseJson(payload)["events"] == replay["events"]

  test "older replays still load without decision references":
    var encoded = $(%*{"protocol": "parley.replay.v1", "names": ["Sprocket", "Gizmo"],
      "config": {"hitPoints": 3, "rounds": 1, "survivors": 1}, "policyNames": ["Sprocket", "Gizmo"], "results": {}, "events": []})
    check ctgLoadReplay(cast[ptr uint8](encoded[0].addr), cint(encoded.len)) == 1
    check parseJson(payload)["decisionRefs"].len == 0
