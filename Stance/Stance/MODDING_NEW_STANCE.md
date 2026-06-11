# Stance! — Modder's Guide: Adding a New Weapon Stance

This guide walks through everything required to add a brand-new weapon stance to **Stance!**. It is written against the current code layout (the `scripts/stance/` tree with the `player/` submodules) and reflects how the existing 19 stances are actually wired.

A "stance" is just a named state the mod can be in, with:

- a **definition** (display name, governing attribute, description, perk ladder),
- a **detection rule** that decides when it's active,
- a **target skill** that receives its level-scaled bonus,
- a set of **registration entries** so settings, perks, and the global mirror all know it exists,
- **localization strings** for its settings UI,
- and optionally some **perk logic**.

Adding one means touching a handful of tables across four files. None of it is hard, but **every step is mandatory** unless noted — skip one and the stance will silently misbehave (no bonus, no toggle, no perk gating, etc.). A checklist is at the end.

> Throughout, the running example is a fictional new stance: **Flailman**, active when a flail-type weapon is equipped, governed by Agility, boosting the Blunt Weapon skill. Swap in your own names as you go.

---

## 0. Before you start: how detection works

Every tick, the player script (`init.lua`) runs `resolveStance(now)`. It builds a few facts about the player's current state, then walks a **fixed priority list** of `if` branches. **The first branch that matches wins.** The variables available to every branch are:

| Variable | Meaning |
|---|---|
| `stanceMode` | `'weapon'`, `'spell'`, or `'nothing'` — whether a weapon/spell is drawn |
| `right` | the object in the right hand (`CarriedRight`), or `nil` |
| `rightRec` | the raw weapon record of `right` |
| `effRec` | the **GRIP-aware** record — the *original* type if GRIP converted the weapon; use this for normal type classification |
| `runtimeRec` | the **current/converted** record as it exists in-hand right now |
| `shield` | the equipped shield record, or `nil` |

Each branch ends by calling the local helper `pick(id, reason)`:

```lua
local r = pick('flailman', 'flail equipped')
if r then return r end
```

`pick` returns `nil` if the stance is disabled in settings (so a disabled stance is transparently skipped and the resolver falls through to the next candidate). **Priority is purely positional** — where you place your branch determines what it beats and what beats it. More on that in Step 4.

