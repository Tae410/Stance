# Stance!

A dynamic stance skill mod for OpenMW Morrowind. **Stance!** adds one Skill
Framework skill whose displayed name, governing attribute, description, and
perks all change to match the weapon style — or activity — you currently have
active.

Inspired by **For Honor**'s stance system — when you change weapons mid-fight,
the game treats you as a different combatant entirely. Stance! reproduces that
feel through a single Skill Framework skill that morphs in real time: its
displayed name, governing attribute, description, and perk ladder all swap to
match what you are doing right now.

The mod is pure Lua, built on top of `Toxicology!`'s architecture, and is
designed to interlope with a large stack of other OpenMW mods. **None of them
are hard dependencies.** Stance! gracefully falls back to native detection when
an integration is missing — you can run it by itself and still get every
stance (some perks and XP sources simply lose their catalyst).

## Integrations

Stance! is **read-only** against every external mod. It never writes to another
mod's data, skills, or settings; it only reads state, listens for events, and
applies its own bonuses through its own delta-accounted channels. All of its
own events live in the `Stance_*` namespace.

**Weapon-style / skill mods**

| Mod | What Stance! reads from it |
|---|---|
| **GRIP** | Weapon-conversion maps (the `GRIPRecords` storage) — a GRIP-converted 2H→1H weapon still classifies as its *original* type for stance purposes |
| **Throwing!** | Twirler effectiveness and perks (Critical / Twin Flight / Bleed / Paralyze) |
| **Staves!** | Thaumaturge effectiveness and perks (Concussive Strike / Arcane Siphon / Resonant Conduit / Null Pulse) |
| **Bullseye** | Huntsman bonuses tied to ranged headshots |
| **Dual Wielding** | Reliable Dualist detection via `EquipSecondWeapon` / `RemoveSecondWeapon` |
| **Blademeister** | Detects Felthorn — the shapeshifting Daedra weapon — by its `sd_` record-id prefix, activating the Blademeister stance regardless of which weapon type Felthorn has become |
| **Simply Mining** | Pitmen mining XP and perks via `SimplyMining_notifyItem` (skill `mining_skill`) |
| **Fishing** | Angler fishing XP and perks via `Fishing_playerCaughtFish` (skill `fishing_skill`) |

**Combat**

| Mod | What Stance! reads from it |
|---|---|
| **N'Garde** | Parry success → parry XP for the **active** stance, with a larger reward for a perfect parry (`ngarde_parrySelf` carries the `isPerfect` flag) |
| **Gothic Style Knockout** | Brawler knockout-chance proc via `GKD_DoKnockdown` |
| **Evasion!** | Surfaces the dodge/Sanctuary bonus in the tooltip with an "Evasion!" attribution (the two contributions track separate deltas and never interfere) |

**Thrown / deployable alchemy** (all by Arcimaestro Antares; pure-content `.esp`s with no Lua)

| Mod | What Stance! reads from it |
|---|---|
| **Thrown Concoctions** | Apothecary stance, active when a concoction flask is equipped (sentinel record `concoction_base`) |
| **Venefic Vials** | Apothecary stance, active when the thrown vial `vv_vial_th` is equipped |
| **Traps** | A small ACTIVATOR listener (`hazard.lua`) credits **Thief** when a non-player actor springs an armed trap (`trap_open`) |
| **Oil Flask** | The same listener credits **Apothecary** while a non-player actor stands in *lit* oil fire (`oil_fire` LIGHT over an `oil_pool`) |

**Magic / crafting / utility**

