## Export complete Parley matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED]

import std/[json, os, osproc, strutils]
import parley/[llm, sim]

const OperatorPrompt = "Survive each round, protect your secret friend, and eliminate your secret enemy when you can."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 3:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len == 3: parseInt(args[2]) else: 1
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  let variant = manifest["variants"][0]
  doAssert variant["id"].getStr() == "table4"
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variant["game_config"])
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< runtimeConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    runtimeConfig["turnDelayMs"] = %0
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var match = initMatch(config)
    let client = newLlmClient(config)
    var rows: seq[string]
    while not match.done:
      let sim = match.sim
      let seat = sim.itSeat
      var standings: seq[string]
      for index, player in sim.seats:
        standings.add(player.name & "=" & $match.totals[index] &
          " (" & $match.roundWins[index] & " round wins)")
      let header = "Round " & $(sim.round + 1) & " of " & $config.rounds &
        ". Match standings so far: " & standings.join(", ") & "."
      let shot = client.scriptedShot(sim, seat)
      let completion = %*{"say": shot.say,
        "shoot": sim.seats[shot.target].name,
        "aim": (if shot.aim == aimHip: "hip" else: "head")}
      let parsed = parseDecision(sim, seat, completion, true)
      doAssert parsed.say == shot.say and parsed.target == shot.target and
        parsed.aim == shot.aim and not parsed.skip
      rows.add($(%*{
        "episode_id": "parley-table4-" & $seed,
        "seed": "parley-table4-" & $seed,
        "decision_id": rows.len,
        "prompt": [
          {"role": "system", "content": systemPrompt(sim, seat)},
          {"role": "user", "content": userPrompt(sim, seat,
            OperatorPrompt, true, header)}
        ],
        "completion": [{"role": "assistant", "content": $completion}],
        "game": "parley",
        "action_schema_revision": "parley-shot-reaction-v1"
      }))
      match.sim.recordSay(seat, parsed.say)
      match.sim.applyShot(seat, parsed.target, parsed.aim)
      if match.sim.done:
        match.finishRound()
      elif config.reactions:
        var speakers: seq[int]
        let nextIt = match.sim.itSeat
        for offset in 1 ..< match.sim.seats.len:
          let other = (nextIt + offset) mod match.sim.seats.len
          if match.sim.seats[other].alive and other != nextIt:
            speakers.add(other)
        if speakers.len > config.maxReactions:
          speakers.setLen(config.maxReactions)
        for other in speakers:
          let reaction = client.scriptedReaction(match.sim, other)
          let reply = %*{"say": reaction.say}
          let parsedReaction = parseDecision(match.sim, other, reply, false)
          doAssert parsedReaction.say == reaction.say
          rows.add($(%*{
            "episode_id": "parley-table4-" & $seed,
            "seed": "parley-table4-" & $seed,
            "decision_id": rows.len,
            "prompt": [
              {"role": "system", "content": systemPrompt(match.sim, other)},
              {"role": "user", "content": userPrompt(match.sim, other,
                OperatorPrompt, false, header)}
            ],
            "completion": [{"role": "assistant", "content": $reply}],
            "game": "parley",
            "action_schema_revision": "parley-shot-reaction-v1"
          }))
          match.sim.recordSay(other, parsedReaction.say)
    doAssert match.roundsPlayed == config.rounds and rows.len > 0
    let outcome = match.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "rounds_played": match.roundsPlayed})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "parley",
    "variant": "table4",
    "source_revision": sourceRevision,
    "teacher": "scripted-shot-and-reaction",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
