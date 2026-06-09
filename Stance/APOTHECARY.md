# Apothecary — Thrown Concoctions integration

A weapon stance, **Apothecary**, that integrates the
[Thrown Concoctions](https://www.nexusmods.com/morrowind/mods/56984) mod, in the
same style as the existing Angler (Fishing), Pitmen (Simply Mining), and
Locksmith (Oblivion-Style Lockpicking) integrations.

> **Note on lineage.** This stance previously integrated *Potion Thrower*, which
> drove everything through its own `PotionArmed` / `PotionThrower_potionHit` /
> `SkillUp` events. Thrown Concoctions is a pure-content `.esp` — it adds 17
> throwable "concoction" weapons (each with a cast-when-strikes enchantment), a
> storage container, and leveled lists, and ships **no Lua, scripts, globals,
> settings group, or events**. The integration was therefore rebuilt around the
> equipped concoction weapon and Stance's own combat bridge, which is both
> simpler and more robust (see "Hit detection" below).

## Behaviour

| Aspect | Detail |
| --- | --- |
| **Active when** | A Thrown Concoction is equipped in the right hand. The concoctions are `MarksmanThrown` weapons, so they are detected by **record id** (matched against the fixed set of 17 concoction ids) rather than by weapon type — this keeps the generic Twirler thrown-weapon stance from claiming them. Detection mirrors Angler (fishing poles) and Pitmen (the miner's pick). |
| **Governing attribute** | Intelligence (the alchemist's wit). |
| **Effectiveness bonus** | Boosts **Alchemy** — the level-scaled `+2…+20` modifier is applied to the vanilla Alchemy skill as a temporary, delta-accounted stat modifier (not real Alchemy progress, so it never collides with the player's actual Alchemy training). The *throwing* side of a concoction is Twirler's domain; Apothecary is about the craft. |
| **Gains XP when** | A thrown concoction **lands on an enemy**. A landed concoction is an ordinary engine hit, so this is credited through Stance's normal combat path. Worth `2.5` XP before the global multiplier (`config.xp.concoctionThrowHit`) — more than a plain melee hit, because every throw expends a concoction, so they are thrown far less often than a reusable weapon is swung. |

### Perks (core-level gated, like every other stance)

| Level | Perk | Effect |
| --- | --- | --- |
| 25 | **Deft Hurler** | Passive **+5 Agility** (a thrown concoction is a `MarksmanThrown` weapon, and Agility feeds the engine's hit-chance roll, so this also makes you land more concoctions). |
| 50 | **Volatile Concoction** | On a landed concoction, 25% chance to drain **15 fatigue** (stagger). |
| 75 | **Corrosive Cloud** | Every landed concoction leaves a 5-second **1 pt/s Damage Health** caustic DoT. |
| 100 | **Master Apothecary** | Passive **+5 Intelligence and +5 Luck**; on a landed concoction, 10% chance of a brief **Paralyze**. |

The passive bonuses (25 Agility, 100 Int/Luck) always apply. The on-hit effects
(50/75/100) need to know *which actor* was struck — which the combat bridge
always supplies (see below), so unlike the old Potion Thrower integration they
require no optional patch and always fire.

## Hit detection — no events required

The previous Potion Thrower integration had to reconcile two different,
optional event signals to learn that a potion had landed (and the on-hit perk
effects only worked if a dedicated patch was installed to carry the struck
target). None of that is needed here.

A Thrown Concoction is a `MarksmanThrown` weapon, so when the player throws one
and it strikes an actor, the hit is resolved by the engine exactly like an
arrow, a bolt, or a steel throwing star. That hit is already observed by
Stance's victim-side combat bridge:

* `scripts/stance/victim.lua` is attached to every NPC and creature and
  registers `I.Combat.addOnHitHandler`. When the attacker is the player it
  forwards `Stance_PlayerDealtHit { target, weapon, … }` to the player script.
* `scripts/stance/init.lua`'s `onPlayerDealtHit` credits hit XP to the active
  stance and dispatches `Perks.onHit`.

The same path that earns Twirler and Huntsman their hit XP earns Apothecary
its concoction XP. When Apothecary is the active stance, `onPlayerDealtHit`
grants the dedicated `concoctionThrowHit` weight (under the `concoction` XP
source) in place of the standard `combatHit` weight, then `Perks.onHit` runs
the Apothecary on-hit effects (stagger / caustic cloud / paralysis), gated on a
ranged hit and on the perk toggle. Because the bridge always carries the struck
`target`, those effects always have an actor to apply to.

Apothecary is only ever active with a Thrown Concoction equipped, and a thrown
weapon is thrown rather than swung, so every hit credited to Apothecary is
necessarily a landed concoction throw.

## Presence detection

Thrown Concoctions exposes no Skill Framework skill, global storage section,
settings group, or event, so the usual probes don't apply. Presence is detected
by the **existence of a concoction weapon record** — the sentinel
`concoction_base` (the un-enchanted template flask, always present when the
plugin is loaded). This is a new `weaponRecordId` probe in
`detectIntegration`, an O(1) keyed lookup in `types.Weapon.records`.

## Integration toggle behaviour

Unlike Angler/Pitmen — whose integration toggle only governs their event-fed
XP — Thrown Concoctions has no separate event behaviour, so its toggle governs
the **stance selection** itself. The resolver's Apothecary branch is gated on
`integrationEnabled('thrownconcoctions')`:

* **Integration ON** (default) → equipping a concoction activates Apothecary.
* **Integration OFF**, or the Apothecary stance disabled → concoctions fall
  through to the generic **Twirler** thrown-weapon stance.

## New settings (all default ON)

* **Stances → Enable Apothecary** (`enableApothecary`)
* **Perks → Apothecary Perks** (`enableApothecaryPerks`)
* **Progression → XP from Concoction Throws** (`xpOnConcoctionHit`)
* **Integrations → Thrown Concoctions** (`integrateThrownConcoctions`)

## Files touched

`scripts/stance/config.lua` (stance definition, perks, `xp.concoctionThrowHit`,
`integrations.thrownconcoctions`), `scripts/stance/init.lua` (integration
setting key, `weaponRecordId` presence probe, `APOTHECARY_RECORD_IDS` +
`isApothecaryWeapon`, the resolver branch above Twirler, the Apothecary XP
branch in `onPlayerDealtHit`, synced key, removal of all Potion Thrower
handlers/events), `scripts/stance/perks.lua` (passive attr contributions +
the Apothecary branch of `Perks.onHit`; removal of `Perks.onPotionHit`),
`scripts/stance/player/xp.lua` (`concoction` XP source gate),
`scripts/stance/settings.lua` (two renamed toggles), `l10n/Stance/en.yaml`
(eight strings). `scripts/stance/player/skill_framework.lua` is unchanged —
`alchemy` was already in the vanilla effectiveness-bonus skill list.

## The 17 concoction records

`concoction_base`, `grease_jar`, `restorative_waters`, `raw_magicka`,
`cleansing_salve`, `flash_bang`, `kwama_queen_ph`, `anti_magicka_bottle`,
`invigorating_aromatic`, `aromatic_of_focus`, `insulating_oil`, `singularity`,
`smoke_bomb`, `liquid_stalhrim`, `plasma_jar`, `dwemer_candle`,
`sapping_poison`.

---

## Companion integrations (added later)

The Apothecary stance now recognises a second thrown apothecary weapon, and two
*deployable* hazard mods (by Arcimaestro Antares) feed stance XP through a
listener rather than by being equipped. A trap is a Thief tool, so it credits
the **Thief** stance; the oil fire is alchemical, so it credits **Apothecary**.

| Mod | Item | How it's handled | Credits |
| --- | --- | --- | --- |
| **Venefic Vials** | `vv_vial_th` (Throwning Venefic Vial — a MarksmanThrown flask) | Equipped-weapon detection, exactly like a concoction. Its own integration toggle (`integrateVeneficVials`), gated independently of Thrown Concoctions. | **Apothecary** (active while equipped; XP + on-hit perks via the normal combat path) |
| **Traps** | `trap_open` (armed trap activator) | Not equippable. `hazard.lua` (on ACTIVATOR objects) detects a non-player actor standing on the armed trap and fires `Stance_HazardHit`. One credit per spring. | **Thief** (3.0 XP, `xpOnTrapHit`), regardless of active stance |
| **Oil Flask** | `oil_fire` (the lit-fire light) | Not equippable. `hazard.lua` (on LIGHT objects) detects a non-player actor standing in a **burning** pool — the `oil_fire` object exists only while lit, which is the "burning" gate. ~1 credit/sec while the enemy burns. | **Apothecary** (0.5 XP/tick, `xpOnOilBurn`), regardless of active stance |

The deployable (non-thrown) Venefic *misc* vial, and the un-ignited oil pool,
are deliberately **not** credited — there is no equipped weapon and no actual
damage, respectively.

### Why the deployables use a listener, not a stance

Traps and oil flasks are MISC items you drop and arm; you never equip them, and
they trigger long after you've moved on to another weapon. A persistent
"stance" therefore makes no sense for them. Instead, a local script attached to
the hazard object (`scripts/stance/hazard.lua`) watches for a non-player actor
standing on the armed trap / in the lit fire and routes a credit to the fixed
stance via `grantStanceXpDirect` (a sibling of `grantStanceXp` that skips the
"only the active stance gains XP" guard). The hazard damage itself is still done
by the source mods' own MWScripts (`HurtStandingActor`); Stance only listens.

Detection is by proximity (the engine's exact `GetStandingActor` has no Lua
hook), so the footprint constants in `hazard.lua` are approximate and tunable.
The listener attaches to all activators/lights but returns no handlers for any
record that isn't `trap_open`/`oil_fire`, so non-hazard objects cost nothing.

New toggles (all default ON): **Integrations → Venefic Vials / Traps / Oil
Flask**, and **Progression → XP from Trap Catches / XP from Oil Fires**.
