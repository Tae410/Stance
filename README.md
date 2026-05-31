# Stance!

**A weapon-style progression mod for OpenMW.** In vanilla Morrowind your combat skills are tied to abstract categories — Long Blade, Marksman, Block. Stance! reframes that around what you're *actually doing in the moment*. Whatever you have in your hands, whatever posture you're holding, is a **stance**: drawing a longsword makes you a *Soloist*, raising a shield makes you a *Fortifier*, holstering everything and haggling with a merchant makes you a *Commoner*. Each stance levels on its own, has its own four-rung perk ladder, and quietly boosts the skill it's built around.

The result is that your character grows in the directions you play. Fight with short blades and you get better at fighting with short blades — separately from, and on top of, your vanilla skill progression.

> **Requires OpenMW 0.49+ and the Skill Framework mod.** Everything else is optional.

---

## The Big Idea

Stance! adds **one** new skill to your character sheet — called **Stance** — through Skill Framework. But that single entry is a chameleon: its name, its governing attribute, and its tooltip all change in real time to match whatever stance you're currently holding. Pick up a bow and the skill reads *Huntsman* (governed by Speed); equip a mace and it becomes *Mjolnir* (Strength).

Behind that one visible entry, the mod tracks **19 separate stances**, each with:

- **Its own level and XP**, from 5 to 100, saved per character. Switching stances never costs you progress — your Soloist level sits untouched while you spend an afternoon as a Thief.
- **A live skill bonus** that grows with the stance's level and is applied directly to the underlying weapon/tool skill. A level-52 Soloist is wielding Long Blade at roughly +11; a maxed one at +20. Leave the stance and the bonus instantly drops to zero.
- **A perk ladder** of four perks that unlock as your *core* Stance skill rises.

### Two levels working together

There's a distinction worth understanding:

- **Each stance's own level** drives its skill bonus and earns from use.
- **The core Stance skill** is a single shared level that rises at half the rate of whatever stance you're actively using. It's the gatekeeper for *perks* — when your core skill hits 25, the first perk of **every** stance unlocks at once, whether you've ever used that stance or not. Core 50, 75, and 100 open the higher tiers.

Perks only take effect while their owning stance is the active one, so unlocking them all at core 25 doesn't flood you with effects — it just means each stance is ready to reward you the moment you adopt it.

---

## How a Stance Gets Chosen

Every game tick, Stance! looks at your equipment and posture and runs down a fixed priority list. The **first match wins**. That ordering is what lets specific cases beat general ones — a Miner's Pick is recognized as *Pitmen* before the generic "it's an axe" *Axeman* rule can claim it.

| # | Stance | Active when… | Attribute | Skill it boosts |
|---|---|---|---|---|
| 1 | **Locksmith** | a lockpick or probe is readied in your right hand | Agility | Security |
| 2 | **Commoner** | weapons sheathed and no tool out — also the final fallback | Luck | Speechcraft |
| 3 | **Arcanist** | spellcasting stance is up | Intelligence | — |
| 4 | **Reforger** | the armorer's repair hammer is in hand | Endurance | Armorer |
| 5 | **Blademeister** | a Felthorn weapon (record id `sd_…`) is equipped | Agility | varies by form |
| 6 | **Angler** | a fishing pole is in hand | Luck | Fishing |
| 7 | **Huntsman** | a bow or crossbow is equipped | Speed | Marksman |
| 8 | **Twirler** | a thrown weapon is equipped | Agility | Throwing |
| 9 | **Thaumaturge** | a stave is equipped | Willpower | Staves / Blunt Weapon |
| 10 | **Dualist** | an off-hand weapon is mounted (Dual Wielding) | Speed | varies by weapon |
| 11 | **Fortifier** | a shield is equipped | Strength | Block |
| 12 | **Guisarmier** | a spear is equipped | Endurance | Spear |
| 13 | **Pitmen** | the Miner's Pick specifically is equipped | Endurance | Mining / Axe |
| 14 | **Axeman** | any axe (one- or two-handed) is equipped | Strength | Axe |
| 15 | **Mjolnir** | a mace, club, warhammer, or maul is equipped | Strength | Blunt Weapon |
| 16 | **Zweihänder** | a two-handed long blade is equipped | Strength | Long Blade |
| 17 | **Soloist** | a one-handed long blade, no shield | Endurance | Long Blade |
| 18 | **Thief** | a short blade is equipped | Speed | Short Blade |
| 19 | **Brawler** | weapon stance raised with an empty right hand | Strength | Hand to Hand |

