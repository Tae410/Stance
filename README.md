# Stance!

A weapon-style progression mod for OpenMW. Every weapon you carry, every tool you use, every posture you hold is a stance — and every stance has its own level, its own perk ladder, and its own governing attribute. The more you fight with a short blade, the better you get at fighting with a short blade, independent of everything else.

Requires **OpenMW 0.49+** and **Skill Framework**.

---

## How It Works

Stance! registers a single skill entry in Skill Framework called **Stance**. That entry is a live window — it changes its name, its governing attribute, and its tooltip to reflect whatever stance you are currently holding. When you pick up a long blade, it becomes *Soloist*. When you holster your weapon and open a merchant window, it becomes *Commoner*. When you equip your repair hammer, it becomes *Reforger*.

There are **19 stances** in total. Each one has:

- Its own independent level and XP bank (5 to 100), stored per character and never lost when you switch.
- A **skill bonus** that increases additively as the stance levels — applied as a live modifier directly to the underlying weapon or tool skill. A Soloist at level 52 gives you roughly +11 Long Blade. At level 100, +20.
- A **perk ladder** of four perks, unlocked at core Stance skill levels 25, 50, 75, and 100.

The **core Stance skill** is separate. It levels at half the rate of any active stance, and it is the sole gatekeeper for perks — reach core level 25 and every stance's first perk becomes available at once, regardless of which stances you have or haven't used. The perks themselves only fire while the stance that owns them is active.

---

## Stances

Detection runs top-to-bottom. The first match wins. Stances earlier in the list take priority over stances below them.

| Priority | Stance | Triggers when... | Attribute | Skill Bonus |
|---|---|---|---|---|
| 1 | **Locksmith** | A lockpick or probe is in your inventory | Agility | Security |
| 2 | **Commoner** | Weapons sheathed, no tools — or final fallback | Luck | Speechcraft |
| 3 | **Arcanist** | Spellcasting stance is active | Intelligence | — |
| 4 | **Reforger** | The armorer's repair hammer is in your right hand | Endurance | Armorer |
| 5 | **Blademeister** | Any Felthorn weapon (sd_ prefix) is equipped | Agility | varies by form |
| 6 | **Angler** | A fishing pole is in your right hand | Luck | Fishing |
| 7 | **Huntsman** | A bow or crossbow is equipped | Speed | Marksman |
| 8 | **Twirler** | A thrown weapon is equipped | Agility | Throwing / Marksman |
| 9 | **Thaumaturge** | A stave (BluntTwoWide) is equipped | Willpower | Staves / Blunt Weapon |
| 10 | **Dualist** | Off-hand weapon is mounted (Dual Wielding) | Speed | varies by weapon |
| 11 | **Fortifier** | A shield is equipped | Strength | Block |
| 12 | **Guisarmier** | A spear is equipped | Endurance | Spear |
| 13 | **Pitmen** | The Miner's Pick specifically is equipped | Endurance | Mining / Axe |
| 14 | **Axeman** | Any axe (one- or two-handed) is equipped | Strength | Axe |
| 15 | **Mjolnir** | A mace, club, warhammer, or maul is equipped | Strength | Blunt Weapon |
| 16 | **Zweihänder** | A two-handed long blade is equipped | Strength | Long Blade |
| 17 | **Soloist** | A one-handed long blade is equipped, no shield | Endurance | Long Blade |
| 18 | **Thief** | A short blade is equipped | Speed | Short Blade |
| 19 | **Brawler** | Right hand is empty, weapon stance is raised | Strength | Hand to Hand |

For modded skills (Throwing, Staves, Fishing, Mining): the bonus routes to the modded skill when its parent mod is detected, and falls back to the vanilla equivalent when it is not.

For dynamic stances (Dualist, Blademeister): the bonus skill is resolved at runtime from the currently equipped weapon type, so it always goes to the right place.

---

## Skill Bonus

Each stance's own level determines an additive bonus applied to its target skill via a Skill Framework dynamic modifier. The ramp is linear from stance level 5 to level 100:

