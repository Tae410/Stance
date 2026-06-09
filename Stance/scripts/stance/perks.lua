--[[
    Stance! — Perk System (perks.lua)

    Implements every perk mechanic for all 19 stances.
    Required by init.lua, which injects a context table via Perks.init().

    ── How the pieces fit together ────────────────────────────────────────────
    Perks are gated on the CORE Stance skill level (25 / 50 / 75 / 100), the
    master "enabled" flag, the master "enableAllPerks" toggle, and each
    stance's individual perk toggle.  All of those checks go through the
    perkActive() helper so the logic lives in exactly one place.

    ── Implementation strategies by perk type ─────────────────────────────────
    ATTRIBUTE PERKS (Arcanist Willpower, Soloist Endurance, etc.)
      Managed every update by computeDesiredAttrContribs() →
      setAttrContrib().  A delta approach is used: we track our own
      contribution separately (persisted in stanceStateSection so it
      survives save/load) and write only the delta, letting magic effects
      from spells and enchantments stack naturally.

    SKILL PERKS (Thief Sneak, Locksmith Security, etc.)
      Registered as Skill Framework dynamic modifiers once on the first
      update that SF is available.  The callback is a closure over the
      stance id and threshold so it always returns the correct value.

    ON-HIT PERKS (bleed, slow, stagger, fatigue drain, bonus damage)
      Dispatched from Perks.onHit(attack) → global event
      'Stance_PerkEffect' → global.lua which has world scope to write
      types.Actor.activeEffects on the target.  Self-heals (Street Master)
      are written directly to the player's dynamic stats here.

    ON-PARRY PERKS (Fortifier)
      Dispatched from Perks.onParry(), broadcast via global events so
      N'Garde bridges can widen parry windows / improve rebound.  Bulwark
      also directly restores a portion of player health.

    INTEGRATION BROADCAST PERKS (Twirler, Thaumaturge, Dualist, Pitmen,
    Angler, Locksmith)
      Broadcast modifier payloads once per second via core.sendGlobalEvent.
      Partner mods or bridge scripts consume those events and apply the
      amplifications inside their own systems.
      Note: Pitmen and Angler broadcast perks are ALREADY implemented in
      init.lua's onSimplyMiningStartMining and onFishingCatch; this module
      only handles the attribute/skill components for those stances.

    ── Context (C) injected by init.lua via Perks.init() ──────────────────────
    C.getActiveStance()          → current stance id string or nil
    C.getCoreLevel()             → current core Stance skill level
    C.getStanceLevel(id)         → per-stance level
    C.integrationPresent(id)     → boolean
    C.readSetting(group,key,def) → setting value with default
    C.stanceEnabled(id)          → boolean
    C.perksEnabled(id)           → boolean (stance perk toggle)
    C.getSelf()                  → openmw.self (the player actor)
    C.getStanceStorage()         → stanceStateSection (playerSection)
]]

local core  = require('openmw.core')
local types = require('openmw.types')
local I     = require('openmw.interfaces')

local statAccess = require('scripts.stance.player.stat_access')

-- ─── Module ────────────────────────────────────────────────────────────────
local Perks = {}

-- ─── Injected context ─────────────────────────────────────────────────────
local C = nil

-- ─── Module-level state ───────────────────────────────────────────────────
local bulwarkLastFired = -math.huge  -- time of last Bulwark absorption
local broadcastLastAt  = -math.huge  -- throttle: integration data sends
local BROADCAST_INTERVAL = 1.0       -- seconds between integration broadcasts

-- ─── Attribute contribution tracking ─────────────────────────────────────
-- We track what WE last wrote per attribute so the delta stays correct when
-- spell effects are also modifying the same attributes simultaneously.
-- Persisted in stanceStateSection so save/load doesn't double-count.
local ATTR_NAMES = {
    'strength', 'intelligence', 'willpower',
    'agility',  'speed',        'endurance',
    'personality', 'luck',
}
local perkAttrContrib = {}
for _, a in ipairs(ATTR_NAMES) do perkAttrContrib[a] = 0 end
local perkContribDirty = false

-- Skill contributions applied by perks (Cutpurse→sneak, Silver Tongue→
-- speechcraft, etc.). Same delta-tracking approach as attributes: we apply via
-- the engine-native skill `.modifier` field (types.NPC.stats.skills.<id>),
-- which works on VANILLA skills — unlike Skill Framework's
-- registerDynamicModifier, which only governs SF's own custom skills and so
-- silently no-op'd every vanilla skill bonus in the previous version.
-- Keyed by skill id; only skills we ever touch are listed so we don't clear
-- modifiers owned by other systems.
local SKILL_NAMES = {
    'longblade', 'shortblade', 'bluntweapon', 'axe', 'spear', 'marksman',
    'handtohand', 'block', 'armorer', 'security', 'speechcraft', 'mercantile',
    'sneak', 'mysticism',
}
local perkSkillContrib = {}
for _, s in ipairs(SKILL_NAMES) do perkSkillContrib[s] = 0 end