For stances tied to other mods' skills (Twirler → Throwing, Thaumaturge → Staves, Angler → Fishing, Pitmen → Mining), the bonus is routed to that mod's skill when it's installed, and falls back to the closest vanilla skill otherwise. For stances whose weapon can vary (Dualist, Blademeister), the target skill is resolved from whatever is actually in hand at that moment.

---

## The Skill Bonus

A stance's own level sets an additive bonus on its target skill. The ramp is linear from level 5 to level 100:

| Stance level | Bonus |
|---|---|
| 5 | +2 |
| ~52 | ~+11 |
| 100 | +20 |

This bonus is applied as a live modifier and updated continuously, so it tracks your stance level and vanishes the instant you switch away. For vanilla skills the bonus is written straight to the engine's native skill modifier; for modded Skill Framework skills it's delivered through Skill Framework's own dynamic-modifier system. Either way it stacks cleanly alongside Fortify/Drain effects and other mods, because Stance! only ever adjusts its own contribution.

---

## Perks

There are four perks per stance — 76 in total — each unlocking at core Stance skill **25 / 50 / 75 / 100** and active only while that stance is the current one.

<details>
<summary><strong>Combat stances</strong></summary>

### Soloist (one-handed long blade)
| Core | Perk | Effect |
|---|---|---|
| 25 | Planted Feet | Knockdown resistance +25% |
| 50 | Heavy Hand | Power attacks +15% damage |
| 75 | Unstoppable | 10% chance to stagger the target |
| 100 | Solitary Will | Effective Endurance +15 |

### Zweihänder (two-handed long blade)
| Core | Perk | Effect |
|---|---|---|
| 25 | Two-Hand Grip | Two-handed damage +10% |
| 50 | Sweeping Arc | Chance to also hit a second nearby enemy |
| 75 | Cleaving Blow | 10% chance to bypass part of the target's armor |
| 100 | Titan Grip | +25% two-handed damage; heavy-weapon fatigue drain halved |

### Thief (short blade)
| Core | Perk | Effect |
|---|---|---|
| 25 | Quick Strike | +10% attack speed with short blades |
| 50 | Cutpurse | Effective Sneak +5 |
| 75 | Backstab | Hits from behind deal +25% damage |
| 100 | Master Thief | +25% short-blade damage; +10% movement speed |

### Axeman (axes)
| Core | Perk | Effect |
|---|---|---|
| 25 | Cleaving Edge | Axe damage +10% |
| 50 | Heavy Chop | Axe power attacks +20% damage |
| 75 | Bleeding Cut | Hits cause a bleed (1 HP/sec for 5 sec) |
| 100 | Headsman | +25% axe damage; 10% armor bypass chance |

### Mjolnir (blunt weapons)
| Core | Perk | Effect |
|---|---|---|
| 25 | Iron Heft | Blunt damage +10% |
| 50 | Crushing Blow | Blunt power attacks +20% damage |
| 75 | Concussive Force | 10% stagger chance |
| 100 | Thunderstrike | +25% blunt damage; 10% armor bypass chance |

### Guisarmier (spears)
| Core | Perk | Effect |
|---|---|---|
| 25 | Reach Advantage | Spear damage +10% |
| 50 | Phalanx Brace | Knockdown resistance +25% |
| 75 | Pinning Thrust | Chance to briefly slow the target |
| 100 | Polearm Master | +25% spear damage; −20% spear fatigue drain |

### Huntsman (bows & crossbows)
| Core | Perk | Effect |
|---|---|---|
| 25 | Steady Aim | Ranged fatigue drain −15% |
| 50 | Pinning Shot | Ranged hits briefly slow the target |
| 75 | Concussive Shot | Headshots drain 25 fatigue from the target |
| 100 | Killshot | Headshots deal +25% damage |