- **Level 5** → +2 points
- **Level 52** → approximately +11 points
- **Level 100** → +20 points

The bonus is live — it updates as your stance level changes and drops to zero the moment you leave the stance.

---

## Perks

Perks are gated on the **core Stance skill level**, not the individual stance level. Reach core level 25 and every stance's first perk is available. Reach 50, 75, and 100 and the remaining tiers open up.

All perk effects are active only while the stance that owns them is the current stance.

### Arcanist
| Core | Perk | Effect |
|---|---|---|
| 25 | Focused Chant | Spell costs reduced by five percent |
| 50 | Meditated Mind | Passive magicka regeneration (Meditation Skill) improved by a quarter |
| 75 | Incanted Focus | Custom-spell magicka refunds (Incantation) improved by ten percent |
| 100 | Aethereal Mind | Spell failure chance halved |

### Reforger
| Core | Perk | Effect |
|---|---|---|
| 25 | Anvil Arms | Fatigue from hammer swings reduced by fifteen percent |
| 50 | Weak-Point Strike | Hammer hits ignore ten percent of the target's armor |
| 75 | Sundering Blow | One in ten hits damages the target's worn armor condition |
| 100 | Forgemaster's Touch | Hammer damage +25%; power attacks have improved stagger chance |

### Blademeister
| Core | Perk | Effect |
|---|---|---|
| 25 | Soul Perception | +5 effective Sneak and +5 effective Mysticism while Felthorn is in hand |
| 50 | Soul Wavelength | +15% weapon damage; hits carry a chance to disrupt the target |
| 75 | Witch Hunter | Power attacks deal +30% damage and have a 15% chance to strike twice |
| 100 | Soul Resonance | +25% damage, +10% attack speed, ignores 10% of target armor |

### Huntsman
| Core | Perk | Effect |
|---|---|---|
| 25 | Steady Aim | Ranged attack fatigue drain reduced by fifteen percent |
| 50 | Pinning Shot | Ranged hits briefly slow the target |
| 75 | Concussive Shot | Bullseye headshots drain 25 fatigue from the target |
| 100 | Killshot | Ranged headshots deal twenty-five percent more damage |

### Twirler
| Core | Perk | Effect |
|---|---|---|
| 25 | Edged Spin | Throwing! critical chance +3% |
| 50 | Twinned Throw | Throwing! twin-flight chance +5% |
| 75 | Rending Hand | Throwing! bleed magnitude increased |
| 100 | Whirlwind Arm | Throwing! paralyze duration +1 second |

### Thaumaturge
| Core | Perk | Effect |
|---|---|---|
| 25 | Concussive Accord | Staves! concussive strike chance +10% |
| 50 | Siphoned Accord | Staves! arcane siphon chance +5% |
| 75 | Resonant Accord | Staves! resonant conduit chance +3% |
| 100 | Pulsed Accord | Staves! null pulse silence duration +2 seconds |

### Dualist
| Core | Perk | Effect |
|---|---|---|
| 25 | Light Footwork | +10% movement speed while dual-wielding |
| 50 | Mirror Edge | Off-hand strikes deal +15% damage |
| 75 | Twin Tempo | +15% attack speed while dual-wielding |
| 100 | Cross Guard | You parry and block as though a shield were held |

### Fortifier
| Core | Perk | Effect |
|---|---|---|
| 25 | Shield Up | Block effectiveness +10% |
| 50 | Warden Stance | N'Garde parry window widened by a quarter |
| 75 | Perfect Guard | N'Garde perfect-parry rebound +20% |
| 100 | Bulwark | Once per 30 seconds, one incoming blow is fully blocked |

### Zweihänder
| Core | Perk | Effect |
|---|---|---|
| 25 | Two-Hand Grip | Two-handed weapon damage +10% |
| 50 | Sweeping Arc | Attacks have a chance to also hit a second nearby enemy |
| 75 | Cleaving Blow | 10% chance to bypass a portion of the target's armor |
| 100 | Titan Grip | +25% two-handed damage; heavy weapon fatigue drain halved |