> **`effRec` vs `runtimeRec`:** use `effRec` for "what did the player mean to wield" (honors GRIP's original type), and `runtimeRec` for "what is literally in hand right now." Most stances use `effRec`. The two-handed/handedness-sensitive branches (Zweihänder, Soloist) use `runtimeRec`. When in doubt, use `effRec`.

---

## 1. Define the stance — `config.lua`

`config.lua` holds the `stances` array (around line 124). Each entry is a self-contained table. Add a new one following this shape:

```lua
{
    id          = 'flailman',          -- unique lowercase id, used EVERYWHERE as the key
    displayName = 'Flailman',          -- shown in tooltip / HUD / console
    attribute   = 'agility',           -- governing attribute (lowercase OpenMW attribute id)
    description  = 'A flail rewards timing over reach...',  -- tooltip flavor text
    integrations = {},                 -- list of integration ids this stance needs; {} = none
    category     = 'damage',           -- loose grouping tag: 'damage' | 'speed' | 'utility' | etc.
    perks = {
        { level = 25,  id = 'flailGrip',    name = 'Flail Grip',
          description = 'The chain forgives a clumsy grip. Knockdown resistance +25%.' },
        { level = 50,  id = 'whippingArc',  name = 'Whipping Arc',
          description = 'Power attacks deal 15% more damage.' },
        { level = 75,  id = 'entangle',     name = 'Entangle',
          description = '10% chance to stagger the target.' },
        { level = 100, id = 'flailMaster',  name = 'Flail Master',
          description = '+25% flail damage; fatigue drain halved.' },
    },
},
```

Rules:

- **`id` is the canonical key.** It must be unique and is reused verbatim in every table in Steps 2–6. Keep it lowercase, no spaces.
- **`attribute`** must be a valid lowercase OpenMW attribute id: `strength`, `intelligence`, `willpower`, `agility`, `speed`, `endurance`, `personality`, `luck`. This is what the chameleon Stance skill swaps to while your stance is active (unless the player disabled attribute-swap).
- **`integrations`** lists integration ids the stance depends on (see the integrations table in the README). Leave `{}` for a pure-vanilla stance like Flailman.
- **`perks`** must have exactly **four** entries at levels **25 / 50 / 75 / 100**. The `id` of each perk is what you'll test against in perk logic (Step 7). The `level` is the **core Stance skill** threshold, not your stance's own level.

That's the data. Nothing here makes the stance *do* anything yet.

---

## 2. Set the target skill — `STANCE_SKILL_TARGET` in `init.lua`

This table (around line 973) maps each stance id to the skill that receives its level-scaled bonus (+2 at stance level 5, up to +20 at 100). Add your entry:

```lua
flailman = { vanilla = 'bluntweapon' },
```

The value table supports three forms:

| Form | Use when | Example |
|---|---|---|
| `{ vanilla = 'skillid' }` | the stance always boosts one vanilla skill | `{ vanilla = 'bluntweapon' }` |
| `{ vanilla = 'x', modded = 'y', integration = 'z' }` | boost a modded skill when integration `z` is present, else fall back to vanilla `x` | `{ vanilla = 'axe', modded = 'mining_skill', integration = 'simplymining' }` |
| `{ dynamic = true }` | the target skill is computed at runtime from the equipped weapon | Dualist, Blademeister |

Valid vanilla skill ids are the OpenMW strings: `longblade`, `shortblade`, `bluntweapon`, `axe`, `spear`, `marksman`, `handtohand`, `block`, `armorer`, `security`, `speechcraft`, `mercantile`, `sneak`, `mysticism`, etc.

If you use `dynamic = true`, you must also add a resolver case inside `resolveStanceSkill()` (just below the table) that returns the right skill id for your stance.

> **Want NO skill bonus?** Omit the stance from this table entirely. `resolveStanceSkill` returns `nil` and no bonus is ever applied (this is exactly how Twirler is configured to grant no effectiveness bonus).

### How the bonus is delivered (you don't write this, but know it)

- **Vanilla skills** get the bonus through the engine's native skill `.modifier` field, applied each tick in `player/skill_framework.lua` (`refreshEffectivenessModifiers`). If your `vanilla` id isn't already in that file's `VANILLA_EFF_SKILLS` list, **add it** — otherwise the native applier won't touch it.
- **Modded SF skills** are delivered through Skill Framework's `registerDynamicModifier`. If your `modded` id and its `integration` id aren't in that file's `MODDED_EFF_SKILLS` map, add them.

For a vanilla skill already in the list (like `bluntweapon`), there's nothing extra to do here.

---

## 3. Add a detection classifier — `init.lua`

If your stance keys off a weapon **type** that no existing helper covers, write a small classifier near the other `is…` functions (lines ~478–710). They all take a record and return a boolean:

```lua
local function isFlail(weaponRec)
    if not weaponRec then return false end
    -- Use a real WTYPE if one fits, or detect by record-id prefix/keyword.
    return weaponRec.type == WTYPE.BluntOneHand
        and type(weaponRec.id) == 'string'
        and weaponRec.id:lower():find('flail')
end
```

The available engine weapon types (`WTYPE.*`, from `types.Weapon.TYPE`) are:

```
ShortBladeOneHand   LongBladeOneHand   LongBladeTwoHand
BluntOneHand        BluntTwoClose      BluntTwoWide
AxeOneHand          AxeTwoHand         SpearTwoWide
MarksmanBow         MarksmanCrossbow   MarksmanThrown
```

Note there is **no "ShortBladeTwoHand"** — any two-handed blade is `LongBladeTwoHand`. (This is why GRIP-converted shortswords need special handling; see the Zweihänder branch.)

If your stance keys off something other than weapon type — an equipped tool, a record-id prefix, an off-hand item — model it on the existing helpers: `isReforgerWeapon` (literal record id), `isFelthorn` (record-id prefix scan), `hasLockpickOrProbeEquipped` (equipment-slot read), `isDualWielding` (integration event state).

If an existing helper already identifies your weapon (e.g. you just want "any axe"), reuse it — no new classifier needed.

---

## 4. Insert the resolver branch — `init.lua`

Inside `resolveStance(now)`, add your branch **at the correct priority**. The branches are numbered in comments (1–19). Placement is everything:

- More **specific** rules go **above** more general ones. Flailman (specific blunt subtype) must come **before** Mjolnir (all blunt weapons), or Mjolnir will swallow every flail.
- Conversely, broad fallbacks (Commoner, Brawler) stay near the bottom.

For Flailman, place it just **above** the Mjolnir branch (priority 15):

```lua
-- 14.5) Flailman: flail-type blunt weapon. Above Mjolnir so a flail
--       routes here instead of being claimed as a generic blunt.
if effRec and isFlail(effRec) then
    local r = pick('flailman', 'flail equipped')
    if r then return r end
end

-- 15) Mjolnir: blunt one-handed or blunt two-handed close...
if effRec and not isReforgerWeapon(right, effRec) and isBluntMjolnir(effRec) then
    ...
```

Guidelines:

- Always gate through `pick(id, reason)` — never `return { id = ... }` directly, or you'll bypass the enable/disable check.
- Use `effRec` for type classification unless you specifically need runtime handedness (`runtimeRec`).
- The `reason` string is debug-only (shown in `stance` console output and detection logs); make it short and human-readable.
- If two stances could match the same weapon, the higher branch wins. Double-check you're not stealing weapons from an existing stance or being stolen from.

---

## 5. Register the stance everywhere — `init.lua`

A stance id must appear in **five** lookup tables or it will be half-broken. All are in `init.lua`. Search for an existing id like `soloist` to find each table.

| Table | Add | Purpose |
|---|---|---|
| `STANCE_SETTING_KEY` | `flailman = 'enableFlailman'` | maps stance → its enable-setting key |
| `PERK_SETTING_KEY` | `flailman = 'enableFlailmanPerks'` | maps stance → its perk-toggle key |
| `SYNCED_KEYS` (Stances) | `{ 'Stances', 'enableFlailman' }` | mirrors the enable setting to the global script |
| `SYNCED_KEYS` (Perks) | `{ 'Perks', 'enableFlailmanPerks' }` | mirrors the perk toggle to the global script |
| `STANCE_SKILL_TARGET` | *(done in Step 2)* | the skill the bonus applies to |

Miss `STANCE_SETTING_KEY` and the enable toggle won't bind (the stance can't be turned off). Miss either `SYNCED_KEYS` entry and the global script won't know the stance's settings (perk effects that run globally can misfire). Miss `PERK_SETTING_KEY` and perk gating/notifications break.