### Fortifier (shields)
| Core | Perk | Effect |
|---|---|---|
| 25 | Shield Up | Block effectiveness +10% |
| 50 | Warden Stance | Widens N'Garde's parry window |
| 75 | Perfect Guard | Boosts N'Garde's perfect-parry rebound |
| 100 | Bulwark | Once per 30 sec, fully blocks one incoming blow |

### Brawler (unarmed)
| Core | Perk | Effect |
|---|---|---|
| 25 | Iron Grip | Hand-to-hand damage +15% |
| 50 | Close-Range Fighter | Unarmed fatigue drain −25% |
| 75 | Concussive Jab | Improved unarmed knockdown chance |
| 100 | Street Master | Unarmed hits briefly restore fatigue |

### Dualist (dual wielding)
| Core | Perk | Effect |
|---|---|---|
| 25 | Light Footwork | +10% movement speed while dual-wielding |
| 50 | Mirror Edge | Off-hand strikes +15% damage |
| 75 | Twin Tempo | +15% attack speed while dual-wielding |
| 100 | Cross Guard | Parry and block as if a shield were held |

</details>

<details>
<summary><strong>Magic, tool & modded-skill stances</strong></summary>

### Arcanist (spellcasting)
| Core | Perk | Effect |
|---|---|---|
| 25 | Focused Chant | Spell costs −5% |
| 50 | Meditated Mind | +25% passive magicka regen (Meditation Skill) |
| 75 | Incanted Focus | +10% custom-spell magicka refunds (Incantation) |
| 100 | Aethereal Mind | Spell failure chance halved |

### Blademeister (Felthorn weapons)
| Core | Perk | Effect |
|---|---|---|
| 25 | Soul Perception | +5 effective Sneak and Mysticism while in hand |
| 50 | Soul Wavelength | +15% weapon damage; chance to disrupt the target |
| 75 | Witch Hunter | Power attacks +30% damage, 15% chance to strike twice |
| 100 | Soul Resonance | +25% damage, +10% attack speed, 10% armor bypass |

### Twirler (thrown weapons — needs Throwing!)
| Core | Perk | Effect |
|---|---|---|
| 25 | Edged Spin | Throwing! critical chance +3% |
| 50 | Twinned Throw | Throwing! twin-flight chance +5% |
| 75 | Rending Hand | Throwing! bleed magnitude increased |
| 100 | Whirlwind Arm | Throwing! paralyze duration +1 sec |

### Thaumaturge (staves — best with Staves!)
| Core | Perk | Effect |
|---|---|---|
| 25 | Concussive Accord | Staves! concussive-strike chance +10% |
| 50 | Siphoned Accord | Staves! arcane-siphon chance +5% |
| 75 | Resonant Accord | Staves! resonant-conduit chance +3% |
| 100 | Pulsed Accord | Staves! null-pulse silence +2 sec |

### Reforger (repair hammer)
| Core | Perk | Effect |
|---|---|---|
| 25 | Anvil Arms | Hammer-swing fatigue −15% |
| 50 | Weak-Point Strike | Hammer hits ignore 10% of armor |
| 75 | Sundering Blow | 1-in-10 hits damages worn armor condition |
| 100 | Forgemaster's Touch | +25% hammer damage; better power-attack stagger |

### Pitmen (Miner's Pick — best with Simply Mining)
| Core | Perk | Effect |
|---|---|---|
| 25 | Rough-Hewn | +10% pick damage in combat |
| 50 | Vein Reader | −20% mining duration |
| 75 | Prospector | +15% ore yield chance |
| 100 | Pit Boss | +25% pick damage; mining 30% faster |

### Angler (fishing pole — best with Fishing)
| Core | Perk | Effect |
|---|---|---|
| 25 | Steady Grip | Fishing-pole attack fatigue −15% |
| 50 | Catch and Release | 10% chance of a bonus fish per cast |
| 75 | Trophy Cast | Fishing treated as +10 for catch quality |
| 100 | Master Angler | +25% pole damage; cast time −20% |

