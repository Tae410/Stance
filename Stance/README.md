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
| **Iron Fist for OpenMW** | Detected via its settings mirror (`IronFistRuntime`). While Brawler is active with a gauntlet or bracer equipped, Brawler adds its own extra unarmed damage on top of Iron Fist's gauntlet bonus, scaled by Brawler's stance level and the Iron Grip perk. See *Brawler + Iron Fist* below |
| **Evasion!** | Surfaces the dodge/Sanctuary bonus in the tooltip with an "Evasion!" attribution (the two contributions track separate deltas and never interfere) |
| **Sol's Timed Directional Attacks** | Detected via its settings section (`Settings_SolTimedDirAttacks`). Tempo-driven stances gain a passive weapon-skill bonus — *timed-directional-attack mastery* — ceilinged from STDA's own `buffBase` and scaled by the core Stance level. See *Sol combat-mod mastery* below |
| **Sol's Weighty Charged Attacks** | Detected via its settings section (`Settings_SolWeightyChargeAttacks`). Heavy, committed stances gain a passive weapon-skill bonus — *weighty-charged-attack mastery* — ceilinged from SWCA's own `buffBase`/`maxCharge` and the equipped weapon's weight, and scaled by the core Stance level. See *Sol combat-mod mastery* below |
| **Move Like This** | Detected via its settings section (`Settings_MoveLikeThis`). Each melee stance's signature directional move(s) are surfaced in its tooltip, and landing one of MLT's two attacker-notified moves (a critical thrust or a mobility slash) grants the active stance extra XP. See *Move Like This — weapon distinctiveness* below |
| **Bardcraft** | Detected via its Skill Framework skill (`bardcraft`). Powers the **Muse** stance: idle performances activate Muse, and finishing a song grants a timed inspiration buff to the stance the song is associated with. See *Muse - the bard's stance* below |

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
| **Hackle-Lo Pipes** (Smoker prefix) | Detects an equipped pipe to show a **Smoking** prefix on the stance name; smoking a hackle-lo leaf grants a temporary additive weapon-skill bonus to the active stance's weapon skill (an extended core-level-gated window — 20s at core 5, +15s every 10 core levels (no longer halved)), and cancels the pipe's Speed drain for the full smoke. Toggle under **Integrations** |
| **Incantation** | Arcanist spellcasting XP via the `spellcast` animation text-key |
| **Meditation Skill** | Arcanist tick XP via the SkillProgression hook |
| **Disenchanting** | Arcanist / Thaumaturge XP via `disenchanting_finishedDisenchanting` |
| **Transcribe** | Arcanist / Thaumaturge XP via `TRAN_doTranscribe` |
| **OSSC (Oblivion-Style Spell Casting)** | Credits the spellcasting stance (Arcanist by default) on each OSSC quick-cast, read from OSSC's own `OSSC_CastingState` event. OSSC casts use their own animations and bypass the vanilla `spellcast` text-key, so without this they earn nothing; the credit is direct (any active stance) and respects the **XP on spell cast** toggle. No OSSC edit required |
| **Weapon Upgrade** | Detects the `repair_hammer_weapon` for Reforger and credits Reforger XP on a successful (or failed) upgrade |
| **Armor Upgrade** | Same hammer detection as Weapon Upgrade — credits Reforger |
| **Oblivion-Style Lockpicking** | Locksmith lockpick XP via `OSL_LockpickSuccess` |
| **Talking Trains Speechcraft** | Detected for display/toggle; Commoner's talking XP reacts to the engine `UiModeChanged` signal directly, so it works with or without this mod |
| **Commercium / Fair Trade** | Commoner trade XP via `FairTrade_Transaction` |
| **Evening Star (Religions of Morrowind)** | Each stance is sworn to one of the three Tribunal Temple deities (Vivec / Almalexia / Sotha Sil). While you worship that deity, the active stance gains a small additive bonus to its target skill, scaled by devotion tier (Follower **+2**, Devotee **+4**). Detected by reading the worship abilities Evening Star grants you — no API needed. Tribunal Temple only; the Sun's Dusk pantheons are ignored. Toggle under **Integrations** |
| **Toxicology!** | Read-only sibling — Stance! never writes to Toxicology's data |