### Guisarmier
| Core | Perk | Effect |
|---|---|---|
| 25 | Reach Advantage | Spear damage +10% |
| 50 | Phalanx Brace | Knockdown resistance +25% |
| 75 | Pinning Thrust | Spear hits have a chance to briefly slow the target |
| 100 | Polearm Master | Spear damage +25%; spear attack fatigue drain -20% |

### Pitmen
| Core | Perk | Effect |
|---|---|---|
| 25 | Rough-Hewn | Miner's Pick damage in combat +10% |
| 50 | Vein Reader | Mining duration with the pick reduced by 20% |
| 75 | Prospector | Ore yield chance +15% |
| 100 | Pit Boss | Pick damage +25%; mining completes 30% faster |

### Angler
| Core | Perk | Effect |
|---|---|---|
| 25 | Steady Grip | Fatigue from fishing pole attacks -15% |
| 50 | Catch and Release | Successful casts have a 10% chance to yield a bonus fish |
| 75 | Trophy Cast | Fishing skill treated as 10 points higher for catch quality |
| 100 | Master Angler | Pole damage +25%; cast time reduced by 20% |

### Axeman
| Core | Perk | Effect |
|---|---|---|
| 25 | Cleaving Edge | Axe damage +10% |
| 50 | Heavy Chop | Axe power attacks +20% damage |
| 75 | Bleeding Cut | Axe hits cause a bleed — 1 health per second for 5 seconds |
| 100 | Headsman | Axe damage +25%; 10% chance to bypass a portion of armor |

### Mjolnir
| Core | Perk | Effect |
|---|---|---|
| 25 | Iron Heft | Blunt weapon damage +10% |
| 50 | Crushing Blow | Blunt power attacks +20% damage |
| 75 | Concussive Force | 10% chance to stagger the target |
| 100 | Thunderstrike | Blunt damage +25%; 10% chance to bypass a portion of armor |

### Soloist
| Core | Perk | Effect |
|---|---|---|
| 25 | Planted Feet | Knockdown resistance +25% |
| 50 | Heavy Hand | Power attacks +15% damage |
| 75 | Unstoppable | 10% chance to stagger the target |
| 100 | Solitary Will | Effective Endurance +15 |

### Thief
| Core | Perk | Effect |
|---|---|---|
| 25 | Quick Strike | Attack speed +10% with short blades |
| 50 | Cutpurse | Effective Sneak +5 |
| 75 | Backstab | Hits from behind deal +25% damage |
| 100 | Master Thief | Short blade damage +25%; movement speed +10% |

### Locksmith
| Core | Perk | Effect |
|---|---|---|
| 25 | Light Fingers | Effective Security +5 |
| 50 | Probe Sage | Probes are 10% less likely to break |
| 75 | Sneak Step | Effective Sneak +5 |
| 100 | Master of Locks | Lock difficulty treated as 15 points lower |

### Brawler
| Core | Perk | Effect |
|---|---|---|
| 25 | Iron Grip | Hand-to-hand damage +15% |
| 50 | Close-Range Fighter | Unarmed attack fatigue drain -25% |
| 75 | Concussive Jab | Improved chance for unarmed hits to knock the target down |
| 100 | Street Master | Successful unarmed hits briefly restore fatigue |

### Commoner
| Core | Perk | Effect |
|---|---|---|
| 25 | Merchant's Eye | Mercantile checks gain a Luck-based bonus |
| 50 | Silver Tongue | Speechcraft effectiveness +10% |
| 75 | Urban Charm | Disposition gains from successful Admire improved |
| 100 | The People's Hero | Better barter prices; faster disposition recovery |

---

## XP Sources

Only the **active stance** earns XP. The core Stance skill earns half that amount simultaneously, passively.

