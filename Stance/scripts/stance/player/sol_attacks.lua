--[[
    Stance! — Sol combat-mod integrations (player/sol_attacks.lua)

    Integrates two of Solthas's weapon-combat-buff mods with Stance!, the same
    way every other external mod is wired: detection is done by init.lua's
    config.integrations table (a settings-group probe — see config.lua), the
    bonus is applied here through the same delta-accounted native-modifier path
    the effectiveness / Fortified / Smoking bonuses use, and the result is
    surfaced in the skill tooltip.

      • SolTimedDirAttacks (STDA) — "Timed Directional Attacks". Time your
        chop / slash / thrust well and you earn a transient buff; fumble and you
        lose fatigue and speed. A directional, finesse, tempo-driven system.

      • SolWeightyChargeAttacks (SWCA) — "Weighty Charged Attacks". Charge a
        heavy attack (slowed while you wind up) to earn a release buff that
        scales with weapon weight and charge time. A heavy, committed,
        power-driven system.

    DESIGN — how the integration augments these mods
    ────────────────────────────────────────────────
    Neither Sol mod fires a public event Stance! could listen on (they run
    entirely off per-frame input polling and apply their own transient stat
    modifiers internally), so — exactly like the Evasion! integration —
    Stance! does NOT try to hook the Sol mods' moment-to-moment logic. Instead
    it grants the ACTIVE stance a passive, delta-accounted bonus to that
    stance's own weapon skill, representing the stance's growing mastery of the
    Sol technique. It compounds with the Sol mod's own transient buff without
    touching it (separate deltas, never double-counted), so the better you get
    at a stance, the more its signature timed / weighty strike rewards you.

    Which stances benefit, and how much, is curated for immersion (see
    config.solAffinity): nimble, tempo-driven stances lean into TIMED directional
    attacks; heavy, committed stances lean into WEIGHTY charged attacks. A few
    weapons that can be played either way appear in both, weighted differently.

    MAGNITUDE — read from the Sol mod's own settings, scaled by stance level
    ────────────────────────────────────────────────────────────────────────
      • The CEILING of each bonus is derived from the Sol mod's OWN live
        settings (probed from its settings section), so the integration always
        tracks however the player has tuned that Sol mod:
          - TIMED   ceiling = round(weight × STDA.buffBase)
                    (STDA.buffBase is a flat skill-point buff; default 10.)
          - WEIGHTY ceiling = round(weight × repBuff), where
                    repBuff = ceil(SWCA.buffBase × (1 + sqrt(W)) × SWCA.maxCharge)
                    mirrors SWCA's own release-buff formula at full charge for
                    the equipped weapon weight W (clamped), so a heavier weapon
                    in the same stance yields a weightier bonus — exactly the
                    "weighty" feel SWCA is built around. (SWCA.buffBase default 2,
                    SWCA.maxCharge default 2.)
      • The bonus then SCALES with the stance's OWN level on the same linear
        ramp the per-stance effectiveness and evasion bonuses use: 0 at
        config.startLevel rising to the full ceiling at config.maxLevel.

    State here (appliedTimed / appliedWeighty) is a TRANSIENT delta tracker —
    the engine zeroes stat modifiers on load, and init.lua's onLoad calls
    clearSolBonuses() to zero the tracker in step (mirrors clearEvasionBonus /
    clearSmokingSpeedOffset), so this is mid-save safe.

    Dependencies (injected via ctx):
        self, types        — engine handles
        config             — scripts.stance.config
        readSetting        — function(group, key, default) → value   (Stance's own)
        readForeignSetting — function(sectionName, key, default) → value (Sol mods')
        getStanceLevel     — function(stanceId) → number
        getActiveStance    — function() → activeStanceId (string|nil)
        integrationPresent — function(integrationId) → boolean
        resolveStanceSkill — function(stanceId) → vanilla skill id | modded id | nil
        getRightHandWeapon — function() → equipped right-hand item | nil
        safeWeaponRecord   — function(item) → weapon record | nil
]]

local M = {}

-- Sol mods' settings sections and the keys we read from them. Defaults match
-- the Sol mods' own declared defaults, used as a fallback when a key can't be
-- read (e.g. the Sol mod is present but a setting hasn't been written yet).
local STDA_SECTION = 'Settings_SolTimedDirAttacks'
local SWCA_SECTION = 'Settings_SolWeightyChargeAttacks'

function M.new(ctx)
    local self  = ctx.self
    local types = ctx.types
    local config = ctx.config
    local readSetting        = ctx.readSetting
    local readForeignSetting = ctx.readForeignSetting
    local getStanceLevel     = ctx.getStanceLevel
    local getActiveStance    = ctx.getActiveStance
    local integrationPresent = ctx.integrationPresent
    local resolveStanceSkill = ctx.resolveStanceSkill
    local getRightHandWeapon = ctx.getRightHandWeapon
    local safeWeaponRecord   = ctx.safeWeaponRecord

    -- Our own delta trackers; never shared. Each records the skill we last
    -- wrote to and the amount of our contribution, so when the active stance
    -- (and therefore the target skill) changes we can pull our bonus off the
    -- old skill before applying to the new one.
    local appliedTimed   = { skill = nil, amount = 0 }
    local appliedWeighty = { skill = nil, amount = 0 }

    -- ─── Helpers ─────────────────────────────────────────────────────────

    -- Linear stance-level ramp: 0 at startLevel → 1 at maxLevel. Identical to
    -- the curve used by effectivenessSkillBonus and getStanceEvasionBonus.
    local function levelFactor(stanceId)
        local lo  = config.startLevel or 5
        local hi  = config.maxLevel   or 100
        if hi <= lo then return 1 end
        local lvl = getStanceLevel(stanceId)
        local t = (lvl - lo) / (hi - lo)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        return t
    end

    -- The affinity record for a stance under a given Sol system ('timed' |
    -- 'weighty'), or nil if the stance has no affinity with that system.
    local function affinity(stanceId, key)
        local a = config.solAffinity and config.solAffinity[stanceId]
        return a and a[key] or nil
    end

    -- Resolve the native (vanilla) skill accessor function for the active
    -- stance's target skill, or nil. Modded Skill-Framework skills (mining_skill,
    -- fishing_skill, staves_staves, throwing, …) are NOT keys on
    -- types.NPC.stats.skills, so this returns nil for them and the bonus is
    -- simply not applied (the curated affinity set only contains stances whose
    -- target resolves to a vanilla weapon skill, so this is belt-and-braces).
    local function targetSkillAccessor(stanceId)
        local skillId = resolveStanceSkill(stanceId)
        if type(skillId) ~= 'string' then return nil, nil end
        local skillsTable = types.NPC and types.NPC.stats and types.NPC.stats.skills
        local accessor = skillsTable and skillsTable[skillId]
        if type(accessor) ~= 'function' then return nil, nil end
        return accessor, skillId
    end

    -- Live weight of the equipped right-hand weapon (1 for hand-to-hand or any
    -- unreadable record), clamped to config.solWeapWeightCap so an absurdly
    -- heavy modded weapon can't drive a runaway weighty bonus. Mirrors SWCA's
    -- own "weight = 1 when handtohand" convention.
    local function equippedWeaponWeight()
        local item = getRightHandWeapon()
        if not item then return 1 end
        local rec = safeWeaponRecord(item)
        local w = rec and tonumber(rec.weight) or 1
        if not w or w < 1 then w = 1 end
        local cap = tonumber(config.solWeapWeightCap) or 30
        if w > cap then w = cap end
        return w
    end

    -- ─── Bonus magnitudes (public, per-stance, current-state) ─────────────

    -- TIMED (STDA) ceiling = round(weight × STDA.buffBase). buffBase is read
    -- live from STDA's settings so the integration tracks the player's tuning.
    local function timedBonusFor(stanceId)
        if not stanceId then return 0 end
        if not readSetting('', 'enabled', true) then return 0 end
        if not integrationPresent('soltimeddirattacks') then return 0 end
        local aff = affinity(stanceId, 'timed')
        if not aff then return 0 end
        if not targetSkillAccessor(stanceId) then return 0 end
        local buffBase = tonumber(readForeignSetting(STDA_SECTION, 'buffBase', 10)) or 10
        if buffBase <= 0 then return 0 end
        local weight  = tonumber(aff.weight) or 1
        local ceiling = weight * buffBase
        return math.floor(ceiling * levelFactor(stanceId) + 0.5)
    end

    -- WEIGHTY (SWCA) ceiling = round(weight × repBuff), repBuff mirroring SWCA's
    -- release-buff formula at full charge for the equipped weapon weight.
    local function weightyBonusFor(stanceId)
        if not stanceId then return 0 end
        if not readSetting('', 'enabled', true) then return 0 end
        if not integrationPresent('solweightychargeattacks') then return 0 end
        local aff = affinity(stanceId, 'weighty')
        if not aff then return 0 end
        if not targetSkillAccessor(stanceId) then return 0 end
        local buffBase  = tonumber(readForeignSetting(SWCA_SECTION, 'buffBase', 2)) or 2
        local maxCharge = tonumber(readForeignSetting(SWCA_SECTION, 'maxCharge', 2)) or 2
        if buffBase <= 0 or maxCharge <= 0 then return 0 end
        local W = equippedWeaponWeight()
        local repBuff = math.ceil(buffBase * (1 + math.sqrt(W)) * maxCharge)
        local weight  = tonumber(aff.weight) or 1
        local ceiling = weight * repBuff
        return math.floor(ceiling * levelFactor(stanceId) + 0.5)
    end

    -- Signature label strings (for the tooltip). '' when no affinity.
    local function timedSignature(stanceId)
        local aff = affinity(stanceId, 'timed')
        return (aff and aff.dir) or ''
    end
    local function weightySignature(stanceId)
        local aff = affinity(stanceId, 'weighty')
        return (aff and aff.sig) or ''
    end

    -- ─── Application (native skill .modifier delta path) ──────────────────

    -- Remove our tracked contribution from a skill by id, if any. pcall-guarded.
    local function peel(tracker)
        if tracker.skill and tracker.amount ~= 0 then
            local skillsTable = types.NPC and types.NPC.stats and types.NPC.stats.skills
            local oldAccessor = skillsTable and skillsTable[tracker.skill]
            if type(oldAccessor) == 'function' then
                pcall(function()
                    local stat = oldAccessor(self)
                    if stat then stat.modifier = math.max(0, (stat.modifier or 0) - tracker.amount) end
                end)
            end
        end
    end

    -- Apply `newAmount` to `newSkillId`'s native modifier, tracked in
    -- `tracker`, using the same delta formula the Smoking/Fortified/perk
    -- systems use: write = current − our_previous + our_new. Because we only
    -- ever adjust the portion we ourselves track, this stacks cleanly with the
    -- Sol mod's own transient modifier, with the effectiveness bonus on the same
    -- skill, and with any perk/spell modifier — no double-counting, no stomping.
    -- When the target skill changes (stance switch, dynamic Dualist/Blademeister
    -- weapon swap, or the skill becoming unavailable), our old contribution is
    -- first removed from the previous skill.
    local function applyToSkill(tracker, newSkillId, newAccessor, newAmount)
        -- If the skill changed, peel our old contribution off the old skill.
        if tracker.skill and tracker.skill ~= newSkillId then
            peel(tracker)
            tracker.skill  = nil
            tracker.amount = 0
        end

        if not newSkillId or not newAccessor then
            -- No valid target this tick: pull our contribution off whatever we
            -- last wrote to.
            peel(tracker)
            tracker.skill  = nil
            tracker.amount = 0
            return
        end

        if newAmount == tracker.amount and newSkillId == tracker.skill then
            return -- nothing to do
        end

        pcall(function()
            local stat = newAccessor(self)
            if not stat then return end
            local cur = stat.modifier or 0
            stat.modifier = math.max(0, cur - tracker.amount + newAmount)
        end)
        tracker.skill  = newSkillId
        tracker.amount = newAmount
    end

    -- Refresh both Sol bonuses for the active stance. Called every poll tick
    -- (same cadence as refreshEvasionBonus / refreshEffectivenessModifiers).
    local function refreshSolBonuses()
        local stanceId = getActiveStance()
        local accessor, skillId = nil, nil
        if stanceId then accessor, skillId = targetSkillAccessor(stanceId) end

        local timed   = stanceId and timedBonusFor(stanceId)   or 0
        local weighty = stanceId and weightyBonusFor(stanceId) or 0

        -- Both systems target the SAME resolved weapon skill of the active
        -- stance; each tracker only ever adjusts its own delta, so applying
        -- them in sequence to the same skill composes correctly.
        applyToSkill(appliedTimed,   timed   > 0 and skillId or nil, timed   > 0 and accessor or nil, timed)
        applyToSkill(appliedWeighty, weighty > 0 and skillId or nil, weighty > 0 and accessor or nil, weighty)
    end

    -- Zero our trackers without writing to the engine. Called from init.lua's
    -- onLoad because the engine zeroes all stat modifiers on load; our tracker
    -- must match or the first refresh would compute its delta against a stale
    -- baseline and over-apply. Mirrors clearEvasionBonus / clearSmokingSpeedOffset.
    local function clearSolBonuses()
        appliedTimed.skill, appliedTimed.amount = nil, 0
        appliedWeighty.skill, appliedWeighty.amount = nil, 0
    end

    return {
        refreshSolBonuses  = refreshSolBonuses,
        clearSolBonuses    = clearSolBonuses,
        -- Tooltip accessors (per-stance, reflect current live state).
        getStanceTimedBonus      = timedBonusFor,
        getStanceWeightyBonus    = weightyBonusFor,
        getStanceTimedSignature  = timedSignature,
        getStanceWeightySignature = weightySignature,
    }
end

return M
