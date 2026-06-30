-- ────────────────────────────────────────────────────────────────────────────
-- Stance! ↔ Bullseye integration module (updated for v1.3.2)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Bullseye integration provides:
--
-- 1. Scaled ranged XP for Huntsman stance: each successful ranged attack grants
--    Huntsman stance XP, scaled by Bullseye's damage multiplier. The multiplier
--    includes headshot bonus, distance bonus, and other Bullseye modifiers.
--
-- 2. Headshot detection: Stance can query whether the last hit was a headshot
--    via the stored multiplier state (useful for perks, cosmetics, or debug).
--
-- v1.3.2 changes:
-- - Event structure stable (Bullseye_hit sends damage multiplier)
-- - N'Garde compatibility verified (no double-SFX during N'Garde parry)
-- - Damage multiplier scaling enabled by default
-- - XP scaling respects both headshot and distance multipliers

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
    local grantStanceXp = ctx.grantStanceXp
    local Perks = ctx.Perks

    local lastDamageMult = 1.0
    local lastWasHeadshot = false

    -- ────────────────────────────────────────────────────────────────────
    -- Ranged attack XP granting: scales with Bullseye damage multiplier.
    -- Called via Bullseye_hit event (sends damage multiplier).
    -- ────────────────────────────────────────────────────────────────────

    local function onBullseyeHit(damageMult)
        if not readSetting('', 'enabled', true) then return end
        if not readSetting('Progression', 'xpOnRanged', true) then return end
        if not readSetting('Integrations', 'integrateBullseye', true) then return end

        -- Store the multiplier for headshot detection and future perk use.
        lastDamageMult = damageMult or 1.0

        -- Bullseye sends the final damage multiplier, which includes:
        -- - Headshot multiplier (if applicable)
        -- - Distance multiplier (scaled by range)
        -- - Sneak buff (if sneaking)
        -- - Movement debuff (if moving)
        --
        -- We use this to scale the base ranged XP. Higher quality shots
        -- (longer distance, headshots, better positioning) grant more XP.
        if getActiveStance() ~= 'huntsman' then return end

        local baseRangedXp = config.xp.rangedSuccess or 1.0
        local scaledXp = baseRangedXp * lastDamageMult

        grantStanceXp(scaledXp, 'ranged', 'huntsman')
        debugLog(string.format('Huntsman credited for ranged hit (%.2f multiplier = %.2f XP).',
            lastDamageMult, scaledXp), 'debugPerkMessages')

        -- Dispatch Huntsman perks (if any).
        if Perks and Perks.onRangedHit then
            Perks.onRangedHit()
        end
    end

    -- ────────────────────────────────────────────────────────────────────
    -- Headshot detection: returns true if last hit was a headshot.
    -- Inferred from damage multiplier being significantly higher than 1.0
    -- (headshot multiplier from Bullseye).
    -- ────────────────────────────────────────────────────────────────────

    local function wasLastHitHeadshot()
        if not readSetting('Integrations', 'integrateBullseye', true) then
            return false
        end
        -- Bullseye's default headshot multiplier is 2.0x. If the damage mult
        -- is significantly higher than a typical non-headshot (1.0-1.5 range),
        -- it's likely a headshot. This is a heuristic; for exact detection,
        -- Bullseye would need to expose a dedicated headshot flag in the event.
        return lastDamageMult >= 1.8
    end

    -- ────────────────────────────────────────────────────────────────────
    -- Distance-based multiplier detection: returns the current multiplier.
    -- Used by perks or cosmetic features (e.g., "Sniper" damage buff at range).
    -- ────────────────────────────────────────────────────────────────────

    local function getLastDamageMultiplier()
        if not readSetting('Integrations', 'integrateBullseye', true) then
            return 1.0
        end
        return lastDamageMult
    end

    -- ────────────────────────────────────────────────────────────────────
    -- Sneak ranged bonus integration: Bullseye grants +modifier to marksman
    -- while sneaking. This stacks with Stance sneaking bonuses independently
    -- (no double-dipping; Bullseye and Stance each apply their own).
    -- ────────────────────────────────────────────────────────────────────

    local function getSneakBonusActive()
        if not readSetting('Integrations', 'integrateBullseye', true) then
            return false
        end
        -- Check if Bullseye's sneak buff was applied (marksman.modifier > 0).
        -- This is a read-only check; the actual modifier is managed by Bullseye.
        -- Useful for perks that want to know if sneak bonus is active.
        return false  -- Placeholder; actual check would require Bullseye interface
    end

    -- Public exports
    return {
        onBullseyeHit = onBullseyeHit,
        wasLastHitHeadshot = wasLastHitHeadshot,
        getLastDamageMultiplier = getLastDamageMultiplier,
        getSneakBonusActive = getSneakBonusActive,
    }
end

return M