| Source | XP | Notes |
|---|---|---|
| Landing a hit | 1.0 | Any weapon or fist |
| Killing an enemy | 2.0 | Forwarded by the global script |
| Casting a spell | 0.8 | Arcanist only |
| Blocking successfully | 1.2 | Fortifier benefits most |
| Time in stance | 0.1 | Per 10 seconds |
| Meditation tick | 0.4 | Arcanist + Meditation Skill |
| Merchant transaction | 1.5 | Commoner benefits most |
| Successful upgrade | 4.0 | Reforger + WeaponUpgrade / ArmorUpgrade |
| Failed upgrade | 0.5 | A lesson learned |
| Successful ore mine | 3.0 | Pitmen + Simply Mining |
| Successful fish catch | 3.0 | Angler + Fishing |

A global **XP multiplier** (0–500%) scales all sources uniformly. It is in the Progression settings group and defaults to 100%.

---

## Progression

The XP required to level up follows a compound curve:

- **Base cost** at level 5: 8 XP
- Each subsequent level costs **6% more** than the last
- **Hard cap** at 400 XP per level

This means early levels come quickly — a short skirmish can push a fresh stance from 5 to 10 — while the final stretch from 90 to 100 requires sustained, deliberate use.

**Race bonuses** give +5 to the Stance skill at character creation for all supported races, including vanilla races and several Tamriel Rebuilt additions (Naga, Ynesai, Reachman, Sea Elf). Can be disabled.

**Class specialization bonus** gives a flat +10 to the Stance skill for characters whose class specializes in Combat. Can be disabled.

---

## Integrations

All integrations are optional. Each one can be individually disabled from the Integrations settings group. Stance! detects these mods at runtime and degrades gracefully when they are absent — it never requires them.

| Mod | What it adds |
|---|---|
| **Skill Framework** | Required. Hosts the Stance skill entry and provides the dynamic modifier API for skill bonuses. |
| **Throwing!** | Enables the Twirler stance and routes the skill bonus to the Throwing skill. Twirler perks amplify Throwing!'s own critical, twin-flight, bleed, and paralyze systems. |
| **Staves!** | Enables the Thaumaturge stance and routes the skill bonus to the Staves skill. Thaumaturge perks amplify Staves!'s concussive strike, arcane siphon, resonant conduit, and null pulse. |
| **Bullseye** | Enables Huntsman perks that interact with headshots. Huntsman still works without it; the headshot perks simply do nothing. |
| **N'Garde** | Enables Fortifier perks that widen the parry window and amplify perfect-parry rebound. Fortifier still works and gives its block bonus without N'Garde. |
| **Dual Wielding** | Enables the Dualist stance. Stance! listens for the mod's equip/remove events and reads the off-hand weapon type to route the skill bonus correctly. |
| **Gothic Style Knockout** | Enables the Brawler's Concussive Jab perk, which improves the mod's non-lethal knockdown chance. |
| **WeaponUpgrade / ArmorUpgrade** | Enables Reforger XP on successful and failed upgrade attempts. |
| **GRIP** | Detected via its GRIPRecords global storage section. Tells the resolver not to rely on weapon type for stance detection, since GRIP can change the effective weapon in hand. |
| **Blademeister** | Enables the Blademeister stance by detecting weapons with the `sd_` record prefix (all 180+ Felthorn forms). |
| **Simply Mining** | Enables Pitmen XP on ore mines and gates the Vein Reader, Prospector, and Pit Boss perks. |
| **Fishing** | Enables Angler XP on fish catches and gates the Catch and Release, Trophy Cast, and Master Angler perks. |
| **Incantation** | Enables the Arcanist's Incanted Focus perk. |
| **Meditation Skill** | Enables the Arcanist's Meditated Mind perk. |
| **Toxicology!** | Detected as a sibling mod. Stance! reads its runtime storage section for coordination; no Stance! perks depend on it directly. |

---

## Settings

The settings menu has nine groups.

**General**
Master enable switch, Skill Framework registration toggle, attribute-swap toggle (turns off the governing attribute changing when you switch stances), and stance change announcements.

**Stances**
Individual on/off for all 19 stances. Disabling a stance removes it from detection entirely — the resolver skips it and falls through to the next candidate.

**Perks**
Master perk toggle and individual perk toggles per stance. Useful for running the skill bonus system without any perk effects.

