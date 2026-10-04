import std/[json, options, strutils]

export options

type
  ParleyError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int
    survivors*: int       ## cogs left standing that ends a round
    hitPoints*: int
    ## Whether the table is TOLD this episode's rounds / survivors. Spectators
    ## always see both; these gate only what reaches the players' prompts.
    roundsKnown*: bool
    survivorsKnown*: bool
    sampled*: bool        ## true once per-episode values have been drawn
    maxSkips*: int        ## times "it" may hold fire per round
    reactions*: bool
    maxReactions*: int
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    ## The platform's wall clock for one hosted episode. The platform hands
    ## COWORLD_TIMEOUT_SECONDS to its worker container, NOT to the game, so
    ## the game has to know its own kill time: this default mirrors the
    ## manifest's episode_timeout_minutes and the env overrides it if present.
    episodeTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  EventKind* = enum
    evRoundStart = "roundStart"
    evDeal = "deal"
    evIt = "it"
    evSay = "say"
    evSkip = "skip"
    evShot = "shot"
    evDeath = "death"
    evScore = "score"
    evRoundEnd = "roundEnd"
    evWhisper = "whisper"  ## private line to one cog; others see only that it happened
    evReveal = "reveal"    ## verified card shown to one cog; others see only that it happened
    evPledge = "pledge"    ## public promise not to shoot a cog for the rest of the round

  Baseline* = enum
    ## Scripted no-model policies, selectable per seat for evaluation cohorts.
    blRandom = "random"         ## random living target; hip-shot at its friend
    blFinisher = "finisher"     ## lowest-hp non-friend, its enemy on ties
    blRetaliator = "retaliator" ## whoever last landed a hit on it, else random
    blProtector = "protector"   ## whoever last hit its friend, else its enemy
    blHoarder = "hoarder"       ## passes while the table has passes, else finisher

  CardKind* = enum
    cardFriend = "friend"
    cardEnemy = "enemy"

  Extras* = object
    ## Optional side actions any cog may attach to a shot or a reaction; the
    ## default value takes none.
    whisperTo*: Option[int]
    whisperText*: string
    revealTo*: Option[int]
    revealCard*: CardKind
    giveTo*: Option[int]    ## hand over 1 banked point
    pledgeTo*: Option[int]  ## promise not to shoot this cog for the rest of the round

  ShotAim* = enum
    ## How "it" aimed. A head-shot always lands. A hip-shot is a gamble: it
    ## misses two times in three, and hit or miss the target takes the gun.
    ## The aim is the shooter's secret — the table only ever sees the outcome.
    aimHead = "head"
    aimHip = "hip"

  GameEvent* = object
    kind*: EventKind
    round*: int     ## 0-based round this event belongs to
    turn*: int
    seat*: int      ## acting seat (speaker, shooter, victim, new "it")
    target*: int    ## shot target seat; -1 otherwise
    text*: string   ## say text; empty otherwise
    hpAfter*: int   ## target hp after a shot; -1 otherwise
    aim*: ShotAim   ## shot events: how the shooter aimed (secret from the table)
    miss*: bool     ## shot events: a shot that did no damage
    friend*: int    ## deal/reveal events: the friend card shown; -1 otherwise
    enemy*: int     ## deal/reveal events: the enemy card shown; -1 otherwise
    points*: int    ## score events: points awarded; 0 otherwise

  Seat* = object
    name*: string
    hp*: int
    alive*: bool
    kills*: int
    deathIndex*: int  ## order of elimination, -1 while alive
    friend*: int      ## this round's secret friend card
    enemy*: int       ## this round's secret enemy card
    hitEnemy*: bool   ## landed at least one hit on its enemy this round
    foeScored*: bool  ## its enemy went out after it landed a hit on them
    whispers*: int    ## whispers sent this round
    revealed*: bool   ## already showed a card this round
    pledges*: seq[int] ## cogs it promised not to shoot this round

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 3,
    survivors: 1,
    hitPoints: 3,
    roundsKnown: true,
    survivorsKnown: true,
    maxSkips: 3,
    reactions: true,
    maxReactions: 2,
    turnDelayMs: 1200,
    playerConnectTimeoutSeconds: 180,
    episodeTimeoutSeconds: 20 * 60,
    model: "anthropic/claude-sonnet-4.6",
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
  if node.hasKey("survivors"):
    config.survivors = node["survivors"].getInt()
  if node.hasKey("hitPoints"):
    config.hitPoints = node["hitPoints"].getInt()
  if node.hasKey("roundsKnown"):
    config.roundsKnown = node["roundsKnown"].getBool()
  if node.hasKey("survivorsKnown"):
    config.survivorsKnown = node["survivorsKnown"].getBool()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("maxSkips"):
    config.maxSkips = node["maxSkips"].getInt()
  if node.hasKey("reactions"):
    config.reactions = node["reactions"].getBool()
  if node.hasKey("maxReactions"):
    config.maxReactions = node["maxReactions"].getInt()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