### Evening Star — Tribunal patronage

When **Evening Star: Religions of Morrowind** is installed and the integration is
enabled, every stance is associated with one of the three living gods of the
Tribunal Temple, grouped by domain:

- **Vivec**, the Warrior-Poet (patron of artists and rogues): the blade stances
  (Soloist, Zweihänder, Blademeister, Dualist), the Thief, the Twirler, the
  Axeman, and the Muse.
- **Almalexia**, the Mother and defender (provision and endurance): the Brawler,
  Guisarmier, Mjölnir, the providers (Angler, Forager, Huntsman), and the Commoner.
- **Sotha Sil**, the Clockwork God and master artificer (magic and reason): the
  casters (Arcanist, Thaumaturge), the crafters (Reforger, Apothecary), the miner
  (Pitmen), and the Locksmith.

Your devotion tier — read from the abilities Evening Star grants you (Worshipper /
Follower → **Follower**; Devotee → **Devotee**) — sets the size of the blessing,
a small additive bonus to the active stance's own target skill. It is deliberately
small (a fraction of the core effectiveness bonus's +2→+20) so it complements your
faith without unbalancing the stance system. The stance's patron and current
blessing are shown in its skill tooltip.

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

## Stance Wheel (included)

The radial **Stance Wheel** selector ships inside this mod — there is no separate
download or content file to enable. Its scripts live under `scripts/StanceWheel/`
and are registered by the same `Stance.omwscripts`, so it is active the moment
Stance! is. Configure it on its own **Stance — Wheel** settings page (Options →
Scripts).

Hold the activation key (default **G**), aim a stance with the mouse or right
stick, and release: the wheel reads your **Quick Select Ultimate** hotbar, equips
the weapon that matches the aimed stance, and lets Stance!'s resolver flip you
into it. **Quick Select Ultimate is still required** for the wheel to do anything
— the wheel is the glue between the two. If Quick Select Ultimate is absent, the
wheel quietly stays dormant (the rest of Stance! is unaffected); it tells you once
when you first press the key.

## The stances


The mod resolves the active stance every frame by walking a priority-ordered
list of detection rules. **The first rule whose signal fires wins.** There are
**21** stances (the numbered list below is illustrative; Muse is detection rule 0).

| # | Stance | Governing | When it activates |
|---|---|---|---|
| 0 | Muse | Personality | Performing a song **idly** (a Bardcraft Practice performance). Sits above everything — while performing, weapons are sheathed, which would otherwise be Commoner |
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

Four transient states **decorate** the active stance's displayed name (in the
HUD indicator and the skill tooltip) without changing which stance is active.
They compose, outermost-first, as **Smoking → Sneaky → Fortified → element →
base** — e.g. `Smoking Sneaky Fortified Blazed Soloist`.

| Prefix | Appears when | Scope | Effect |
|---|---|---|---|
| **Smoking** | A Hackle-Lo pipe is in the off-hand / a hackle-lo smoke is active | **Every** stance (requires the Hackle-Lo Pipes mod) | A temporary additive weapon-skill bonus while the smoke buff window is live — gated to the core Stance level and extended (20s at core 5, +15s every 10 core levels; no longer halved); also cancels the pipe's Speed drain for the full smoke |
| **Sneaky** | You are crouched / sneaking (`self.controls.sneak`) | **Every** stance | Cosmetic only |
| **Fortified** | A shield is equipped alongside a one-handed melee weapon | Soloist, Thief, Mjölnir, Axeman, Blademeister | Cosmetic **+** an additive **Block** skill bonus that scales with your own Block skill while equipped |
| **Blazed / Frozen / Electrified** | Spellsword has imbued your weapon with fire / frost / shock | Any stance that wields an imbuable weapon (everything except Arcanist, Commoner, Locksmith, Reforger, Muse) | Cosmetic only |

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

### Sol combat-mod mastery