-- ─── Magic effect IDs ─────────────────────────────────────────────────────
-- core.magic.EFFECT_TYPE provides named integer IDs on OpenMW 0.49+.
-- The integer fallbacks match Morrowind's canonical MGEF record order.
local _cme = (core.magic and core.magic.EFFECT_TYPE) or {}
local EFF = {
    Burden        = _cme.Burden        or 7,
    DamageHealth  = _cme.DamageHealth  or 21,
    DamageFatigue = _cme.DamageFatigue or 23,
    Paralyze      = _cme.Paralyze      or 102,
    RestoreFatigue= _cme.RestoreFatigue or 79,
}
-- String labels for global.lua's fallback branch (if activeEffects:add fails).
local EFF_NAME = {
    [EFF.Burden]         = 'burden',
    [EFF.DamageHealth]   = 'damageHealth',
    [EFF.DamageFatigue]  = 'damageFatigue',
    [EFF.Paralyze]       = 'paralyze',
    [EFF.RestoreFatigue] = 'restoreFatigue',
}

-- ─── Context helpers (safe wrappers around C.*) ───────────────────────────
local function getActiveStance()     return C and C.getActiveStance()   or nil   end
local function getCoreLevel()        return C and C.getCoreLevel()      or 0     end
local function getStanceLevel(id)    return C and C.getStanceLevel(id)  or 0     end
local function intPresent(id)        return C and C.integrationPresent(id)       end
local function readSetting(g, k, d)  return C and C.readSetting(g, k, d) or d   end
local function perksEnabled(sid)     return C and C.perksEnabled(sid)   or false end
local function getSelf()             return C and C.getSelf()                    end

-- Full gate: every condition must pass for a perk to be active.
local function perkActive(stanceId, threshold)
    if not readSetting('', 'enabled', true)          then return false end
    if not readSetting('Perks', 'enableAllPerks', true) then return false end
    if getActiveStance() ~= stanceId                 then return false end
    if not perksEnabled(stanceId)                    then return false end
    return getCoreLevel() >= threshold
end

-- ─── Persistent storage ───────────────────────────────────────────────────
local PERK_ATTR_KEY = 'perkAttrContribs_v1'

local function getStorage() return C and C.getStanceStorage and C.getStanceStorage() end

local function savePerkContribs()
    local store = getStorage()
    if not store then return end
    pcall(function() store:set(PERK_ATTR_KEY, perkAttrContrib) end)
    perkContribDirty = false
end

-- NOTE: there is intentionally no loadPerkContribs. The engine resets runtime
-- attribute modifiers to 0 on load, so the saved contribution table must NOT
-- be restored — doing so would make setAttrContrib think the bonus is already
-- applied and skip re-applying it. Perks.init baselines the tracker to 0 and
-- the normal update loop re-applies the correct values.

-- ─── Attribute helpers ────────────────────────────────────────────────────
-- getActorAttrs(actor) now lives in player/stat_access.lua; setAttrContrib
-- below calls it as statAccess.getActorAttrs(getSelf()).

-- Apply a delta change to one attribute modifier.
-- Delta formula: new_mod = current_mod - prev_our_contrib + new_our_contrib
-- This stacks correctly with concurrent spell/enchantment modifiers because
-- we only adjust the portion WE own.
local function setAttrContrib(attrName, newContrib)
    local prev = perkAttrContrib[attrName] or 0
    if prev == newContrib then return end
    local attrs = statAccess.getActorAttrs(getSelf())
    if not attrs or not attrs[attrName] then return end
    local curMod = 0
    pcall(function() curMod = attrs[attrName].modifier or 0 end)
    pcall(function() attrs[attrName].modifier = curMod - prev + newContrib end)
    perkAttrContrib[attrName] = newContrib
    perkContribDirty = true
end

-- Apply a delta change to one skill modifier, mirroring setAttrContrib.
-- Uses the engine-native skill stat (writable `.modifier`); stacks correctly
-- with concurrent fortify/drain effects because we only adjust our own portion.
local function setSkillContrib(skillId, newContrib)
    local prev = perkSkillContrib[skillId] or 0
    if prev == newContrib then return end
    local stat = statAccess.getSkillStat(getSelf(), skillId)
    if not stat then return end
    local curMod = 0
    pcall(function() curMod = stat.modifier or 0 end)
    pcall(function() stat.modifier = curMod - prev + newContrib end)
    perkSkillContrib[skillId] = newContrib
end

