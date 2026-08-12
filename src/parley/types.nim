import std/[json, strutils]

type
  ParleyError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int
    hitPoints*: int
    maxTurns*: int
    reactions*: bool
    maxReactions*: int
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  EventKind* = enum
    evRoundStart = "roundStart"
    evDeal = "deal"
    evIt = "it"
    evSay = "say"
    evShot = "shot"
    evDeath = "death"
    evScore = "score"
    evRoundEnd = "roundEnd"

  GameEvent* = object
    kind*: EventKind
    round*: int     ## 0-based round this event belongs to
    turn*: int
    seat*: int      ## acting seat (speaker, shooter, victim, new "it")
    target*: int    ## shot target seat; -1 otherwise
    text*: string   ## say text; empty otherwise
    hpAfter*: int   ## target hp after a shot; -1 otherwise
    friend*: int    ## deal events: this seat's friend card; -1 otherwise
    enemy*: int     ## deal events: this seat's enemy card; -1 otherwise
    points*: int    ## score events: points awarded; 0 otherwise

  Seat* = object
    name*: string
    hp*: int
    alive*: bool
    kills*: int
    deathIndex*: int  ## order of elimination, -1 while alive
    friend*: int      ## this round's secret friend card
    enemy*: int       ## this round's secret enemy card
    enemyKill*: bool  ## fatally shot its enemy this round

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 3,
    hitPoints: 3,
    maxTurns: 60,
    reactions: true,
    maxReactions: 3,
    turnDelayMs: 1200,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 300,
    llmTimeoutSeconds: 45
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(ParleyError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("hitPoints"):
    config.hitPoints = node["hitPoints"].getInt()
  if node.hasKey("maxTurns"):
    config.maxTurns = node["maxTurns"].getInt()
  if node.hasKey("reactions"):
    config.reactions = node["reactions"].getBool()
  if node.hasKey("maxReactions"):
    config.maxReactions = node["maxReactions"].getInt()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
