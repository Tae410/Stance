--[[
    Stance! — Config

    Central tuning file. All numerical values, stance definitions, perk
    ladders, and integration table-driven settings live here.

    The mod is built around a registry of "stances". Every stance has:
      * a stable internal id (used as storage key, lowercase, ASCII)
      * a display name (the user-facing label)
      * a governing attribute (the attribute the stance scales with)
      * a description (a 1-2 sentence stance summary)
      * an effectiveness category
      * a list of integration ids the stance prefers to interlope with
      * a perk ladder (25/50/75/100). Where a stance has an associated mod,
        the perks reuse / amplify the source mod's existing perk catalog so
        both mods feel cohesive when running together. Stances without an
        associated mod get net-new perks that fit the stance's theme.

    Inspired by For Honor's stance system — when you change weapons mid-
    fight, the game treats you as a different combatant entirely. Stance!
    reproduces that feel by giving each weapon style its own independent
    skill level, its own perk ladder, and its own attribute scaling, all
    surfaced through a single Skill Framework entry that morphs in real
    time as you change weapons.

    Detection priority (first match wins):
       1) Locksmith    — lockpick OR probe equipped (any weapon stance)
       2) Commoner     — sheathed (no lockpick/probe — Locksmith fallback)
       3) Arcanist     — spellcasting stance active
       4) Reforger     — armorer's repair hammer equipped, weapon stance up
       5) Blademeister — Felthorn (any sd_-prefixed weapon form) equipped
       6) Angler       — fishing pole equipped (record id "a_fishing_pole" or "hb_fishing_pole")
       7) Huntsman     — bow or crossbow equipped
       8) Twirler      — thrown weapon equipped
       9) Thaumaturge  — stave (BluntTwoWide) equipped
      10) Dualist      — Dual Wielding off-hand event active (any 1H melee primary)
      11) Fortifier    — a shield is equipped (regardless of weapon)
      12) Guisarmier   — spear (SpearTwoWide)
      13) Pitmen       — the Miner's Pick specifically (AxeTwoHand, record id "miner's pick")
      14) Axeman       — axe of either size (AxeOneHand or AxeTwoHand)
      15) Mjolnir      — blunt one-handed (BluntOneHand) or blunt two-handed close (BluntTwoClose); excludes staves (BluntTwoWide, covered by Thaumaturge)
      16) Zweihänder   — long-blade two-handed weapon (LongBladeTwoHand)
      17) Soloist      — long-blade one-handed weapon (LongBladeOneHand)
      18) Thief        — short blade (ShortBladeOneHand)
      19) Brawler      — unarmed, right hand truly empty, weapon stance up
      20) Commoner     — final fallback

    One-handed blunts and two-handed-close blunts (maces, clubs, warhammers,
    mauls) are now caught by Mjolnir (13) before reaching Commoner. Staves
    (BluntTwoWide) remain under Thaumaturge (8) at higher priority.

    No prefixes. No combination stances. No GRIP-conversion-based stances —
    the conversion records aren't reliably available across save/load
    cycles, so classification is by raw weapon type instead.
]]

