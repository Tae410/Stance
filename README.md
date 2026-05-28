# Stance!

A dynamic stance skill mod for OpenMW Morrowind. **Stance!** adds one Skill
Framework skill whose displayed name, governing attribute, description, and
perks all change to match the weapon style you currently have active.

Inspired by **For Honor**'s stance system — when you change weapons mid-fight,
the game treats you as a different combatant entirely. Stance! reproduces that
feel through a single Skill Framework skill that morphs in real time: its
displayed name, governing attribute, description, and perk ladder all swap to
match the weapon style you currently have active.

The mod is pure Lua, built on top of `Toxicology!`'s architecture, and
designed to interlope with a stack of other OpenMW skill mods:

| Mod | What Stance! reads from it |
|---|---|
| **GRIP** | Weapon-conversion maps — a GRIP-converted 2H→1H weapon still classifies as 2H for stance purposes |
| **Throwing!** | Twirler stance effectiveness and perks (Critical / Twin Flight / Bleed / Paralyze) |
| **Staves!** | Thaumaturge stance effectiveness and perks (Concussive Strike / Arcane Siphon / Resonant Conduit / Null Pulse) |
| **Bullseye** | Huntsman stance bonuses tied to ranged headshots |
| **N'Garde** | Block / parry success for Fortifier XP and the perfect-parry bonus |
| **Dual Wielding** | Reliable Dualist detection via `EquipSecondWeapon` and `RemoveSecondWeapon` events |
| **Gothic Style Knockout** | Brawler knockout-chance proc via `GKD_DoKnockdown` |
| **Incantation** | Arcanist spellcasting XP via the `spellcast` animation text-key |
| **Meditation Skill** | Arcanist tick XP via the SkillProgression hook |
| **Weapon Upgrade** | Detects the `repair_hammer_weapon` for Reforger and credits Reforger XP on a successful upgrade |
| **Armor Upgrade** | Same as Weapon Upgrade — detects the same hammer for Reforger |
| **Blademeister** | Detects Felthorn — the shapeshifting Daedra weapon — by its `sd_` record-id prefix, activating the Blademeister stance regardless of which weapon type Felthorn has transformed into |
| **Toxicology!** | Read-only sibling — Stance! never writes to Toxicology's data |

None of these mods are hard dependencies. Stance! gracefully falls back to
native detection when an integration is missing — you can run Stance! by
itself and still get every stance (some perks lose their catalyst).

## Requirements

- OpenMW 0.49.0 or later
- Skill Framework
- Stats Window Extender (optional, for the "Stance" subsection placement)

## Installation

1. Install the `Stance` folder as an OpenMW data folder (the folder containing
   `Stance.omwscripts`).
2. Enable `Stance.omwscripts` in your OpenMW content list.
3. Make sure Skill Framework loads before Stance.
4. Open **Options → Scripts → Stance!** to configure.

## The stances

The mod resolves the active stance every frame by walking a priority-ordered
list. The first stance whose detection signal fires wins.

| # | Stance | Governing | When it activates |
|---|---|---|---|
| 1 | Locksmith | Agility | Lockpick OR probe equipped (readied via Use, not just carried) |
| 2 | Commoner | Luck | Weapons sheathed (no lockpicks/probes — Locksmith fallback) |
| 3 | Arcanist | Intelligence | Spellcasting stance active |
| 4 | Reforger | Endurance | Armorer's repair hammer equipped, weapon stance up |
| 5 | Blademeister | Agility | Felthorn equipped (any `sd_`-prefixed form from the Blademeister mod) |
| 6 | Huntsman | Speed | Bow or crossbow equipped |
| 7 | Twirler | Agility | Thrown weapon equipped |
| 8 | Thaumaturge | Willpower | Stave (BluntTwoWide) equipped |
| 9 | Dualist | Speed | Dual Wielding off-hand event active |
| 10 | Fortifier | Strength | A shield is equipped (regardless of weapon) |
| 11 | Guisarmier | Endurance | Spear (SpearTwoWide) |
| 12 | Axeman | Strength | Axe (AxeOneHand or AxeTwoHand) |
| 13 | Zweihänder | Strength | Long-blade two-handed weapon (LongBladeTwoHand only) |
| 14 | Soloist | Endurance | Long-blade one-handed weapon (LongBladeOneHand only) |
| 15 | Thief | Speed | Short blade (ShortBladeOneHand) |
| 16 | Brawler | Strength | Fists up, no weapon equipped |