| Mod | What Stance! reads from it |
|---|---|
| **Spellsword** (Imbule Weapon) | Reads the imbue state (`IW_ActiveSpell` → `activeSpell`) to prepend a **cosmetic element prefix** to the stance name — see *Stance name prefixes* below. No XP/perks/resolver effect |
| **Incantation** | Arcanist spellcasting XP via the `spellcast` animation text-key |
| **Meditation Skill** | Arcanist tick XP via the SkillProgression hook |
| **Disenchanting** | Arcanist / Thaumaturge XP via `disenchanting_finishedDisenchanting` |
| **Transcribe** | Arcanist / Thaumaturge XP via `TRAN_doTranscribe` |
| **Weapon Upgrade** | Detects the `repair_hammer_weapon` for Reforger and credits Reforger XP on a successful (or failed) upgrade |
| **Armor Upgrade** | Same hammer detection as Weapon Upgrade — credits Reforger |
| **Oblivion-Style Lockpicking** | Locksmith lockpick XP via `OSL_LockpickSuccess` |
| **Talking Trains Speechcraft** | Detected for display/toggle; Commoner's talking XP reacts to the engine `UiModeChanged` signal directly, so it works with or without this mod |
| **Commercium / Fair Trade** | Commoner trade XP via `FairTrade_Transaction` |
| **Toxicology!** | Read-only sibling — Stance! never writes to Toxicology's data |

## Requirements

- OpenMW 0.49.0 or later (developed/tested against 0.51)
- Skill Framework
- Stats Window Extender (optional, for the "Stance" subsection placement)

## Installation

1. Install the mod folder as an OpenMW data folder (the folder containing
   `Stance.omwscripts`).
2. Enable `Stance.omwscripts` in your OpenMW content list.
3. Make sure Skill Framework loads before Stance.
4. Open **Options → Scripts → Stance!** to configure.

## The stances

The mod resolves the active stance every frame by walking a priority-ordered
list of detection rules. **The first rule whose signal fires wins.** There are
**19** stances.

| # | Stance | Governing | When it activates |
|---|---|---|---|
| 1 | Locksmith | Agility | Lockpick **or** probe readied in the right hand (via Use, not merely carried) |
| 2 | Arcanist | Intelligence | Spellcasting stance active |
| 3 | Reforger | Endurance | Armorer's repair hammer equipped, weapon stance up |
| 4 | Blademeister | Agility | Felthorn equipped (any `sd_`-prefixed shapeshifted form) |
| 5 | Angler | Luck | Fishing pole equipped |
| 6 | Huntsman | Speed | Bow or crossbow equipped |
| 7 | Apothecary | Intelligence | A thrown alchemy item equipped — a Thrown Concoction **or** a Venefic Vial |
| 8 | Twirler | Agility | Thrown weapon equipped (non-alchemy, non-axe) |
| 9 | Thaumaturge | Willpower | Stave (BluntTwoWide) equipped |
| 10 | Dualist | Speed | Dual Wielding off-hand active with a one-handed primary |
| 11 | Guisarmier | Endurance | Spear (SpearTwoWide) |
| 12 | Pitmen | Endurance | Miner's Pick specifically |
| 13 | Axeman | Strength | Any axe — one- or two-handed, **including throwing axes** |
| 14 | Mjolnir | Strength | Blunt one-handed, or blunt two-handed *close* |
| 15 | Zweihänder | Strength | Long-blade two-handed only |
| 16 | Soloist | Endurance | Long-blade one-handed only |
| 17 | Thief | Speed | Short blade |
| 18 | Brawler | Strength | Fists up, no weapon equipped |
| 19 | Commoner | Luck | Weapons sheathed, or nothing above matched (the fallback) |

> **Identity-first stances sit high.** Blademeister sits above the weapon-type
> branches so any of Felthorn's shapeshifted forms route to Blademeister rather
> than to Zweihänder/Thief/etc. — the meister-and-weapon partnership *is* the
> stance. Likewise Angler (pole), Apothecary (thrown alchemy), Pitmen (Miner's
> Pick), and throwing-axe→Axeman all sit just above the broad weapon-type branch
> they would otherwise fall into, so a tool or special item is scored as itself.

> **Weapon coverage.** Every weapon type is now covered: Guisarmier for spears,
> Axeman for axes, Mjölnir for blunts (1H and 2H-close), Zweihänder for
> long-blade 2H, Soloist for long-blade 1H, Thief for short blades, Thaumaturge
> for staves (2H-wide blunt). Anything not otherwise claimed falls through to
> Commoner.