---

## 6. Add settings + localization — `settings.lua` and `l10n/Stance/en.yaml`

### 6a. Settings entries (`settings.lua`)

In the **Stances** group, add an enable checkbox:

```lua
{ key = 'enableFlailman', renderer = 'checkbox',
  name = 'SettingEnableFlailman', description = 'SettingEnableFlailmanDescription', default = true },
```

In the **Perks** group, add a perk toggle:

```lua
{ key = 'enableFlailmanPerks', renderer = 'checkbox',
  name = 'SettingEnableFlailmanPerks', description = 'SettingEnableFlailmanPerksDescription', default = true },
```

The `key` values must exactly match what you put in `STANCE_SETTING_KEY` / `PERK_SETTING_KEY` and `SYNCED_KEYS`.

### 6b. Localization (`l10n/Stance/en.yaml`)

Every `name`/`description` above is an l10n key, not literal text. Add all four strings or the settings page shows raw keys:

```yaml
SettingEnableFlailman: Enable Flailman
SettingEnableFlailmanDescription: Active when a flail-type blunt weapon is equipped. Governed by Agility; boosts Blunt Weapon.
SettingEnableFlailmanPerks: Flailman Perks
SettingEnableFlailmanPerksDescription: Flail Grip (25), Whipping Arc (50), Entangle (75), Flail Master (100).
```

If you ship other language files, add the keys there too (English is the fallback).

---

## 7. Implement perk logic — `perks.lua` (optional but usual)

Perks come in two flavors. Both live in `perks.lua` and both gate on the **core** Stance level via the local `cl` (core level) and the active stance id `sid`.

### 7a. Passive stat perks (attributes / skills)

These are reconciled every tick by `computeDesiredAttrContribs()` (attributes) and `computeDesiredSkillContribs()` (skills). Add a block keyed on your stance id. Example — Flailman's perks that boost attributes:

```lua
-- in computeDesiredAttrContribs(), alongside the other stance blocks:
if sid == 'flailman' and perksEnabled('flailman') then
    if cl >= 25  then d.endurance = d.endurance + 10 end  -- Flail Grip (knockdown resist proxy)
    if cl >= 100 then d.agility   = d.agility   + 10 end  -- Flail Master
end
```