When either of Solthas's weapon-combat-buff mods is installed, stances whose
fighting style fits earn a passive bonus to their **own weapon skill** — the
stance's growing *mastery* of that mod's signature technique. Like the Evasion!
integration, this is a delta-accounted bonus applied while the stance is active;
it **compounds with** the Sol mod's own transient buff on separate deltas and
never touches it. Neither Sol mod fires an event Stance! could hook, so the
integration reads each mod's **own live settings** to size the bonus instead.

- **Timed Directional Attacks (STDA)** — nimble, tempo-driven stances (Thief,
  Soloist, Dualist, Guisarmier, Blademeister, and lightly Axeman / Mjölnir /
  Zweihänder / Brawler). The bonus ceiling is `weight × STDA.buffBase` (read live
  from STDA). Each stance names its signature directional attack — Chop / Slash /
  Thrust — shown in the tooltip.
- **Weighty Charged Attacks (SWCA)** — heavy, committed stances (Mjölnir,
  Zweihänder, Axeman, Guisarmier, Soloist, Reforger). The ceiling mirrors SWCA's
  own release-buff formula at full charge for the **equipped weapon's weight**
  (`weight × ceil(SWCA.buffBase × (1 + √W) × SWCA.maxCharge)`, both read live from
  SWCA, with `W` clamped by `solWeapWeightCap`) — so a heavier weapon in the same
  stance gives a weightier bonus. Each stance names its signature blow (Smite,
  Cleave, Set Spear, Power Thrust, Forge Blow).

In both cases the bonus **scales with the core Stance level**, on the same
linear ramp the effectiveness bonus uses: 0 at the start level
rising to the full ceiling at level 100. A few weapons that play either way
appear under both systems, weighted toward their dominant character; tool,
activity, and caster stances have no affinity. The applicable stances, signature
labels, and per-stance weights are all data in `config.solAffinity`. Each
integration has its own toggle under **Integrations**, and the whole thing is
read-only — neither Sol mod is ever written to, and the bonus is simply absent
when its mod is not installed.

### Brawler + Iron Fist for OpenMW

**Iron Fist for OpenMW** adds an unarmed
damage bonus from equipped gauntlets, bracers, or gloves, scaled by their
armor weight class, your Strength and Hand-to-Hand skill, and the swing
itself — plus optional durability wear and casting the glove's own
enchantment on a hit. When it's installed and enabled, Brawler builds
directly on top of it:

- While Brawler is active and you have a gauntlet or bracer equipped, Brawler
  adds its **own** extra unarmed damage on top of whatever Iron Fist itself
  just dealt. The two bonuses are independent and simply add together — Iron
  Fist's own mechanic is never read, modified, or duplicated.
- The hand-armor tier (**Light / Medium / Heavy**) is the *exact same*
  classification Brawler's existing Hand-to-Hand bonus already uses (the
  vanilla GMST-based weight thresholds, `iGauntletWeight` / `fLightMaxMod` /
  `fMedMaxMod`) — "Heavy" means the identical thing to both systems, and each
  tier has its own bonus ceiling (`config.brawlerGauntlet`'s
  `ironfistBonusMax`).
- That ceiling is reached gradually as Brawler levels up, on the same stepped
  ramp `config.leveling`'s effectiveness bonus already uses elsewhere — 0
  just past the start level, full strength once the ramp caps (level 50 by
  default).
- **Iron Grip** (level 25+) applies its description's literal **+15%
  hand-to-hand damage** to this term specifically — the first time that perk
  has ever had a direct damage effect; everywhere else it still works the way
  it always has, as a Strength bonus.
- Already wearing **bare fists**? Both Iron Fist's own bonus and this one are
  zero — there's nothing to amplify without a glove on. Already correctly
  credited as ordinary unarmed combat: Brawler's standard combat-hit XP flows
  on every landed punch regardless of any of this, exactly as it always has.
- Does not touch, gate on, or interact with the **Gothic Style Knockout**
  integration in any way — that integration's events
  (`Stance_BrawlerKnockdown` / `GKD_DoKnockdown`) are completely separate and
  unaffected.

Entirely inert without Iron Fist installed (detected via its own settings
mirror, `IronFistRuntime`) and turned off the moment its own "enabled"
setting is off — there is no separate "fake" version of this bonus without
the real mod present. Toggle is **Iron Fist for OpenMW** under
**Integrations**.