### Stance name prefixes

Three transient states **decorate** the active stance's displayed name (in the
HUD indicator and the skill tooltip) without changing which stance is active.
They compose, outermost-first, as **Sneaky → Fortified → element → base** — e.g.
`Sneaky Fortified Blazed Soloist`.

| Prefix | Appears when | Scope | Effect |
|---|---|---|---|
| **Sneaky** | You are crouched / sneaking (`self.controls.sneak`) | **Every** stance | Cosmetic only |
| **Fortified** | A shield is equipped alongside a one-handed melee weapon | Soloist, Thief, Mjölnir, Axeman, Blademeister | Cosmetic **+** an additive **Block** skill bonus that scales with your own Block skill while equipped |
| **Blazed / Frozen / Electrified** | Spellsword has imbued your weapon with fire / frost / shock | Any stance that wields an imbuable weapon (everything except Arcanist, Commoner, Locksmith, Reforger) | Cosmetic only |

> **Fortifier was deprecated into the "Fortified" prefix.** Earlier versions had
> a standalone *Fortifier* stance for "shield equipped". That stance is gone: a
> shield with a one-handed melee weapon now keeps you in that weapon's stance
> (e.g. `Fortified Soloist`) and grants a Block bonus while equipped. The bonus
> **scales with your own Block skill** — +2 at Block 5 rising to +20 at Block
> 100, the exact same additive ramp the weapon-skill effectiveness bonus uses
> (and tuned by the same two numbers in `config.lua`). There is no flat value
> to configure. A bare shield, or
> shield-plus-fists, gets no prefix or bonus — "Fortified" requires a compatible
> weapon. N'Garde parry XP now flows to whatever weapon stance is active.

## How leveling works

Two layers work together:

**Per-stance levels.** Each stance has its **own** XP bank and level (5 → 100),
saved in your character's data. Only the **active** stance earns XP — whatever
you are doing trains the stance you currently hold. Switch weapons and the
stance you were in is **banked exactly as it was**; the new stance picks up from
its own saved level. A stance's own level scales its **effectiveness** (a smooth
ramp from 100% at the start level to 150% at level 100, delivered as a +2→+20
bonus to that stance's target skill), shown in the tooltip.

**The core Stance skill.** The single skill Skill Framework displays. Its row
in the character sheet (under the **Stance** subsection, via Stats Window
Extender) renames itself **live** to the decorated active stance — sheathe your
blade and it reads `Commoner`; draw a longsword behind a shield while crouched
and it reads `Sneaky Fortified Soloist`. Whenever the active stance gains XP,
the core skill gains **half** of that amount and levels **independently**. So each individual stance levels roughly twice as fast
as the core skill, and the core skill is a running measure of your overall
stance mastery that never resets when you switch.

**Perks come from the core skill.** A perk is active once your **core** Stance
skill reaches its threshold (25 / 50 / 75 / 100) — and that applies to *every*
stance at once. Reach core level 25 and every stance's level-25 perk unlocks;
the active stance just decides which ladder is shown.

> Example: fighting as Commoner grants Commoner 6 XP and the core skill 3 XP.
> Commoner's own level climbs quickly; the core skill climbs at half pace. When
> the core skill hits 25, the level-25 perk unlocks for Commoner — and for every
> other stance too.

### XP sources

Each source trains the **active** stance (and feeds the core skill at half rate)
only while that stance is enabled. Every source has its own toggle under
**Progression**, and every amount is scaled by the global **XP Multiplier**.

