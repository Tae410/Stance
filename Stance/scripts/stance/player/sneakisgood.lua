-- ────────────────────────────────────────────────────────────────────────────
-- Stance! ↔ SneakIsGoodNow integration module
-- ────────────────────────────────────────────────────────────────────────────
--
-- When SneakIsGoodNow is active, Stance! provides two sneak-bonus systems:
--
-- 1. Attentiveness bonus: makes enemies harder to detect. Applied via the
--    SneakIsGoodNow interface's elusivenessMod field. Scales with both stance
--    level and the player's sneak skill.
--
-- 2. Weapon skill bonus while sneaking: for stances with sneakWeaponSkillBonus,
--    a transient bonus to the stance's target weapon skill, applied only while
--    the player is crouched/sneaking. Like the Fortified Block bonus, it's
--    computed per-tick and cleared when sneak ends.

local M = {}

function M.new(ctx)
    local self = ctx.self
    local types = ctx.types
    local core = ctx.core
    local config = ctx.config
    local readSetting = ctx.readSetting
    local debugLog = ctx.debugLog
    local getActiveStance = ctx.getActiveStance
    local getStanceLevel = ctx.getStanceLevel
    local getActiveStanceConfig = ctx.getActiveStanceConfig
    local currentFortifiedBlockBonus = ctx.currentFortifiedBlockBonus

    -- Check if SneakIsGoodNow is available. Store reference for later use.
    local I = require('openmw.interfaces')
    local sneakIsGood = I.SneakIsGoodNow

    local lastRefreshedSneak = false

    -- ────────────────────────────────────────────────────────────────────
    -- Attentiveness bonus: scales elusivenessMod to make detection harder.
    -- ────────────────────────────────────────────────────────────────────

    local function refreshAttentivenessBonus()
        if not sneakIsGood or not readSetting('', 'enabled', true) then return end
        if not readSetting('Integrations', 'integrateSneakIsGoodNow', true) then return end

        local playerIsSneaking = sneakIsGood.playerState.isSneaking or false
        if not playerIsSneaking then
            -- Not sneaking; don't apply any bonus (vanilla elusiveness).
            if lastRefreshedSneak then
                sneakIsGood.extraMods.elusivenessMod = 1.0
                lastRefreshedSneak = false
                debugLog('SneakIsGoodNow attentiveness reset (not sneaking).', 'debugSneakBonus')
            end
            return
        end

        -- Player is sneaking. Compute attentiveness bonus.
        local activeId = getActiveStance()
        if not activeId then return end

        local stanceLevel = getStanceLevel(activeId) or 5
        local sneakSkill = (types.NPC.stats.skills.sneak(self).modified) or 0

        -- Attentiveness multiplier formula:
        -- 1.0 + (stance_level / 100) * attentivenessPerLevel
        --     + (sneak_skill / 100) * attentivenessPerSkill
        local perLevelParam = config.sneak.attentivenessPerLevel or 0.5
        local perSkillParam = config.sneak.attentivenessPerSkill or 0.3
        local levelTerm = (stanceLevel / 100) * perLevelParam
        local skillTerm = (sneakSkill / 100) * perSkillParam
        local elusivenessMod = 1.0 + levelTerm + skillTerm

        -- Clamp to reasonable bounds (can't be negative, and 2.0 is a reasonable max).
        elusivenessMod = math.max(0.5, math.min(2.0, elusivenessMod))

        sneakIsGood.extraMods.elusivenessMod = elusivenessMod
        lastRefreshedSneak = true
        debugLog(string.format(
            'SneakIsGoodNow attentiveness bonus: %.2f (level %d + sneak %d)',
            elusivenessMod, stanceLevel, sneakSkill), 'debugSneakBonus')
    end

    -- ────────────────────────────────────────────────────────────────────
    -- Weapon skill bonus while sneaking: transient bonus to the stance's
    -- target skill, applied only while crouched.
    -- ────────────────────────────────────────────────────────────────────

    local function refreshSneakWeaponSkillBonus()
        -- This bonus is computed and applied in skill_framework.lua's
        -- refreshEffectivenessModifiers function, where it's paired with
        -- other transient bonuses. This function is a no-op stub; the
        -- logic lives in that file for coherence with the effectiveness system.
        -- (The bonus is delivered through a .modifier field on the skill,
        --  exactly like the Block bonus.)
    end

    local function getSneakWeaponSkillBonus(stanceId)
        -- Compute the sneak-active weapon skill bonus for the given stance.
        -- Returns 0 if not sneaking, not enabled, or the stance doesn't support it.
        --
        -- Formula: same ramp as effectiveness bonus, but only while sneaking.
        -- bonus = (stance_level / (maxLevel - startLevel)) * (maxBonus - minBonus) + minBonus
        -- Using config.leveling numbers (startLevel=5, maxLevel=100,
        -- effectivenessMinBonus=2, effectivenessMaxBonus=20).

        if not sneakIsGood or not readSetting('', 'enabled', true) then return 0 end
        if not readSetting('Integrations', 'integrateSneakIsGoodNow', true) then return 0 end

        local playerIsSneaking = sneakIsGood.playerState.isSneaking or false
        if not playerIsSneaking then return 0 end

        local stanceConf = getActiveStanceConfig(stanceId)
        if not stanceConf or not stanceConf.sneakWeaponSkillBonus then return 0 end

        local stanceLevel = getStanceLevel(stanceId) or 5
        local leveling = config.leveling or {}
        local startLevel = leveling.startLevel or 5
        local maxLevel = leveling.maxLevel or 100
        local minBonus = leveling.effectivenessMinBonus or 2
        local maxBonus = leveling.effectivenessMaxBonus or 20

        -- Clamp level to range
        stanceLevel = math.max(startLevel, math.min(maxLevel, stanceLevel))

        -- Linear ramp from minBonus at startLevel to maxBonus at maxLevel
        local range = maxLevel - startLevel
        local progress = (stanceLevel - startLevel) / range
        local bonus = minBonus + (progress * (maxBonus - minBonus))

        return bonus
    end

    -- Public exports
    return {
        refreshAttentivenessBonus = refreshAttentivenessBonus,
        refreshSneakWeaponSkillBonus = refreshSneakWeaponSkillBonus,
        getSneakWeaponSkillBonus = getSneakWeaponSkillBonus,
    }
end

return M