**Progression**
Race bonus toggle, class specialization bonus toggle, individual toggles for every XP source (hits, kills, spells, blocks, time, merchant transactions, upgrades, mining, fishing), and the global XP multiplier slider (0–500%).

**Integrations**
Individual enable toggles for all 15 supported mods. A disabled integration is ignored at detection time even if the mod is installed and loaded.

**HUD Indicator**
Show or hide the on-screen stance name label. Drag it into position while any menu is open. Lock position toggle. Icon size (8–96 px).

**Tooltip**
Toggle mechanic information (level, core, attribute, skill bonus, XP progress) and perk listings independently. Option to show only unlocked perks.

**Notifications**
Perk-unlocked popup style: Disabled, Popup, or Message. Position (Top Left, Top Center, Center, Bottom Left, Bottom Center). Duration (0.5–10 seconds). Maximum visible popups at once (1–10).

**Debug**
Master debug toggle (must be on for any category to fire) with individual category toggles: general, detection, XP, perks, integrations, and UI.

---

## Console Commands

Type `stance` in the OpenMW console.

| Command | Effect |
|---|---|
| `stance list` | Print all stances with their current level, skill bonus, target skill, and enabled state. Also shows the active stance and core skill level. |
| `stance active` | Print the active stance's full details: stance level, core level, skill bonus, target skill, governing attribute, and next perk. |
| `stance set <id> <level>` | Set a specific stance's level directly. Example: `stance set soloist 75` |
| `stance set core <level>` | Set the core Stance skill level directly. |
| `stance reset` | Reset all stance levels to start (5). Core skill level is unchanged. |
| `stance reload` | Flag the skill for re-registration on the next poll tick. Useful after changing settings mid-session. |
| `stance help` | Print the command list. |

Stance IDs for use in console commands: `arcanist`, `reforger`, `blademeister`, `huntsman`, `twirler`, `thaumaturge`, `dualist`, `fortifier`, `zweihander`, `guisarmier`, `pitmen`, `axeman`, `mjolnir`, `soloist`, `thief`, `angler`, `brawler`, `locksmith`, `commoner`.

---

## Script Interface

Other mods can query Stance! at runtime via `I.Stance`.

```lua
local I = require('openmw.interfaces')

I.Stance.getActiveStance()         -- returns the active stance id string, or nil
I.Stance.getStanceLevel(id)        -- level of the named stance (or active if nil)
I.Stance.getCoreLevel()            -- the shared core Stance skill level
I.Stance.getSkillBonus(id)         -- the additive skill-point bonus for the named stance
I.Stance.getTargetSkill(id)        -- the SF skill id the bonus is applied to
I.Stance.isPerkUnlocked(id, level) -- true if core level >= the perk threshold
```

`getEffectiveness(id)` is also available as a backwards-compatible alias for `getSkillBonus`. It now returns additive skill points rather than the old multiplier value.

---

## File Structure

```
scripts/stance/
├── init.lua      — player script: detection, XP, perks, HUD, console commands
├── global.lua    — global script: kill forwarding, settings mirror, event relay
├── config.lua    — all numerical values, stance definitions, perk ladders, integrations
└── settings.lua  — OpenMW settings page registration (nine groups)
```

---

## Compatibility Notes

Stance! is read-only with respect to every mod it integrates with. It listens to public events and reads public storage sections; it never writes to another mod's state.

The GRIP integration prevents false stance detection when GRIP converts a weapon's effective type at runtime, since the converted record may not match the raw weapon type in hand.

The Blademeister integration uses a record-id prefix scan (`sd_`) rather than a settings section or Skill Framework skill, because the mod registers neither. The prefix is unique in the base game and vanilla mods; if a mod in your load order also uses `sd_` weapon record ids, Blademeister stance may fire unexpectedly.

If your version of the Fishing mod fires a different catch event name than `Fishing_playerCaughtFish`, add an alias in `init.lua`'s `eventHandlers` table pointing to the same handler.

Safe to add to an existing save. Safe to remove — the Skill Framework entry will simply be absent on next load.