### Move Like This — weapon distinctiveness

[Move Like This](https://www.nexusmods.com/morrowind/mods/59154) gives every
weapon type its own chop / slash / thrust behaviour — Cleave, Critical, Stagger,
Armor Pierce, Stomp, First Strike, Shield Break, Mobility / Blind — which is
exactly the per-weapon character Stance! is built around. The integration is
**read-only**: Stance! never re-applies or alters Move Like This's effects. It
ties the two mods together two ways:

- **Signature move in the tooltip.** Each melee stance's signature directional
  move(s) are listed in its tooltip (e.g. Soloist → *Thrust → Critical · Slash →
  Cleave*; Axeman → *Chop → Shield Break · Slash → Cleave*). The mapping lives in
  `config.mltSignature`. Dualist and Blademeister wield a varying weapon, so
  theirs read *"varies with your weapon."*
- **Signature-move XP.** Move Like This sends two events to the attacker when the
  player lands them — a **critical thrust** and a **mobility slash**. Stance!
  listens for both and credits the **active** stance (which is necessarily the
  matching weapon stance), so landing your stance's signature move trains it a
  little faster, on top of the ordinary hit XP. Each has its own toggle under
  **Progression**. The other MLT effects (cleave, stagger, armor pierce, stomp,
  first strike, shield break, blind) do not notify the attacker, so they carry no
  dedicated XP source.

Because Move Like This's *skill-scaled* effects — critical chance, stagger
chance, mobility/blind magnitude, and cleave accuracy — all key off the
attacker's **weapon skill**, the active stance's effectiveness and Sol mastery
bonuses (which raise that weapon skill) already **sharpen these moves as the
stance levels**, with no extra bookkeeping. Mastering a stance literally makes
its signature Move-Like-This strike land harder and more often.

### Muse - the bard's stance (Bardcraft)

Bardcraft (nexusmods.com/morrowind/mods/56814) turns music into a gameplay loop;
**Muse** turns that music into combat preparation. Muse is a twentieth stance
that is active **only while you perform a song idly** - a Bardcraft *Practice*
performance, played for yourself rather than for a venue or crowd. It is
governed by **Personality** and has **no perks**.

**Every song buffs a specific stance.** Each song maps, consistently, to one
combat stance: curated overrides match first by song id, then by a keyword in
the title (a *war* ballad -> Zweihander, a *hunt* song -> Huntsman, a *drinking*
tune -> Brawler, ...); any other song is hashed deterministically onto the
buffable list, so the same song always inspires the same stance. The mapping is
in `config.muse` (`songOverrides` + `buffableStances`).

**Notes become buff time.** While you play, every note Bardcraft reports feeds a
timer: a **clean note adds** `successSeconds` and drains **2 fatigue**; a
**fumbled note subtracts** `failSeconds` and drains **4 fatigue**. When the song
ends, the accumulated time (floored at zero) becomes the **duration** of an
*inspiration* buff applied to the associated stance - a temporary bonus to that
stance's weapon skill (magnitude scales with your Bardcraft skill), delivered through the
same delta-accounted path as every other Stance bonus, so it stacks cleanly.

**Muse levels** from carrying idle songs to completion and from successfully
administering buffs. It has no perks; instead, **each Muse milestone (every 25
levels) raises the loop allowance by +1** - how many of a looping song's repeats
may feed the buff timer (base 1, up to 5). Loop boundaries are read from
Bardcraft's bar events.

**Tooltips.** When a buffed stance is active, its tooltip shows the live
inspiration - `Muse: +N <skill> from '<song>'  (M:SS left)` - counting down in
real time, plus the known songs that inspire it. The Muse stance's own tooltip
shows the in-progress performance: the song, the stance it will buff, the
running buffer, and the loop / note tally.

Everything is read-only with respect to Bardcraft - Stance only listens to its
events (`BO_ConductorEvent` for start/loop/stop, `BC_PerformerNoteHandled` for
each note). Toggle the whole feature with the **Bardcraft** integration, and the
stance itself with **Enable Muse**.

## How leveling works

Two layers work together:

**Per-stance levels.** Each stance has its **own** XP bank and level (5 → 100),
saved in your character's data. Only the **active** stance earns XP — whatever
you are doing trains the stance you currently hold. Switch weapons and the
stance you were in is **banked exactly as it was**; the new stance picks up from
its own saved level. A stance's own level governs its **perks** (below); its
**bonuses**, however, scale on the core level (also below).

**The core Stance skill.** The single skill Skill Framework displays. Its row
in the character sheet (under the **Stance** subsection, via Stats Window
Extender) renames itself **live** to the decorated active stance — sheathe your
blade and it reads `Commoner`; draw a longsword behind a shield while crouched
and it reads `Sneaky Fortified Soloist`. Its **icon** tracks the stance too:
the same `icons/Stance/<X>.dds` glyph the HUD shows is drawn on the combat-skill
frame, so the stats-menu row and its hover tooltip always match the HUD.
Whenever the active stance gains XP, the core skill gains only a **small fraction**
of that amount — **half**, divided again by the progression slowdown (so roughly
**one sixth** at the default settings) — and levels **normally**, like any other
skill. So each individual stance levels **several times faster** than the core
skill, which is a slow running measure of your overall stance mastery that never
resets when you switch.
There is **no rest requirement** — stance XP and core XP both flow continuously.

**Perks unlock on the stance's OWN level.** A perk is active once *that stance's*
level reaches its threshold (25 / 50 / 75 / 100). Commoner's perks are gated on
the Commoner level, Soloist's on the Soloist level, and so on — each stance's
ladder is independent.

**Bonuses scale on the CORE level.** A stance's magnitude bonuses — its
weapon-skill **effectiveness** (+2 at the start level, +2 every 5 levels, up to
+20), the **Sol** timed/weighty mastery, **Move Like This**, and **Brawler**'s
unarmored bonus — grow with the **core** Stance level, so all stances strengthen
together as your overall mastery rises. Two exceptions: **Block**'s fortified
bonus already scales with the Block skill and is left alone, and the **Muse**
stance's bonuses scale with your **Bardcraft** skill (a better bard plays
stronger inspiration) rather than the core level.