| Source | Trains the active stance when… | Default weight |
|---|---|---|
| Successful weapon hit | in any stance | 1.0 |
| Kill or knockout | in any stance | 2.0 |
| Successful spell cast | in Arcanist | 0.8 |
| Successful N'Garde parry / perfect parry | in any stance | 1.2 / 2.4 |
| Time-in-stance tick (every 10s) | in any stance | 0.1 |
| Meditation tick (via Meditation Skill) | in Arcanist | 0.4 |
| Merchant transaction (Commercium / Fair Trade) | in Commoner | 1.5 (+ value bonus) |
| First / repeat dialogue (Talking Trains pairing) | in Commoner | 1.0 / 0.25 |
| Weapon / armor upgrade — success / failure | in Reforger | 4.0 / 0.5 |
| Successful mine (Simply Mining) | in Pitmen | 3.0 |
| Caught fish (Fishing) | in Angler | 3.0 |
| Sprung lock (Oblivion-Style Lockpicking) | in Locksmith | 2.0 |
| Landed thrown concoction | in Apothecary | 2.5 |
| Enemy springs your trap | credited to Thief | 3.0 |
| Enemy burns in your oil (per tick) | credited to Apothecary | 0.5 |
| Disenchant (Disenchanting) | in Arcanist / Thaumaturge | 1.5 (+ per-point bonus) |
| Transcribe a spell (Transcribe) | in Arcanist / Thaumaturge | 3.0 |

## Perks

Each stance has a 25 / 50 / 75 / 100 perk ladder keyed to the **core** Stance
skill level. An unlock popup fires when the core skill crosses a threshold while
that stance is active. Perks can be disabled per-stance or globally under
**Perks**.

