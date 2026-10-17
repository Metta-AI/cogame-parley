## Versioned rules wording. Player strategy, state, and action grammar stay with their owners.
import std/[json, strutils]
import crunchy
import types

const PromptBankVersion* = "parley-rules-v1"
const Templates = [
  staticRead("prompts/canonical.txt"),
  staticRead("prompts/plain.txt"),
  staticRead("prompts/numbered.txt"),
  staticRead("prompts/questions.txt"),
  staticRead("prompts/reordered.txt"),
  staticRead("prompts/heldout-briefing.txt"),
  staticRead("prompts/heldout-reference.txt")
]

proc renderSystemPrompt*(config: GameConfig, name, tableRules: string, whispers: int): string =
  Templates[ord(config.selectedPromptVariant)] % [name, $config.hitPoints, tableRules, $whispers]

proc promptMetadata*(config: GameConfig, system, user: string): JsonNode =
  ## Hash each exact message separately: concatenation would lose message boundaries.
  %*{"bank": PromptBankVersion, "variant": $config.selectedPromptVariant,
     "selection": $config.promptVariant, "seed": config.promptSeed,
     "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}