local config = {
    -- ─── Skill Framework registration ──────────────────────────────────────
    skillId = 'stance',
    defaultDisplayName = 'Stance',
    defaultAttribute = 'luck',
    startLevel = 5,
    maxLevel = 100,
    classBonus = 10,

    -- ─── Leveling ─────────────────────────────────────────────────────────
    -- Per-stance progression with a shared core skill:
    --   * Each stance has its OWN xp bank and level (5 - 100), persisted in
    --     player storage. Only the ACTIVE stance gains xp; switching stances
    --     banks the current one untouched.
    --   * The core "Stance" skill (owned by Skill Framework) gains HALF of
    --     whatever the active stance just gained, and levels independently.
    --     So each stance levels roughly twice as fast as the core skill.
    --   * PERKS unlock from the CORE skill level: at core level 25 every
    --     stance's level-25 perk becomes available, and so on for 50/75/100.
    --   * A stance's OWN level scales its EFFECTIVENESS BONUS (see
    --     `leveling.effectivenessMinBonus` / `leveling.effectivenessMaxBonus`
    --     below) — a smooth ramp from +effectivenessMinBonus at startLevel to
    --     +effectivenessMaxBonus at maxLevel, applied as a Skill Framework
    --     dynamic modifier on the skill tied to the stance's weapon type or
    --     mod integration. This is surfaced in the tooltip and exposed on the
    --     script interface for other systems.
    leveling = {
        baseXpToLevel  = 8,     -- flat base xp for the first stance level-up
        xpRampPerLevel = 0.06,  -- +6% required xp per level above startLevel
        maxXpToLevel   = 400,   -- hard cap on per-level xp requirement

        -- ── Progression slowdown ──────────────────────────────────────────
        -- Multiplies the XP required for EVERY stance level-up, and divides the
        -- amount fed to the core Stance skill, so BOTH the per-stance levels and
        -- the shared core skill take this many times longer to advance. Set to
        -- 3 so Stance leveling reads as a slow, seamless companion to vanilla
        -- Morrowind leveling rather than a fast parallel track.
        progressionSlowdown = 3,

        -- ── Effectiveness (additive weapon-skill bonus) ───────────────────
        -- The bonus a stance grants to its OWN target skill is now a STEPPED,
        -- purely additive value driven by the stance's own level. It is gained
        -- in discrete +effectivenessStepBonus increments every
        -- effectivenessStepLevels stance levels, starting at effectivenessMinBonus
        -- at startLevel and HARD-CAPPED at effectivenessMaxBonus. This replaces
        -- the old smooth linear ramp; the stepped form makes the gain feel earned
        -- and keeps the early-game number small.
        --   Soloist lv 5   - +2  Long Blade   (startLevel: effectivenessMinBonus)
        --   Soloist lv 10  - +4  Long Blade
        --   Soloist lv 25  - +10 Long Blade
        --   Soloist lv 50  - +20 Long Blade   (cap reached: effectivenessMaxBonus)
        --   Soloist lv 100 - +20 Long Blade   (held at cap)
        -- IMPORTANT: this bonus is applied to ONE skill — the active stance's
        -- target skill — and ONLY while that stance is active. Switching stances
        -- moves it; leaving a weapon stance clears it. It NEVER persists onto a
        -- skill whose stance you are not currently in.
        effectivenessMinBonus = 2,   -- additive skill pts at startLevel
        effectivenessMaxBonus = 20,  -- additive skill pts cap (hard ceiling)
        effectivenessStepLevels = 5, -- gain a step every this many stance levels
        effectivenessStepBonus  = 2, -- +this many skill pts per step
    },

    -- ─── Fortified (shield + one-handed melee) ────────────────────────────
    -- The Fortifier stance is deprecated: a shield equipped alongside a
    -- one-handed melee weapon decorates that weapon's stance with a
    -- "Fortified" prefix (e.g. "Fortified Soloist") and grants an additive
    -- Block skill bonus while so equipped. The bonus SCALES with the player's
    -- own Block skill (base), using the same effectivenessMinBonus →
    -- effectivenessMaxBonus ramp (above) the weapon-skill effectiveness
    -- bonuses use, across the same startLevel - maxLevel range — so the two
    -- knobs in the leveling block tune both systems in unison. There is no
    -- separate flat value to configure.

    -- ─── Brawler gauntlet tradeoff (hand armor while unarmed) ──────────────
    -- While the Brawler stance is active (fists up, no weapon), the armor worn
    -- in the hand slots grants an additive Hand-to-Hand bonus at the cost of
    -- unarmed attack speed, scaling with the armor's weight class — heavier
    -- plate hits harder but slower. BOTH gauntlets (LGauntlet/RGauntlet) and
    -- bracers (LBracer/RBracer) occupy the gauntlet equipment slots and both
    -- are classified here; the heavier of the two equipped pieces sets the
    -- tier. The weight class is computed EXACTLY as the engine does it (see
    -- player/prefixes.lua classifyHandArmor, mirroring mwclass/armor.cpp
    -- getEquipmentSkill): weight ≤ floor(iGauntletWeight) × fLightMaxMod - Light,
    -- ≤ × fMedMaxMod - Medium, else Heavy. "Unarmored" means no hand armor at
    -- all (bare fists) - the 'none' tier: no bonus, no penalty.
    --
    --   hhBonus     — additive Hand-to-Hand skill points. Stacks ON TOP of the
    --                 Brawler effectiveness bonus through the same delta-
    --                 accounted native-modifier path (so it clears cleanly when
    --                 the gauntlets come off or the stance changes).
    --   speedDebuff — subtracted from the unarmed attack-animation speed
    --                 multiplier (1.0 = normal). 0.25 ⇒ swings play at 0.75×.
    -- The values below are the design defaults; tune freely. Light/Medium/Heavy
    -- map 1:1 to the three vanilla armor weight classes.
    --
    -- ironfistBonusMax / ironGripMult (Iron Fist integration, victim.lua): when
    -- the optional "Iron Fist for OpenMW" mod is installed and enabled, Brawler
    -- adds its OWN extra unarmed damage on top of Iron Fist's own gauntlet
    -- bonus — gated on this SAME tier (so "Heavy" means the identical thing to
    -- both systems) and scaled by Brawler's stance-level progress using the
    -- exact ramp shape effectivenessSkillBonus already uses elsewhere (a
    -- stepped 0..1 fraction of config.leveling's min/max/step, NOT a separate
    -- knob set). ironfistBonusMax is the bonus at FULL progress (maxLevel,
    -- i.e. the same level effectivenessMaxBonus is reached). ironGripMult is
    -- the Iron Grip perk's (cl>=25) literal "+15% hand-to-hand damage" —
    -- previously only simulated via a Strength bonus; this is its first
    -- direct application, applied to this term specifically (see victim.lua).
    -- Zero footprint without Iron Fist installed: nothing here fires unless
    -- IronFistRuntime is detected present AND enabled.
    brawlerGauntlet = {
        light  = { hhBonus = 2.5, speedDebuff = 0.25, ironfistBonusMax = 1.5 },
        medium = { hhBonus = 5.0, speedDebuff = 0.50, ironfistBonusMax = 3.0 },
        heavy  = { hhBonus = 7.5, speedDebuff = 0.75, ironfistBonusMax = 4.5 },
        -- Defensive floor on the resulting speed multiplier so a re-tune (or a
        -- mod-raised debuff) can never freeze unarmed attacks at 0× speed.
        minSpeedMult = 0.10,
        ironGripMult = 1.15,
    },

    -- ─── SneakIsGoodNow integration (attentiveness + sneak weapon bonus) ──────
    -- When SneakIsGoodNow is active and the player is sneaking, Stance!
    -- contributes two bonus systems:
    --
    -- 1. Attentiveness bonus: scales elusivenessMod (detection difficulty).
    --    Multiplier = 1.0 + (stance_level / 100) * attentivenessPerLevel
    --                       + (sneak_skill / 100) * attentivenessPerSkill
    --    Higher = harder to detect. Applied while player is sneaking.
    --
    -- 2. Weapon skill bonus while sneaking: for stances with
    --    sneakWeaponSkillBonus = true, grants a sneak-active bonus to the
    --    stance's target weapon skill. Scales like the Block bonus:
    --    Bonus = base + (stance_level / 100) * effectivenessMaxBonus
    --    BUT: only while sneaking. When sneak ends, the bonus vanishes.
    --    (Not persisted; pure transient visibility like Fortified/Sneaky prefix.)
    sneak = {
        enabled                 = true,   -- master toggle for sneak integrations
        attentivenessPerLevel   = 0.5,    -- elusiveness multiplier per stance level (e.g., level 100 adds +0.5 to mod)
        attentivenessPerSkill   = 0.3,    -- elusiveness multiplier per sneak skill point (e.g., skill 100 adds +0.3)
        -- Note: weapon skill bonus uses the effectiveness scaling already in
        -- config.leveling (effectivenessMinBonus / effectivenessMaxBonus),
        -- so a single stance level adds 2 points of weapon skill while sneaking
        -- if its sneakWeaponSkillBonus is enabled.
    },

    -- ─── XP source weights ────────────────────────────────────────────────
    -- Each successful action grants this much xp to the ACTIVE stance,
    -- before the global xpMultiplier setting is applied. The core Stance
    -- skill simultaneously receives half of that scaled amount.
    xp = {
        combatHit             = 1.00,
        combatKill            = 2.00,
        spellCast             = 0.80,
        blockSuccess          = 1.20,
        -- Fortifier: earns on N'Garde parries (NOT on landing hits). A perfect
        -- parry is worth more than an ordinary one.
        parrySuccess          = 1.20,  -- a successful parry
        perfectParrySuccess   = 2.40,  -- a perfectly-timed parry
        stanceTimeTick        = 0.10,
        stanceTimeIntervalSec = 10.0,
        meditateTick          = 0.40,
        merchantTransaction   = 1.50,
        -- Reforger: granted whenever the player successfully upgrades a
        -- weapon or piece of armor with the Weapon/Armor Upgrade mods.
        upgradeSuccess        = 4.00,
        upgradeFailure        = 0.50,  -- a failed attempt still teaches you
        -- Pitmen: granted whenever SimplyMining confirms a successful ore
        -- mine while Pitmen is the active stance.
        miningSuccess         = 3.00,  -- digging out a vein is real work
        -- Angler: granted whenever Fishing confirms a successful fish catch
        -- while Angler is the active stance.
        fishingCatch          = 3.00,  -- landing a fish is patient work
        -- Locksmith: granted whenever Oblivion-Style Lockpicking confirms a
        -- successful pick or probe while Locksmith is the active stance.
        lockpickSuccess       = 2.00,  -- a sprung lock is a small triumph
        -- Apothecary: granted whenever a thrown concoction LANDS on an enemy
        -- (a Thrown Concoctions flask is a MarksmanThrown weapon, so a landed
        -- throw is just an ordinary engine hit) while Apothecary is the active
        -- stance. Worth more than a plain melee hit because every throw expends
        -- a concoction, so they are thrown far less often than a reusable weapon
        -- is swung. The unified hit path (victim.lua - Stance_PlayerDealtHit)
        -- credits this in place of combatHit when Apothecary is active.
        concoctionThrowHit    = 2.50,  -- a concoction that finds its mark
        -- Huntsman: granted when Bullseye confirms a successful ranged attack
        -- while Huntsman is the active stance. The XP is scaled by Bullseye's
        -- damage multiplier (headshot, distance, sneak, movement penalties, etc.).
        -- A long-range perfect headshot grants significantly more XP than a
        -- point-blank miss. Base value 1.0 means a 1.0x multiplier hit grants
        -- 1.0 XP; a 2.5x headshot hit grants 2.5 XP.
        rangedSuccess         = 1.00,  -- base ranged attack XP (scaled by Bullseye multiplier)

        -- Move Like This: granted when the player LANDS one of MLT's signature
        -- directional moves that notifies the attacker. MLT fires
        -- 'MLT_DirAttack_criticalHit' on a critical thrust (Long Blade 1H/2H,
        -- Short Blade, Hand-to-Hand) and 'MLT_mobilityBuff' on a mobility slash
        -- (Short Blade / Hand-to-Hand, when that slash effect is selected). Each
        -- credits the ACTIVE stance — which is necessarily the matching weapon
        -- stance — so landing your stance's signature MLT move trains it a touch
        -- faster, on top of the ordinary hit XP. Mirrors the N'Garde parry XP
        -- source. The other MLT effects (cleave, stagger, armor pierce, stomp,
        -- first strike, shield break, blind) do not notify the attacker, so they
        -- have no dedicated XP source; they still scale with the active stance's
        -- weapon skill, which the effectiveness/Sol mastery bonuses raise.
        mltCriticalStrike     = 1.50,  -- a critical thrust found the gap
        mltMobilityStrike     = 0.75,  -- a flowing slash opened the footwork

        -- Muse: granted for performing an idle (Practice) song to completion,
        -- and again whenever a finished song successfully administers an
        -- inspiration buff to its associated stance. See player/muse.lua.
        museSongComplete      = 3.00,  -- a song carried through to its end
        museBuffAdminister    = 2.00,  -- inspiration successfully bestowed

        -- Thief: granted when an enemy is caught by a deployed Trap (the Traps
        -- mod's armed trap, which deals a massive one-shot hit). Credited to the
        -- Thief stance directly — trapping is a thief's craft — regardless of
        -- what the player is wielding when the victim steps on it. One credit
        -- per trap trigger.
        trapHit               = 3.00,  -- an enemy springs your trap

        -- Apothecary: granted while an enemy stands in a BURNING oil pool (the
        -- Oil Flask mod's lit pool, which deals damage over time). Credited to
        -- the Apothecary stance directly. Small per-tick value because the
        -- listener fires repeatedly (about once per second) for as long as the
        -- enemy keeps burning.
        oilBurnTick           = 0.50,  -- an enemy burns in your oil
        -- Commoner: granted when the player starts a conversation with an NPC
        -- while Commoner is the active stance (weapons sheathed). The first
        -- conversation with a given NPC is worth more than later ones, so
        -- grinding the same NPC isn't optimal. Pairs naturally with the
        -- Talking Trains Speechcraft mod (both react to a dialogue opening).
        dialogueTalkFirst     = 1.00,  -- first time speaking to this NPC
        dialogueTalkRepeat    = 0.25,  -- speaking to an NPC already met
        -- Arcanist & Thaumaturge: granted when the Disenchanting mod confirms a
        -- successful disenchant while either stance is active. The amount
        -- scales gently with the enchantment magnitude that was unravelled.
        disenchantBase        = 1.50,  -- flat reward for a successful disenchant
        disenchantPerPoint    = 0.05,  -- bonus per enchant-point of magnitude
        disenchantMaxBonus    = 6.00,  -- cap on the magnitude bonus
        -- Commoner: granted when the Commercium / Fair Trade mod confirms a
        -- barter transaction while Commoner is the active stance. A small flat
        -- reward plus a gentle bonus scaled by the value of the deal.
        commerciumBase        = 1.50,  -- flat reward per transaction
        commerciumPerValue    = 0.002, -- bonus per gold of transaction value
        commerciumMaxBonus    = 4.00,  -- cap on the value bonus
        -- Arcanist & Thaumaturge: granted when the Transcribe mod confirms a
        -- successful spell transcription while either stance is active.
        transcribeSuccess     = 3.00,  -- copying an enchantment into a spell
        -- Forager: granted from the Gardening and Farming mod's own progress.
        -- That mod tracks a single MWScript global (`tribGardner`) that it
        -- raises by +0.1 every time you PLANT a seed (drop it) and by +0.2 every
        -- time you HARVEST a grown plant with the Harvest Hoe or a Scythe. The
        -- global script watches that value and forwards each increase here as a
        -- delta; we credit Forager `delta * gardeningProgressScale` XP. At the
        -- default scale of 15, a planting (+0.1) is worth 1.5 XP and a harvest
        -- (+0.2) is worth 3.0 XP — so harvesting yields twice the XP of planting,
        -- exactly the 1:2 weighting the source mod uses, and a harvest matches a
        -- mined ore / landed fish (3.0). Credited to Forager directly, whatever
        -- you happen to be wielding (you can plant a seed bare-handed), mirroring
        -- the way the source mod levels its Gardening skill on both actions.
        gardeningProgressScale = 15.00,

        -- ── Dualist split penalty ─────────────────────────────────────────
        -- Dualist divides its attention between the right-hand and off-hand
        -- weapon, so its on-hit and on-kill XP is HALVED to simulate that split.
        -- Blocking while in Dualist is likewise worth half (you are juggling two
        -- weapons, not bracing behind a shield). These scale the relevant XP
        -- sources ONLY when Dualist is the active stance.
        dualistHitXpScale   = 0.5,  -- multiplies hit/kill XP while Dualist
        dualistBlockXpScale = 0.5,  -- multiplies block XP while Dualist

        -- ── Locksmith lock-difficulty scaling ─────────────────────────────
        -- A picked or probed lock grants lockpickSuccess (above) as a floor, plus
        -- a bonus proportional to the object's lock/trap difficulty IF Oblivion-
        -- Style Lockpicking reports it in its success event. A stubborn lock is a
        -- bigger triumph than a flimsy one. Degrades gracefully to the flat floor
        -- when no difficulty is reported.
        lockpickPerDifficulty = 0.10,  -- bonus XP per point of lock difficulty
        lockpickMaxBonus      = 6.00,  -- cap on the difficulty bonus
    },

    -- ─── Stance definitions ───────────────────────────────────────────────
    stances = {
        {
            id = 'arcanist',
            displayName = 'Arcanist',
            icon = 'icons/Stance/Arcanist.dds',
            attribute = 'intelligence',
            description = 'The spellcasting posture, favored by the Telvanni and those who study under them. Magicka yields more readily when the mind stills the body and the voice carries the working.',
            integrations = { 'incantation', 'meditation' },
            category = 'magic',
            evasionBonus = 4,   -- Light armor, calm mind; modest dodge
            perks = {
                {
                    level = 25, id = 'focusedChant', name = 'Focused Chant',
                    description = 'The chant finds its economy through repetition — spell costs reduced by 5%.',
                },
                {
                    level = 50, id = 'meditatedMind', name = 'Meditated Mind',
                    description = 'Stillness refills the well within — passive magicka regeneration improved by a quarter.',
                },
                {
                    level = 75, id = 'incantedFocus', name = 'Incanted Focus',
                    description = 'A refined incantation returns more than it takes — custom-spell magicka refunds improved by 10%.',
                },
                {
                    level = 100, id = 'aetherealMind', name = 'Aethereal Mind',
                    description = 'The true adept does not cast spells, but remembers them — spell failure chance halved.',
                },
            },
        },

        {
            id = 'reforger',
            displayName = 'Reforger',
            icon = 'icons/Stance/Reforger.dds',
            attribute = 'endurance',
            description = 'The armorer\'s hammer knows every joint and seam in a cuirass. You carry it as a weapon because you know where it breaks. The forge builds the arms that swing it.',
            integrations = { 'weaponupgrade', 'armorupgrade' },
            category = 'damage',
            evasionBonus = 2,   -- Non-combat posture; minimal dodge
            perks = {
                {
                    level = 25, id = 'anvilArms', name = 'Anvil Arms',
                    description = 'Forge-hardened arms tire slowly — fatigue from hammer swings reduced by 15%.',
                },
                {
                    level = 50, id = 'weakPointStrike', name = 'Weak-Point Strike',
                    description = 'You strike where the rivets thin — hammer blows ignore 10% of the target\'s worn armor.',
                },
                {
                    level = 75, id = 'sunderingBlow', name = 'Sundering Blow',
                    description = 'The armorer\'s eye finds the flaw in the plate — each hammer hit has a chance in ten to damage worn armor.',
                },
                {
                    level = 100, id = 'forgemastersTouch', name = 'Forgemaster\'s Touch',
                    description = 'What the forge tempers, the forge can unmake — hammer damage increased by a quarter, with a better chance to stagger on power attacks.',
                },
            },
        },

        {
            id = 'blademeister',
            displayName = 'Blademeister',
            icon = 'icons/Stance/Blademeister.dds',
            attribute = 'agility',
            description = 'A pact between wielder and blade — the weapon shaped by something older than craft, the hand guided by something stranger than training. The two grow toward one another with each soul the blade drinks.',
            integrations = { 'blademeister' },
            category = 'damage',
            evasionBonus = 8,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Soul-bond sharpens reactions; strong dodge
            perks = {
                {
                    level = 25, id = 'quickeningHunger', name = 'Quickening Hunger',
                    description = 'The blade\'s hunger quickens — Soul Resonance builds 50% faster from hits and kills.',
                },
                {
                    level = 50, id = 'sustainedResonance', name = 'Sustained Resonance',
                    description = 'The pact holds its fire longer — the Resonance meter drains a third more slowly.',
                },
                {
                    level = 75, id = 'tirelessPact', name = 'Tireless Pact',
                    description = 'Felthorn recovers swiftly from its feasting — the Soul Exhaustion cooldown is halved.',
                },
                {
                    level = 100, id = 'endlessResonance', name = 'Endless Resonance',
                    description = 'A soul taken at the height of resonance feeds the surge — a resonant kill refills the meter, and the surge burns stronger.',
                },
            },
        },

        {
            id = 'huntsman',
            displayName = 'Huntsman',
            icon = 'icons/Stance/Huntsman.dds',
            attribute = 'speed',
            description = 'The bow is not a warrior\'s weapon by nature — it is a hunter\'s tool, grown patient on the game trails of the Ashlands and the green forests east of the Velothi Mountains. Speed governs the draw.',
            integrations = { 'bullseye' },
            category = 'ranged',
            evasionBonus = 6,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Ranged discipline; distance is its own dodge
            perks = {
                {
                    level = 25, id = 'steadyAim', name = 'Steady Aim',
                    description = 'The hunter\'s breathing runs slow and sure — fatigue from ranged attacks reduced by 15%.',
                },
                {
                    level = 50, id = 'pinningShot', name = 'Pinning Shot',
                    description = 'Struck game does not flee far — ranged hits briefly slow the target.',
                },
                {
                    level = 75, id = 'concussiveShot', name = 'Concussive Shot',
                    description = 'A blow to the skull scatters the legs — headshots drain 25 fatigue from the target.',
                },
                {
                    level = 100, id = 'killshot', name = 'Killshot',
                    description = 'The well-placed arrow wastes nothing — headshots deal 25% more damage.',
                },
            },
        },

        {
            id = 'twirler',
            displayName = 'Twirler',
            icon = 'icons/Stance/Twirler.dds',
            attribute = 'agility',
            description = 'Thrown steel is a poor substitute for a proper blade — until it is not. Those who practice the spinning release learn that distance and precision together are more dangerous than proximity alone. Agility governs the wrist.',
            integrations = { 'throwing' },
            category = 'ranged',
            evasionBonus = 6,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Agility-governed; mobile and evasive
            perks = {
                {
                    level = 25, id = 'edgedSpin', name = 'Edged Spin',
                    description = 'The spin before release sets the edge — throwing critical chance increased by 3%.',
                },
                {
                    level = 50, id = 'twinnedThrow', name = 'Twinned Throw',
                    description = 'Two blades leave the hand as one — twin-flight chance increased by 5%.',
                },
                {
                    level = 75, id = 'rendingHand', name = 'Rending Hand',
                    description = 'The barbed edge bites and holds — bleed magnitude on thrown hits increased.',
                },
                {
                    level = 100, id = 'whirlwindArm', name = 'Whirlwind Arm',
                    description = 'The arm becomes a wheel, the release its spoke — thrown-weapon paralysis lasts one second longer.',
                },
            },
        },

        {
            id = 'thaumaturge',
            displayName = 'Thaumaturge',
            icon = 'icons/Stance/Thaumaturge.dds',
            attribute = 'willpower',
            description = 'A stave is not a mace with ambitions — it is a conduit, shaped from wood and intention, that bends magicka along the blow. Willpower governs the form, as with all things that bend the unseen to a purpose.',
            integrations = { 'staves' },
            category = 'magic',
            evasionBonus = 4,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Mobile caster; deliberate footwork
            perks = {
                {
                    level = 25, id = 'concussiveAccord', name = 'Concussive Accord',
                    description = 'The blow and the current arrive together — concussive-strike chance increased by 10%.',
                },
                {
                    level = 50, id = 'siphonedAccord', name = 'Siphoned Accord',
                    description = 'What the strike breaks, the conduit drinks — arcane-siphon chance increased by 5%.',
                },
                {
                    level = 75, id = 'resonantAccord', name = 'Resonant Accord',
                    description = 'The stave remembers every working it has channeled — resonant-conduit chance increased by 3%.',
                },
                {
                    level = 100, id = 'pulsedAccord', name = 'Pulsed Accord',
                    description = 'The silence is not absence but pressure — null-pulse silence lasts two seconds longer.',
                },
            },
        },

        {
            id = 'dualist',
            displayName = 'Dualist',
            icon = 'icons/Stance/Dualist.dds',
            attribute = 'speed',
            description = 'Two blades, one mind. The off-hand weapon is not a second chance — it is the first blow\'s completion. Speed is the governing virtue, for a slow dualist is simply outnumbered.',
            integrations = { 'dualwielding' },
            category = 'speed',
            evasionBonus = 8,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Speed-governed dual fighter; mobile and hard to pin
            perks = {
                {
                    level = 25, id = 'lightFootwork', name = 'Light Footwork',
                    description = 'Twin blades, twin commitments; the feet keep pace — movement speed increased by 10% while dual-wielding.',
                },
                {
                    level = 50, id = 'mirrorEdge', name = 'Mirror Edge',
                    description = 'The off-hand echoes what the main hand begins — off-hand strikes deal 15% more damage.',
                },
                {
                    level = 75, id = 'twinTempo', name = 'Twin Tempo',
                    description = 'Matched steel finds a rhythm a single blade cannot — attack speed increased by 15%.',
                },
                {
                    level = 100, id = 'crossGuard', name = 'Cross Guard',
                    description = 'Two blades crossed in time become a wall — you parry as though a shield were held.',
                },
            },
        },

        {
            id = 'zweihander',
            displayName = 'Zweihänder',
            icon = 'icons/Stance/Zweihander.dds',
            attribute = 'strength',
            description = 'A two-handed long blade is not a larger sword — it is a different instrument, governed by different rules. Heavy, unforgiving, and ruinous when it lands. Strength governs it, as it has always governed the things that simply refuse to stop.',
            integrations = {},
            category = 'damage',
            evasionBonus = 3,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Committed two-handed swings; limited footwork
            perks = {
                {
                    level = 25, id = 'twoHandGrip', name = 'Two-Hand Grip',
                    description = 'Both hands behind the steel, and the steel carries it all — two-handed damage increased by 10%.',
                },
                {
                    level = 50, id = 'sweepingArc', name = 'Sweeping Arc',
                    description = 'The wide blade clears the ground it passes — a chance to also strike a second nearby enemy.',
                },
                {
                    level = 75, id = 'cleavingBlow', name = 'Cleaving Blow',
                    description = 'The blow finds the gap beneath the plate — a 10% chance to bypass a portion of armor.',
                },
                {
                    level = 100, id = 'titanGrip', name = 'Titan Grip',
                    description = 'The greatblade becomes part of the arm — two-handed damage increased by a quarter, heavy-weapon drain halved.',
                },
            },
        },

        {
            id = 'guisarmier',
            displayName = 'Guisarmier',
            icon = 'icons/Stance/Guisarmier.dds',
            attribute = 'endurance',
            description = 'The spear\'s virtue is reach — the gap between its point and your body is the argument it makes. The Redoran house-guard tradition has understood this for generations. Endurance governs it, for the spear demands patience as much as strength.',
            integrations = {},
            category = 'damage',
            evasionBonus = 5,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Reach keeps threats at distance; lateral footwork
            perks = {
                {
                    level = 25, id = 'reachAdvantage', name = 'Reach Advantage',
                    description = 'Distance is the spearman\'s first weapon — spear damage increased by 10%.',
                },
                {
                    level = 50, id = 'phalanxBrace', name = 'Phalanx Brace',
                    description = 'A set spear meets the charge before it lands — knockdown resistance increased by a quarter.',
                },
                {
                    level = 75, id = 'pinningThrust', name = 'Pinning Thrust',
                    description = 'The wound in the leg is slow, but it lasts — spear hits may briefly slow the target.',
                },
                {
                    level = 100, id = 'polearmMaster', name = 'Polearm Master',
                    description = 'In trained hands the spear is both fast and final — spear damage increased by a quarter, attack fatigue drain reduced by 20%.',
                },
            },
        },

        {
            id = 'pitmen',
            displayName = 'Pitmen',
            icon = 'icons/Stance/Pitman.dds',
            attribute = 'endurance',
            description = 'The Miner\'s Pick was not made for war — which is exactly what makes it dangerous in the hands of someone who knows its weight. The Pitmen swings it the same way below ground as above. Endurance governs the form.',
            integrations = { 'simplymining' },
            category = 'damage',
            evasionBonus = 2,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Heavy tool, underground work; poor dodge instinct
            perks = {
                {
                    level = 25, id = 'roughHewn', name = 'Rough-Hewn',
                    description = 'The ore-head carries through whatever it meets — pick damage in combat increased by 10%.',
                },
                {
                    level = 50, id = 'veinReader', name = 'Vein Reader',
                    description = 'You read the seam before the first blow falls — mining duration reduced by 20%.',
                },
                {
                    level = 75, id = 'prospector', name = 'Prospector',
                    description = 'A trained eye finds the rich pocket in bare stone — ore-yield chance increased by 15%.',
                },
                {
                    level = 100, id = 'pitboss', name = 'Pit Boss',
                    description = 'The most dangerous thing in the shaft — pick damage increased by a quarter, mining 30% faster.',
                },
            },
        },

        {
            id = 'angler',
            displayName = 'Angler',
            icon = 'icons/Stance/Angler.dds',
            attribute = 'luck',
            description = 'The fishing pole is a weapon the way a healer is a combatant — technically accurate and widely underestimated. Luck governs the Angler, for Vvardenfell\'s waters reward the fortunate cast as much as the practiced one.',
            integrations = { 'fishing' },
            category = 'utility',
            evasionBonus = 3,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Patient and still; calm awareness helps a little
            perks = {
                {
                    level = 25, id = 'steadyGrip', name = 'Steady Grip',
                    description = 'The hands that hold a line taut hold a swing true — fatigue from fishing-pole attacks reduced by 15%.',
                },
                {
                    level = 50, id = 'catchAndRelease', name = 'Catch and Release',
                    description = 'The water gives more than it promised — casts have a 10% chance to yield an extra fish.',
                },
                {
                    level = 75, id = 'trophyCast', name = 'Trophy Cast',
                    description = 'You know where the great ones hide in the deep — fishing skill counts as ten points higher for catch quality.',
                },
                {
                    level = 100, id = 'masterAngler', name = 'Master Angler',
                    description = 'The rod is an extension of will — pole damage increased by a quarter, cast time reduced by 20%.',
                },
            },
        },

        {
            id = 'apothecary',
            displayName = 'Apothecary',
            icon = 'icons/Stance/Apothecary.dds',
            attribute = 'intelligence',
            description = 'A flask is a spell you can hold in your hand, and the Apothecary has decided the most direct delivery is overhand. Governed by Intelligence — the same wit that distills a poison judges the arc that delivers it. Active whenever a Thrown Concoction is readied as a weapon, and boosts Alchemy. Levels only when a hurled concoction finds an enemy. Requires the Thrown Concoctions mod.',
            integrations = { 'thrownconcoctions' },
            category = 'utility',
            evasionBonus = 5,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Range-oriented; keeps enemies at flask distance
            perks = {
                {
                    level = 25, id = 'deftHurler', name = 'Deft Hurler',
                    description = 'The wrist learns what the eye only guesses — Agility raised by 5, steadying every throw.',
                },
                {
                    level = 50, id = 'volatileConcoction', name = 'Volatile Concoction',
                    description = 'You have stopped corking gently — a landed concoction has a one-in-four chance to burst and stagger, draining fatigue.',
                },
                {
                    level = 75, id = 'corrosiveCloud', name = 'Corrosive Cloud',
                    description = 'Residue keeps working long after the glass shatters — every landed concoction leaves a brief caustic cloud.',
                },
                {
                    level = 100, id = 'masterApothecary', name = 'Master Apothecary',
                    description = 'Medicine and murder differ only in dosage — Intelligence and Luck raised by 5, with a small chance to paralyze on a landed hit.',
                },
            },
        },

        {
            id = 'forager',
            displayName = 'Forager',
            icon = 'icons/Stance/Forager.dds',
            attribute = 'intelligence',
            description = 'The garden and the battlefield are the same ground to one who works both. The Forager tends, reaps, and — when the wandering beasts come for the harvest — fights with whatever tool is already in hand. Intelligence governs the craft, as it governs the Gardening it grows from.',
            integrations = {},
            category = 'utility',
            evasionBonus = 3,   -- Patient, watchful work; a fair eye for trouble
            -- The Forager is unique: it carries TWO perk ladders, and the one that
            -- applies is chosen by the TOOL currently in hand (see the resolver's
            -- getActiveForagerSubtype and init.lua's getStancePerks / perks.lua's
            -- subtype-gated effects). Holding a GARDENING tool (Hammer, Shovel,
            -- Shears, Waterskin) shows and applies `perksGardening`; holding a
            -- HARVESTING tool (Harvest Hoe / Scythe or a combat Farming Scythe)
            -- shows and applies `perksHarvesting`. Both ladders unlock off the same
            -- shared core Stance skill level (25/50/75/100). There is intentionally
            -- no plain `perks` field — every consumer routes through getStancePerks.
            perksGardening = {
                {
                    level = 25, id = 'greenThumb', name = 'Green Thumb',
                    description = 'Each plant\'s virtue feeds the alchemist\'s craft — Alchemy raised by 5.',
                },
                {
                    level = 50, id = 'cultivatorsPatience', name = "Cultivator's Patience",
                    description = 'Tending growth teaches the long view; the mind sharpens with every turning season. Intelligence increased by five.',
                },
                {
                    level = 75, id = 'rootedEndurance', name = 'Rooted Endurance',
                    description = 'Days bent to the soil harden the back — Endurance raised by 5.',
                },
                {
                    level = 100, id = 'masterGardener', name = 'Master Gardener',
                    description = 'The garden answers a master\'s hand — Intelligence and Alchemy each raised by a further 5.',
                },
            },
            perksHarvesting = {
                {
                    level = 25, id = 'reapersGrip', name = "Reaper's Grip",
                    description = 'The scythe is swung the same whether the stalk is wheat or throat. Strength increased by five.',
                },
                {
                    level = 50, id = 'sweepingCut', name = 'Sweeping Cut',
                    description = 'The harvest stroke runs wide and unbroken — Agility raised by 5.',
                },
                {
                    level = 75, id = 'bountifulHands', name = 'Bountiful Hands',
                    description = 'The seasoned reaper\'s hands find more in every swing — Luck raised by 5.',
                },
                {
                    level = 100, id = 'masterHarvester', name = 'Master Harvester',
                    description = 'Whatever the field yields, you take all of it — Strength and Agility each raised by a further 5.',
                },
            },
        },

        {
            id = 'axeman',
            displayName = 'Axeman',
            icon = 'icons/Stance/Axeman.dds',
            attribute = 'strength',
            description = 'An axe asks only one question and accepts only one answer. No governing attribute was ever more honestly earned by the weapon that demanded it. Governed by Strength.',
            integrations = {},
            category = 'damage',
            evasionBonus = 3,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Heavy, strength-governed; evasion is not its strength
            perks = {
                {
                    level = 25, id = 'cleavingEdge', name = 'Cleaving Edge',
                    description = 'The axe does not negotiate — axe damage increased by 10%.',
                },
                {
                    level = 50, id = 'heavyChop', name = 'Heavy Chop',
                    description = 'The full weight of the swing, committed without reservation — axe power attacks deal 20% more.',
                },
                {
                    level = 75, id = 'bleedingCut', name = 'Bleeding Cut',
                    description = 'An axe leaves no clean wound — axe hits cause a bleed, draining health for five seconds.',
                },
                {
                    level = 100, id = 'headsman', name = 'Headsman',
                    description = 'The executioner\'s art is precision, not savagery — axe damage increased by a quarter, with a chance to bypass a portion of armor.',
                },
            },
        },

        {
            id = 'mjolnir',
            displayName = 'Mjolnir',
            icon = 'icons/Stance/Mjolnir.dds',
            attribute = 'strength',
            description = 'Maces, clubs, warhammers, mauls — instruments of reduction. What they strike, they simplify. Strength governs the stance without argument. Staves are a different tradition entirely and are not welcome here.',
            integrations = {},
            category = 'damage',
            evasionBonus = 2,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Heaviest weapons; slow, committed stance
            perks = {
                {
                    level = 25, id = 'ironHeft', name = 'Iron Heft',
                    description = 'The weapon\'s mass is its argument — blunt damage increased by 10%.',
                },
                {
                    level = 50, id = 'crushingBlow', name = 'Crushing Blow',
                    description = 'Everything behind a single committed swing — blunt power attacks deal 20% more.',
                },
                {
                    level = 75, id = 'concussiveForce', name = 'Concussive Force',
                    description = 'A firm blow to the skull disorients — blunt hits have a 10% chance to stagger.',
                },
                {
                    level = 100, id = 'thunderstrike', name = 'Thunderstrike',
                    description = 'What stands against it does not stand long — blunt damage increased by a quarter, with a chance to bypass a portion of armor.',
                },
            },
        },

        {
            id = 'soloist',
            displayName = 'Soloist',
            icon = 'icons/Stance/Soloist.dds',
            attribute = 'endurance',
            description = 'A long blade in one hand, no shield — a deliberate choice, not a deficiency. The empty off-hand is the statement. Endurance governs the form, for the fighter who carries only a blade cannot afford to tire.',
            integrations = {},
            category = 'damage',
            evasionBonus = 5,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking   -- Mobile single-weapon fighter; free hand aids balance
            perks = {
                {
                    level = 25, id = 'plantedFeet', name = 'Planted Feet',
                    description = 'Weight unspread cannot be easily toppled — knockdown resistance increased by 25%.',
                },
                {
                    level = 50, id = 'heavyHand', name = 'Heavy Hand',
                    description = 'A blade\'s weight focused through one arm carries far — power attacks deal 15% more damage.',
                },
                {
                    level = 75, id = 'unstoppable', name = 'Unstoppable',
                    description = 'There is a quality in the unhurried swing that unsettles — hits have a 10% chance to stagger.',
                },
                {
                    level = 100, id = 'solitaryWill', name = 'Solitary Will',
                    description = 'The body learns what the stance demands — effective Endurance raised by 15.',
                },
            },
        },

        {
            id = 'thief',
            displayName = 'Thief',
            icon = 'icons/Stance/Thief.dds',
            attribute = 'speed',
            description = 'A short blade was never meant for dueling — it was meant to end the matter before a duel could begin. Speed governs the form, as the Morag Tong have always understood.',
            integrations = {},
            category = 'speed',
            evasionBonus = 10,
            sneakWeaponSkillBonus = true,  -- weapon skill bonus while sneaking  -- Speed + short blade; the most evasive melee stance
            perks = {
                {
                    level = 25, id = 'quickStrike', name = 'Quick Strike',
                    description = 'The short blade\'s virtue is that it arrives first — attack speed increased by 10%.',
                },
                {
                    level = 50, id = 'cutpurse', name = 'Cutpurse',
                    description = 'Light feet matter as much as a light hand — effective Sneak raised by 5.',
                },
                {
                    level = 75, id = 'backstab', name = 'Backstab',
                    description = 'The surest mark is the one not yet turned — hits from behind deal 25% more damage.',
                },
                {
                    level = 100, id = 'masterThief', name = 'Master Thief',
                    description = 'The blade and the shadow share one master — short-blade damage increased by a quarter, movement improved by 10%.',
                },
            },
        },

        {
            id = 'locksmith',
            displayName = 'Locksmith',
            icon = 'icons/Stance/Locksmith.dds',
            attribute = 'agility',
            description = 'Tools in the pouch, eyes on the keyhole — the posture of one who does not expect trouble but has not forgotten how to make it. Agility governs the form, as it governs the Security skill these tools serve.',
            integrations = {},
            category = 'utility',
            evasionBonus = 6,   -- Agility-governed; light-footed and always watching exits
            perks = {
                {
                    level = 25, id = 'lightFingers', name = 'Light Fingers',
                    description = 'Hands that have learned patience work the tumblers surely — effective Security raised by 5.',
                },
                {
                    level = 50, id = 'probeSage', name = 'Probe Sage',
                    description = 'The probe is a conversation with the lock, not a demand — probes are 10% less likely to break.',
                },
                {
                    level = 75, id = 'sneakStep', name = 'Sneak Step',
                    description = 'A locksmith who is heard is no locksmith at all — effective Sneak raised by 5.',
                },
                {
                    level = 100, id = 'masterOfLocks', name = 'Master of Locks',
                    description = 'The worst locks are only stubborn, never impossible — lock difficulty counts as fifteen points lower.',
                },
            },
        },

        {
            id = 'brawler',
            displayName = 'Brawler',
            icon = 'icons/Stance/Brawler.dds',
            attribute = 'strength',
            description = 'The fist is the oldest weapon — always carried, never confiscated, never broken. Strength governs it, as it has since before blades had names.',
            integrations = { 'gothicknockout', 'ironfist' },
            category = 'fatigue',
            evasionBonus = 5,   -- Weave and bob; unarmed fighters learn to slip punches
            perks = {
                {
                    level = 25, id = 'ironGrip', name = 'Iron Grip',
                    description = 'The hand that grips becomes its own weapon — hand-to-hand damage increased by 15%.',
                },
                {
                    level = 50, id = 'closeRangeFighter', name = 'Close-Range Fighter',
                    description = 'Fighting bare-handed costs less when you know how — unarmed fatigue drain reduced by a quarter.',
                },
                {
                    level = 75, id = 'concussiveJab', name = 'Concussive Jab',
                    description = 'The jaw is architecture, and a proper blow unmakes it — unarmed hits knock down more readily.',
                },
                {
                    level = 100, id = 'streetMaster', name = 'Street Master',
                    description = 'Each strike takes back what the body gives — unarmed hits briefly restore fatigue.',
                },
            },
        },

        {
            id = 'commoner',
            displayName = 'Commoner',
            icon = 'icons/Stance/Commoner.dds',
            attribute = 'luck',
            description = 'Weapons sheathed, fists still — the posture of commerce and conversation, of gates passed without incident and prices reduced by patience. Luck is its virtue, the diplomat\'s constant companion.',
            integrations = {},
            category = 'social',
            evasionBonus = 4,   -- Civilian awareness; knowing when not to be in the way
            perks = {
                {
                    level = 25, id = 'merchantsEye', name = "Merchant's Eye",
                    description = 'A Luck-touched gaze sees the margin in every trade. Mercantile checks benefit from a small Luck-based bonus.',
                },
                {
                    level = 50, id = 'silverTongue', name = 'Silver Tongue',
                    description = 'The voice carries more than its words — Speechcraft effectiveness increased by 10%.',
                },
                {
                    level = 75, id = 'urbanCharm', name = 'Urban Charm',
                    description = 'Admiration lands differently in practiced hands — greater disposition gains from a successful Admire.',
                },
                {
                    level = 100, id = 'thePeoplesHero', name = "The People's Hero",
                    description = 'The city knows your name for the right reasons. Barter prices improve and disposition recovers more quickly between conversations.',
                },
            },
        },
        {
            id = 'muse',
            displayName = 'Muse',
            icon = 'icons/Stance/Muse.dds',
            attribute = 'personality',
            description = 'Not a fighting form at all, but the open, listening posture of the performer mid-song. The Muse stance takes hold only while you play idly for yourself; carry a tune to its end and its inspiration settles on whatever discipline the song speaks to. Personality is its virtue — the bard\'s gift for moving others, and oneself.',
            integrations = { 'bardcraft' },
            category = 'support',
            -- No effectiveness target (Muse buffs OTHER stances, not a weapon
            -- skill of its own) and no evasion bonus; it is a non-combat stance.
            evasionBonus = 0,
            -- Muse perks augment the song-buff mechanic itself rather than a
            -- weapon skill. They are read by player/muse.lua (gated on the CORE
            -- Stance level like every other ladder) to scale the inspiration
            -- economy: cheaper notes, broader reach, longer windows, and a
            -- capstone that rewards the player's own composed songs.
            perks = {
                {
                    level = 25, id = 'easyBreath', name = 'Easy Breath',
                    description = 'A practiced player wastes no wind — fatigue drained per note while performing reduced by a third.',
                },
                {
                    level = 50, id = 'sharedRefrain', name = 'Shared Refrain',
                    description = 'A great melody lifts more than one craft — a finished song also inspires a kindred stance at half strength.',
                },
                {
                    level = 75, id = 'lingeringChord', name = 'Lingering Chord',
                    description = 'The best songs are slow to fade — inspiration windows last a quarter longer.',
                },
                {
                    level = 100, id = 'ownComposition', name = "Composer's Voice",
                    description = 'What you author, you command. A song of your own composition inspires at full magnitude regardless of length, and its window is never cut short by the level gate.',
                },
            },
        },
    },

    -- ─── Integration / external mod detection ─────────────────────────────
    -- Detection probes in order of preference:
    --   1) Skill Framework skill registered with `skillId` below
    --   2) Global storage section `storageSection` is non-empty
    --   3) Settings group `settingsGroup` is non-empty (used by mods that
    --      don't expose a SF skill but do register a settings page)
    --   4) Public event listed in `event` has fired recently
    integrations = {
        toxicology = {
            label = 'Toxicology!',
            skillId = 'toxicology',
            storageSection = 'Runtime_Toxicology',
        },
        throwing = {
            label = 'Throwing!',
            skillId = 'throwing',
            storageSection = 'Runtime_Throwing',
        },
        staves = {
            label = 'Staves!',
            skillId = 'staves_staves',
            storageSection = 'Runtime_Staves',
        },
        meditation = {
            label = 'Meditation Skill',
            skillId = 'meditation_skill',
        },
        incantation = {
            label = 'Incantation',
            skillId = 'incantation_skill',
        },
        bullseye = {
            label = 'Bullseye',
            settingsGroup = 'SettingsBullseye',
        },
        ngarde = {
            label = "N'Garde",
            -- Detected via N'Garde's persistent parry settings group (the event
            -- only fires mid-combat, so a settings-group probe is more reliable
            -- for presence). Fortifier's parry XP listens for the player-side
            -- 'ngarde_parrySelf' event, which carries the isPerfect flag.
            settingsGroup = 'Settings_NGarde_parrySettingsGroupKey',
            event = 'ngarde_parrySelf',
        },
        dualwielding = {
            label = 'Dual Wielding',
            event = 'EquipSecondWeapon',
            settingsGroup = 'DualWieldingscontrols',
        },
        gothicknockout = {
            label = 'Gothic Style Knockout',
            settingsGroup = 'SettingsGKD',
            event = 'GKD_DoKnockdown',
        },
        weaponupgrade = {
            label = 'WeaponUpgrade',
            settingsGroup = 'SettingsWeaponUpgrade',
        },
        armorupgrade = {
            label = 'ArmorUpgrade',
            settingsGroup = 'SettingsArmorUpgrade',
        },
        grip = {
            label = 'GRIP',
            -- GRIP doesn't register a Skill Framework skill or fire a
            -- detectable global event during normal play. Its canonical
            -- signal is the 'GRIPRecords' global storage section, which
            -- the mod always writes during onInit even before the player
            -- swaps any weapon. (WeaponUpgrade uses the same probe.)
            storageSection = 'GRIPRecords',
        },
        ironfist = {
            label = 'Iron Fist',
            -- Iron Fist for OpenMW mirrors its settings page into the
            -- 'IronFistRuntime' global storage section on every menu init,
            -- populated with defaults even if the player never opens its
            -- settings page — the same always-written-early signal grip
            -- uses for 'GRIPRecords'. Consumed by victim.lua (NOT by this
            -- player script) for the Brawler unarmed-damage amplification;
            -- see config.brawlerGauntlet's ironfistBonusMax/ironGripMult.
            storageSection = 'IronFistRuntime',
        },
        simplymining = {
            label = 'Simply Mining',
            -- Simply Mining registers a SkillFramework skill called
            -- 'mining_skill'. Detecting that skill confirms the mod is
            -- present. The Pitmen stance then listens for the player event
            -- 'SimplyMining_notifyItem' (fired on every successful ore mine)
            -- to grant mining XP and to gate the Vein Reader / Prospector /
            -- Pit Boss perks.
            skillId = 'mining_skill',
        },
        fishing = {
            label = 'Fishing',
            -- The Fishing mod registers a Skill Framework skill called
            -- 'fishing_skill'. Detecting that skill confirms the base mod
            -- is present. The Angler stance listens for 'Fishing_playerCaughtFish'
            -- (fired whenever the player successfully lands a fish) to grant
            -- fishing XP and to gate the Catch and Release / Trophy Cast /
            -- Master Angler perks.
            --
            -- NOTE: If your version of the Fishing mod fires a different
            -- event name (e.g. 'Fishing_CaughtFish', 'Fishing_notifyItem'),
            -- update the eventHandlers entry in init.lua to match.
            skillId = 'fishing_skill',
        },
        thrownconcoctions = {
            label = 'Thrown Concoctions',
            -- Thrown Concoctions is a pure-content .esp: it adds 17
            -- MarksmanThrown "concoction" weapons (each carrying a
            -- cast-when-strikes enchantment) plus a storage container, and
            -- ships NO Lua, scripts, globals, settings group, or events. There
            -- is therefore nothing event- or storage-based to probe. Presence
            -- is detected by the existence of one of its weapon records — the
            -- sentinel `concoction_base` (the un-enchanted template flask that
            -- is always present when the plugin is loaded). See detectIntegration's
            -- weaponRecordId branch in init.lua.
            --
            -- The Apothecary stance is active whenever one of these concoction
            -- records is equipped in the right hand (resolver isApothecaryWeapon
            -- branch, which sits just above the generic Twirler thrown-weapon
            -- branch so concoctions route to Apothecary rather than Twirler).
            -- A landed concoction is an ordinary engine hit, so XP and the
            -- on-hit perk effects flow through the same victim-side combat
            -- bridge (victim.lua - Stance_PlayerDealtHit) every other weapon
            -- stance uses; no dedicated patch or event is required.
            weaponRecordId = 'concoction_base',
        },

        veneficvials = {
            label = 'Venefic Vials',
            -- Venefic Vials is a pure-content .esp (by Arcimaestro Antares). It
            -- ships a deployable MISC vial plus a THROWN weapon variant
            -- ('vv_vial_th', a MarksmanThrown flask with a cast-on-strike venom
            -- enchantment). Only the thrown variant is an equippable weapon, so
            -- that is what the Apothecary stance keys off — exactly like the
            -- Thrown Concoctions integration. Presence is the existence of the
            -- 'vv_vial_th' weapon record. The deployable MISC vial is NOT a
            -- weapon and is not stance-detectable (see traps/oilflask below for
            -- how the deployable mods from the same author are handled instead).
            weaponRecordId = 'vv_vial_th',
        },

        traps = {
            label = 'Traps',
            -- Traps (by Arcimaestro Antares) is a pure-content .esp with no Lua.
            -- A trap is a deployable MISC item that, once armed, becomes the
            -- 'trap_open' ACTIVATOR and deals a massive one-shot hit (an MWScript
            -- HurtStandingActor) to whoever stands on it. A deployable is never
            -- equipped, so there is no weapon stance to enter; instead a small
            -- listener (scripts/stance/hazard.lua, attached to ACTIVATOR objects)
            -- watches the armed trap and, when a non-player actor is caught,
            -- fires Stance_HazardHit so the player script can credit the Thief
            -- stance. Presence is the existence of the 'trap_open' record.
            activatorRecordId = 'trap_open',
        },

        oilflask = {
            label = 'Oil Flask',
            -- Oil Flask (by Arcimaestro Antares) is a pure-content .esp with no
            -- Lua. A flask is a deployable MISC item; broken on the ground it
            -- becomes the 'oil_pool' ACTIVATOR, and once IGNITED with a torch it
            -- spawns an 'oil_fire' LIGHT and deals fire damage over time
            -- (HurtStandingActor) to actors standing in it. The hazard listener
            -- (scripts/stance/hazard.lua) attaches to the 'oil_fire' LIGHT —
            -- whose mere existence means the pool is burning — and credits the
            -- Apothecary stance while a non-player actor stands in the fire.
            -- This is why crediting requires the fire to be lit, matching
            -- "burned specifically from the oil flasks". Presence is the
            -- existence of the 'oil_pool' record.
            activatorRecordId = 'oil_pool',
        },

        spellsword = {
            label = 'Spellsword',
            -- Spellsword (Imbule Weapon) is a pure-Lua mod: the player imbues
            -- their weapon with an element, and every strike applies that
            -- element. It owns the imbue effect entirely; this integration only
            -- READS Spellsword's authoritative imbue state (the global storage
            -- section 'IW_ActiveSpell', key 'activeSpell') to prepend a purely
            -- cosmetic element prefix to the active stance name — Blazed (fire),
            -- Frozen (frost), Electrified (shock) — in the HUD indicator and the
            -- skill tooltip, for stances that wield an imbuable weapon. No XP,
            -- perks, resolver behaviour, or events are involved. Presence is the
            -- existence of Spellsword's default 'spellsword_fire' imbue spell
            -- record (always defined when the mod is loaded).
            spellRecordId = 'spellsword_fire',
        },
        oblivionlockpicking = {
            label = 'Oblivion-Style Lockpicking',
            -- OSL has no Skill Framework skill of its own; it overrides the
            -- vanilla lockpicking minigame. It registers a settings group and,
            -- on every successful pick/probe, fires the GLOBAL event
            -- 'OSL_LockpickSuccess' { player, target, probe }. Stance's global
            -- script relays that to the player as 'Stance_LockpickSuccess',
            -- which the Locksmith stance uses to grant lockpick XP.
            settingsGroup = 'Settings/OblivionLockpicking/3_GlobalOptions',
            event = 'OSL_LockpickSuccess',
        },
        talkingtrains = {
            label = 'Talking Trains Speechcraft',
            -- Talking Trains grants vanilla Speechcraft progress when a dialogue
            -- opens. It fires no event, so its presence is detected via its
            -- settings group. Stance's Commoner talking-XP source does not
            -- depend on this mod (it reacts to the engine UiModeChanged signal
            -- directly), but detecting it lets the integration be shown and
            -- toggled, and documents the pairing.
            settingsGroup = 'SettingsTalkingTrainsSpeech',
        },
        disenchanting = {
            label = 'Disenchanting',
            -- The Disenchanting mod fires the player event
            -- 'disenchanting_finishedDisenchanting' { enchPoints, effects, ... }
            -- on every SUCCESSFUL disenchant. Arcanist and Thaumaturge earn XP
            -- from it. Detected via the mod's skill-progression settings group.
            settingsGroup = 'SettingsDisenchantingSkill Progression',
            event = 'disenchanting_finishedDisenchanting',
        },
        evasion = {
            label = 'Evasion!',
            -- Evasion! registers a player-settings section called
            -- 'Settings_Evasion'. Detecting that section confirms the mod is
            -- present. When detected, Stance! surfaces the evasion bonus in
            -- the tooltip with an "Evasion!" attribution label. The bonus
            -- itself (flat Sanctuary) is applied unconditionally via the same
            -- activeEffects:modify delta-accounting pattern Evasion! uses
            -- internally — the two contributions track separate deltas and
            -- never interfere with each other.
            settingsGroup = 'Settings_Evasion',
        },
        commercium = {
            label = 'Commercium / Fair Trade',
            -- Commercium fires the GLOBAL event 'FairTrade_Transaction'
            -- { absValue, isBuying, merchant, ... } on each barter deal. Stance's
            -- global script relays it to the player as
            -- 'Stance_CommerciumTransaction', which the Commoner stance uses to
            -- grant trade XP. Detected via its player settings group.
            settingsGroup = 'SettingsPlayerFairTrade',
            event = 'FairTrade_Transaction',
        },
        transcribe = {
            label = 'Transcribe',
            -- Transcribe fires the GLOBAL event 'TRAN_doTranscribe'
            -- { actor, item, enchantid, ... } when the player commits a spell
            -- transcription (the global handler always completes it). Stance's
            -- global script relays it to the player as
            -- 'Stance_TranscribeSuccess' for Arcanist/Thaumaturge XP. We use the
            -- request event (not TRAN_createUI, which also fires on menu open).
            settingsGroup = 'Settings_Transcription',
            event = 'TRAN_doTranscribe',
        },
        blademeister = {
            label = 'Blademeister',
            -- Blademeister has no Skill Framework skill, no global storage
            -- section, no public event hookups. Its presence is detected
            -- indirectly: when the player equips any weapon whose record
            -- id starts with the `sd_` prefix, the mod is necessarily
            -- loaded (the engine couldn't have spawned that record
            -- otherwise). So integration presence is checked by
            -- consulting types.Weapon.records for at least one record
            -- whose id starts with `sd_`. See init.lua's detectIntegration.
            recordIdPrefix = 'sd_',
        },
        soltimeddirattacks = {
            label = "Sol's Timed Directional Attacks",
            -- STDA (by Solthas) is a pure-Lua PLAYER-scope mod that fires no
            -- public event — it runs entirely off per-frame input polling and
            -- applies its own transient stat modifiers. Its canonical presence
            -- signal is its permanent player settings section
            -- 'Settings_SolTimedDirAttacks', which is written when the mod
            -- registers its settings group. Stance! READS that section's
            -- 'buffBase' value to size the per-stance "timed directional attack"
            -- mastery bonus (see player/sol_attacks.lua + config.solAffinity);
            -- it never writes to STDA's data and does not require it to be
            -- present (the bonus is simply absent when STDA is not installed).
            settingsGroup = 'Settings_SolTimedDirAttacks',
        },
        solweightychargeattacks = {
            label = "Sol's Weighty Charged Attacks",
            -- SWCA (by Solthas), like STDA, is a pure-Lua PLAYER-scope mod with
            -- no public event — it polls input per frame and applies its own
            -- transient modifiers. Presence is detected via its permanent player
            -- settings section 'Settings_SolWeightyChargeAttacks'. Stance! READS
            -- that section's 'buffBase' and 'maxCharge' values to size the
            -- per-stance "weighty charged attack" mastery bonus, which also
            -- scales with the equipped weapon's weight via SWCA's own
            -- release-buff formula (see player/sol_attacks.lua). Read-only; not
            -- required; never written to.
            settingsGroup = 'Settings_SolWeightyChargeAttacks',
        },
        movelikethis = {
            label = 'Move Like This',
            -- Move Like This (by GlDanik) adds vanilla-inspired per-weapon-type
            -- directional-attack mechanics (Cleave, Critical, Stagger, Armor
            -- Pierce, Stomp, First Strike, Shield Break, Mobility/Blind) keyed to
            -- the equipped weapon type and the chop/slash/thrust direction. It
            -- registers its settings group from a GLOBAL script, so presence is
            -- detected via the 'Settings_MoveLikeThis' section (detectIntegration
            -- probes both player and global storage). Stance! integrates two
            -- ways, both read-only and non-invasive:
            --   1) XP: it listens for the two attacker-notified MLT events
            --      ('MLT_DirAttack_criticalHit', 'MLT_mobilityBuff') and credits
            --      the active stance when the player lands that signature move.
            --   2) Tooltip: each melee stance's signature MLT directional
            --      move(s) are surfaced in the stance tooltip (see
            --      config.mltSignature), and noted to grow with the stance's
            --      weapon-skill mastery (MLT's crit/stagger/mobility/blind/cleave
            --      math all scale with the attacker's weapon skill, which the
            --      effectiveness + Sol mastery bonuses raise). Stance never
            --      re-applies or modifies MLT's effects.
            settingsGroup = 'Settings_MoveLikeThis',
        },
        bardcraft = {
            label = 'Bardcraft',
            -- Bardcraft registers a Skill Framework skill, 'bardcraft', so its
            -- presence is detected the clean way — via getSkillRecord (see
            -- detectIntegration's skillId branch). Powers the Muse stance: idle
            -- (Practice) performances activate Muse, and finishing a song grants
            -- a timed inspiration buff to the stance the song is associated with.
            -- Read-only with respect to Bardcraft (we only listen to its events).
            skillId = 'bardcraft',
        },
    },

    -- ─── Sol combat-mod integration tuning ────────────────────────────────
    -- Cap on the weapon weight used when sizing the Weighty Charged Attacks
    -- (SWCA) mastery bonus, so an absurdly heavy modded weapon can't drive a
    -- runaway bonus. Mirrors the spirit of SWCA's own weight scaling while
    -- keeping the integration bounded. (A 30-weight weapon already yields a
    -- (1 + sqrt(30)) ≈ 6.5× factor.)
    solWeapWeightCap = 30,

    -- Per-stance affinities for the two Sol combat mods. A stance listed here
    -- earns a passive bonus to its OWN weapon skill — scaled by the stance's
    -- level (0 at startLevel - full ceiling at maxLevel) and ceilinged from the
    -- relevant Sol mod's OWN live settings — while that Sol mod is present and
    -- the stance is active. See player/sol_attacks.lua for the full mechanic.
    --
    -- The split is curated for immersion:
    --   • TIMED   (STDA) — nimble, tempo-driven, finesse stances whose
    --     fighting style lives on well-timed directional attacks. `dir` names
    --     the signature directional attack (Chop / Slash / Thrust), shown in
    --     the tooltip; `weight` scales the ceiling relative to STDA.buffBase.
    --   • WEIGHTY (SWCA) — heavy, committed, power stances whose signature is
    --     the charged, weighty strike. `sig` names the signature blow, shown in
    --     the tooltip; `weight` scales the ceiling relative to SWCA's
    --     weight/charge-derived release buff.
    -- A weapon that can be played either way (greatswords, axes, spears,
    -- one-handed long blades) appears under BOTH, weighted toward its dominant
    -- character. Tool / activity / caster stances (Pitmen, Angler, Arcanist, …)
    -- have no affinity — they don't make timed or weighty melee strikes.
    --
    -- Only stances whose target skill resolves to a VANILLA weapon skill are
    -- listed (the bonus is delivered through the native skill `.modifier` path);
    -- modded-skill stances are intentionally omitted.
    solAffinity = {
        -- Finesse / tempo (TIMED-leaning)
        thief        = { timed = { dir = 'Slash',  weight = 1.0 } },                                 -- short blades live on tempo and the drawing cut
        soloist      = { timed = { dir = 'Slash',  weight = 1.0 }, weighty = { sig = 'Power Thrust', weight = 0.6 } }, -- the duelist's measured cut, with the occasional committed lunge
        dualist      = { timed = { dir = 'Slash',  weight = 1.0 } },                                 -- a cadence of crossing cuts from both hands
        guisarmier   = { timed = { dir = 'Thrust', weight = 1.0 }, weighty = { sig = 'Set Spear',   weight = 0.7 } }, -- the spear's reach-lunge; a braced couch when committed
        blademeister = { timed = { dir = 'Slash',  weight = 0.9 } },                                 -- Felthorn flows with its wielder's rhythm
        -- Power / weight (WEIGHTY-leaning)
        mjolnir      = { weighty = { sig = 'Smite',  weight = 1.0 }, timed = { dir = 'Chop', weight = 0.6 } }, -- the hammer IS the weighty charged blow
        zweihander   = { weighty = { sig = 'Cleave', weight = 1.0 }, timed = { dir = 'Chop', weight = 0.6 } }, -- the greatsword's defining wind-up arc
        axeman       = { weighty = { sig = 'Cleave', weight = 0.9 }, timed = { dir = 'Chop', weight = 0.8 } }, -- the overhand cleave, timed or charged
        reforger     = { weighty = { sig = 'Forge Blow', weight = 0.8 } },                           -- the smith's full-shoulder hammer swing
        -- Unarmed (TIMED only — fists chain on rhythm, not weight)
        brawler      = { timed = { dir = 'Chop', weight = 0.8 } },
    },

    -- ─── Move Like This — per-stance signature directional moves ──────────
    -- Move Like This gives each weapon type distinct chop/slash/thrust effects.
    -- This table names, per melee stance, the signature move(s) that mod grants
    -- the stance's weapon — surfaced in the stance tooltip when Move Like This
    -- is present, so the player can read what makes the stance distinct in
    -- combat. Purely descriptive: Stance does not re-apply or alter MLT's
    -- effects (it only credits XP on the two MLT events that notify the
    -- attacker — see config.xp.mltCriticalStrike / mltMobilityStrike). MLT's
    -- crit / stagger / mobility / blind / cleave math all scale with the
    -- attacker's weapon skill, so the active stance's effectiveness + Sol
    -- mastery bonuses (which raise that weapon skill) already sharpen these
    -- moves as the stance levels — hence the `scales` note shown in the tooltip.
    --
    -- Only stances tied to a FIXED melee weapon type are listed. Dualist and
    -- Blademeister wield a varying 1H/typed weapon, so their MLT effects follow
    -- whatever form is in hand (noted generically). Ranged/thrown/tool/caster
    -- stances get no MLT directional effects and are omitted.
    --   `moves`  — short label of the signature directional effect(s)
    --   `xp`     — true if the stance can earn the MLT signature-move XP source
    --              (i.e. its weapon can trigger a critical thrust or mobility slash)
    mltSignature = {
        soloist      = { moves = 'Thrust - Critical / Slash - Cleave',                 xp = true },
        zweihander   = { moves = 'Thrust - Critical / Slash - Cleave',                 xp = true },
        thief        = { moves = 'Thrust - Critical / Slash - Mobility / Blind / Cleave', xp = true },
        brawler      = { moves = 'Thrust - Critical / Slash - Mobility / Blind / Chop - Stomp', xp = true },
        mjolnir      = { moves = 'Thrust - Stagger / Slash - Armor Pierce / Cleave',    xp = false },
        axeman       = { moves = 'Chop - Shield Break / Slash - Cleave',                xp = false },
        guisarmier   = { moves = 'Thrust - First Strike / Slash - Cleave',              xp = false },
        thaumaturge  = { moves = 'Chop - Stomp / Slash - Cleave / Thrust - Stagger / Fatigue damage', xp = false },
        dualist      = { moves = 'Varies with your primary weapon',                     xp = true },
        blademeister = { moves = 'Varies with Felthorn\'s current form',                xp = true },
    },

    -- ─── Muse stance / Bardcraft tuning ───────────────────────────────────
    -- The Muse stance is active only while performing a song IDLY (a Bardcraft
    -- Practice performance). Finishing a song grants a timed "inspiration" buff
    -- (an additive weapon-skill bonus) to the stance the song is associated
    -- with. See player/muse.lua for the full mechanic.
    muse = {
        -- Bardcraft PerformanceType values that count as "idle" play and
        -- activate Muse. Practice (3) = playing for yourself, no venue/crowd.
        -- (Perform=0, Tavern=1, Street=2, Practice=3, Ambient=4, NPCTeaching=5.)
        idlePerfTypes = { [3] = true },

        -- Buff-timer economy: each successful note adds time, each fumbled note
        -- subtracts it; the total (clamped >= 0) becomes the buff duration.
        successSeconds = 2.0,   -- buff seconds gained per successful note
        failSeconds    = 1.0,   -- buff seconds lost per fumbled note
        -- Fatigue drained per note played (success vs fumble).
        successFatigue = 2,
        failFatigue    = 1,

        -- ── Buff duration: gated to Muse stance level (EXTENDED) ───────────
        -- The note-ledger time is multiplied by buffDurationScale, then capped by
        -- a window that grows with the MUSE stance's level: gateBaseSeconds at
        -- gateAtLevel, +gateAddSeconds every gatePerLevels Muse levels. Extended
        -- so inspiration lingers noticeably longer than before.
        --   Muse lv 5  - up to 20s
        --   Muse lv 15 - up to 35s
        --   Muse lv 25 - up to 50s ...
        buffDurationScale = 1.0,
        gateBaseSeconds   = 20,
        gateAtLevel       = 5,
        gatePerLevels     = 10,
        gateAddSeconds    = 15,

        -- 'Shared Refrain' (Muse perk, lv 50): a finished song also inspires a
        -- second, KINDRED stance at half magnitude. This maps each inspirable
        -- stance to its kin (same weapon family / role). Bidirectional; stances
        -- absent here simply get no second buff. Tune freely to taste.
        kindredStance = {
            soloist   = 'zweihander',  zweihander  = 'soloist',     -- Long Blade kin
            axeman    = 'mjolnir',     mjolnir     = 'axeman',       -- swung-weight kin
            huntsman  = 'twirler',     twirler     = 'huntsman',     -- finesse / agility kin
            arcanist  = 'thaumaturge', thaumaturge = 'arcanist',     -- caster kin
            thief     = 'guisarmier',  guisarmier  = 'thief',        -- reach / speed kin
            brawler   = 'pitmen',      pitmen      = 'brawler',      -- endurance bruiser kin
        },

        -- Loop allowance: how many loops of a song contribute to the buff timer.
        -- Grows +1 per Muse milestone (every loopMilestoneInterval levels).
        baseLoops             = 1,
        loopMilestoneInterval = 25,   -- +1 loopable buff at Muse lvl 25/50/75/100
        maxLoops              = 5,

        -- Inspiration buff magnitude (skill points), scaled by Muse level.
        buffMagnitudeBase     = 5,
        buffMagnitudePerLevel = 0.10,  -- +0.1/level -> +10 at level 100
        buffMagnitudeMax      = 20,

        -- A song must be at least this complete (0..1) to grant the Muse
        -- "song completed" XP.
        minCompletionForXp = 0.5,

        -- Stances a song can be associated with (the combat/weapon stances whose
        -- inspiration is a weapon-skill bonus). Non-combat / tool / caster
        -- stances and Muse itself are intentionally excluded. A song with no
        -- override hashes deterministically onto this list, so every song maps
        -- to exactly one stance, always the same one.
        buffableStances = {
            'soloist', 'zweihander', 'thief', 'dualist', 'guisarmier',
            'axeman', 'mjolnir', 'brawler', 'huntsman', 'twirler',
            'blademeister', 'thaumaturge',
        },

        -- Curated song -> stance overrides, matched first by exact song id, then
        -- by a lowercased substring of the song title (so thematic songs buff a
        -- coherent stance).
        songOverrides = {
            ['war']    = 'zweihander',
            ['battle'] = 'zweihander',
            ['hunt']   = 'huntsman',
            ['hawk']   = 'huntsman',
            ['drink']  = 'brawler',
            ['tavern'] = 'brawler',
            ['thief']  = 'thief',
            ['shadow'] = 'thief',
            ['blade']  = 'soloist',
            ['duel']   = 'soloist',
            ['storm']  = 'thaumaturge',
            ['arcane'] = 'thaumaturge',
        },
    },

    -- ─── Smoker prefix (Hackle-Lo Pipes) buff gating ──────────────────────
    -- The Smoking weapon-skill bonus (+weaponBonus while a smoke buff is live)
    -- now lasts a WINDOW that Stance manages itself, rather than tracking the
    -- pipe potion's full effect duration. The window is the smoke potion's own
    -- remaining time, first multiplied by durationScale (0.5 = halved), then
    -- HARD-CAPPED by a window that grows with the CORE Stance skill level:
    -- gateBaseSeconds at gateAtLevel, +gateAddSeconds every gatePerLevels core
    -- levels.
    --   core lv 5  - up to 10s   (gateBaseSeconds at gateAtLevel)
    --   core lv 15 - up to 20s
    --   core lv 25 - up to 30s ...
    -- The pipe's Speed-drain cancellation is unaffected and still lasts the
    -- full potion duration; only the +weaponBonus window is gated here.
    smoker = {
        weaponBonus     = 10,   -- additive weapon-skill pts while the window is live
        durationScale   = 1.0,  -- use the potion's full remaining time (EXTENDED)
        gateBaseSeconds = 20,
        gateAtLevel     = 5,
        gatePerLevels   = 10,
        gateAddSeconds  = 15,
        -- Per-ingredient weapon-skill bonus. The Hackle-Lo Pipes mod decides which
        -- leaf you smoke; Stance reads the resulting smoke effect and grants a
        -- bonus flavoured to it. Keys are the mod's smoke-effect ids (lower-case).
        -- Any type not listed here uses weaponBonus above. Tune freely.
        weaponBonusByType = {
            ['pe_hackle-lo_smoke']            = 8,   -- common leaf (the cheap, Speed-draining smoke)
            ['pe_hackle-lo_smoke_ancestral']  = 10,  -- ancestral blend — focused, steady
            ['pe_hackle-lo_smoke_dagoth']     = 14,  -- Sixth House resin — potent and aggressive
            ['pe_hackle-lo_smoke_peace']      = 6,   -- calming smoke — mildest edge
            ['pe_hackle-lo_smoke_vip']        = 12,  -- premium blend — richer effect
            ['pe_hackle-lo_smoke_windwalker'] = 10,  -- windwalker leaf — brisk and clean
        },
        -- Friendly names shown in the skill tooltip while each smoke is active.
        typeNames = {
            ['pe_hackle-lo_smoke']            = 'Hackle-Lo Leaf',
            ['pe_hackle-lo_smoke_ancestral']  = 'Ancestral Blend',
            ['pe_hackle-lo_smoke_dagoth']     = 'Sixth House Resin',
            ['pe_hackle-lo_smoke_peace']      = 'Calming Smoke',
            ['pe_hackle-lo_smoke_vip']        = 'Velothi Reserve',
            ['pe_hackle-lo_smoke_windwalker'] = 'Windwalker Leaf',
        },
    },

    -- ─── Evening Star (Religions of Morrowind) integration ────────────────────
    -- Associates each stance with one of the three Tribunal Temple deities and, while
    -- the player worships that deity, grants a small additive bonus to the active
    -- stance's target skill, scaled by devotion tier. Detection reads the abilities
    -- Evening Star grants (gift_1 at Worshipper/Follower, gift_3 at Devotee) from the
    -- player's own spells, so no Evening Star API is required. Deliberately covers
    -- ONLY the Tribunal Temple — the Sun's Dusk / Sixth House pantheons are ignored.
    -- The bonus is small and additive so it complements, never eclipses, the core
    -- effectiveness bonus (+2..+20) — keeping the mod's balance intact.
    eveningStar = {
        pantheonName = 'Tribunal Temple',
        -- Additive target-skill bonus by devotion tier (1 = Follower, 2 = Devotee).
        tierBonus = { [1] = 2, [2] = 4 },
        tierName  = { [1] = 'Follower', [2] = 'Devotee' },
        -- The three Tribunal deities and the abilities Evening Star grants, used only
        -- to detect the player's devotion tier from their active spells.
        deities = {
            vivec     = { name = 'Vivec',     title = 'the Warrior-Poet',  gift1 = 'es_tt_vivec_g1',     gift3 = 'poets_charm'       },
            almalexia = { name = 'Almalexia', title = 'the Mother',        gift1 = 'es_tt_almalexia_g1', gift3 = 'mothers_grace'     },
            sothasil  = { name = 'Sotha Sil', title = 'the Clockwork God', gift1 = 'es_tt_sothasil_g1',  gift3 = 'sothas_reflection' },
        },
        -- Stance → Tribunal deity, cohesive by domain:
        --   Vivec (Warrior-Poet; patron of artists & rogues): blades, dual-wield,
        --     thrown weapons, and the bard.
        --   Almalexia (Mother & Defender; provision & endurance): unarmed, mace,
        --     spear, and the providers (fishing, foraging, the hunt, the common folk).
        --   Sotha Sil (Clockwork God & Artificer; magic & reason): the casters,
        --     crafters, miners (Dwemer depths), and lock-tinkers.
        stanceDeity = {
            soloist   = 'vivec', zweihander = 'vivec', blademeister = 'vivec',
            dualist   = 'vivec', thief      = 'vivec', twirler      = 'vivec',
            axeman    = 'vivec', muse       = 'vivec',

            brawler   = 'almalexia', guisarmier = 'almalexia', mjolnir = 'almalexia',
            angler    = 'almalexia', forager    = 'almalexia', commoner = 'almalexia',
            huntsman  = 'almalexia',

            arcanist  = 'sothasil', thaumaturge = 'sothasil', reforger = 'sothasil',
            apothecary = 'sothasil', pitmen     = 'sothasil', locksmith = 'sothasil',
        },
    },

    -- The Reforger stance's detection trigger. Both WeaponUpgrade and
    -- ArmorUpgrade gate their behavior on the player holding this exact
    -- record id, so this is the canonical signal.
    reforgerHammerRecordId = 'repair_hammer_weapon',

    -- The Blademeister (Soul Eater) stance's detection trigger. Felthorn,
    -- the shapeshifting Daedra weapon from the Blademeister mod, doesn't
    -- have one canonical record id — instead the mod defines 180+ weapon
    -- records (one per material × form × tier) all sharing the `sd_`
    -- prefix that the mod author uses for every Felthorn shape.
    -- Examples: sd_IronRapier0, sd_DaedricClaymore4, sd_CatgirlRapier,
    -- sd_SaintSword2, sd_DremoraAxe1, sd_GlassLongsword3.
    -- A simple prefix match catches every form Felthorn can take, and
    -- since Blademeister is the only Morrowind mod using `sd_` for weapon
    -- records (verified by scanning the ESP — all 181 weapons in the mod
    -- use this prefix and nothing else does), false positives in a
    -- standard load order are vanishingly rare.
    blademeisterRecordPrefix = 'sd_',

    -- ─── Stance change debounce ───────────────────────────────────────────
    stanceChangeDebounceSec = 0.35,

    -- ─── Detection polling cadence ────────────────────────────────────────
    pollIntervalSec = 0.25,

    -- ─── UI ───────────────────────────────────────────────────────────────
    ui = {
        tooltipStanceColor = { 0.92, 0.85, 0.55 },
        tooltipPerkColor   = { 0.85, 0.85, 0.85 },
        messageDuration    = 3.0,
        hudIconSize        = 48,   -- default on-screen pixel size of the stance icon
    },

    -- ─── Debug ────────────────────────────────────────────────────────────
    debug = {
        defaultDebug = false,
    },

    -- ─── Felthorn ambient voice ───────────────────────────────────────────
    -- Flavor lines the Felthorn blade "speaks" while the Blademeister stance
    -- is active (i.e. while a Felthorn weapon is equipped). Shown as ordinary
    -- vanilla messages via ui.showMessage. Purely cosmetic; safe to edit,
    -- reorder, or extend. Set `enabled = false` to silence entirely.
    --
    -- Lore note: Felthorn is a sentient, soul-drinking Daedric blade. Its
    -- voice is patient, hungry, and faintly amused — it regards its wielder as
    -- a temporary partnership and every kill as a shared meal. Lines avoid
    -- naming real NPCs/places so they stay setting-neutral and lore-safe.
    -- ─── Blademeister: Soul Resonance / Soul Exhaustion ───────────────────
    -- The Felthorn pact meter (player/blademeister.lua). Build it with Felthorn
    -- hits/kills; at full it RESONATES (weapon-skill surge on Felthorn's resolved
    -- form + Shield mitigation) and drains; at empty Felthorn is EXHAUSTED for a
    -- cooldown. The weapon-skill bonus rides the same additive native-modifier path
    -- as effectiveness/muse; the mitigation rides a Shield active-effect like the
    -- evasion Sanctuary bonus. State persists; buffs are transient.
    blademeister = {
        enabled       = true,

        -- Meter economy (points; meterMax is the trigger threshold).
        meterMax      = 100,
        buildPerHit   = 5,    -- meter per landed Felthorn hit
        buildPerKill  = 10,    -- meter per Felthorn kill
        -- Perfect parry (Felthorn, no shield): feeds this FRACTION of buildPerHit to
        -- the Resonance meter, rewarding defensive timing. 0 disables.
        perfectParryResonanceFraction = 0.5,
        decayPerSec   = 10,     -- passive meter decay while BUILDING and not hitting
        decayGraceSec = 3,     -- no decay for this long after the last hit

        -- Resonant payoff.
        drainPerSec     = 10,   -- meter drained per second while RESONANT (≈12.5s window at full)
        weaponSkillBonus = 10, -- additive pts to Felthorn's resolved weapon skill (more skill → more damage)
        shieldPoints     = 10, -- Shield active-effect magnitude (armor rating → damage mitigation)

        -- Exhaustion cooldown (seconds) before the meter can build again.
        cooldownSec   = 20,

        -- Feedback toggles.
        voiceResonance   = true,  -- speak on RESONANT
        voiceExhaustion  = true,  -- speak on EXHAUSTED
        flashOnResonance = false, -- reserved: no verified screen-flash API in this build

        -- HUD resonance bar textures (880×64 PNG in icons/Stance). The resonance
        -- texture fills while building/resonating; the exhaustion texture fills as
        -- Felthorn recovers during the cooldown.
        barResonanceTexture  = 'textures/Stance/resonance_bar.png',
        barExhaustionTexture = 'textures/Stance/lag_bar.png',

        -- Perk augments (unlock on the CORE Stance level like every ladder; only
        -- take effect while Blademeister perks are enabled). Each centres on a
        -- phase of the Soul Resonance lifecycle.
        perks = {
            quickeningBuildMult  = 1.5,   -- 25  Quickening Hunger: meter gain ×this
            sustainedDrainMult   = 0.667, -- 50  Sustained Resonance: resonant drain ×this (slower)
            tirelessCooldownMult = 0.5,   -- 75  Tireless Pact: exhaustion cooldown ×this (shorter)
            endlessKillCascade   = true,  -- 100 Endless Resonance: a kill while resonant refills the meter
            endlessResonantBoost = 1.25,  -- 100 Endless Resonance: resonant skill+shield ×this
        },
    },

    -- Spellsword Resonance (Phase 3). While Blademeister is RESONANT and Felthorn
    -- carries a Spellsword elemental imbue (Blazed/Frozen/Electrified), each landed
    -- hit deals a bonus burst of the MATCHING element worth this fraction of the
    -- hit's physical damage. Purely transient (recomputed every hit; nothing saved).
    spellswordResonance = {
        enabled = true,
        elementalDamageBonus  = 0.30,  -- +30% of hit damage as matching elemental damage
        requiresResonanceState = true, -- only while the Soul Resonance surge is active
        requiresSpellswordPrefix = true, -- inherently enforced: the imbue supplies the element
    },

    -- OSSC (Oblivion-Style Spell Casting) integration. OSSC casts your selected
    -- spell from a hotkey without entering a spell stance, using its OWN animation
    -- groups (QuickCast/QuickThrow/QuickBuff) — so the vanilla 'spellcast' text-key
    -- never fires and those casts would otherwise earn no Stance XP. This feeds the
    -- spellcasting stance on each quick-cast, credited DIRECTLY (regardless of the
    -- active stance) so a sword-and-spell hybrid still trains it. Detected purely by
    -- receiving OSSC's own OSSC_CastingState event, so no OSSC edit is needed and it
    -- stays inert when OSSC is absent. The credit still respects the global
    -- "XP on spell cast" toggle and the spellcasting stance being enabled.
    ossc = {
        castStance = 'arcanist',  -- stance credited on an OSSC quick-cast
        castXp     = 0.8,         -- XP per quick-cast (matches a normal spell cast)
    },
    felthornAmbient = {
        enabled = true,

        -- Seconds between idle lines while equipped. A line fires at a random
        -- interval in [minIntervalSec, maxIntervalSec] so it never feels metronomic.
        minIntervalSec = 20,
        maxIntervalSec = 75,

        -- Brief quiet period after first equipping before the first idle line,
        -- so the equip line (greetings) isn't immediately followed by chatter.
        firstLineDelaySec = 12,

        -- Don't repeat the same line twice in a row (avoids obvious looping).
        avoidImmediateRepeat = true,

        -- Spoken once, the moment Felthorn is drawn / Blademeister becomes active.
        greetings = {
            'Felthorn stirs against your palm, and is pleased to wake.',
            'The blade hums — a low, patient hunger at the edge of hearing.',
            'Again you take me up. Good. I had grown bored of the dark.',
            'Felthorn drinks the light along its edge, and waits for redder fare.',
            'A familiar grip. Let us see whose souls keep us company today.',
        },

        -- Spoken at random intervals while the stance remains active and idle.
        idle = {
            'A patient edge outlives a hasty one. Wait. They always come.',
            'I have tasted kings and beggars alike. The soul has no rank to me.',
            'You carry me as a tool. I carry you as a vessel. We are honest, at least.',
            'Somewhere a soul forgets it is already promised to me.',
            'The dead are quiet companions. I have gathered a great many.',
            'Sharpen nothing. I keep my own edge, and my own counsel.',
            'Flesh is a brief argument. I have never lost it.',
            'You dream of glory. I dream only of the next warmth.',
            'When your hand finally fails, another will take me up. It always does.',
            'Listen. That silence? That is the sound of something deciding to flee.',
            'Iron rusts, glass shatters, ebony chips. I endure. Remember which of us is the weapon.',
            'I have worn a hundred shapes for a hundred hands. Yours is… adequate.',
        },

        -- Spoken (chance-gated) right after a kill while the stance is active.
        onKillChance = 1,
        onKill = {
            'Mmm. That one had more to give than it looked.',
            'A soul, neatly folded and put away. We are well fed.',
            'Felthorn warms. Do not stop now — hunger returns so quickly.',
            'One more for the long dark inside me. They are never lonely there.',
            'You strike, I keep. A fair division of labor.',
        },

        -- Spoken the instant the Soul Resonance meter fills (BUILDING -> RESONANT).
        -- The pact speaks as one voice.
        resonance = {
            'SOUL RESONANCE. You and Felthorn cry out as one — the blade sings white.',
            'The hunger and the hand align. Felthorn blazes: "RESONANCE!"',
            'Now we are of one mind. Strike, vessel — the souls answer with us.',
            'Felthorn floods you with borrowed strength. "Together, then. RESONANCE."',
        },

        -- Spoken when the meter drains to empty (RESONANT -> EXHAUSTED).
        exhaustion = {
            'The fire gutters. Felthorn falls quiet — spent, and needing rest.',
            'Enough. The souls are still. Let me gather myself before we burn again.',
            'Felthorn cools in your grip, hunger sated for now. Give it a moment.',
            'The resonance fades to ash. We have spent ourselves; we must wait.',
        },

        -- ── Contextual lines (event-driven, via felthornVoice.sayEvent) ───────
        -- One shared throttle keeps several events firing at once from stacking
        -- into a wall of text. Each category has its own <name>Chance (default 1).
        contextualMinGapSec = 6,

        -- A perfect parry landed with Felthorn and no shield (feeds Resonance).
        perfectParryChance = 1,
        perfectParry = {
            'A clean turn. Felthorn drinks the moment and asks for more.',
            'Yes — let them spend themselves on my edge. We grow stronger for it.',
            'Beautifully timed. The blade hums; the resonance gathers.',
            'Their blow becomes our hunger. Parry again, vessel.',
            'Felthorn savors the ring of steel turned aside. Keep this rhythm.',
        },

        -- Player health dipped below lowHealthThreshold (fires once per dip; the
        -- warning re-arms only after health recovers past lowHealthRearm).
        lowHealthThreshold = 0.25,   -- fraction of max health
        lowHealthRearm     = 0.50,   -- recover past this to re-arm the warning
        lowHealthChance    = 1,
        lowHealth = {
            'Your blood runs thin, vessel. Do not die — I dislike changing hands.',
            'Careful! A corpse cannot wield me, and I am not done with you yet.',
            'Felthorn tastes your wound. Steady yourself, or we both go dark.',
            'You falter. Remember: if you fall, I simply wait for the next hand.',
        },

        -- The Blademeister stance advanced a level (spoken from drainStanceLevelUps).
        levelUpChance = 1,
        levelUp = {
            'We sharpen together, you and I. The pact deepens.',
            'Felthorn feels your growing mastery. Good. Feed it further.',
            'You learn my hunger\'s rhythm. Soon you will not flinch from it at all.',
            'Stronger. The blade approves — and approval, from me, is rare.',
        },
    },
}

return config