-- ─── Desired attribute contributions ─────────────────────────────────────
-- Returns a table {attrName = desired_contribution} for the ACTIVE stance.
-- Stances not currently active contribute 0 across the board.
local function computeDesiredAttrContribs()
    local d = {}
    for _, a in ipairs(ATTR_NAMES) do d[a] = 0 end

    local sid = getActiveStance()
    if not sid then return d end
    local cl = getCoreLevel()

    -- ── Arcanist ──────────────────────────────────────────────────────────
    -- Willpower reduces spell cost in Morrowind's cast formula.
    -- Intelligence expands the magicka pool and improves Incantation refunds.
    -- Luck directly reduces spell failure probability at all schools.
    if sid == 'arcanist' and perksEnabled('arcanist') then
        if cl >= 25  then d.willpower    = d.willpower    + 5  end  -- Focused Chant
        if cl >= 50  then d.willpower    = d.willpower    + 5  end  -- Meditated Mind  (+10 total)
        if cl >= 75  then d.intelligence = d.intelligence + 5  end  -- Incanted Focus
        if cl >= 100 then d.luck         = d.luck         + 10 end  -- Aethereal Mind
    end

    -- ── Reforger ──────────────────────────────────────────────────────────
    -- Endurance reduces general fatigue drain (Anvil Arms proxy).
    -- Strength at cap makes the hammer genuinely dangerous (Forgemaster's Touch).
    if sid == 'reforger' and perksEnabled('reforger') then
        if cl >= 25  then d.endurance = d.endurance + 5  end  -- Anvil Arms
        if cl >= 100 then d.strength  = d.strength  + 15 end  -- Forgemaster's Touch
    end

    -- ── Blademeister ──────────────────────────────────────────────────────
    -- Agility governs Sneak and melee precision.
    -- Strength accumulates with each perk to represent the growing soul-pact damage.
    if sid == 'blademeister' and perksEnabled('blademeister') then
        if cl >= 25  then d.agility  = d.agility  + 5  end  -- Soul Perception (attr; SF handles Mysticism)
        if cl >= 50  then d.strength = d.strength + 5  end  -- Soul Wavelength (+15% damage proxy)
        if cl >= 75  then d.strength = d.strength + 5  end  -- Witch Hunter (+30% power attack proxy; total +10)
        if cl >= 100 then                                     -- Soul Resonance
            d.agility = d.agility + 10   -- speed/armor-ignore proxy via Agility (total +15)
            d.strength= d.strength + 5   -- damage increase proxy (total +15 Str)
        end
    end

    -- ── Huntsman ──────────────────────────────────────────────────────────
    -- Endurance: Steady Aim reduces archery fatigue drain.
    -- Agility: Killshot improves ranged accuracy.
    if sid == 'huntsman' and perksEnabled('huntsman') then
        if cl >= 25  then d.endurance = d.endurance + 5 end  -- Steady Aim
        if cl >= 100 then d.agility   = d.agility   + 5 end  -- Killshot
    end

    -- ── Twirler ───────────────────────────────────────────────────────────
    -- Agility governs thrown weapon accuracy.
    -- Perk effects are primarily broadcast (see broadcastIntegrationData).
    if sid == 'twirler' and perksEnabled('twirler') then
        if cl >= 25  then d.agility = d.agility + 5  end  -- Edged Spin (attr side)
        if cl >= 100 then d.agility = d.agility + 5  end  -- Whirlwind Arm (total +10)
    end

    -- ── Thaumaturge ───────────────────────────────────────────────────────
    -- Willpower governs stave resonance; perk effects are broadcast only.
    if sid == 'thaumaturge' and perksEnabled('thaumaturge') then
        if cl >= 25  then d.willpower = d.willpower + 5  end  -- Concussive Accord (attr side)
        if cl >= 100 then d.willpower = d.willpower + 5  end  -- Pulsed Accord (total +10)
    end

    -- ── Dualist ───────────────────────────────────────────────────────────
    -- Speed governs movement while dual-wielding (Light Footwork).
    -- Agility governs off-hand precision (Twin Tempo).
    if sid == 'dualist' and perksEnabled('dualist') then
        if cl >= 25  then d.speed   = d.speed   + 10 end  -- Light Footwork
        if cl >= 75  then d.agility = d.agility + 5  end  -- Twin Tempo
    end

    -- ── Fortifier ─────────────────────────────────────────────────────────
    -- Strength increases block push.
    -- Endurance at cap represents Bulwark's physical conditioning.
    if sid == 'fortifier' and perksEnabled('fortifier') then
        if cl >= 25  then d.strength  = d.strength  + 5 end  -- Shield Up
        if cl >= 100 then d.endurance = d.endurance + 5 end  -- Bulwark
    end

    -- ── Zweihänder ────────────────────────────────────────────────────────
    -- All Str: 25 (+5), 100 (+15 more = +20 total).
    -- On-hit effects handle arc and cleave (see Perks.onHit).
    if sid == 'zweihander' and perksEnabled('zweihander') then
        if cl >= 25  then d.strength = d.strength + 5  end  -- Two-Hand Grip
        if cl >= 100 then d.strength = d.strength + 15 end  -- Titan Grip (total +20)
    end

    -- ── Guisarmier ────────────────────────────────────────────────────────
    -- Reach Advantage / Polearm Master: Strength for spear damage.
    -- Phalanx Brace: Endurance for knockdown resist.
    if sid == 'guisarmier' and perksEnabled('guisarmier') then
        if cl >= 25  then d.strength  = d.strength  + 5  end  -- Reach Advantage
        if cl >= 50  then d.endurance = d.endurance + 10 end  -- Phalanx Brace
        if cl >= 100 then d.strength  = d.strength  + 10 end  -- Polearm Master (total +15 Str)
    end

    -- ── Pitmen ────────────────────────────────────────────────────────────
    -- Rough-Hewn / Pit Boss: Strength for pick combat damage.
    -- Mining speed/yield perks are handled by init.lua onSimplyMiningStartMining.
    if sid == 'pitmen' and perksEnabled('pitmen') then
        if cl >= 25  then d.strength = d.strength + 5  end  -- Rough-Hewn
        if cl >= 100 then d.strength = d.strength + 10 end  -- Pit Boss (total +15)
    end

    -- ── Angler ────────────────────────────────────────────────────────────
    -- Steady Grip: Endurance for fatigue reduction.
    -- Master Angler: Luck for improved catches.
    -- Catch-and-Release / Trophy Cast broadcast is in init.lua onFishingCatch.
    if sid == 'angler' and perksEnabled('angler') then
        if cl >= 25  then d.endurance = d.endurance + 5 end  -- Steady Grip
        if cl >= 100 then d.luck      = d.luck      + 5 end  -- Master Angler
    end

    -- ── Apothecary ────────────────────────────────────────────────────────
    -- Deft Hurler: Agility steadies the throw (a thrown concoction is a
    -- MarksmanThrown weapon, and Agility feeds the engine's hit-chance roll).
    -- Master Apothecary: Intelligence (the alchemist's wit) and Luck (a
    -- fortunate dose). The on-hit effects (Volatile Concoction / Corrosive
    -- Cloud / paralysis) live in Perks.onHit — the struck actor is supplied by
    -- the normal victim-side combat bridge, so they need no special hook.
    if sid == 'apothecary' and perksEnabled('apothecary') then
        if cl >= 25  then d.agility = d.agility + 5 end  -- Deft Hurler
        if cl >= 100 then                                  -- Master Apothecary
            d.intelligence = d.intelligence + 5
            d.luck         = d.luck         + 5
        end
    end

    -- ── Axeman ────────────────────────────────────────────────────────────
    -- Strength accumulates across the ladder: +5 / +10 / +20 total.
    -- Bleeding Cut is an on-hit effect (see Perks.onHit).
    if sid == 'axeman' and perksEnabled('axeman') then
        if cl >= 25  then d.strength = d.strength + 5  end  -- Cleaving Edge
        if cl >= 50  then d.strength = d.strength + 5  end  -- Heavy Chop  (total +10)
        if cl >= 100 then d.strength = d.strength + 10 end  -- Headsman    (total +20)
    end

    -- ── Mjolnir ───────────────────────────────────────────────────────────
    -- Mirror of Axeman: Strength +5 / +10 / +20 total.
    -- Concussive Force is on-hit (see Perks.onHit).
    if sid == 'mjolnir' and perksEnabled('mjolnir') then
        if cl >= 25  then d.strength = d.strength + 5  end  -- Iron Heft
        if cl >= 50  then d.strength = d.strength + 5  end  -- Crushing Blow (total +10)
        if cl >= 100 then d.strength = d.strength + 10 end  -- Thunderstrike (total +20)
    end

    -- ── Soloist ───────────────────────────────────────────────────────────
    -- Planted Feet + Unstoppable: Endurance for knockdown resist.
    -- Heavy Hand: Strength for power-attack damage.
    -- Solitary Will: large Endurance boost at cap.
    if sid == 'soloist' and perksEnabled('soloist') then
        if cl >= 25  then d.endurance = d.endurance + 10 end  -- Planted Feet
        if cl >= 50  then d.strength  = d.strength  + 5  end  -- Heavy Hand
        if cl >= 75  then d.endurance = d.endurance + 5  end  -- Unstoppable (total +15 End)
        if cl >= 100 then d.endurance = d.endurance + 15 end  -- Solitary Will (total +30 End)
    end

    -- ── Thief ─────────────────────────────────────────────────────────────
    -- Agility: Quick Strike (attack speed proxy) and Backstab (precision).
    -- Speed: Master Thief movement bonus.
    -- Cutpurse is a native Sneak modifier (see computeDesiredSkillContribs).
    if sid == 'thief' and perksEnabled('thief') then
        if cl >= 25  then d.agility = d.agility + 5  end  -- Quick Strike
        if cl >= 75  then d.agility = d.agility + 5  end  -- Backstab (total +10 Agi)
        if cl >= 100 then d.speed   = d.speed   + 10 end  -- Master Thief
    end

    -- ── Locksmith ─────────────────────────────────────────────────────────
    -- Agility governs Security, so attribute boosts complement the SF mods.
    if sid == 'locksmith' and perksEnabled('locksmith') then
        if cl >= 25  then d.agility = d.agility + 5 end  -- Light Fingers (attr side)
        if cl >= 100 then d.agility = d.agility + 5 end  -- Master of Locks (total +10)
    end

    -- ── Brawler ───────────────────────────────────────────────────────────
    -- Iron Grip: Strength for HtH damage.
    -- Close-Range Fighter: Endurance for fatigue reduction.
    -- Street Master: further Strength + Endurance at cap.
    -- Concussive Jab is on-hit (see Perks.onHit).
    if sid == 'brawler' and perksEnabled('brawler') then
        if cl >= 25  then d.strength  = d.strength  + 10 end  -- Iron Grip
        if cl >= 50  then d.endurance = d.endurance + 5  end  -- Close-Range Fighter
        if cl >= 100 then                                      -- Street Master
            d.strength  = d.strength  + 5
            d.endurance = d.endurance + 5
        end
    end

    -- ── Commoner ──────────────────────────────────────────────────────────
    -- Luck: Merchant's Eye (barter rolls) and People's Hero (total +10).
    -- Personality: Urban Charm (Admire) and People's Hero (total +10).
    -- Silver Tongue is a native Speechcraft modifier (see computeDesiredSkillContribs).
    if sid == 'commoner' and perksEnabled('commoner') then
        if cl >= 25  then d.luck        = d.luck        + 5 end  -- Merchant's Eye
        if cl >= 75  then d.personality = d.personality + 5 end  -- Urban Charm
        if cl >= 100 then
            d.luck        = d.luck        + 5  -- People's Hero (total +10 Luck)
            d.personality = d.personality + 5  -- People's Hero (total +10 Per)
        end
    end

    return d
end

-- Sync desired contributions to the actor's actual attribute modifiers.
local function updateAttributePerks()
    local desired = computeDesiredAttrContribs()
    for _, a in ipairs(ATTR_NAMES) do
        setAttrContrib(a, desired[a] or 0)
    end
    if perkContribDirty then savePerkContribs() end
end

-- ─── Perk skill bonuses (native skill modifiers) ──────────────────────────
-- These were previously registered via I.SkillFramework.registerDynamicModifier
-- against VANILLA skill ids. Skill Framework only manages its own custom
-- skills, so getSkillRecord('sneak') etc. returned nil and the modifiers were
-- never attached — every one of these bonuses silently did nothing. We now
-- compute the desired per-skill contribution each frame and apply it through
-- the engine-native skill `.modifier` field (the same mechanism the attribute
-- perks use), which works on all vanilla skills.
--
-- Only one stance is active at a time, so contributions never overlap across
-- stances; within a stance, two perks targeting the same skill (none today)
-- would simply sum here.
local function computeDesiredSkillContribs()
    local d = {}
    for _, s in ipairs(SKILL_NAMES) do d[s] = 0 end

    -- Blademeister — Soul Perception (25): +5 Mysticism
    if perkActive('blademeister', 25) then d.mysticism = d.mysticism + 5 end
    -- Thief — Cutpurse (50): +5 Sneak
    if perkActive('thief', 50) then d.sneak = d.sneak + 5 end
    -- Locksmith — Light Fingers (25): +5 Security
    if perkActive('locksmith', 25) then d.security = d.security + 5 end
    -- Locksmith — Sneak Step (75): +5 Sneak
    if perkActive('locksmith', 75) then d.sneak = d.sneak + 5 end
    -- Commoner — Silver Tongue (50): +5 Speechcraft
    if perkActive('commoner', 50) then d.speechcraft = d.speechcraft + 5 end

    return d
end

local function updateSkillPerks()
    local desired = computeDesiredSkillContribs()
    for _, s in ipairs(SKILL_NAMES) do
        setSkillContrib(s, desired[s] or 0)
    end
end

-- ─── On-hit helpers ───────────────────────────────────────────────────────
local function roll(chance) return math.random() < chance end

-- Dispatch an effect to global.lua for world-scope application to target.
local function sendEffect(target, effectId, magnitude, duration)
    if not target then return end
    pcall(core.sendGlobalEvent, 'Stance_PerkEffect', {
        target     = target,
        effectId   = effectId,
        effectName = EFF_NAME[effectId] or 'unknown',
        magnitude  = magnitude,
        duration   = duration,
    })
end

-- True when the weapon in this attack is a ranged type.
local function isRangedAttack(attack)
    if not attack or not attack.weapon then return false end
    local ok, rec = pcall(types.Weapon.record, attack.weapon)
    if not ok or not rec then return false end
    local WT = (types.Weapon and types.Weapon.TYPE) or {}
    return rec.type == WT.MarksmanBow
        or rec.type == WT.MarksmanCrossbow
        or rec.type == WT.MarksmanThrown
end

-- True when the attack looks like a sneak attack.
-- Tries attack.isSneakAttack first (available on some builds); falls back
-- to checking whether the player actor is currently sneaking.
local function isSneakAttack(attack)
    local flag = nil
    pcall(function() flag = attack.isSneakAttack end)
    if flag ~= nil then return flag == true end
    local actor = getSelf()
    if not actor then return false end
    local ok, sneaking = pcall(function()
        return types.Actor.isSneaking and types.Actor.isSneaking(actor)
    end)
    return ok and sneaking == true
end

-- ─── On-hit perk dispatch (Perks.onHit) ──────────────────────────────────
-- Called from init.lua's onPlayerDealtHit (the Stance_PlayerDealtHit event
-- handler fed by scripts/stance/victim.lua) AFTER hit XP is credited.

function Perks.onHit(attack)
    if not C then return end
    if not readSetting('', 'enabled', true) then return end
    if not attack or not attack.target then return end

    local sid = getActiveStance()
    if not sid then return end
    local cl  = getCoreLevel()
    local tgt = attack.target

    -- ── Reforger ──────────────────────────────────────────────────────────
    -- Weak-Point Strike (50): every hammer blow drives a small burst of
    -- DamageHealth — the armorer's eye finding the thin rivet on every swing.
    -- Sundering Blow (75): 10% chance per hit to drain target fatigue,
    -- disrupting armor rhythm (armor-condition damage proxy).
    if sid == 'reforger' and perksEnabled('reforger') then
        if cl >= 50 then
            sendEffect(tgt, EFF.DamageHealth, 3, 0)
        end
        if cl >= 75 and roll(0.10) then
            sendEffect(tgt, EFF.DamageFatigue, 15, 0)
        end
    end

    -- ── Blademeister ──────────────────────────────────────────────────────
    -- Soul Wavelength (50): 10% chance per hit to disrupt the target's
    -- concentration (DamageFatigue — the resonance interrupts their form).
    -- Witch Hunter (75): 15% chance of a resonant strike (DamageHealth).
    -- Soul Resonance (100): 5% chance of a brief Paralyze (armor-bypass via
    -- the blade finding a gap the soul-pact reveals).
    if sid == 'blademeister' and perksEnabled('blademeister') then
        if cl >= 50 and roll(0.10) then
            sendEffect(tgt, EFF.DamageFatigue, 10, 0)
        end
        if cl >= 75 and roll(0.15) then
            sendEffect(tgt, EFF.DamageHealth, 5, 0)
        end
        if cl >= 100 and roll(0.05) then
            sendEffect(tgt, EFF.Paralyze, 1, 0.5)
        end
    end

    -- ── Huntsman ──────────────────────────────────────────────────────────
    -- Pinning Shot (50): ranged hits apply Burden (slow) for 3 seconds.
    -- Concussive Shot (75): ranged hits also drain 25 fatigue.
    -- Killshot (100): ranged hits deal additional DamageHealth (25% damage
    -- bonus simulated as a fixed extra hit).
    if sid == 'huntsman' and perksEnabled('huntsman') then
        if isRangedAttack(attack) then
            if cl >= 50 then
                sendEffect(tgt, EFF.Burden, 40, 3)
            end
            if cl >= 75 then
                sendEffect(tgt, EFF.DamageFatigue, 25, 0)
            end
            if cl >= 100 then
                sendEffect(tgt, EFF.DamageHealth, 10, 0)
            end
        end
    end

    -- ── Apothecary ────────────────────────────────────────────────────────
    -- Effects of a landed concoction. Apothecary is only ever active with a
    -- Thrown Concoction (a MarksmanThrown weapon) equipped, so the ranged-hit
    -- guard is effectively always true here — it is kept for symmetry with
    -- Huntsman and as defence against a future melee-capable concoction.
    -- Volatile Concoction (50): 25% chance the flask bursts hard enough to
    --   stagger the victim, draining fatigue.
    -- Corrosive Cloud (75): every landed concoction leaves a brief caustic
    --   cloud — a 5-second DamageHealth DoT (1 pt/s), stacking duration like
    --   Axeman's bleed.
    -- Master Apothecary (100): 10% chance the toxic shock paralyses outright
    --   for a brief moment.
    if sid == 'apothecary' and perksEnabled('apothecary') then
        if isRangedAttack(attack) then
            if cl >= 50 and roll(0.25) then
                sendEffect(tgt, EFF.DamageFatigue, 15, 0)
            end
            if cl >= 75 then
                sendEffect(tgt, EFF.DamageHealth, 1, 5)
            end
            if cl >= 100 and roll(0.10) then
                sendEffect(tgt, EFF.Paralyze, 1, 0.5)
            end
        end
    end

    -- ── Guisarmier ────────────────────────────────────────────────────────
    -- Pinning Thrust (75): 10% chance per hit to slow the target (Burden 2s).
    if sid == 'guisarmier' and perksEnabled('guisarmier') then
        if cl >= 75 and roll(0.10) then
            sendEffect(tgt, EFF.Burden, 30, 2)
        end
    end

    -- ── Axeman ────────────────────────────────────────────────────────────
    -- Bleeding Cut (75): every axe hit applies a 5-second DamageHealth DoT
    -- (1 pt/s).  Multiple hits stack duration in the engine's effect system.
    -- Headsman (100): 10% chance to bypass a portion of armor
    -- (simulated as bonus DamageHealth on a successful chance roll).
    if sid == 'axeman' and perksEnabled('axeman') then
        if cl >= 75 then
            sendEffect(tgt, EFF.DamageHealth, 1, 5)
        end
        if cl >= 100 and roll(0.10) then
            sendEffect(tgt, EFF.DamageHealth, 5, 0)
        end
    end

    -- ── Mjolnir ───────────────────────────────────────────────────────────
    -- Concussive Force (75): 10% chance per hit to stagger (Paralyze 0.5s).
    -- Thunderstrike (100): additional 10% armor-bypass chance
    -- (bonus DamageHealth on roll).
    if sid == 'mjolnir' and perksEnabled('mjolnir') then
        if cl >= 75 and roll(0.10) then
            sendEffect(tgt, EFF.Paralyze, 1, 0.5)
        end
        if cl >= 100 and roll(0.10) then
            sendEffect(tgt, EFF.DamageHealth, 5, 0)
        end
    end

    -- ── Zweihänder ────────────────────────────────────────────────────────
    -- Sweeping Arc (50): 15% chance — the wide blade clips a second enemy;
    -- simulated as bonus DamageFatigue on the primary target (stance disruption).
    -- Cleaving Blow (75): 10% chance to bypass armor (bonus DamageHealth).
    -- Titan Grip (100): fatigue drain from swings halved — no per-hit effect;
    -- handled by the +15 Strength attribute bonus in computeDesired.
    if sid == 'zweihander' and perksEnabled('zweihander') then
        if cl >= 50 and roll(0.15) then
            sendEffect(tgt, EFF.DamageFatigue, 8, 0)
        end
        if cl >= 75 and roll(0.10) then
            sendEffect(tgt, EFF.DamageHealth, 5, 0)
        end
    end

    -- ── Soloist ───────────────────────────────────────────────────────────
    -- Unstoppable (75): 10% chance to stagger (Paralyze 0.5s).
    if sid == 'soloist' and perksEnabled('soloist') then
        if cl >= 75 and roll(0.10) then
            sendEffect(tgt, EFF.Paralyze, 1, 0.5)
        end
    end

    -- ── Thief ─────────────────────────────────────────────────────────────
    -- Backstab (75): bonus DamageHealth on sneak attacks.
    -- Master Thief (100): short blade does 25% more; simulated as additional
    -- DamageHealth on every hit at cap level.
    if sid == 'thief' and perksEnabled('thief') then
        if cl >= 75 and isSneakAttack(attack) then
            sendEffect(tgt, EFF.DamageHealth, 8, 0)
        end
        if cl >= 100 then
            sendEffect(tgt, EFF.DamageHealth, 4, 0)
        end
    end

    -- ── Brawler ───────────────────────────────────────────────────────────
    -- Concussive Jab (75): 15% chance per hit to knock down (Paralyze 1s).
    --   Also broadcast Stance_BrawlerKnockdown so Gothic Style Knockout
    --   bridges can respond and integrate their own knockdown system.
    -- Street Master (100): each unarmed hit restores 5 fatigue to self.
    if sid == 'brawler' and perksEnabled('brawler') then
        if cl >= 75 and roll(0.15) then
            sendEffect(tgt, EFF.Paralyze, 1, 1.0)
            pcall(core.sendGlobalEvent, 'Stance_BrawlerKnockdown', {
                coreLevel = cl,
            })
        end
        if cl >= 100 then
            local actor = getSelf()
            if actor then
                pcall(function()
                    local dyn = statAccess.dynamic(actor)
                    local fat = dyn.fatigue
                    if fat then
                        fat.current = math.min(fat.modified, fat.current + 5)
                    end
                end)
            end
        end
    end
end

-- ─── On-parry perk dispatch (Perks.onParry) ───────────────────────────────
-- Called from init.lua's onNGardeParrySuccess AFTER XP is credited.

function Perks.onParry()
    if not C then return end
    if not readSetting('', 'enabled', true) then return end

    local sid = getActiveStance()
    if sid ~= 'fortifier' then return end
    if not perksEnabled('fortifier') then return end

    local cl  = getCoreLevel()
    local now = core.getSimulationTime()

    -- Bulwark (100): once per 30 seconds, partially absorb an incoming blow.
    -- Restores up to 5% of max health as a "blocked damage burst", then
    -- broadcasts so N'Garde bridges can react to the activation.
    if cl >= 100 and (now - bulwarkLastFired) >= 30.0 then
        bulwarkLastFired = now
        local actor = getSelf()
        if actor then
            pcall(function()
                local dyn = statAccess.dynamic(actor)
                local hp = dyn.health
                if hp then
                    local restore = math.min(hp.modified * 0.05, hp.modified - hp.current)
                    if restore > 0 then hp.current = hp.current + restore end
                end
            end)
        end
        pcall(core.sendGlobalEvent, 'Stance_BulwarkActivated', {
            stanceLevel = getStanceLevel('fortifier'),
            coreLevel   = cl,
        })
    end

    -- Always broadcast current Fortifier modifier values so N'Garde bridge
    -- scripts can widen the parry window (Warden Stance, lv50) and improve
    -- perfect-parry rebound (Perfect Guard, lv75).
    pcall(core.sendGlobalEvent, 'Stance_FortifierParryBonus', {
        parryWindowMult = cl >= 50 and 1.25 or 1.0,   -- Warden Stance
        reboundBonus    = cl >= 75 and 0.20 or 0.0,   -- Perfect Guard
        coreLevel       = cl,
    })
end

-- ─── On-kill hook (Perks.onKill) ──────────────────────────────────────────
-- Called from init.lua's onStanceKillGrant after XP is credited.
-- Currently no stance has a kill-triggered perk; the hook is reserved for
-- future expansion.
function Perks.onKill()
    -- (intentionally empty — wired up for forward compatibility)
end

-- ─── Integration broadcast perks ──────────────────────────────────────────
-- Broadcast current perk modifier values once per BROADCAST_INTERVAL so
-- partner mods / bridge scripts always have fresh data.
-- This mirrors the existing Fishing / SimplyMining broadcast pattern.

local function broadcastIntegrationData(now)
    if (now - broadcastLastAt) < BROADCAST_INTERVAL then return end
    broadcastLastAt = now

    local sid = getActiveStance()
    if not sid then return end
    local cl = getCoreLevel()

    -- ── Twirler → Throwing! ───────────────────────────────────────────────
    if sid == 'twirler' and perksEnabled('twirler') and intPresent('throwing') then
        pcall(core.sendGlobalEvent, 'Stance_TwirlerBonuses', {
            critBonus     = cl >= 25  and 0.03 or 0.0,  -- Edged Spin
            twinBonus     = cl >= 50  and 0.05 or 0.0,  -- Twinned Throw
            bleedBonus    = cl >= 75  and 1    or 0,    -- Rending Hand (magnitude floor)
            paralyzeBonus = cl >= 100 and 1.0  or 0.0,  -- Whirlwind Arm (extra seconds)
            coreLevel     = cl,
        })
    end

    -- ── Thaumaturge → Staves! ─────────────────────────────────────────────
    if sid == 'thaumaturge' and perksEnabled('thaumaturge') and intPresent('staves') then
        pcall(core.sendGlobalEvent, 'Stance_ThaumaturgeBonuses', {
            concussiveBonus = cl >= 25  and 0.10 or 0.0,  -- Concussive Accord
            siphonBonus     = cl >= 50  and 0.05 or 0.0,  -- Siphoned Accord
            resonantBonus   = cl >= 75  and 0.03 or 0.0,  -- Resonant Accord
            pulseBonus      = cl >= 100 and 2.0  or 0.0,  -- Pulsed Accord (extra seconds)
            coreLevel       = cl,
        })
    end

    -- ── Dualist → Dual Wielding + N'Garde ────────────────────────────────
    if sid == 'dualist' and perksEnabled('dualist') and intPresent('dualwielding') then
        pcall(core.sendGlobalEvent, 'Stance_DualistBonuses', {
            offHandBonus      = cl >= 50  and 0.15 or 0.0,  -- Mirror Edge
            attackSpeedBonus  = cl >= 75  and 0.15 or 0.0,  -- Twin Tempo
            crossGuardActive  = cl >= 100,                   -- Cross Guard
            coreLevel         = cl,
        })
        -- Cross Guard (100): separate event for N'Garde bridge to grant
        -- parry capability as though a shield were held.
        if cl >= 100 and intPresent('ngarde') then
            pcall(core.sendGlobalEvent, 'Stance_DualistCrossGuard', {
                active    = true,
                coreLevel = cl,
            })
        end
    end

    -- ── Locksmith → probe / lock mods ────────────────────────────────────
    if sid == 'locksmith' and perksEnabled('locksmith') then
        pcall(core.sendGlobalEvent, 'Stance_LocksmithBonuses', {
            probeBreakReduction = cl >= 50  and 0.10 or 0.0,  -- Probe Sage
            lockDiffReduction   = cl >= 100 and 15   or 0,   -- Master of Locks
            coreLevel           = cl,
        })
    end
end

-- ─── Main update (Perks.update) ───────────────────────────────────────────
-- Called from init.lua's onUpdate once per poll tick, after applyActiveStance.

function Perks.update(now)
    if not C then return end

    -- When the mod is globally disabled, clear all attribute bonuses cleanly.
    if not readSetting('', 'enabled', true) then
        for _, a in ipairs(ATTR_NAMES) do setAttrContrib(a, 0) end
        for _, s in ipairs(SKILL_NAMES) do setSkillContrib(s, 0) end
        if perkContribDirty then savePerkContribs() end
        return
    end

    updateAttributePerks()
    updateSkillPerks()
    broadcastIntegrationData(now)
end

-- ─── Initialisation (Perks.init) ─────────────────────────────────────────
-- Called lazily from init.lua's ensurePerksInit, which fires on the first
-- onUpdate after load.
--
-- IMPORTANT — runtime-modifier reset on load:
--   setAttrContrib writes the engine's attribute `.modifier` field, which is a
--   RUNTIME modifier the engine does NOT persist — it is reset to 0 whenever a
--   save is loaded. Our own per-attribute bookkeeping (perkAttrContrib) must
--   therefore also start at 0 on load, so the first computeDesiredAttrContribs
--   pass re-applies the full, correct contribution onto the freshly-zeroed
--   engine modifier.
--
--   The previous version restored perkAttrContrib from persistent storage on
--   load. That desynced the two: the engine modifier was 0 but our tracker
--   said (e.g.) +15, so setAttrContrib saw prev==new and skipped the write —
--   the bonus silently vanished, and dual-applied attribute/skill bonuses
--   could read at stale or capped values across reloads. We now baseline to 0
--   and let the normal update loop reconcile.
function Perks.init(context)
    C = context

    -- Reset volatile state.
    bulwarkLastFired = -math.huge
    broadcastLastAt  = -math.huge

    -- The engine's attribute AND skill modifiers are 0 at load time, so our
    -- tracked contributions must be 0 too. The next Perks.update reconciles
    -- them to the active stance's desired contributions.
    for _, a in ipairs(ATTR_NAMES)  do perkAttrContrib[a]  = 0 end
    for _, s in ipairs(SKILL_NAMES) do perkSkillContrib[s] = 0 end
    perkContribDirty = false
end

return Perks
