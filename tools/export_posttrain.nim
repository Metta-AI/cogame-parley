## Export complete Parley matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED]

import std/[json, options, os, osproc, strutils]
import bitworld/decision_trajectory
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
  doAssert execProcess("git status --porcelain").strip().len == 0,
    "Commit the qualified source before generating a pinned training corpus"
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  let variant = manifest["variants"][0]
  doAssert variant["id"].getStr() == "table5"
  var runs = newJArray()
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
    let episodeId = "parley-table5-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, "parley-" & $seed,
      "parley", "source-" & sourceRevision, sourceRevision)
    var decisionIndex = 0
    while not match.done:
      let sim = match.decisionSim()
      let seat = sim.itSeat
      let header = match.matchHeader()
      let shot = client.scriptedShot(sim, seat)
      let completion = %*{"say": shot.say,
        "shoot": sim.seats[shot.target].name,
        "aim": (if shot.aim == aimHip: "hip" else: "head")}
      let parsed = parseDecision(sim, seat, completion, true)
      doAssert parsed.say == shot.say and parsed.target == shot.target and
        parsed.aim == shot.aim and not parsed.skip
      var attempt = newDecisionAttempt(episodeId & "-" & $decisionIndex,
        "scripted-shot-and-reaction", aoTeacher)
      attempt.prompt = %*[
        {"role": "system", "content": systemPrompt(sim, seat)},
        {"role": "user", "content": userPrompt(sim, seat, OperatorPrompt, true, header)}]
      attempt.response = %($completion)
      attempt.rawResponse = copy(completion)
      attempt.parsedAction = decisionAction(sim, parsed, true)
      attempt.accepted = true
      let beforeEvent = match.allEvents().len
      match.sim.recordSay(seat, parsed.say)
      match.sim.applyShot(seat, parsed.target, parsed.aim)
      let action = appliedDecisionAction(sim, match.allEvents(), beforeEvent, seat, true)
      trajectory.recordDecision($decisionIndex, $seat, copy(attempt.prompt), @[attempt],
        some(attempt.attemptId), action, asAccepted)
      inc decisionIndex
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
          let before = match.decisionSim()
          var attempt = newDecisionAttempt(episodeId & "-" & $decisionIndex,
            "scripted-shot-and-reaction", aoTeacher)
          attempt.prompt = %*[
            {"role": "system", "content": systemPrompt(before, other)},
            {"role": "user", "content": userPrompt(before, other,
              OperatorPrompt, false, match.matchHeader())}]
          attempt.response = %($reply)
          attempt.rawResponse = copy(reply)
          attempt.parsedAction = decisionAction(before, parsedReaction, false)
          attempt.accepted = true
          let beforeEvent = match.allEvents().len
          match.sim.recordSay(other, parsedReaction.say)
          let action = appliedDecisionAction(before, match.allEvents(), beforeEvent, other, false)
          trajectory.recordDecision($decisionIndex, $other, copy(attempt.prompt), @[attempt],
            some(attempt.attemptId), action, asAccepted)
          inc decisionIndex
    doAssert match.roundsPlayed == config.rounds and decisionIndex > 0
    let outcome = match.resultsJson()
    var participants = newJObject()
    for seat in 0 ..< outcome["scores"].len: participants[$seat] = outcome["scores"][seat]
    trajectory.finish(esCompleted, outcome, participants)
    trajectory.writeCompleteEpisode(output / (episodeId & ".jsonl"))
    runs.add(%*{"seed": seed, "seed_family": "parley-" & $seed,
      "decisions": decisionIndex, "scores": outcome["scores"],
      "rounds_played": match.roundsPlayed})
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "parley",
    "variant": "table5",
    "source_revision": sourceRevision,
    "teacher": "scripted-shot-and-reaction",
    "operator_prompt": OperatorPrompt,
    "format": "coworld-private-complete-episodes-v1",
    "dataset_export": "shared importer owns seed-family splits and target selection",
    "runs": runs
  }) & "\n")
  echo "complete private episodes=", matches