For a **skill** bonus perk (like Thief's Cutpurse → +5 Sneak), add to `computeDesiredSkillContribs()` instead, and make sure the skill id is in that file's `SKILL_NAMES` list:

```lua
if perkActive('flailman', 50) then d.bluntweapon = d.bluntweapon + 5 end
```

The contribution system uses **delta accounting** — you declare the *desired total* and the engine reconciles it. Don't write `.modifier` directly; let the loop do it. (This is what keeps bonuses from drifting across save/load and from fighting other mods.)

> **Important:** if another mod owns a vanilla skill's modifier (the way **Throwing!** owns Marksman), do **not** also write that skill from a perk — you'll get a tug-of-war. Route around it the way the effectiveness system cedes Marksman to Throwing!.

### 7b. Active on-hit perks

For perks that fire on a landed hit (damage bursts, bleeds, staggers), add a block to `Perks.onHit(attack)`. The victim is `attack.target`:

```lua
if sid == 'flailman' and perksEnabled('flailman') then
    if cl >= 75 and roll(0.10) then
        sendEffect(attack.target, EFF.DamageFatigue, 15, 0)   -- Entangle: stagger proxy
    end
end
```

`sendEffect(target, effectId, magnitude, duration)` dispatches a magic effect to the global script for world-scope application. `EFF.*` holds the effect ids (`DamageHealth`, `DamageFatigue`, `Paralyze`, etc.); `roll(p)` is a probability helper. On-hit XP is already credited before `Perks.onHit` runs, so you only handle effects here.

### 7c. Multiplicative / engine-level perks

Damage multipliers, attack-speed, armor-bypass and similar are applied through the mechanisms the existing combat perks use (see how Soloist/Axeman/Mjolnir implement their +damage tiers). Mirror the closest existing perk to your intended effect rather than inventing a new pathway.

---

## 8. Test

1. **Load order:** Stance! after Skill Framework, plus any integration mods your stance needs.
2. In-game, open the console and run `stance list` — your stance should appear with its level, bonus, target skill, and `on/off` state.
3. Equip the triggering weapon and run `stance active` — confirm it's detected, the attribute swapped, and the bonus reads `+2 <Skill>` at a fresh level.
4. `stance set flailman 100` and re-check — bonus should read `+20`.
5. `stance set core 25/50/75/100` and verify each perk tier unlocks (watch the unlock popup and the tooltip's perk list).
6. Equip a *neighboring* weapon type and confirm your stance does **not** steal it (priority check), and that the previously-correct stance still wins.

---

## Checklist

Per new stance id `myStance`:

- [ ] **`config.lua`** — entry in `stances` with `id`, `displayName`, `attribute`, `description`, `integrations`, `category`, and four perks at 25/50/75/100.
- [ ] **`init.lua` `STANCE_SKILL_TARGET`** — target skill (or omit for no bonus; or `dynamic = true` + a `resolveStanceSkill` case).
- [ ] **`player/skill_framework.lua`** — if the target is a vanilla skill not already in `VANILLA_EFF_SKILLS`, add it (or for a modded skill, add to `MODDED_EFF_SKILLS`).
- [ ] **`init.lua`** — a classifier (`isMyStance`) if no existing helper fits.
- [ ] **`init.lua` `resolveStance`** — a branch at the correct priority, gated through `pick`.
- [ ] **`init.lua` `STANCE_SETTING_KEY`** — `myStance = 'enableMyStance'`.
- [ ] **`init.lua` `PERK_SETTING_KEY`** — `myStance = 'enableMyStancePerks'`.
- [ ] **`init.lua` `SYNCED_KEYS`** — both `{ 'Stances', 'enableMyStance' }` and `{ 'Perks', 'enableMyStancePerks' }`.
- [ ] **`settings.lua`** — enable checkbox in Stances group, perk checkbox in Perks group.
- [ ] **`l10n/Stance/en.yaml`** — `SettingEnableMyStance`, `...Description`, `SettingEnableMyStancePerks`, `...Description`.
- [ ] **`perks.lua`** — perk logic in `computeDesiredAttrContribs` / `computeDesiredSkillContribs` / `Perks.onHit` as needed (and add any new skill id to `SKILL_NAMES`).
- [ ] **Test** the six points above.

---

## Reference: which file owns what

| Concern | File |
|---|---|
| Stance definitions, perk ladders, leveling numbers, integration specs | `config.lua` |
| Detection, resolver priority, classifiers, registration tables, console, event wiring | `init.lua` |
| Effectiveness skill-bonus application (vanilla native + modded SF) | `player/skill_framework.lua` |
| Perk effects, attribute/skill contributions, on-hit dispatch | `perks.lua` |
| Settings page (the ten groups) | `settings.lua` |
| UI text for settings | `l10n/Stance/en.yaml` |
| HUD indicator, GRIP lookups, XP banking, console internals, stat accessors | `player/hud.lua`, `player/grip.lua`, `player/xp.lua`, `player/console.lua`, `player/stat_access.lua` |
| Global-scope kill relay, settings mirror, perk-effect application | `global.lua` |
| Victim-side hit/kill reporting (NPCs & creatures) | `victim.lua` |

---

## Design conventions worth following

- **One canonical id.** Pick the stance id once and use it identically in every table. Most "my stance does nothing" bugs are a typo'd or missing id in one of the five registration tables.
- **Specific beats general in the resolver.** If your weapon is a subtype of an existing category, your branch goes above the category's branch.
- **Never write stat modifiers directly from perks.** Use the contribution tables so delta accounting handles save/load and multi-mod stacking.
- **Cede shared vanilla skills.** If another mod actively rewrites a vanilla skill's modifier, don't fight it — route your bonus elsewhere or let that mod mirror it.
- **Four perks, at 25/50/75/100, gated on core level.** Keep to the established cadence so the perk UI and notifications behave.
- **Degrade gracefully.** If your stance leans on an integration, guard every integration call so the stance still works (minus the integration-specific perks) when the mod is absent.