### Locksmith (lockpick / probe)
| Core | Perk | Effect |
|---|---|---|
| 25 | Light Fingers | Effective Security +5 |
| 50 | Probe Sage | Probes 10% less likely to break |
| 75 | Sneak Step | Effective Sneak +5 |
| 100 | Master of Locks | Lock difficulty treated as 15 lower |

### Commoner (unarmed, social fallback)
| Core | Perk | Effect |
|---|---|---|
| 25 | Merchant's Eye | Luck-based bonus to Mercantile checks |
| 50 | Silver Tongue | Speechcraft effectiveness +10% |
| 75 | Urban Charm | Better disposition gains from Admire |
| 100 | The People's Hero | Better barter prices; faster disposition recovery |

</details>

---

## Earning XP

Only the **active stance** earns XP, and the **core skill** earns half of that amount at the same time. Every source can be toggled on or off individually.

| Source | XP | Notes |
|---|---|---|
| Landing a hit | 1.0 | any weapon or fist |
| Killing an enemy | 2.0 | credited to the killer specifically |
| Casting a spell | 0.8 | Arcanist |
| Blocking successfully | 1.2 | Fortifier |
| Holding a stance | 0.1 | per 10 seconds |
| Meditation tick | 0.4 | Arcanist + Meditation Skill |
| Merchant transaction | 1.5 | Commoner |
| Successful repair/upgrade | 4.0 | Reforger + WeaponUpgrade/ArmorUpgrade |
| Failed upgrade | 0.5 | a lesson learned |
| Mining ore | 3.0 | Pitmen + Simply Mining |
| Catching a fish | 3.0 | Angler + Fishing |

A single **XP multiplier** (0–500%, default 100%) scales every source at once.

### Leveling curve

Levels cost more as you climb: **8 XP** at level 5, **+6%** per level after, capped at **400 XP** per level. Early levels fly by — a skirmish can carry a fresh stance from 5 to 10 — while the final push from 90 to 100 takes real, sustained use.

**Starting bonuses** (both optional): +5 to the Stance skill at character creation for supported races (vanilla plus several Tamriel Rebuilt additions), and +10 for characters whose class specializes in Combat.

---

## Optional Integrations

Stance! detects supported mods at runtime and works fine without any of them — missing integrations simply leave the relevant perks or XP sources inert. Each can also be toggled off manually.

| Mod | What it unlocks |
|---|---|
| **Skill Framework** | *Required.* Hosts the Stance skill entry and the modded-skill bonus path. |
| **Throwing!** | The Twirler stance; routes its bonus to the Throwing skill and powers the Twirler perks. |
| **Staves!** | The Thaumaturge stance; routes its bonus to Staves and powers the Thaumaturge perks. |
| **Dual Wielding** | The Dualist stance; reads the off-hand weapon to target the right skill. |
| **Blademeister** | The Blademeister stance, detected via the `sd_` weapon-record prefix. |
| **GRIP** | Keeps stance detection correct when GRIP converts a weapon's effective type in hand. |
| **Bullseye** | Huntsman's headshot perks. |
| **N'Garde** | Fortifier's parry-window and rebound perks. |
| **Gothic Style Knockout** | Brawler's Concussive Jab knockdown. |
| **WeaponUpgrade / ArmorUpgrade** | Reforger XP on repair/upgrade attempts. |
| **Simply Mining** | Pitmen XP and its higher perks. |
| **Fishing** | Angler XP and its higher perks. |
| **Incantation** | Arcanist's Incanted Focus. |
| **Meditation Skill** | Arcanist's Meditated Mind. |
| **Toxicology!** | Detected for coordination; no perks depend on it directly. |

---

## Settings