> **Blademeister sits above the weapon-type branches** so any of Felthorn's
> 180+ shapeshifted forms route to Blademeister regardless of which weapon
> type Felthorn has transformed into. A Felthorn-claymore wouldn't trigger
> Zweihänder; a Felthorn-shortsword wouldn't trigger Thief. Identity beats
> classification — the meister-and-weapon partnership is the stance.

> **Note on weapon coverage.** Each weapon-specific stance now keys off a
> specific weapon-type bucket: Guisarmier for spears, Axeman for axes,
> Zweihänder for long-blade 2H, Soloist for long-blade 1H, Thief for short
> blades. Weapons not covered above (one-handed blunts, two-handed blunts
> that aren't staves) fall through to Commoner unless a higher-priority
> branch claims them — Fortifier with a shield, Dualist with a second
> weapon, Reforger with the hammer.

## How leveling works

Two layers work together:

**Per-stance levels.** Each stance has its **own** XP bank and level (5 → 100),
saved in your character's data. Only the **active** stance earns XP — whatever
you're doing trains the stance you currently hold. Switch weapons and the
stance you were in is **banked exactly as it was**; the new stance picks up
from its own saved level. A stance's own level scales its **effectiveness**
(a smooth ramp from 100% at the start level to 150% at level 100), shown in
the tooltip.

**The core Stance skill.** The single skill Skill Framework displays. Whenever
the active stance gains XP, the core skill gains **half** of that amount and
levels **independently**. So each individual stance levels roughly twice as
fast as the core skill, and the core skill is a running measure of your
overall stance mastery that never resets when you switch.

**Perks come from the core skill.** A perk is active once your **core** Stance
skill reaches its threshold (25 / 50 / 75 / 100) — and that applies to *every*
stance at once. Reach core level 25 and every stance's level-25 perk unlocks;
the active stance just decides which ladder is shown.

> Example: fighting as Commoner grants Commoner 6 XP and the core skill 3 XP.
> Commoner's own level climbs quickly; the core skill climbs at half pace.
> When the core skill hits 25, the level-25 perk unlocks for Commoner — and for
> every other stance too.

### XP sources

| Source | Trains the active stance when... | Toggle |
|---|---|---|
| Successful weapon hit | in any stance | XP on Hit |
| Kill or knockout | in any stance | XP on Kill |
| Successful spell cast | in Arcanist | XP on Spell Cast |
| Successful N'Garde parry | in any stance (+ drip while Fortifier) | XP on Block |
| Time-in-stance tick (every 10s) | in any stance | XP on Time |
| Meditation tick (via Meditation Skill) | Arcanist | XP on Time |
| Successful merchant transaction | Commoner | XP on Merchant |
| Successful weapon/armor upgrade | Reforger | XP on Upgrade |
| Failed weapon/armor upgrade (smaller amount) | Reforger | XP on Upgrade |

Each XP amount is multiplied by the global **XP Multiplier** setting. The
active stance gets the full amount; the core skill gets half. Every source has
its own toggle under **Progression**, and XP is only credited to a stance
while it is the active stance and enabled in settings.

## Perks

Each stance has a 25/50/75/100 perk ladder keyed to the **core** Stance skill
level. An unlock popup fires when the core skill crosses a threshold while
that stance is active. Perks can be disabled per-stance or globally under
**Perks**.

Where a stance has an associated mod, the perks **reuse the source mod's
own perk catalog** so the two systems compound naturally:

- **Twirler** perks amplify Throwing!'s Critical / Twin Flight / Bleed / Paralyze
- **Thaumaturge** perks amplify Staves!'s Concussive Strike / Arcane Siphon / Resonant Conduit / Null Pulse
- **Huntsman** perks ride on Bullseye's headshot detection
- **Fortifier** perks widen N'Garde's parry window
- **Brawler** perks tie to Gothic Style Knockout's confirmed knockout
- **Arcanist** perks layer on Incantation's magicka refund and Meditation's regen
- **Reforger** perks are combat-themed, making the repair hammer a viable weapon: less fatigue drain (Anvil Arms), armor penetration (Weak-Point Strike), an armor-condition damage proc on hit (Sundering Blow), and a damage/stagger capstone (Forgemaster's Touch)
- **Blademeister** perks are Soul Eater themed — the meister-weapon pact growing across four stages. Soul Perception adds Sneak and Mysticism (Maka's signature ability), Soul Wavelength adds damage and a disrupt rider, Witch Hunter is a power-attack finisher (the technique that earned Soul his title), and Soul Resonance is the peak-partnership capstone

Stances without an associated mod (Zweihänder, Soloist, Dualist, Commoner,
Guisarmier, Axeman, Thief, Locksmith) have net-new perks themed for that
stance.

## HUD indicator

The HUD shows **only** the name of the currently active stance. No level,
no decoration — just the name in the corner of the screen.

**Draggable.** Open any vanilla menu (inventory, map, magic, stats) and
click-drag the indicator to any position on screen. The position is saved
automatically to player settings and clamps to the actual HUD layer size,
so very large stored values are safe across resolution changes. The X/Y
values in **Options → UI** are also editable directly — set them to 0 to
restore the default lower-left placement.

Lock the position from **Options → UI → Lock HUD Position** if you don't
want to drag accidentally.

## Settings

All settings live under **Options → Scripts → Stance!**, organized into 9
focused groups:

1. **General** — master toggle, skill registration, dynamic attribute swap,
   stance-change announcements.
2. **Stances** — 15 stance enable toggles, ordered by detection priority.
3. **Perks** — master perks toggle + 15 per-stance perk toggles (same order).
   Disabling a stance's perks suppresses its level-up notifications and
   hides the perk ladder from the tooltip; the stance still levels normally.
4. **Progression** — race / class bonuses, 8 per-source XP toggles
   (hit / kill / spell / block / time / merchant / upgrade), and a global
   XP multiplier (0–500%).
5. **Integrations** — 12 external-mod hookups grouped by category (Magic,
   Combat, Weapon style, Crafting, Sibling). Disabling an integration falls
   back to native detection where possible.
6. **HUD Indicator** — show toggle, lock toggle, text size, X / Y position.
   The HUD shows only the active stance's name and can be dragged in-game
   when any vanilla menu is open.
7. **Tooltip** — what appears inside the dynamic Stance-skill tooltip
   (mechanic details, perk ladder, unlocked-only filter, all-stances summary).
8. **Notifications** — perk-unlock popup style (Disabled / Popup / Message),
   position (5 named anchors), duration, and stack cap.
9. **Debug** — categorised logging (off by default).

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
- `stance reset` — reset every stance's own level/XP to the start (core skill
  is left untouched; use `stance set core <level>` for that)
- `stance reload` — flag the skill for re-registration on the next tick

Stance ids: `locksmith arcanist reforger blademeister huntsman twirler
thaumaturge dualist fortifier guisarmier axeman zweihander soloist thief
brawler commoner`.

## Architecture notes

Following Toxicology!'s scope split:

- `scripts/stance/settings.lua` — MENU scope. Registers all settings groups.
- `scripts/stance/init.lua` — PLAYER scope. Owns the active-stance resolver,
  per-stance XP/level state, the half-rate core-skill feed, the Skill
  Framework integration, the perk popup manager, the draggable HUD, the
  console commands, and every external-mod detection hook.
- `scripts/stance/global.lua` — GLOBAL scope. Mirrors player settings into
  the `Runtime_Stance` global storage section and forwards actor-death
  events back to the player as `Stance_KillGrant` for kill XP credit.
- `scripts/stance/config.lua` — pure data. Stance definitions, perk ladders,
  integration table, XP weights, UI defaults.

Persistent state lives in `storage.playerSection('Stance_StateV1')` under
one table keyed by stance id, so future migrations are straightforward
(bump the version suffix and write a migration in `onLoad`).

The mod is read-only against every external mod. It never writes to
Toxicology, Throwing!, Staves!, Bullseye, N'Garde, GRIP, Dual Wielding,
Gothic Style Knockout, Incantation, Meditation, Weapon Upgrade, or Armor
Upgrade state. All `Stance_*` events keep the namespace clear.
