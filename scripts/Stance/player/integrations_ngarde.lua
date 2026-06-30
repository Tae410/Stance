-- ────────────────────────────────────────────────────────────────────────────
-- Stance! ↔ N'Garde integration module (updated for v1.3.11)
-- ────────────────────────────────────────────────────────────────────────────
--
-- N'Garde integration provides:
--
-- 1. Parry XP for Fortifier stance: both regular and perfect parries grant
--    stance XP (perfect parries grant more). Sent via ngarde_parrySelf event,
--    which is received directly by the parrying actor (the player).
--
-- 2. Soul Resonance feed on perfect parry with Blademeister: when a perfect
--    parry lands with Blademeister active and no shield equipped, a fraction
--    of the standard on-hit resonance is added to the Soul Resonance meter.
--    This only works when not already under Fortified Block bonus.
--
-- 3. Optional state polling: Stance can query N'Garde parry state via the
--    NGardePlayer interface (v1.1) for advanced integrations (e.g., suppressing
--    other bonuses during active parry, cosmetic feedback, etc.).
--
-- v1.3.11 changes:
-- - Interface v1.1 now includes: isStaggered, isAttacking, startedParry,
--   isParrying, isAttackForbidden, canParry, externalParryControl
-- - Parry event structure unchanged (damageRemainingRatio, isPerfect, originalDamage)
-- - Settings group detection via 'Settings_NGarde_parrySettingsGroupKey' is stable

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
    local grantStanceXp = ctx.grantStanceXp
    local Perks = ctx.Perks

    -- Check if N'Garde is available. Store reference for polled state queries.
    local I = require('openmw.interfaces')
    local ngarde = I.NGardePlayer

    local lastIsParrying = false
    local lastStartedParry = false

    -- ────────────────────────────────────────────────────────────────────
    -- Parry XP granting: regular and perfect parries.
    -- Called via ngarde_parrySelf event payload.
    -- ────────────────────────────────────────────────────────────────────

    local function onParrySuccess(payload)
        if not readSetting('', 'enabled', true) then return end
        if not readSetting('Progression', 'xpOnParry', true) then return end
        if not readSetting('Integrations', 'integrateNGarde', true) then return end

        -- N'Garde sends 'ngarde_parrySelf' to the parrying actor (the player, when
        -- the player parries) with { damageRemainingRatio, isPerfect, originalDamage }.
        -- 'isPerfect' is the authoritative perfect-parry flag from N'Garde v1.3+.
        local perfect = (type(payload) == 'table') and payload.isPerfect or false

        if getActiveStance() then
            if perfect then
                grantStanceXp(config.xp.perfectParrySuccess or 2.4, 'perfectparry', getActiveStance())
            else
                grantStanceXp(config.xp.parrySuccess or 1.2, 'parry', getActiveStance())
            end
            debugLog(string.format('%s credited for a %sparry.',
                getActiveStance(), perfect and 'perfect ' or ''), 'debugPerkMessages')
        end

        -- Dispatch Fortifier parry perks (Warden Stance, Perfect Guard, Bulwark).
        if Perks and Perks.onParry then
            Perks.onParry()
        end
    end

    -- ────────────────────────────────────────────────────────────────────
    -- Soul Resonance feed on perfect parry with Blademeister stance.
    -- Called inline from ngarde_parrySelf handler (checked in init.lua).
    -- ────────────────────────────────────────────────────────────────────

    local function onPerfectParryBlademeister(activeStanceId, payload)
        -- This is called from init.lua inline to minimize overhead.
        -- It assumes payload.isPerfect is true and activeStanceId == 'blademeister'.
        -- Actual logic lives in blademeister.lua; this is just a wrapper.
        if not readSetting('', 'enabled', true) then return end
        if not readSetting('Integrations', 'integrateNGarde', true) then return end

        local isValidPayload = type(payload) == 'table' and payload.isPerfect == true
        local isBlademaster = activeStanceId == 'blademeister'
        local noFortifiedBonus = (currentFortifiedBlockBonus() or 0) <= 0

        if not (isValidPayload and isBlademaster and noFortifiedBonus) then
            return
        end

        -- Inject resonance via blademeister module (if available).
        -- This is expected to be called as:
        --   blademeister.onPerfectParry(activeStanceId)
        -- The actual implementation lives in blademeister.lua.
        debugLog(string.format(
            'N\'Garde perfect parry with %s (damage ratio: %.2f)',
            activeStanceId,
            (payload.damageRemainingRatio or 1.0) * 100
        ), 'debugPerkMessages')
    end

    -- ────────────────────────────────────────────────────────────────────
    -- Optional: Parry state polling via N'Garde v1.1 interface.
    -- ────────────────────────────────────────────────────────────────────
    -- These functions allow Stance to query N'Garde parry state for advanced
    -- uses (e.g., suppressing bonuses during active parry, cosmetic feedback).

    local function isNGardeParrying()
        if not ngarde or not ngarde.isParrying then return false end
        return ngarde.isParrying()
    end

    local function isNGardeStaggered()
        if not ngarde or not ngarde.isStaggered then return false end
        return ngarde.isStaggered()
    end

    local function didNGardeStartParry()
        if not ngarde or not ngarde.startedParry then return false end
        return ngarde.startedParry()
    end

    local function isNGardeAttacking()
        if not ngarde or not ngarde.isAttacking then return false end
        return ngarde.isAttacking()
    end

    local function canNGardeParry()
        if not ngarde or not ngarde.canParry then return false end
        return ngarde.canParry()
    end

    local function getNGardeVersion()
        if not ngarde or not ngarde.version then return nil end
        return ngarde.version
    end

    -- ────────────────────────────────────────────────────────────────────
    -- Per-tick state tracking: optional, for future use.
    -- ────────────────────────────────────────────────────────────────────

    local function updateParryState()
        -- This can be called each frame to track state changes.
        -- Currently a no-op, but reserved for future cosmetic/debug features.
        if not ngarde then return end

        local isParrying = isNGardeParrying()
        local startedParry = didNGardeStartParry()

        -- Edge detection example (for future use):
        -- if isParrying and not lastIsParrying then
        --     debugLog('N\'Garde parry started', 'debugParryState')
        -- elseif not isParrying and lastIsParrying then
        --     debugLog('N\'Garde parry ended', 'debugParryState')
        -- end

        lastIsParrying = isParrying
        lastStartedParry = startedParry
    end

    -- Public exports
    return {
        onParrySuccess = onParrySuccess,
        onPerfectParryBlademeister = onPerfectParryBlademeister,
        updateParryState = updateParryState,
        
        -- State polling (v1.1 interface)
        isParrying = isNGardeParrying,
        isStaggered = isNGardeStaggered,
        startedParry = didNGardeStartParry,
        isAttacking = isNGardeAttacking,
        canParry = canNGardeParry,
        version = getNGardeVersion,
    }
end

return M