Where a stance has an associated mod, its perks **reuse the source mod's own
perk catalog** so the two systems compound naturally — Twirler amplifies
Throwing!'s Critical / Twin Flight / Bleed / Paralyze; Thaumaturge amplifies
Staves!'s Concussive Strike / Arcane Siphon / Resonant Conduit / Null Pulse;
Huntsman rides on Bullseye's headshots; Brawler ties to Gothic Style Knockout's
confirmed knockout; Arcanist layers on Incantation's magicka refund and
Meditation's regen; Pitmen (Vein Reader / Prospector / Pit Boss) and Angler
(Catch and Release / Trophy Cast / Master Angler) build on Simply Mining and
Fishing; Apothecary builds on thrown-alchemy hits; Reforger's perks are
combat-themed to make the repair hammer a viable weapon (Anvil Arms,
Weak-Point Strike, Sundering Blow, Forgemaster's Touch); and Blademeister's are
Soul Eater themed (Soul Perception → Sneak + Mysticism, Soul Wavelength,
Witch Hunter, Soul Resonance).

Stances without an associated mod (Zweihänder, Soloist, Dualist, Commoner,
Guisarmier, Axeman, Mjölnir, Thief, Locksmith) have net-new perks themed for
that stance.

## HUD indicator

The HUD shows **only** the name of the currently active stance (with any active
prefixes — *Sneaky / Fortified / Blazed-Frozen-Electrified*). No level, no other
decoration — just the name in the corner of the screen.

**Draggable.** Open any vanilla menu (inventory, map, magic, stats) and
click-drag the indicator to any position on screen. The position is saved
automatically and clamps to the actual HUD layer size, so very large stored
values are safe across resolution changes. The X / Y values in **Options → UI**
are also editable directly — set them to 0 to restore the default lower-left
placement. Lock it from **Options → UI → Lock HUD Position** to avoid dragging
accidentally.

## Settings

All settings live under **Options → Scripts → Stance!**, organized into nine
focused groups:

1. **General** — master toggle, skill registration, dynamic attribute swap,
   stance-change announcements.
2. **Stances** — one enable toggle per stance (19), plus **Enable Fortified**
   and **Enable Sneaky** (the prefix controls). The Fortified Block bonus has
   no slider — it scales with your Block skill automatically.
3. **Perks** — master perks toggle plus one per-stance perk toggle. Disabling a
   stance's perks suppresses its level-up notifications and hides its perk
   ladder from the tooltip; the stance still levels normally.
4. **Progression** — race / class bonuses, the per-source XP toggles, and the
   global XP multiplier (0–500%).
5. **Integrations** — one toggle per external-mod hookup, grouped by category.
   Disabling an integration falls back to native detection where possible.
6. **HUD Indicator** — show toggle, lock toggle, text size, X / Y position.
7. **Tooltip** — what appears inside the dynamic Stance-skill tooltip
   (mechanic details, perk ladder, unlocked-only filter, all-stances summary).
8. **Notifications** — perk-unlock popup style (Disabled / Popup / Message),
   position (named anchors), duration, and stack cap.
9. **Debug** — categorised logging (off by default). The "detection" category
   traces stance/prefix transitions (e.g. `Fortified -> true`, `Sneaky -> true`).

## Console commands

Open the in-game console (`` ` ``) and type any of these. (Stance registers
`stance` as a console command override on OpenMW 0.49+, so these are routed to
the mod instead of being parsed as Lua.)

- `stance` or `stance help` — usage summary
- `stance list` — core Stance skill level, the active stance, and every stance
  with its own level, effectiveness %, and on/off state
- `stance active` — the active stance with its level, the core level, current
  effectiveness, governing attribute, and the next perk to unlock
- `stance set core <level>` — set the **core** Stance skill (e.g. `stance set core 75`)
- `stance set <stanceId> <level>` — set one stance's own level
  (e.g. `stance set commoner 40`)
- `stance reset` — reset every stance's own level/XP to the start (the core
  skill is left untouched; use `stance set core <level>` for that)
- `stance reload` — flag the skill for re-registration on the next tick

Stance ids: `locksmith arcanist reforger blademeister angler huntsman apothecary
twirler thaumaturge dualist guisarmier pitmen axeman mjolnir zweihander soloist
thief brawler commoner`. (`stance set` validates against the live stance list,
so the ids always match whatever stances are defined.)

## Architecture notes

Following Toxicology!'s scope split:

- `scripts/stance/settings.lua` — **MENU** scope. Registers all nine settings
  groups.
- `scripts/stance/init.lua` — **PLAYER** scope, the orchestrator. Owns all
  persisted state (per-stance XP/levels, dual-wield flags), settings access,
  the perks bootstrap, the update loop, save/load, and every event
  registration. The heavy lifting is delegated to the `player/` modules below;
  init.lua wires them together and keeps anything a save file touches.
- `scripts/stance/global.lua` — **GLOBAL** scope. Mirrors player settings into a
  global storage section, forwards actor-death events back to the player for
  kill XP, and relays the global events from integration mods (lockpicking,
  fair trade, transcribe, etc.) to the player script.
- `scripts/stance/victim.lua` — **NPC/CREATURE** local scope. Reports hits and
  kills the player deals, back to the player as `Stance_PlayerDealtHit`.
- `scripts/stance/hazard.lua` — **ACTIVATOR / LIGHT** local scope. Watches armed
  traps and burning oil and fires `Stance_HazardHit` so deployable-alchemy kills
  credit the right stance.
- `scripts/stance/config.lua` — pure data. Stance definitions, perk ladders, the
  integration table, XP weights, and UI defaults.
- `scripts/stance/perks.lua` — perk effects: attribute/skill contribution tables
  (delta-accounted) and on-hit dispatch.
- `scripts/stance/player/` — PLAYER-scope submodules, each constructed by
  init.lua with an explicit dependency table: `resolver.lua` (every weapon
  classifier and the `resolveStance` priority waterfall; constructs `grip.lua`
  — the GRIP record mapping — internally), `prefixes.lua` (the imbue /
  Fortified / Sneaky name decorations, the Block-scaled Fortified bonus, and
  the prefix tooltip notes), `evasion.lua` (the per-stance Sanctuary bonus),
  `integrations_xp.lua` (the external-mod XP event handlers),
  `skill_framework.lua` (skill registration and effectiveness application),
  `hud.lua` (the indicator), `xp.lua` (XP banking), `console.lua` (console
  internals), `stat_access.lua` (stat accessors), and `felthorn_voice.lua`
  (Blademeister ambient lines). The modules hold only transient,
  recomputed-per-tick state — persisted state never leaves init.lua.

Persistent state lives in `storage.playerSection('Stance_StateV2')` under one
table keyed by stance id, so future migrations are straightforward (bump the
version suffix and write a migration in `onLoad`).