> Example: fighting as Commoner grants Commoner 6 XP and the core skill ~1 XP
> (half, then divided by the slowdown). Commoner's own level climbs several
> times faster than the core skill. Commoner's level-25 perk unlocks when
> **Commoner** reaches 25, while its effectiveness bonus steps up (+2 every 5
> levels) as the **core** skill climbs.

### XP sources

Each source trains the **active** stance (and feeds the core skill at a reduced rate — about one sixth)
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
| Idle song completed (Bardcraft) | in Muse | 3.0 |
| Inspiration buff administered (Bardcraft) | in Muse | 2.0 |
| Move Like This critical thrust | in any crit-capable stance (Soloist / Zweihänder / Thief / Brawler) | 1.5 |
| Move Like This mobility slash | in Thief / Brawler (when that slash effect is set) | 0.75 |

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
confirmed knockout and gives its Iron Grip perk a literal damage effect when
Iron Fist for OpenMW is installed; Arcanist layers on Incantation's magicka refund and
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

The HUD shows the **icon** of the currently active stance, with the stance
**name** beneath it (including any active prefixes — *Sneaky / Fortified /
Blazed-Frozen-Electrified*). Each of the 19 stances has its own icon, shipped
in `icons/Stance/` and wired through the stance's `icon` field in `config.lua`;
the indicator swaps icon and name automatically as the active stance changes.
While you are **crouched** (the *Sneaky* prefix is active), a small Sneaky
badge is overlaid on the bottom-right corner of the stance icon — the icon
counterpart of the `Sneaky …` name prefix — and it disappears the moment you
stand. The name can be hidden for an icon-only indicator, and the icon size is
adjustable (the name scales with it, and so does the badge). If a stance is
ever missing an icon, the indicator falls back to showing just the name so it
is never blank.

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
6. **HUD Indicator** — show toggle, show-stance-name toggle (icon-only when
   off), lock toggle, indicator (icon) size, X / Y position.
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
