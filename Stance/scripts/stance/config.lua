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
    --   * Each stance has its OWN xp bank and level (5 → 100), persisted in
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
        -- Effectiveness is now an additive skill-point bonus applied via Skill
        -- Framework's registerDynamicModifier on the skill tied to each stance's
        -- weapon type or modded integration. The bonus ramps linearly from
        -- effectivenessMinBonus at startLevel to effectivenessMaxBonus at maxLevel.
        --   Soloist lv 5  → +2 Long Blade
        --   Soloist lv 52 → +11 Long Blade   (approx midpoint)
        --   Soloist lv 100 → +20 Long Blade
        effectivenessMinBonus = 2,  -- additive skill pts at startLevel
        effectivenessMaxBonus = 20, -- additive skill pts at maxLevel
    },

    -- ─── Fortified (shield + one-handed melee) ────────────────────────────
    -- The Fortifier stance is deprecated: a shield equipped alongside a
    -- one-handed melee weapon decorates that weapon's stance with a
    -- "Fortified" prefix (e.g. "Fortified Soloist") and grants an additive
    -- Block skill bonus while so equipped. The bonus SCALES with the player's
    -- own Block skill (base), using the same effectivenessMinBonus →
    -- effectivenessMaxBonus ramp (above) the weapon-skill effectiveness
    -- bonuses use, across the same startLevel → maxLevel range — so the two
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
    -- getEquipmentSkill): weight ≤ floor(iGauntletWeight) × fLightMaxMod → Light,
    -- ≤ × fMedMaxMod → Medium, else Heavy. "Unarmored" means no hand armor at
    -- all (bare fists) → the 'none' tier: no bonus, no penalty.
    --
    --   hhBonus     — additive Hand-to-Hand skill points. Stacks ON TOP of the
    --                 Brawler effectiveness bonus through the same delta-
    --                 accounted native-modifier path (so it clears cleanly when
    --                 the gauntlets come off or the stance changes).
    --   speedDebuff — subtracted from the unarmed attack-animation speed
    --                 multiplier (1.0 = normal). 0.25 ⇒ swings play at 0.75×.
    -- The values below are the design defaults; tune freely. Light/Medium/Heavy
    -- map 1:1 to the three vanilla armor weight classes.
    brawlerGauntlet = {
        light  = { hhBonus = 2.5, speedDebuff = 0.15 },
        medium = { hhBonus = 5.0, speedDebuff = 0.25 },
        heavy  = { hhBonus = 7.5, speedDebuff = 0.35 },
        -- Defensive floor on the resulting speed multiplier so a re-tune (or a
        -- mod-raised debuff) can never freeze unarmed attacks at 0× speed.
        minSpeedMult = 0.10,
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
        -- is swung. The unified hit path (victim.lua → Stance_PlayerDealtHit)
        -- credits this in place of combatHit when Apothecary is active.
        concoctionThrowHit    = 2.50,  -- a concoction that finds its mark

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
                    description = 'Repetition teaches economy. Spell costs reduced by five percent.',
                },
                {
                    level = 50, id = 'meditatedMind', name = 'Meditated Mind',
                    description = 'Still water reflects the stars. Passive magicka regeneration from sustained meditation improves by a quarter.',
                },
                {
                    level = 75, id = 'incantedFocus', name = 'Incanted Focus',
                    description = 'To refine the incantation is to refine the return. Custom-spell magicka refunds improved by ten percent.',
                },
                {
                    level = 100, id = 'aetherealMind', name = 'Aethereal Mind',
                    description = 'Those who have truly mastered the form do not cast spells — they remember them. Spell failure chance halved.',
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
                    description = 'Long hours at the forge build arms that do not tire easily. Fatigue from hammer swings reduced by fifteen percent.',
                },
                {
                    level = 50, id = 'weakPointStrike', name = 'Weak-Point Strike',
                    description = 'Where the rivets thin, so does the protection. Hammer blows ignore ten percent of the target\'s worn armor.',
                },
                {
                    level = 75, id = 'sunderingBlow', name = 'Sundering Blow',
                    description = 'The armorer\'s eye finds flaws in plate that warriors miss. Each hit carries a chance in ten to damage the target\'s worn armor.',
                },
                {
                    level = 100, id = 'forgemastersTouch', name = 'Forgemaster\'s Touch',
                    description = 'What the forge tempers, the forge can unmake. Hammer damage increases by a quarter; power attacks have an improved chance to stagger.',
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
                    level = 25, id = 'soulPerception', name = 'Soul Perception',
                    description = 'The meister\'s gift: to see what others cannot. Sneak and Mysticism each increase by five while Felthorn is in hand.',
                },
                {
                    level = 50, id = 'soulWavelength', name = 'Soul Wavelength',
                    description = 'The blade and the arm learn each other\'s rhythm. Weapon damage increases by fifteen percent; hits carry a chance to disrupt the target.',
                },
                {
                    level = 75, id = 'witchHunter', name = 'Witch Hunter',
                    description = 'The pact resolves into motion. Power attacks deal thirty percent more damage and carry a chance to strike twice.',
                },
                {
                    level = 100, id = 'soulResonance', name = 'Soul Resonance',
                    description = 'Meister and weapon, indistinguishable. Damage increases by a quarter; attack speed improves; the blade ignores a portion of armor.',
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
                    description = 'The hunter\'s breathing is slow and deliberate. Fatigue from ranged attacks reduced by fifteen percent.',
                },
                {
                    level = 50, id = 'pinningShot', name = 'Pinning Shot',
                    description = 'Game that is struck does not always fall at once. Ranged hits briefly slow the target.',
                },
                {
                    level = 75, id = 'concussiveShot', name = 'Concussive Shot',
                    description = 'A solid blow to the skull scrambles the legs. Headshots drain twenty-five fatigue from the target.',
                },
                {
                    level = 100, id = 'killshot', name = 'Killshot',
                    description = 'The hunter who knows where to place the arrow wastes nothing. Headshots deal twenty-five percent more damage.',
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
                    description = 'The rotation before release is not wasted motion. Throwing critical chance increases by three percent.',
                },
                {
                    level = 50, id = 'twinnedThrow', name = 'Twinned Throw',
                    description = 'Two projectiles from one motion — a discipline of the wrist, not the arm. Twin-flight chance increases by five percent.',
                },
                {
                    level = 75, id = 'rendingHand', name = 'Rending Hand',
                    description = 'The barbed edge bites and holds. Bleed magnitude on thrown hits increases.',
                },
                {
                    level = 100, id = 'whirlwindArm', name = 'Whirlwind Arm',
                    description = 'The arm is a wheel; the release is its spoke. Paralysis duration from thrown weapons increases by one second.',
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
                    description = 'The blow and the current arrive together. Concussive strike chance increases by ten percent.',
                },
                {
                    level = 50, id = 'siphonedAccord', name = 'Siphoned Accord',
                    description = 'What the strike breaks, the conduit drinks. Arcane siphon chance increases by five percent.',
                },
                {
                    level = 75, id = 'resonantAccord', name = 'Resonant Accord',
                    description = 'The stave remembers every working it has channeled. Resonant conduit chance increases by three percent.',
                },
                {
                    level = 100, id = 'pulsedAccord', name = 'Pulsed Accord',
                    description = 'The silence is not absence — it is pressure. Null pulse silence duration extends by two seconds.',
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
                    description = 'Two blades mean two commitments; the feet compensate. Movement speed increases by ten percent while dual-wielding.',
                },
                {
                    level = 50, id = 'mirrorEdge', name = 'Mirror Edge',
                    description = 'The off-hand echoes what the main hand begins. Off-hand strikes deal fifteen percent more damage.',
                },
                {
                    level = 75, id = 'twinTempo', name = 'Twin Tempo',
                    description = 'There is a rhythm in matched steel that a single blade cannot find. Attack speed increases by fifteen percent.',
                },
                {
                    level = 100, id = 'crossGuard', name = 'Cross Guard',
                    description = 'Two blades crossed in time become a wall. You parry as though a shield were held.',
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
                    description = 'Both hands behind the steel means the steel carries everything behind it. Two-handed weapon damage increased by ten percent.',
                },
                {
                    level = 50, id = 'sweepingArc', name = 'Sweeping Arc',
                    description = 'The wide blade clears the ground it passes. Attacks have a chance to also strike a second nearby enemy.',
                },
                {
                    level = 75, id = 'cleavingBlow', name = 'Cleaving Blow',
                    description = 'Armor is weight; the blow that finds the gap beneath it ignores both. Hits have a ten percent chance to bypass a portion of armor.',
                },
                {
                    level = 100, id = 'titanGrip', name = 'Titan Grip',
                    description = 'The blade becomes part of the arm; the arm forgets fatigue. Two-handed damage increases by a quarter; heavy weapon drain is halved.',
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
                    description = 'Distance is the spearman\'s first weapon. Spear damage increased by ten percent.',
                },
                {
                    level = 50, id = 'phalanxBrace', name = 'Phalanx Brace',
                    description = 'A set spear meets a charge before the charge meets the spearman. Knockdown resistance increased by a quarter.',
                },
                {
                    level = 75, id = 'pinningThrust', name = 'Pinning Thrust',
                    description = 'The wound in the leg is slower than the wound in the chest, but it lasts longer. Spear hits have a chance to briefly slow the target.',
                },
                {
                    level = 100, id = 'polearmMaster', name = 'Polearm Master',
                    description = 'The spear in trained hands is both fast and final. Spear damage increased by a quarter; attack fatigue drain reduced by twenty percent.',
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
                    description = 'The ore-head is heavy; the swing carries through whatever it finds. Pick damage in combat increased by ten percent.',
                },
                {
                    level = 50, id = 'veinReader', name = 'Vein Reader',
                    description = 'The practiced pitman reads the seam before the first blow falls. Mining duration with the pick reduced by twenty percent.',
                },
                {
                    level = 75, id = 'prospector', name = 'Prospector',
                    description = 'A trained eye finds the rich pocket where the untrained sees only stone. Ore yield chance increased by fifteen percent.',
                },
                {
                    level = 100, id = 'pitboss', name = 'Pit Boss',
                    description = 'Below ground or above it, this is the most dangerous thing in the shaft. Pick damage increased by a quarter; mining completes thirty percent faster.',
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
                    description = 'The same controlled breathing that holds a line taut keeps a swing from going wide. Fatigue from fishing pole attacks reduced by fifteen percent.',
                },
                {
                    level = 50, id = 'catchAndRelease', name = 'Catch and Release',
                    description = 'A skilled hand at the water tends to find more than was promised. Successful casts have a ten percent chance to yield an additional fish.',
                },
                {
                    level = 75, id = 'trophyCast', name = 'Trophy Cast',
                    description = 'The seasoned Angler always finds the large ones hiding in the deep current. Fishing skill treated as ten points higher when determining catch quality.',
                },
                {
                    level = 100, id = 'masterAngler', name = 'Master Angler',
                    description = 'The rod is an extension of will, and the Angler behind it has run out of patience for amateurs. Pole damage increased by a quarter; cast time reduced by twenty percent.',
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
                    description = 'Hours spent lobbing flasks teach the wrist what the eye only guesses. Agility is raised by five, steadying every throw.',
                },
                {
                    level = 50, id = 'volatileConcoction', name = 'Volatile Concoction',
                    description = 'The Apothecary stops corking gently. A landed concoction has a one-in-four chance to burst with enough force to stagger its victim, draining their fatigue.',
                },
                {
                    level = 75, id = 'corrosiveCloud', name = 'Corrosive Cloud',
                    description = 'Residue clings and keeps working long after the glass has shattered. Every landed concoction leaves a brief caustic cloud that gnaws at the target over several seconds.',
                },
                {
                    level = 100, id = 'masterApothecary', name = 'Master Apothecary',
                    description = 'The line between medicine and murder is a matter of dosage, and the Apothecary has mastered both. Intelligence and Luck are each raised by five, and a landed concoction has a small chance to paralyze its victim outright as the toxic shock takes hold.',
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
                    description = 'The gardener knows each plant\'s virtue, and the harvest feeds the alchemist\'s craft. Effective Alchemy skill increased by five.',
                },
                {
                    level = 50, id = 'cultivatorsPatience', name = "Cultivator's Patience",
                    description = 'Tending growth teaches the long view; the mind sharpens with every turning season. Intelligence increased by five.',
                },
                {
                    level = 75, id = 'rootedEndurance', name = 'Rooted Endurance',
                    description = 'Days bent to the soil harden the back and steady the hands. Endurance increased by five.',
                },
                {
                    level = 100, id = 'masterGardener', name = 'Master Gardener',
                    description = 'The garden answers to a master\'s hand — every bed thrives, every reagent runs richer. Intelligence and Alchemy are each increased by a further five.',
                },
            },
            perksHarvesting = {
                {
                    level = 25, id = 'reapersGrip', name = "Reaper's Grip",
                    description = 'The scythe is swung the same whether the stalk is wheat or throat. Strength increased by five.',
                },
                {
                    level = 50, id = 'sweepingCut', name = 'Sweeping Cut',
                    description = 'The harvest stroke is wide and unbroken; momentum carries from one mark to the next. Agility increased by five.',
                },
                {
                    level = 75, id = 'bountifulHands', name = 'Bountiful Hands',
                    description = 'The seasoned reaper\'s hands find more in every swing — grain, coin, or spoils. Luck increased by five.',
                },
                {
                    level = 100, id = 'masterHarvester', name = 'Master Harvester',
                    description = 'Whatever the field yields, you take all of it — and faster than anyone. Strength and Agility are each increased by a further five.',
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
                    description = 'The axe does not negotiate. Axe damage increased by ten percent.',
                },
                {
                    level = 50, id = 'heavyChop', name = 'Heavy Chop',
                    description = 'The full weight of the swing, committed without reservation. Power attacks with axes deal twenty percent more damage.',
                },
                {
                    level = 75, id = 'bleedingCut', name = 'Bleeding Cut',
                    description = 'The wound an axe leaves is not clean. Axe hits cause a small bleed — health drained each second for five seconds.',
                },
                {
                    level = 100, id = 'headsman', name = 'Headsman',
                    description = 'The executioner\'s art is precision, not savagery. Axe damage increased by a quarter; hits have a chance to bypass a portion of armor.',
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
                    description = 'The mass of the weapon is its argument. Blunt weapon damage increased by ten percent.',
                },
                {
                    level = 50, id = 'crushingBlow', name = 'Crushing Blow',
                    description = 'A clean swing with everything behind it. Power attacks with blunt weapons deal twenty percent more damage.',
                },
                {
                    level = 75, id = 'concussiveForce', name = 'Concussive Force',
                    description = 'A firm blow to the skull disorients. Blunt hits have a ten percent chance to stagger the target.',
                },
                {
                    level = 100, id = 'thunderstrike', name = 'Thunderstrike',
                    description = 'What stands against it does not stand long. Blunt damage increased by a quarter; hits have a chance to bypass a portion of armor.',
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
                    description = 'One who does not spread the weight cannot be easily toppled. Knockdown resistance increased by twenty-five percent.',
                },
                {
                    level = 50, id = 'heavyHand', name = 'Heavy Hand',
                    description = 'The weight of the blade, focused through a single arm, carries more than most expect. Power attacks deal fifteen percent more damage.',
                },
                {
                    level = 75, id = 'unstoppable', name = 'Unstoppable',
                    description = 'There is a quality in the unhurried swing that unsettles the body it lands on. Hits have a ten percent chance to stagger the target.',
                },
                {
                    level = 100, id = 'solitaryWill', name = 'Solitary Will',
                    description = 'The body learns what the stance demands. Effective Endurance increased by fifteen points.',
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
                    description = 'The short blade\'s chief virtue is that it arrives before the longer one. Attack speed increased by ten percent.',
                },
                {
                    level = 50, id = 'cutpurse', name = 'Cutpurse',
                    description = 'Light feet matter as much as a light hand. Effective Sneak increased by five.',
                },
                {
                    level = 75, id = 'backstab', name = 'Backstab',
                    description = 'The most economical target is the one that has not yet turned. Hits from behind deal twenty-five percent more damage.',
                },
                {
                    level = 100, id = 'masterThief', name = 'Master Thief',
                    description = 'The blade and the shadow have the same master. Short blade damage increased by a quarter; movement speed improved by ten percent.',
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
                    description = 'The hands that have learned patience work the tumblers more surely. Effective Security skill increased by five.',
                },
                {
                    level = 50, id = 'probeSage', name = 'Probe Sage',
                    description = 'The probe is a conversation with the lock, not a demand. Probes are ten percent less likely to break on use.',
                },
                {
                    level = 75, id = 'sneakStep', name = 'Sneak Step',
                    description = 'The locksmith who is heard is not a locksmith. Effective Sneak skill increased by five.',
                },
                {
                    level = 100, id = 'masterOfLocks', name = 'Master of Locks',
                    description = 'The worst locks are only stubborn, not impossible. Lock difficulty is treated as fifteen points lower.',
                },
            },
        },

        {
            id = 'brawler',
            displayName = 'Brawler',
            icon = 'icons/Stance/Brawler.dds',
            attribute = 'strength',
            description = 'The fist is the oldest weapon — always carried, never confiscated, never broken. Strength governs it, as it has since before blades had names.',
            integrations = { 'gothicknockout' },
            category = 'fatigue',
            evasionBonus = 5,   -- Weave and bob; unarmed fighters learn to slip punches
            perks = {
                {
                    level = 25, id = 'ironGrip', name = 'Iron Grip',
                    description = 'The hand that grips becomes its own weapon. Hand-to-hand damage increased by fifteen percent.',
                },
                {
                    level = 50, id = 'closeRangeFighter', name = 'Close-Range Fighter',
                    description = 'Fighting without a weapon costs something — this lessens what it costs. Fatigue drain from unarmed attacks reduced by a quarter.',
                },
                {
                    level = 75, id = 'concussiveJab', name = 'Concussive Jab',
                    description = 'The jaw is architecture; a proper blow unmakes it. Unarmed hits have an improved chance to knock the target down.',
                },
                {
                    level = 100, id = 'streetMaster', name = 'Street Master',
                    description = 'Each strike finds what the body can give back. Successful unarmed hits briefly restore fatigue.',
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
                    description = 'The voice carries more than words. Speechcraft effectiveness increased by ten percent.',
                },
                {
                    level = 75, id = 'urbanCharm', name = 'Urban Charm',
                    description = 'Admiration, when it lands, lands differently in practiced hands. Disposition gains from successful Admire are improved.',
                },
                {
                    level = 100, id = 'thePeoplesHero', name = "The People's Hero",
                    description = 'The city knows your name for the right reasons. Barter prices improve and disposition recovers more quickly between conversations.',
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
            -- bridge (victim.lua → Stance_PlayerDealtHit) every other weapon
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
    felthornAmbient = {
        enabled = true,

        -- Seconds between idle lines while equipped. A line fires at a random
        -- interval in [minIntervalSec, maxIntervalSec] so it never feels metronomic.
        minIntervalSec = 75,
        maxIntervalSec = 160,

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
        onKillChance = 0.5,
        onKill = {
            'Mmm. That one had more to give than it looked.',
            'A soul, neatly folded and put away. We are well fed.',
            'Felthorn warms. Do not stop now — hunger returns so quickly.',
            'One more for the long dark inside me. They are never lonely there.',
            'You strike, I keep. A fair division of labor.',
        },
    },
}

return config
