# Stance! — Complete Documentation

A **dynamic stance skill system** for OpenMW Morrowind that transforms a single Skill Framework skill into a shape-shifting ability tied to your current weapon style, activity, or equipment. Inspired by **For Honor**'s stance mechanics — when you change weapons mid-fight, you become a different combatant entirely.

---

## Table of Contents

1. [Core Concept](#core-concept)
2. [Features Overview](#features-overview)
3. [Requirements & Installation](#requirements--installation)
4. [The 21 Stances](#the-21-stances)
5. [Stance Prefixes](#stance-prefixes)
6. [Integrations](#integrations)
7. [Perk System & Progression](#perk-system--progression)
8. [HUD Indicator](#hud-indicator)
9. [Settings & Customization](#settings--customization)
10. [Console Commands](#console-commands)
11. [Architecture & Design](#architecture--design)
12. [File Structure](#file-structure)

---

## Core Concept

Stance! uses a single Skill Framework skill that **morphs in real time** to match your active weapon style or activity. Every element changes dynamically:

- **Display name** — the stance title (Zweihänder, Brawler, Arcanist, etc.)
- **Governing attribute** — attribute scaling changes per stance
- **Description** — stance-specific flavor text
- **Perk ladder** — 25/50/75/100 perks tailored to the stance
- **Effectiveness bonus** — weapon-skill contribution from stance level
- **HUD icon** — visual indicator swaps per stance

**No weapon pausing. No mode switches.** The skill detects your active weapon every frame and updates instantly. Switch from a two-handed sword to fists mid-combat, and the system automatically reclassifies you as Brawler with all associated perks, attribute scaling, and XP progression.

### Philosophy: Read-Only Integration

Stance! is **pure Lua** and **read-only** against every external mod:
- Never modifies another mod's data, skills, or settings
- Only reads state and listens for events
- Applies bonuses through its own delta-accounted channels
- All events live in the `Stance_*` namespace
- Gracefully falls back to native detection when integrations are absent

You can run Stance! standalone and get every stance; integrations simply unlock additional XP sources and perk catalysts.

---

## Features Overview

### Dynamic Weapon-Style Detection
- **19 weapon styles** (stances) + **Muse** (performance-based) = 20 core stances
- **Fortified prefix** — shield equipped adds Block bonus (stackable)
- **Sneaky prefix** — crouched visibility badge overlay
- **Imbue prefixes** — Spellsword imbues prepend elemental tags to stance names

### Per-Stance Progression
- Each stance has **independent XP bank and level** (5–100)
- Only the **active stance** gains XP; switching stances preserves previous banks untouched
- **Core "Stance" skill** gains half of active stance XP and levels independently
- **Perks unlock from core skill level** — at core level 25, all level-25 perks become available
- A stance's **own level** drives its **effectiveness bonus** (weapon-skill multiplier)

### Comprehensive Integration Stack
- **22+ integrations** covering weapon mods, combat systems, alchemy, magic, crafting, utility
- **Event-driven architecture** — no polling, no data conflicts
- **Independent per-mod modules** — each lives in `scripts/Stance/player/integrations_*.lua`
- Integrations include: Iron Fist, N'Garde parry, Bullseye headshots, GRIP weapon conversion, Throwing!, Staves!, Sol combat mods, Bardcraft, Simply Mining, Fishing, and many more

### Rich HUD System
- **Stance icon** (64×64 DDS) swaps per active stance
- **Stance name** displays beneath icon with prefix badges (Sneaky overlay)
- **Draggable positioning** — click-drag to any screen location
- **Configurable size** and optional name-only mode
- **Lock toggle** to prevent accidental repositioning
- Position saved per resolution

### Customizable Notifications
- **Perk unlock popups** — appear at stance levels 25/50/75/100
- **Three notification styles** — Disabled / Popup / Message box
- **Configurable anchors** — place popups anywhere on screen
- **Stack cap** — limit simultaneous notifications (default 3)
- **Custom duration** — set how long popups stay visible

---

## Requirements & Installation

### Minimum Requirements
- **OpenMW 0.49.0** or later (developed/tested against 0.51+)
- **Skill Framework** — required for skill registration and morphing
- **Stats Window Extender** (optional) — enables "Stance" subsection in the skill list UI

### Installation Steps

1. **Copy the mod folder** (`Stance/`) to your OpenMW data folder
2. **Enable `Stance.omwscripts`** in your OpenMW content list (`.omwscripts` file, not `.esp`)
3. **Ensure load order** — Skill Framework loads **before** Stance!
4. **Launch OpenMW** and the mod initializes automatically
5. **Open Options → Scripts → Stance!** to configure settings

### Optional: StanceWheel Mod

This repository also includes **StanceWheel** (`scripts/StanceWheel/`), a companion quick-select menu:
- Radial stance picker
- Three-phase weapon selection for Dualist stance
- Shield-selection flow for Fortified stance
- Integrates with Quick Select Ultimate interface
- Entirely optional; Stance! works without it

---

## The 21 Stances

Each stance has a unique **ID**, **display name**, **governing attribute**, **effectiveness type**, and **activation rules**. The resolver checks rules in priority order; **the first match wins**.

| # | Stance | Attribute | Detection Rule | Mods |
|---|---|---|---|---|
| **0** | **Muse** | Personality | Performing a song idly (Bardcraft Practice) | Bardcraft |
| 1 | Locksmith | Agility | Lockpick or probe readied in right hand (via Use) | Oblivion-Style Lockpicking |
| 2 | Arcanist | Intelligence | Spellcasting stance active (engine state) | Incantation, Meditation, Disenchanting, Transcribe |
| 3 | Reforger | Endurance | Armorer's repair hammer equipped + weapon stance active | Weapon Upgrade, Armor Upgrade |
| 4 | Blademeister | Agility | Felthorn equipped (any `sd_`-prefixed shapeshifted form) | Felthorn (Daedra weapon) |
| 5 | Angler | Luck | Fishing pole equipped (`a_fishing_pole` or `hb_fishing_pole`) | Fishing |
| 6 | Huntsman | Speed | Bow or crossbow equipped (any ranged weapon type) | Bullseye |
| 7 | Apothecary | Intelligence | Thrown alchemy item equipped (concoction flask or vial) | Thrown Concoctions, Venefic Vials |
| 8 | Twirler | Agility | Thrown weapon equipped (non-alchemy, non-axe) | Throwing! |
| 9 | Thaumaturge | Willpower | Stave equipped (BluntTwoWide classification) | Staves! |
| 10 | Dualist | Speed | Dual Wielding off-hand active + one-handed primary weapon | Dual Wielding |
| 11 | Guisarmier | Endurance | Spear equipped (SpearTwoWide classification) | (native) |
| 12 | Pitmen | Endurance | Miner's Pick specifically (record ID `miner's pick`, AxeTwoHand) | Simply Mining |
| 13 | Axeman | Strength | Any axe (AxeOneHand or AxeTwoHand, including throwing axes) | (native) |
| 14 | Mjolnir | Strength | Blunt one-handed OR blunt two-handed close (maces, clubs, warhammers) | (native) |
| 15 | Zweihänder | Strength | Long-blade two-handed weapon (LongBladeTwoHand) | (native) |
| 16 | Soloist | Endurance | Long-blade one-handed weapon (LongBladeOneHand) | (native) |
| 17 | Thief | Speed | Short blade (ShortBladeOneHand) | (native) |
| 18 | Brawler | Strength | Fists up, no weapon equipped + weapon stance active | Iron Fist |
| 19 | Commoner | Luck | Weapons sheathed OR no rule above matched (fallback) | (native) |

### Priority Notes

**Identity-first stances sit high** in the resolver chain:
- **Blademeister** (rule 4) prioritizes before weapon-type branches, so Felthorn's shapeshifted forms always route to Blademeister regardless of temporary weapon classification
- **Angler** (rule 5) sits before ranged weapons, ensuring a fishing pole activates Angler instead of Huntsman
- **Apothecary** (rule 7) sits before thrown weapons, so thrown alchemy items route to Apothecary
- **Pitmen** (rule 12) sits before generic axes, so the Miner's Pick activates Pitmen instead of Axeman
- **Throwing axes** route to **Axeman** (rule 13), not Twirler (rule 8), via dedicated record-ID detection

### Stance Effectiveness Categories

Each stance applies its effectiveness bonus to a **target weapon skill**:

| Stance | Target Skill | Category |
|---|---|---|
| Locksmith | Security | Utility |
| Arcanist | Mysticism | Spellcasting |
| Reforger | Armorer | Utility |
| Blademeister | Long Blade | Melee |
| Angler | Fishing | Utility |
| Huntsman | Marksmanship | Ranged |
| Apothecary | Alchemy | Utility |
| Twirler | Throwing | Ranged |
| Thaumaturge | Mysticism | Spellcasting |
| Dualist | Either equipped weapon's skill | Melee |
| Guisarmier | Long Blade / Spear | Melee |
| Pitmen | Mining | Utility |
| Axeman | Axes | Melee |
| Mjolnir | Blunt Weapon | Melee |
| Zweihänder | Long Blade | Melee |
| Soloist | Long Blade | Melee |
| Thief | Short Blade | Melee |
| Brawler | Unarmed (via Iron Fist) | Melee |
| Commoner | Luck (passive) | Fallback |
| Muse | Personality (song buffs) | Music |

---

## Stance Prefixes

Stance names can be decorated with **cosmetic prefixes** that appear in the HUD and tooltip without affecting XP progression or perk levels. These are purely visual indicators of temporary state.

### Sneaky Prefix
- **Trigger** — player crouched (sneak mode active)
- **Display** — `Sneaky Zweihänder`, `Sneaky Brawler`, etc.
- **HUD badge** — small `Sneaky` overlay on bottom-right corner of stance icon
- **Disappears** — instantly when standing

### Fortified Prefix
- **Trigger** — shield equipped (any armor type classified as Shield)
- **Display** — `Fortified Zweihänder`, `Fortified Arcanist`, etc.
- **Block bonus** — **additive weapon-skill bonus** scaled from current Block skill
  - Bonus = `(Block Skill / 100) * 30` (configurable in settings)
  - Stacks additively with stance effectiveness
  - Applied as a delta-accounted Skill Framework modifier
- **Duration** — persists while shield equipped
- **HUD badge** — no visual badge (name-only prefix)

### Imbue Prefixes (Spellsword Integration)
- **Trigger** — Spellsword imbue active (`IW_ActiveSpell` state)
- **Display** — prepends element name to stance: `Fire Zweihänder`, `Frost Brawler`, `Shock Dualist`
- **Purpose** — cosmetic identification of imbue state
- **Effect** — no gameplay impact; XP and perks unaffected
- **Requires** — Spellsword mod + imbue active

---

## Integrations

Stance! integrates with **22+ OpenMW mods** through event-driven, read-only hooks. Each integration is modular, independent, and gracefully degrades if the source mod is absent.

### Organization

Integrations are grouped by **category** and implemented across three files:

- **`integrations_xp.lua`** — Event handlers for XP credit from external mods (the largest integration module)
- **`integrations_ngarde.lua`** — N'Garde parry-specific detection and XP logic
- **`integrations_bullseye.lua`** — Bullseye headshot bonuses
- Plus individual integrations wired into resolver, perks, and HUD systems

---

### Weapon-Style & Skill Mods

#### GRIP
- **What Stance! reads** — weapon-conversion maps (`GRIPRecords` storage)
- **Behavior** — a GRIP-converted 2H→1H weapon retains its **original weapon type** for stance purposes
- **Example** — a two-handed sword converted to one-handed still classifies as Zweihänder (via original type), not Soloist
- **Use case** — seamless weapon-mod compatibility; conversion doesn't trip stance resolution

#### Throwing!
- **What Stance! reads** — Twirler effectiveness and perk states
- **Perks unlocked** — Critical / Twin Flight / Bleed / Paralyze
- **XP sources** — on-hit XP, critical hits, thrown-weapon kills
- **Behavior** — Twirler stance unlocks Throwing!'s full perk catalog; perks scale with Twirler level

#### Staves!
- **What Stance! reads** — Thaumaturge effectiveness and perk states
- **Perks unlocked** — Concussive Strike / Arcane Siphon / Resonant Conduit / Null Pulse
- **XP sources** — on-hit XP, stave-specific ability triggers
- **Behavior** — Thaumaturge stance unlocks Staves!'s perk ladder

#### Bullseye
- **What Stance! reads** — headshot bonuses and accuracy modifiers
- **Behavior** — Huntsman stance gains bonus XP and damage scaling on successful headshots
- **Detection** — via `Bullseye_Headshot` event

#### Dual Wielding
- **What Stance! reads** — off-hand weapon state via events
- **Events** — `EquipSecondWeapon` (Dualist activated) / `RemoveSecondWeapon` (Dualist deactivated)
- **Behavior** — reliable Dualist detection; XP credited to active stance + core skill

#### Blademeister (Felthorn)
- **What Stance! reads** — record-ID prefix (`sd_`) for Felthorn's shapeshifted forms
- **Behavior** — any `sd_`-prefixed weapon automatically activates Blademeister regardless of current form
- **Ambient lines** — Felthorn speaks contextual dialogue (greetings, kills, low-health warnings, etc.)
- **Soul Resonance state** — tracked for special voice-line triggers (resonance achieved / exhaustion)
- **Perks** — Soul Perception, Soul Wavelength, Witch Hunter, Soul Resonance

#### Simply Mining
- **What Stance! reads** — mining success event (`SimplyMining_notifyItem`)
- **Skill** — mining_skill (internal Simply Mining identifier)
- **XP sources** — Pitmen stance gains XP on successful mining
- **Perks** — Vein Reader / Prospector / Pit Boss

#### Fishing
- **What Stance! reads** — fish caught event (`Fishing_playerCaughtFish`)
- **Skill** — fishing_skill (internal Fishing identifier)
- **XP sources** — Angler stance gains XP per fish caught
- **Perks** — Catch and Release / Trophy Cast / Master Angler

---

### Combat Integrations

#### N'Garde (Parry System)
- **What Stance! reads** — parry success event (`ngarde_parrySelf`)
- **Flag** — `isPerfect` indicates a perfect parry (damage negation, not just deflection)
- **Behavior** — successful parry grants **active stance** XP (larger reward for perfect parries)
- **Synergy** — Blademeister + perfect parry = Soul Resonance meter increment
- **Module** — `integrations_ngarde.lua` handles detection and XP credit

#### Gothic Style Knockout
- **What Stance! reads** — knockdown trigger (`GKD_DoKnockdown`)
- **Behavior** — Brawler stance gains bonus XP when landing a knockout
- **Proc chance** — KO knockdowns trigger Brawler level-up XP boost

#### Evasion!
- **What Stance! reads** — dodge/Sanctuary bonus state
- **Tooltip integration** — surfaces Evasion! bonus in the dynamic Stance skill tooltip with attribution
- **Tracking** — Evasion! and Stance! deltas track independently; they never interfere
- **Display** — "Evasion! +X" line appears alongside stance effectiveness bonus

#### Sol's Timed Directional Attacks (STDA)
- **Detection** — via MCM settings section (`Settings_SolTimedDirAttacks`)
- **Behavior** — tempo-driven stances (Twirler, Thaumaturge, Dualist, Muse, Commoner) gain a passive **weapon-skill bonus**:
  - **Timed-directional-attack mastery** — bonus ceilinged from STDA's `buffBase` and scaled by stance level
- **Tooltip** — stance effectiveness displays STDA mastery contribution separately
- **Module** — `sol_attacks.lua` handles detection and bonus calculation

#### Sol's Weighty Charged Attacks (SWCA)
- **Detection** — via MCM settings section (`Settings_SolWeightyChargeAttacks`)
- **Behavior** — heavy, committed stances (Zweihänder, Mjolnir, Thaumaturge, Axeman, Guisarmier) gain:
  - **Weighty-charged-attack mastery** — bonus ceilinged from SWCA's `buffBase`/`maxCharge` and equipped weapon weight, scaled by stance level
- **Tooltip** — weighty mastery contribution displayed alongside effectiveness
- **Module** — `sol_attacks.lua` (shared with STDA)

#### Move Like This (MLT)
- **Detection** — via MCM settings section (`Settings_MoveLikeThis`)
- **Behavior** — each melee stance's signature directional move(s) displayed in tooltip
- **XP reward** — landing one of MLT's two attacker-notified moves (critical thrust or mobility slash) grants **active stance** bonus XP
- **Attacker notify** — MLT fires an engine event when a valid move lands; Stance! listens and credits XP
- **Tooltip** — stance descriptions include MLT move references (e.g., "Overhead Slash" for Zweihänder)

#### Bardcraft (Music System)
- **Detection** — via Skill Framework skill presence (`bardcraft`)
- **Powers** — **Muse stance**: idle performances (Bardcraft Practice performances) activate Muse
- **Song completion** — finishing a song grants a **timed inspiration buff** to the stance the song is associated with
  - Buff scales with song performance quality
  - Buff duration configurable
  - Each stance has its own associated song category
- **Perks** — Muse has dedicated perks (Bardcraft integration)
- **Module** — `muse.lua` handles Bardcraft event hooks and buff logic

---

### Thrown & Deployable Alchemy (Arcimaestro Antares)

All mods below are **pure-content `.esp` files with no Lua**, making them safe for read-only integration.

#### Thrown Concoctions
- **What Stance! reads** — concoction flask equipped (sentinel record `concoction_base`)
- **Behavior** — equipping any thrown concoction activates Apothecary stance
- **XP sources** — Apothecary gains XP on successful concoction hits/alchemy actions

#### Venefic Vials
- **What Stance! reads** — thrown vial equipped (specific record ID `vv_vial_th`)
- **Behavior** — equipping the vial activates Apothecary stance
- **XP sources** — Apothecary gains XP on vial hits

#### Traps
- **What Stance! reads** — trap activation events (trap opening by non-player actor)
- **Module** — `hazard.lua` ACTIVATOR listener
- **Behavior** — credits **Thief** stance when a non-player actor springs an armed trap (`trap_open`)
- **XP** — standing near a trap kill gives Thief XP

#### Oil Flask
- **What Stance! reads** — burning oil fire state (lit `oil_fire` LIGHT over an `oil_pool`)
- **Module** — `hazard.lua` LIGHT listener
- **Behavior** — credits **Apothecary** stance when a non-player actor stands in lit oil fire
- **XP** — oil fire kills credit Apothecary XP

---

### Magic, Crafting & Utility Integrations

#### Spellsword (Imbue Weapon)
- **What Stance! reads** — imbue state (`IW_ActiveSpell` → `activeSpell`)
- **Behavior** — prepends a **cosmetic element prefix** to stance name (e.g., `Fire Zweihänder`)
- **XP/perks** — no XP or perk effect; purely visual
- **Resolver effect** — no stance change; only a name decoration

#### Incantation
- **What Stance! reads** — spellcasting animation text-key events
- **Behavior** — Arcanist stance gains XP on successful spellcasts
- **XP sources** — per-cast XP, scaled by spell power

#### Meditation Skill
- **What Stance! reads** — meditation tick via SkillProgression hook
- **Behavior** — Arcanist stance gains passive XP while meditating
- **XP sources** — passive meditation ticks when meditation skill active

#### Disenchanting
- **What Stance! reads** — disenchantment completion event (`disenchanting_finishedDisenchanting`)
- **Behavior** — Arcanist OR Thaumaturge stance gains XP on successful disenchantment
- **Stance selection** — if Thaumaturge active, Thaumaturge gains XP; else Arcanist

#### Transcribe
- **What Stance! reads** — transcription completion event (`TRAN_doTranscribe`)
- **Behavior** — Arcanist OR Thaumaturge stance gains XP on spell transcription
- **Stance selection** — if Thaumaturge active, Thaumaturge gains XP; else Arcanist

#### Weapon Upgrade
- **What Stance! reads** — repair hammer equipped (record ID `repair_hammer_weapon`)
- **Behavior** — Reforger stance gains XP on successful (or failed) weapon upgrade
- **XP sources** — per-upgrade XP, not tied to success/failure (both award XP)

#### Armor Upgrade
- **What Stance! reads** — same repair hammer detection as Weapon Upgrade
- **Behavior** — Reforger stance gains XP on armor upgrades
- **Shared detection** — Weapon Upgrade and Armor Upgrade share the same hammer record ID

#### Oblivion-Style Lockpicking
- **What Stance! reads** — lockpick success event (`OSL_LockpickSuccess`)
- **Behavior** — Locksmith stance gains bonus XP on successful lockpick
- **XP sources** — per-successful-pick XP

#### Talking Trains Speechcraft
- **Detection** — MCM presence check (optional integration)
- **Behavior** — mod is detected for display/toggle; Commoner's talking XP reacts to engine `UiModeChanged` signal directly
- **Synergy** — works with or without Talking Trains mod (native engine integration)

#### Commercium / Fair Trade
- **What Stance! reads** — trade transaction event (`FairTrade_Transaction`)
- **Behavior** — Commoner stance gains XP on successful merchant trades
- **XP sources** — per-transaction XP, scaled by value

#### Toxicology! (Sibling Mod)
- **Relationship** — read-only sibling system
- **Behavior** — Stance! never writes to Toxicology's data, skills, or settings
- **Coexistence** — both mods run independently with zero data conflicts
- **Event namespace** — Toxicology! has `Toxicology_*` events; Stance! has `Stance_*` events

---

## Perk System & Progression

### XP Mechanics

Stance! uses a **dual-level system**:

1. **Per-stance level** (5–100)
   - Independent XP bank for each active stance
   - Only the **active stance** gains XP; switching stances preserves prior banks untouched
   - Levels faster than core skill (gains 100% of integration XP)

2. **Core "Stance" skill level** (5–100)
   - Shared across all stances
   - Gains **50% of whatever the active stance just gained** (via `progressionSlowdown` multiplier)
   - Levels roughly half as fast as active stances

### Perk Unlock Timing

**Perks unlock from the core skill level** (not per-stance levels):
- **Core level 25** → all level-25 perks become available across all stances
- **Core level 50** → all level-50 perks unlock
- **Core level 75** → level-75 perks
- **Core level 100** → level-100 perks (max)

Once a perk tier unlocks globally, **each stance displays its perk ladder** in the tooltip showing which perks are available for that specific stance.

### Perk Ladders

Each stance has **four perks** at tiers 25/50/75/100, organized by **integration association**:

#### Muse (Bardcraft Integration)
- 25: Performer's Grace
- 50: Encore
- 75: Bardcraft mastery
- 100: Inspirational Aura

#### Locksmith (Oblivion-Style Lockpicking Integration)
- 25: Careful Hands
- 50: Lock Whisperer
- 75: Safe Cracker
- 100: Open Sesame

#### Arcanist (Incantation / Meditation Integration)
- 25: Mana Efficiency
- 50: Arcane Mastery
- 75: Spellwarp
- 100: Mythic Sorcery

#### Reforger (Weapon/Armor Upgrade Integration)
- 25: Anvil Arms
- 50: Weak-Point Strike
- 75: Sundering Blow
- 100: Forgemaster's Touch

#### Blademeister (Felthorn Integration)
- 25: Soul Perception
- 50: Soul Wavelength
- 75: Witch Hunter
- 100: Soul Resonance

#### Angler (Fishing Integration)
- 25: Catch and Release
- 50: Trophy Cast
- 75: Master Angler
- 100: Trophy Mounted

#### Huntsman (Bullseye Integration)
- 25: Quick Draw
- 50: Deadshot
- 75: Headhunter
- 100: Sniper's Mark

#### Apothecary (Thrown Concoctions Integration)
- 25: Flask Handler
- 50: Alchemical Precision
- 75: Concoction Mastery
- 100: Elixir Savant

#### Twirler (Throwing! Integration)
- 25: Critical Strike
- 50: Twin Flight
- 75: Bleed Master
- 100: Paralyze Expert

#### Thaumaturge (Staves! Integration)
- 25: Concussive Strike
- 50: Arcane Siphon
- 75: Resonant Conduit
- 100: Null Pulse

#### Dualist (Dual Wielding Integration) — Net-New
- 25: Paired Strike
- 50: Blade Dance
- 75: Synchronization
- 100: Unbreakable Rhythm

#### Guisarmier — Net-New
- 25: Reach Mastery
- 50: Sweeping Slash
- 75: Pike Charge
- 100: Spear Lord

#### Pitmen (Simply Mining Integration)
- 25: Vein Reader
- 50: Prospector
- 75: Pit Boss
- 100: Mother Lode

#### Axeman — Net-New
- 25: Cleave
- 50: Splitting Blow
- 75: Rending Strike
- 100: Executioner's Edge

#### Mjolnir — Net-New
- 25: Crushing Force
- 50: Maul Master
- 75: Hammer Throw
- 100: Warhammer Legend

#### Zweihänder — Net-New
- 25: Power Slash
- 50: Overhead Strike
- 75: Momentum
- 100: Unstoppable Force

#### Soloist — Net-New
- 25: Riposte
- 50: Whirlwind Strike
- 75: Blade Finesse
- 100: Master Swordsman

#### Thief — Net-New
- 25: Quick Slash
- 50: Backstab
- 75: Shadow Master
- 100: Assassin's Creed

#### Brawler (Iron Fist Integration)
- 25: Haymaker
- 50: Devastating Punch
- 75: Shatter Guard
- 100: Bare-Knuckle Champion

#### Commoner (Fallback) — Net-New
- 25: Street Smarts
- 50: Jack of All Trades
- 75: Survivor's Instinct
- 100: Legendary Wanderer

### XP Sources

XP is credited to the **active stance** from various triggers:

| Source | Stance(s) | Trigger | Config |
|---|---|---|---|
| **Combat hits** | All melee/brawler | On-hit during combat | Combat XP multiplier |
| **Combat kills** | All melee/brawler | Killing an enemy | Kill XP multiplier |
| **Parry (N'Garde)** | Active stance | Successful parry (bonus for perfect) | N'Garde parry XP |
| **Headshots (Bullseye)** | Huntsman | Ranged headshot | Bullseye XP multiplier |
| **Thrown weapon hits** | Twirler, Axeman (throwable) | Successful thrown-weapon hit | Throw XP multiplier |
| **Mining (Simply Mining)** | Pitmen | Successful mine | Mining XP multiplier |
| **Fishing** | Angler | Fish caught | Fishing XP multiplier |
| **Spellcasting (Incantation)** | Arcanist | Spell cast successfully | Spell XP multiplier |
| **Meditation ticks** | Arcanist | Meditation active | Meditation XP multiplier |
| **Disenchanting** | Arcanist, Thaumaturge | Spell disenchanted | Disenchanting XP multiplier |
| **Transcription** | Arcanist, Thaumaturge | Spell transcribed | Transcription XP multiplier |
| **Lockpicking** | Locksmith | Lock picked successfully | Lockpicking XP multiplier |
| **Trading** | Commoner | Item sold/bartered | Trading XP multiplier |
| **Trap kills** | Thief | Non-player death from trap | Trap XP multiplier |
| **Oil fire kills** | Apothecary | Non-player death from oil fire | Oil fire XP multiplier |
| **Weapon upgrade** | Reforger | Weapon upgraded (success/fail) | Upgrade XP multiplier |
| **Concoction hits** | Apothecary | Thrown concoction hits | Alchemy XP multiplier |
| **Directional attacks (MLT)** | Active stance | Critical thrust or mobility slash lands | MLT bonus XP |
| **Song completion (Bardcraft)** | Muse | Song finished | Inspiration buff duration |

### Progression Tuning

**All XP multipliers are configurable via MCM:**
- Per-source XP weight (0–500%)
- Global XP multiplier (0–500%)
- Race/class XP bonuses
- Progression slowdown (core multiplier affecting all sources)

Example: A player with `Combat XP: 200%` gains twice the XP from combat hits; a player with `Global XP: 50%` gains half XP from all sources.

---

## HUD Indicator

The **Stance HUD** is a persistent, configurable widget displaying the active stance in real-time.

### Visual Elements

1. **Stance Icon** (64×64 DDS texture)
   - Unique icon per stance, stored in `icons/Stance/`
   - Auto-swaps as active stance changes
   - Fallback to text if icon missing

2. **Stance Name**
   - Display name + active prefixes (Sneaky, Fortified, imbues)
   - Updates instantly on stance change
   - Can be hidden for icon-only mode

3. **Sneaky Badge**
   - Small overlay on bottom-right corner of icon
   - Appears when crouched (Sneaky prefix active)
   - Disappears on stand

### Positioning & Customization

- **Draggable** — click-drag to any screen location
- **Position saved** — persists across sessions and resolution changes
- **Lock toggle** — prevents accidental repositioning
- **Size slider** — adjust icon size (scales name and badge proportionally)
- **Name-only mode** — hide icon, show text label only
- **Default position** — lower-left corner of screen
- **Reset** — set X/Y to 0 in MCM to restore default placement

### HUD Icon Assets

All stance icons are stored as **uncompressed RGBA32 DDS** files:

| Icon | File | Status |
|---|---|---|
| Muse | `Muse.dds` | ✓ |
| Locksmith | `Locksmith.dds` | ✓ |
| Arcanist | `Arcanist.dds` | ✓ |
| Reforger | `Reforger.dds` | ✓ |
| Blademeister | `Blademeister.dds` | ✓ |
| Angler | `Angler.dds` | ✓ |
| Huntsman | `Huntsman.dds` | ✓ |
| Apothecary | `Apothecary.dds` | ✓ |
| Twirler | `Twirler.dds` | ✓ |
| Thaumaturge | `Thaumaturge.dds` | ✓ |
| Dualist | `Dualist.dds` | ✓ |
| Guisarmier | `Guisarmier.dds` | ✓ |
| Pitmen | `Pitmen.dds` | ✓ |
| Axeman | `Axeman.dds` | ✓ |
| Mjolnir | `Mjolnir.dds` | ✓ |
| Zweihänder | `Zweihänder.dds` | ✓ |
| Soloist | `Soloist.dds` | ✓ |
| Thief | `Thief.dds` | ✓ |
| Brawler | `Brawler.dds` | Gauntlet tiers |
| Commoner | `Commoner.dds` | ✓ |
| Fortified | `Fortified.dds` | Prefix badge |
| Sneaky | (overlay) | Prefix badge |
| Muse instruments | `Muse_*.dds` | Drum, Fiddle, etc. |
| Imbues | `*_Imbue.dds` | Fire, Frost, Shock |
| Brawler gauntlets | `*Gauntlets.dds` | Light, Medium, Heavy |

**Important:** OpenMW UI requires **uncompressed RGBA32**. DXT1/BC1 compression causes purple placeholder rendering.

### Tooltip Integration

When hovering over the stance name in the HUD or stats window:

- **Stance description** — short flavor text
- **Governing attribute** — current scaling attribute
- **Effectiveness bonus** — weapon-skill bonus from stance level
- **Core skill level** — shared progression level
- **Active perk tier** — next unlock level (25/50/75/100)
- **Perk ladder** — available perks for this stance (unlocked-only filter optional)
- **Integration notes** — associated mod perks (e.g., "Throwing! perks: Critical, Twin Flight, Bleed, Paralyze")
- **Sol combat mods** — STDA/SWCA mastery contributions (if active)
- **Evasion! bonus** — Sanctuary contribution (if mod active)
- **Move Like This** — signature directional moves (if mod active)

---

## Settings & Customization

All settings are accessible via **Options → Scripts → Stance!** and organized into **nine focused groups**:

### 1. General
- **Master toggle** — enable/disable mod entirely
- **Skill registration** — force re-register skill on next update
- **Dynamic attribute swap** — toggle whether stance changes swap governing attribute
- **Stance-change announcements** — notify player on stance switch (chat message)
- **Localization** — select language (English only currently)

### 2. Stances
- **Enable per-stance** — 19 toggles (one per stance); disable to stop a stance from ever activating
- **Enable Fortified** — shield-equipped stance prefix
- **Enable Sneaky** — crouch-state name prefix
- **Fortified Block bonus** — configurable scaling factor (% of Block skill → weapon-skill bonus)

### 3. Perks
- **Master perks toggle** — enable/disable all perk effects globally
- **Per-stance perk toggle** — 19 toggles; disable to suppress level-up notifications and hide perk ladder, but stances still level normally

### 4. Progression
- **Race/class bonuses** — separate toggles for race-based and class-based XP multipliers
- **XP source toggles** — enable/disable each integration's XP source (combat, spellcasting, mining, fishing, etc.)
- **Global XP multiplier** — 0–500% (scales all XP sources uniformly)

### 5. Integrations
- **Per-integration toggles** — grouped by category:
  - Weapon-style mods (GRIP, Throwing!, Staves!, etc.)
  - Combat mods (N'Garde, Bullseye, Sol mods, etc.)
  - Utility mods (Fishing, Mining, Disenchanting, etc.)
- **Fallback behavior** — disabling an integration falls back to native detection where possible

### 6. HUD Indicator
- **Show toggle** — hide/show stance indicator
- **Show name toggle** — icon-only mode
- **Lock toggle** — prevent accidental dragging
- **Icon size** — adjustable slider (scales name and badge)
- **X / Y position** — editable numeric fields (0 = default)

### 7. Tooltip
- **Mechanic details** — show/hide stance-resolution logic explanation
- **Perk ladder** — show/hide available perks
- **Unlocked-only filter** — hide unavailable perks until unlocked
- **All-stances summary** — show/hide full stance list with brief descriptions

### 8. Notifications
- **Perk unlock style** — Disabled / Popup / Message box
- **Popup anchor** — named screen position (top-left, center, bottom-right, etc.)
- **Popup duration** — how long notifications stay visible (seconds)
- **Stack cap** — max simultaneous popups (default 3)

### 9. Debug
- **Logging categories** — off by default:
  - **Detection** — trace stance/prefix transitions (e.g., `Fortified -> true`, `Sneaky -> true`)
  - **XP** — log XP credit events and per-stance balances
  - **Integration** — log external-mod event triggers
  - **HUD** — log stance icon/name updates
  - **Perks** — log perk unlock/effect application
  - **Resolver** — detailed weapon-classification and rule-matching traces

---

## Console Commands

Open the in-game console (`` ` ``) and type any command. Stance registers `stance` as a console-command override on OpenMW 0.49+, so these are routed to the mod instead of being parsed as Lua.

### Command Reference

#### `stance` or `stance help`
Displays usage summary and all available commands.

#### `stance list`
Shows:
- Core Stance skill level
- Active stance (with its current level)
- All 19 stances with:
  - Individual stance level
  - Effectiveness % (based on level)
  - On/off state (enabled/disabled in settings)

#### `stance active`
Displays active stance details:
- Stance name and ID
- Current stance level
- Core skill level
- Effectiveness bonus (weapon-skill contribution)
- Governing attribute
- Next perk tier to unlock

#### `stance set core <level>`
Set the **core Stance skill** to a specific level (5–100).

Example: `stance set core 75`

#### `stance set <stanceId> <level>`
Set an individual stance's level (5–100).

Example: `stance set zweihander 50` (sets Zweihänder to level 50)

#### `stance reset`
Reset every **per-stance** level/XP to the starting value (level 5). The **core skill** is left untouched; use `stance set core <level>` to reset that separately.

#### `stance reload`
Flag the skill for re-registration on the next tick. Useful after changing Skill Framework settings or if the skill somehow desyncs.

### Valid Stance IDs
```
locksmith arcanist reforger blademeister angler huntsman apothecary twirler
thaumaturge dualist guisarmier pitmen axeman mjolnir zweihander soloist thief
brawler commoner
```

Aliases (case-insensitive):
- `zweihander` = `zwei`, `2h_sword`
- `soloist` = `solo`, `1h_sword`
- `shortblade` = `thief`, `dagger`
- `blunt2h` = `mjolnir`, `warhammer`

---

## Architecture & Design

### Scope Structure (Following Toxicology!'s Pattern)

Stance! uses OpenMW's **scope system** to isolate data and logic by context:

#### MENU Scope
**File:** `scripts/Stance/settings.lua`

Registers all nine MCM settings groups. Runs only when options menus are open; has no access to player state.

#### PLAYER Scope
**File:** `scripts/Stance/init.lua` (orchestrator) + `scripts/Stance/player/` (submodules)

- **init.lua** — owns all persisted state:
  - Per-stance XP/levels
  - Dual-wield flags
  - Settings access layer
  - Perks bootstrap
  - Main update loop
  - Save/load handlers
  - Event registration orchestration
  
- Heavy lifting delegated to modular submodules (listed below); init.lua wires them together

#### GLOBAL Scope
**File:** `scripts/Stance/global.lua`

- Mirrors player settings into global storage (accessible from other scopes)
- Forwards actor-death events back to player for kill XP
- Relays global events from integration mods (lockpicking, fair trade, transcribe, etc.)

#### NPC / CREATURE Local Scope
**File:** `scripts/Stance/victim.lua`

Attached to each NPC/creature actor. Reports hits and kills the player deals, firing `Stance_PlayerDealtHit` back to the player script.

#### ACTIVATOR / LIGHT Local Scope
**File:** `scripts/Stance/hazard.lua`

Watches armed traps and burning oil; fires `Stance_HazardHit` so deployable-alchemy kills credit the right stance.

---

### Player-Scope Submodules

All modules in `scripts/Stance/player/` are constructed by **init.lua** with explicit dependency injection. Modules receive a **dep table** containing required functions and state accessors:

| Module | Purpose |
|---|---|
| **resolver.lua** | Weapon classifier; implements the priority-ordered stance-detection waterfall. Constructs `grip.lua` internally for GRIP record mapping. |
| **grip.lua** | GRIP weapon-conversion record mapping (lazily constructed). |
| **prefixes.lua** | Imbue / Fortified / Sneaky name decoration logic; Block-scaled Fortified bonus; prefix tooltip notes. |
| **evasion.lua** | Per-stance Sanctuary bonus calculation and tooltip integration. |
| **integrations_xp.lua** | External-mod XP event handlers (largest integration module). |
| **integrations_ngarde.lua** | N'Garde parry-specific detection and XP credit. |
| **integrations_bullseye.lua** | Bullseye headshot bonuses and detection. |
| **skill_framework.lua** | Skill registration and dynamic effectiveness application. |
| **hud.lua** | Stance indicator widget (icon, name, dragging, positioning). |
| **xp.lua** | XP banking, per-level progression curves, and level-up logic. |
| **console.lua** | Console-command parsing and output formatting. |
| **stat_access.lua** | Accessors for player attributes, skills, and equipment state. |
| **perks.lua** (root) | Perk effects: attribute/skill contribution tables (delta-accounted) and on-hit dispatch. |
| **codex.lua** | Stance encyclopedia and lore text (used by tooltip). |
| **muse.lua** | Bardcraft integration (music system, idle performance detection, song buffs). |
| **felthorn_voice.lua** | Blademeister ambient dialogue system (greetings, kills, low-health warnings, resonance state). |
| **sol_attacks.lua** | Sol's Timed Directional Attacks and Weighty Charged Attacks mastery bonuses. |
| **sneakisgood.lua** | Integration with SneakIsGooderNow (if installed). |

### Core Data Files

| File | Purpose |
|---|---|
| **config.lua** | Central tuning: stance definitions, perk ladders, integration table, XP weights, UI defaults. |
| **perks.lua** | Perk effects implementations. |

---

### Event Architecture

Stance! fires custom events in the `Stance_*` namespace. Other mods and scripts can listen for these:

| Event | Fired When | Payload |
|---|---|---|
| `Stance_StanceChanged` | Active stance changes | `stanceId`, `stanceName` |
| `Stance_PrefixChanged` | Prefix state changes (Sneaky, Fortified) | `prefix`, `isActive` |
| `Stance_XpGranted` | Any XP credited to a stance | `stanceId`, `amount`, `source` |
| `Stance_LevelUp` | Stance reaches new level | `stanceId`, `newLevel` |
| `Stance_PerkUnlocked` | Perk tier unlocked globally | `level`, `stances` (array) |
| `Stance_PlayerDealtHit` | Player hits an actor (via victim.lua) | `target`, `damage`, `isCritical` |
| `Stance_HazardHit` | Actor dies to trap/oil (via hazard.lua) | `source`, `actor` |

### Persisted State

Persisted state lives in **`storage.playerSection('Stance_StateV2')`** under one table keyed by stance ID:

```lua
{
  locksmith = { xp = 100, level = 15, ... },
  arcanist = { xp = 45, level = 8, ... },
  -- ... one entry per stance
  _meta = { version = 2 }
}
```

**Future migrations** are straightforward: bump the version suffix (e.g., `Stance_StateV3`) and write a migration function in `onLoad`.

### Dependency Injection Pattern

Submodules receive a **dependency table** from init.lua:

```lua
local module = require('scripts.Stance.player.resolver')
local resolver = module:new({
  storage = storage,
  config = config,
  log = log,
  settings = settingsAccessor,
  -- ... other deps
})
```

This ensures:
- **Zero globals** — all state flows through explicit deps
- **Easy testing** — mock dependencies for unit tests
- **Clear contracts** — each module declares what it needs
- **Circular-dependency safety** — init.lua orchestrates dependency order

---

## File Structure

```
Stance/
├── Stance.omwscripts                          # OpenMW script loader configuration
├── README.md                                  # Original documentation
├── MODDING_NEW_STANCE.md                      # Guide for adding new stances
│
├── scripts/Stance/
│   ├── init.lua                               # PLAYER scope, orchestrator
│   ├── settings.lua                           # MENU scope, MCM registration
│   ├── config.lua                             # Stance definitions, perks, integrations
│   ├── perks.lua                              # Perk effect implementations
│   ├── global.lua                             # GLOBAL scope, event relay
│   ├── victim.lua                             # NPC/CREATURE scope, hit tracking
│   ├── hazard.lua                             # ACTIVATOR/LIGHT scope, trap/oil detection
│   │
│   └── player/                                # PLAYER-scope submodules
│       ├── resolver.lua                       # Stance detection (priority waterfall)
│       ├── grip.lua                           # GRIP weapon conversion mapping
│       ├── prefixes.lua                       # Name prefix logic (Sneaky, Fortified, imbues)
│       ├── evasion.lua                        # Evasion! dodge bonus integration
│       ├── integrations_xp.lua                # Event-driven XP handlers (22+ mods)
│       ├── integrations_ngarde.lua            # N'Garde parry-specific logic
│       ├── integrations_bullseye.lua          # Bullseye headshot bonuses
│       ├── skill_framework.lua                # Skill registration & effectiveness
│       ├── hud.lua                            # Stance indicator widget
│       ├── xp.lua                             # XP banking & progression
│       ├── console.lua                        # Console command parsing
│       ├── stat_access.lua                    # Player stat accessors
│       ├── codex.lua                          # Stance lore & descriptions
│       ├── muse.lua                           # Bardcraft music integration
│       ├── felthorn_voice.lua                 # Blademeister ambient dialogue
│       ├── sol_attacks.lua                    # Sol combat-mod mastery
│       └── sneakisgood.lua                    # SneakIsGooderNow integration
│
├── scripts/StanceWheel/
│   ├── wheel.lua                              # Radial stance picker widget
│   └── settings.lua                           # StanceWheel MCM settings
│
├── icons/Stance/
│   ├── Angler.dds                             # Angler stance icon
│   ├── Apothecary.dds                         # Apothecary stance icon
│   ├── Arcanist.dds                           # Arcanist stance icon
│   ├── Axeman.dds                             # Axeman stance icon
│   ├── Blademeister.dds                       # Blademeister stance icon
│   ├── Brawler.dds                            # Brawler stance icon (gauntlet variant)
│   ├── Commoner.dds                           # Commoner stance icon
│   ├── Dualist.dds                            # Dualist stance icon
│   ├── Fire_Imbue.dds                         # Fire imbue prefix overlay
│   ├── Forager.dds                            # Forager stance icon (unused/reserved)
│   ├── Fortified.dds                          # Fortified prefix badge
│   ├── Frost_Imbue.dds                        # Frost imbue prefix overlay
│   ├── Guisarmier.dds                         # Guisarmier stance icon
│   ├── HeavyGauntlets.dds                     # Heavy gauntlet tier for Brawler
│   ├── Huntsman.dds                           # Huntsman stance icon
│   ├── LightGauntlets.dds                     # Light gauntlet tier for Brawler
│   ├── Locksmith.dds                          # Locksmith stance icon
│   ├── MediumGauntlets.dds                    # Medium gauntlet tier for Brawler
│   ├── Mjolnir.dds                            # Mjolnir stance icon
│   ├── Muse.dds                               # Muse stance icon
│   ├── Muse_Drum.dds                          # Muse instrument variant (Drum)
│   ├── Muse_Fiddle.dds                        # Muse instrument variant (Fiddle)
│   ├── Pitmen.dds                             # Pitmen stance icon
│   ├── Reforger.dds                           # Reforger stance icon
│   ├── Shock_Imbue.dds                        # Shock imbue prefix overlay
│   ├── Soloist.dds                            # Soloist stance icon
│   ├── Thaumaturge.dds                        # Thaumaturge stance icon
│   ├── Thief.dds                              # Thief stance icon
│   ├── Twirler.dds                            # Twirler stance icon
│   └── Zweihänder.dds                         # Zweihänder stance icon
│
├── l10n/Stance/
│   └── en.yaml                                # English localization (44+ KB, 1000+ strings)
│
├── l10n/StanceWheel/
│   └── en.yaml                                # StanceWheel English localization
│
└── textures/Stance/
    ├── ... additional UI textures / overlays
    └── ...
```

### Asset Formats

**Icons (DDS)**
- Format: **Uncompressed RGBA32**
- Size: 64×64 or 128×128 pixels
- Location: `icons/Stance/*.dds`
- ⚠️ **Critical:** DXT1/BC1 compression causes purple placeholder rendering in OpenMW UI

**Localization (YAML)**
- Format: YAML key-value pairs
- Scope: Stance names, descriptions, perk names, MCM labels, tooltips, console output
- Files: `l10n/Stance/en.yaml` (44+ KB), `l10n/StanceWheel/en.yaml`

---

## Modding & Extensibility

### Creating a New Stance

For detailed instructions on adding custom stances, skills, or integrations, see **`MODDING_NEW_STANCE.md`** in the mod folder.

### Key Extension Points

1. **Adding a new stance** — edit `config.lua`:
   ```lua
   -- Add to stances table
   {
     id = 'mycustom',
     displayName = 'My Custom Stance',
     attribute = 'strength',
     ...
   }
   ```

2. **Adding integration XP** — edit `scripts/Stance/player/integrations_xp.lua`:
   ```lua
   local function onMyModEvent(e)
     stance:creditStance('mycustom', 50, 'mymod')
   end
   ```

3. **Adding perk effects** — edit `scripts/Stance/perks.lua`:
   ```lua
   perks.mycustom = {
     [25] = { ... perk definition ... },
     ...
   }
   ```

### Integration Development

See **`integrations_xp.lua`** for 20+ examples of event-driven integrations with various mods. Each integration:
- Listens for a specific mod event
- Validates the mod is active
- Credits XP to the appropriate stance
- Never writes external data

---

## Conclusion

**Stance!** delivers a deeply integrated, modular stance system for OpenMW Morrowind that:

- ✓ Transforms a single skill into a shape-shifting ability tied to weapon style
- ✓ Supports 20+ stances with independent progression
- ✓ Integrates read-only with 22+ external mods
- ✓ Provides rich, customizable HUD and notification systems
- ✓ Uses pure Lua with dependency injection for maintainability
- ✓ Gracefully degrades when integrations are absent
- ✓ Exposes full console API for debugging and testing

For support, modding guidance, or integration requests, refer to **`MODDING_NEW_STANCE.md`** and the extensive comments throughout the codebase.

---

**Stance! — Every weapon style is a different warrior.**
