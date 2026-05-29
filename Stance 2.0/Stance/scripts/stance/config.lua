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

    -- ─── XP source weights ────────────────────────────────────────────────
    -- Each successful action grants this much xp to the ACTIVE stance,
    -- before the global xpMultiplier setting is applied. The core Stance
    -- skill simultaneously receives half of that scaled amount.
    xp = {
        combatHit             = 1.00,
        combatKill            = 2.00,
        spellCast             = 0.80,
        blockSuccess          = 1.20,
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
    },

    -- ─── Stance definitions ───────────────────────────────────────────────
    stances = {
        {
            id = 'arcanist',
            displayName = 'Arcanist',
            attribute = 'intelligence',
            description = 'The spellcasting posture, favored by the Telvanni and those who study under them. Magicka yields more readily when the mind stills the body and the voice carries the working.',
            integrations = { 'incantation', 'meditation' },
            category = 'magic',
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
            attribute = 'endurance',
            description = 'The armorer\'s hammer knows every joint and seam in a cuirass. You carry it as a weapon because you know where it breaks. The forge builds the arms that swing it.',
            integrations = { 'weaponupgrade', 'armorupgrade' },
            category = 'damage',
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
            attribute = 'agility',
            description = 'A pact between wielder and blade — the weapon shaped by something older than craft, the hand guided by something stranger than training. The two grow toward one another with each soul the blade drinks.',
            integrations = { 'blademeister' },
            category = 'damage',
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
            attribute = 'speed',
            description = 'The bow is not a warrior\'s weapon by nature — it is a hunter\'s tool, grown patient on the game trails of the Ashlands and the green forests east of the Velothi Mountains. Speed governs the draw.',
            integrations = { 'bullseye' },
            category = 'ranged',
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
            attribute = 'agility',
            description = 'Thrown steel is a poor substitute for a proper blade — until it is not. Those who practice the spinning release learn that distance and precision together are more dangerous than proximity alone.',
            integrations = { 'throwing' },
            category = 'ranged',
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
            attribute = 'willpower',
            description = 'A stave is not a mace with ambitions — it is a conduit, shaped from wood and intention, that bends magicka along the blow. Willpower governs the form, as with all things that bend the unseen to a purpose.',
            integrations = { 'staves' },
            category = 'magic',
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
            attribute = 'speed',
            description = 'Two blades, one mind. The off-hand weapon is not a second chance — it is the first blow\'s completion. Speed is the governing virtue, for a slow dualist is simply outnumbered.',
            integrations = { 'dualwielding' },
            category = 'speed',
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
            id = 'fortifier',
            displayName = 'Fortifier',
            attribute = 'strength',
            description = 'The shield is not passive defense — it is the fulcrum on which an attack is broken. Strength governs the stance, for a shield held without will is an obstacle, not a ward.',
            integrations = { 'ngarde' },
            category = 'block',
            perks = {
                {
                    level = 25, id = 'shieldUp', name = 'Shield Up',
                    description = 'The shield raised in readiness stops more than the one raised in panic. Block effectiveness increased by ten percent.',
                },
                {
                    level = 50, id = 'wardenStance', name = 'Warden Stance',
                    description = 'The practiced defender reads the blow before it lands. Parry window widened by a quarter.',
                },
                {
                    level = 75, id = 'perfectGuard', name = 'Perfect Guard',
                    description = 'A parry returned with force teaches the lesson twice. Perfect-parry damage rebound improves by twenty percent.',
                },
                {
                    level = 100, id = 'bulwark', name = 'Bulwark',
                    description = 'Once in the span of thirty breaths, the shield answers what the arm cannot. One incoming blow is fully blocked.',
                },
            },
        },

        {
            id = 'zweihander',
            displayName = 'Zweihänder',
            attribute = 'strength',
            description = 'A two-handed long blade is not a larger sword — it is a different instrument, governed by different rules. Heavy, unforgiving, and ruinous when it lands. Strength governs it, as it has always governed the things that simply refuse to stop.',
            integrations = {},
            category = 'damage',
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
            attribute = 'endurance',
            description = 'The spear\'s virtue is reach — the gap between its point and your body is the argument it makes. The Redoran house-guard tradition has understood this for generations. Endurance governs it, for the spear demands patience as much as strength.',
            integrations = {},
            category = 'damage',
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
            attribute = 'endurance',
            description = 'The Miner\'s Pick was not made for war — which is exactly what makes it dangerous in the hands of someone who knows its weight. The Pitmen swings it the same way below ground as above. Endurance governs the form.',
            integrations = { 'simplymining' },
            category = 'damage',
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
            attribute = 'luck',
            description = 'The fishing pole is a weapon the way a healer is a combatant — technically accurate and widely underestimated. Luck governs the Angler, for Vvardenfell\'s waters reward the fortunate cast as much as the practiced one.',
            integrations = { 'fishing' },
            category = 'utility',
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
            id = 'axeman',
            displayName = 'Axeman',
            attribute = 'strength',
            description = 'An axe asks only one question and accepts only one answer. No governing attribute was ever more honestly earned by the weapon that demanded it. Governed by Strength.',
            integrations = {},
            category = 'damage',
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
            attribute = 'strength',
            description = 'Maces, clubs, warhammers, mauls — instruments of reduction. What they strike, they simplify. Strength governs the stance without argument. Staves are a different tradition entirely and are not welcome here.',
            integrations = {},
            category = 'damage',
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
            attribute = 'endurance',
            description = 'A long blade in one hand, no shield — a deliberate choice, not a deficiency. The empty off-hand is the statement. Endurance governs the form, for the fighter who carries only a blade cannot afford to tire.',
            integrations = {},
            category = 'damage',
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
            attribute = 'speed',
            description = 'A short blade was never meant for dueling — it was meant to end the matter before a duel could begin. Speed governs the form, as the Morag Tong have always understood.',
            integrations = {},
            category = 'speed',
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
            attribute = 'agility',
            description = 'Tools in the pouch, eyes on the keyhole — the posture of one who does not expect trouble but has not forgotten how to make it. Agility governs the form, as it governs the Security skill these tools serve.',
            integrations = {},
            category = 'utility',
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
            attribute = 'strength',
            description = 'The fist is the oldest weapon — always carried, never confiscated, never broken. Strength governs it, as it has since before blades had names.',
            integrations = { 'gothicknockout' },
            category = 'fatigue',
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
            attribute = 'luck',
            description = 'Weapons sheathed, fists still — the posture of commerce and conversation, of gates passed without incident and prices reduced by patience. Luck is its virtue, the diplomat\'s constant companion.',
            integrations = {},
            category = 'social',
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
            event = 'ngarde_ParrySuccess',
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
        hudIconSize        = 22,
    },

    -- ─── Debug ────────────────────────────────────────────────────────────
    debug = {
        defaultDebug = false,
    },
}

return config