The settings page (under OpenMW's mod settings menu) has ten groups:

- **General** — master on/off, Skill Framework registration, attribute-swap toggle (stops the governing attribute from changing per stance), stance-change announcements.
- **Stances** — individual on/off for all 19 stances; a disabled stance is skipped during detection.
- **Perks** — master perk toggle plus a toggle per stance (run pure skill bonuses with no perk effects if you like).
- **Progression** — race and class bonuses, a toggle for every XP source, and the global XP multiplier.
- **Integrations** — an enable switch for each of the 15 supported mods.
- **HUD Indicator** — show/hide and reposition the on-screen stance label; lock toggle; icon size.
- **Tooltip** — toggle the mechanic readout and the perk list separately; option to show only unlocked perks.
- **Notifications** — perk-unlock popup style, screen position, duration, and max simultaneous popups.
- **Debug** — a master debug switch plus per-category logging (detection, XP, perks, integrations, UI).

---

## Console Commands

Type these in the OpenMW console (prefixed with `stance`):

| Command | Effect |
|---|---|
| `stance list` | List every stance with its level, bonus, target skill, and enabled state. |
| `stance active` | Full detail on the current stance. |
| `stance set <id> <level>` | Set one stance's level — e.g. `stance set soloist 75`. |
| `stance set core <level>` | Set the core Stance skill level. |
| `stance reset` | Reset all stance levels to 5 (core skill unchanged). |
| `stance reload` | Re-register the skill on the next tick (handy after changing settings). |
| `stance help` | Print the command list. |

Valid stance ids: `arcanist`, `reforger`, `blademeister`, `huntsman`, `twirler`, `thaumaturge`, `dualist`, `fortifier`, `zweihander`, `guisarmier`, `pitmen`, `axeman`, `mjolnir`, `soloist`, `thief`, `angler`, `brawler`, `locksmith`, `commoner`.

---

## For Modders — Script Interface

Other mods can query Stance! at runtime through `I.Stance`:

```lua
local I = require('openmw.interfaces')

I.Stance.getActiveStance()         -- active stance id string, or nil
I.Stance.getStanceLevel(id)        -- level of a stance (active stance if id is nil)
I.Stance.getCoreLevel()            -- the shared core Stance skill level
I.Stance.getSkillBonus(id)         -- additive skill-point bonus for a stance
I.Stance.getTargetSkill(id)        -- the skill id the bonus is applied to
I.Stance.isPerkUnlocked(id, level) -- true if core level >= the perk threshold
```

`getEffectiveness(id)` remains as a backwards-compatible alias for `getSkillBonus`; it returns additive skill points, not the old multiplier.

---

## How It's Built

```
scripts/stance/
├── init.lua                 — player script: detection, resolver, console, event wiring
├── global.lua               — global script: validated-kill relay, settings mirror
├── victim.lua               — runs on NPCs/creatures: reports player-dealt hits and kills
├── perks.lua                — perk logic, attribute/skill contributions, on-hit effects
├── config.lua               — all numbers: stance defs, perk ladders, integration specs
├── settings.lua             — settings-page registration (ten groups)
└── player/
    ├── skill_framework.lua   — Stance-skill registration, effectiveness bonuses
    ├── xp.lua                — XP banking and core-skill feed
    ├── hud.lua               — on-screen stance indicator
    ├── grip.lua              — GRIP weapon-conversion lookups
    ├── console.lua           — console command handling
    └── stat_access.lua       — native attribute/skill/dynamic stat accessors
```

A small companion script attached to NPCs and creatures (`victim.lua`) is what makes combat-hit and kill XP reliable: combat-hit events fire on the *victim* in OpenMW, so the victim's script reports back to the player when you land a blow or score a kill, with the kill credited only when you were actually the one who dealt the fatal hit.

---

## Compatibility

- **Read-only toward other mods.** Stance! listens to public events and reads public storage; it never writes another mod's state. Where it must share a vanilla skill with another mod (e.g. Throwing! also manages Marksman), it yields ownership so the two don't fight.
- **Safe to add mid-playthrough**, and safe to remove — the Skill Framework entry just won't be there next load.
- **GRIP:** stance detection accounts for GRIP converting a weapon's effective type at runtime.
- **Blademeister** is detected by the `sd_` record-id prefix; if another mod in your load order uses that prefix for weapons, Blademeister may trigger on them.
- **Fishing:** if your Fishing version emits a catch event other than `Fishing_playerCaughtFish`, add an alias for it in `init.lua`'s `eventHandlers` table.
