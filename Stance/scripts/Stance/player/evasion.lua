--[[
    Stance! — per-stance Sanctuary (evasion) bonus (player/evasion.lua)

    Applies each stance's configured evasionBonus as a flat Sanctuary
    active-effect modifier, using the same delta-accounting pattern Evasion!
    uses internally, so the two contributions stack without interfering.

    Module state (previousEvasionBonus) is a TRANSIENT delta tracker: the
    engine zeroes active effects on load, and init.lua's onLoad calls
    clearEvasionBonus() to zero the tracker in step — identical behavior to
    before the extraction, so this is mid-save safe.

    Dependencies (injected via ctx):
        self, types, core — engine handles
        config            — scripts.stance.config
        readSetting       — function(group, key, default) → value
        getStanceConfig   — function(stanceId) → stance table | nil
        getStanceLevel    — function(stanceId) → number
        getActiveStance   — function() → activeStanceId (string|nil)
]]

local M = {}

function M.new(ctx)
    local self  = ctx.self
    local types = ctx.types
    local core  = ctx.core
    local config = ctx.config
    local readSetting     = ctx.readSetting
    local getStanceConfig = ctx.getStanceConfig
    local getStanceLevel  = ctx.getStanceLevel
    local getActiveStance = ctx.getActiveStance

    -- ─── Evasion integration — per-stance Sanctuary bonus ────────────────────
    --
    -- Each stance defines an evasionBonus in config.lua (a Sanctuary ceiling
    -- at max stance level). This system applies that bonus as a flat active-effect
    -- Sanctuary modifier using the same delta-accounting pattern that Evasion! uses
    -- internally: we track our own portion in previousEvasionBonus and only write
    -- the difference to activeEffects:modify, so our contribution stacks cleanly
    -- with Evasion!'s own Sanctuary calculation and with any other
    -- Fortify-Sanctuary effects in the world without double-counting or stomping.
    --
    -- The bonus scales linearly from 0 at config.startLevel to stance.evasionBonus
    -- at config.maxLevel — mirroring how the weapon-skill effectiveness bonus scales
    -- from effectivenessMinBonus to effectivenessMaxBonus over stance level. Unlike
    -- the weapon-skill bonus (which is global min/max), each stance has its own
    -- ceiling, reflecting its thematic relationship to dodge and mobility.
    --
    -- Evasion! detection is optional: when the mod is present, the tooltip gains
    -- an "(Evasion!)" attribution label on the bonus line. The Sanctuary modifier
    -- is applied unconditionally; Evasion! is not required.

    local SANCTUARY_EFFECT    = core.magic.EFFECT_TYPE.Sanctuary
    local previousEvasionBonus = 0  -- our own delta tracker; never shared

    -- Return the current evasion bonus for stanceId, scaled by stance level.
    -- Returns a whole number (floor + round-half-up).
    local function getStanceEvasionBonus(stanceId)
        if not readSetting('', 'enabled', true) then return 0 end
        local stance = getStanceConfig(stanceId)
        if not stance then return 0 end
        local maxBonus = tonumber(stance.evasionBonus) or 0
        if maxBonus <= 0 then return 0 end
        local lo  = config.startLevel or 5
        local hi  = config.maxLevel   or 100
        local lvl = getStanceLevel(stanceId)
        if hi <= lo then return maxBonus end
        local t = math.max(0, math.min(1, (lvl - lo) / (hi - lo)))
        return math.floor(maxBonus * t + 0.5)
    end

    -- Apply/remove the per-stance Sanctuary bonus using Evasion!'s delta pattern.
    -- Called every update tick (same cadence as refreshEffectivenessModifiers).
    local function refreshEvasionBonus()
        local newBonus = (getActiveStance() and getStanceEvasionBonus(getActiveStance())) or 0
        local delta = newBonus - previousEvasionBonus
        if delta ~= 0 then
            types.Actor.activeEffects(self):modify(delta, SANCTUARY_EFFECT)
            previousEvasionBonus = newBonus
        end
    end

    -- Clear our Sanctuary contribution. Called on load because the engine zeroes
    -- all active effects on load; our tracker must match or the first refresh
    -- will compute delta = newBonus - staleValue and over-apply.
    local function clearEvasionBonus()
        previousEvasionBonus = 0
    end

    return {
        getStanceEvasionBonus = getStanceEvasionBonus,
        refreshEvasionBonus   = refreshEvasionBonus,
        clearEvasionBonus     = clearEvasionBonus,
    }
end

return M
