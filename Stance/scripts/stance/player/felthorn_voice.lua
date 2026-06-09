--[[
    Stance! — Felthorn ambient voice (player/felthorn_voice.lua)

    A small, self-contained cosmetic module. While the Blademeister stance is
    active (a Felthorn weapon equipped), Felthorn "speaks" the occasional line
    as an ordinary vanilla message (ui.showMessage):

      * a greeting the moment the stance becomes active,
      * idle lines at randomized intervals while it stays active,
      * an optional line after a kill.

    All text and timing live in config.felthornAmbient — edit there, not here.
    This module holds only timing/sequencing state and has no dependencies on
    the rest of the player script beyond the context table passed to new().

    Integration (init.lua) is three lines:
      local felthornVoice = require('scripts.stance.player.felthorn_voice').new{
          config = config, ui = ui, core = core, readSetting = readSetting }
      ...in onUpdate, each tick:  felthornVoice.update(activeStanceId, now)
      ...on a kill (optional):    felthornVoice.onKill(activeStanceId)
      ...on load / stance reset:  felthornVoice.reset()

    It is keyed to the 'blademeister' stance id; if that id ever changes,
    update STANCE_ID below.
]]

local M = {}

local STANCE_ID = 'blademeister'

function M.new(ctx)
    ctx = ctx or {}
    local config      = ctx.config
    local ui          = ctx.ui
    local core        = ctx.core
    local readSetting = ctx.readSetting or function() return true end

    -- Fail safe: if anything required is missing, return a no-op object so a
    -- misconfigured context can never break the update loop.
    local function cfg()
        return config and config.felthornAmbient or nil
    end

    -- ── State ─────────────────────────────────────────────────────────────
    local wasActive    = false        -- was Blademeister active last tick?
    local nextLineAt   = math.huge    -- sim time of the next idle line
    local lastLine     = nil          -- last line shown (immediate-repeat guard)

    local function now()
        if core and core.getSimulationTime then
            local ok, t = pcall(core.getSimulationTime)
            if ok then return t end
        end
        return 0
    end

    local function show(text)
        if not text then return end
        if ui and ui.showMessage then
            pcall(ui.showMessage, text)
        end
    end

    -- Pick a random entry from a list, optionally avoiding an immediate repeat.
    local function pickLine(list, avoidRepeat)
        if type(list) ~= 'table' or #list == 0 then return nil end
        if #list == 1 then return list[1] end
        local choice
        for _ = 1, 6 do  -- a few tries is plenty to dodge a repeat
            choice = list[math.random(1, #list)]
            if not (avoidRepeat and choice == lastLine) then break end
        end
        lastLine = choice
        return choice
    end

    local function scheduleNextIdle(c, fromNow)
        local lo = tonumber(c.minIntervalSec) or 75
        local hi = tonumber(c.maxIntervalSec) or 160
        if hi < lo then hi = lo end
        local delay = lo + math.random() * (hi - lo)
        nextLineAt = fromNow + delay
    end

    -- Master gate: stance must be Blademeister, the mod enabled, the feature
    -- enabled, and a config block present.
    local function shouldSpeak(activeStanceId)
        if activeStanceId ~= STANCE_ID then return false end
        if readSetting('', 'enabled', true) ~= true then return false end
        local c = cfg()
        if not c or c.enabled == false then return false end
        return true
    end

    -- ── Public API ────────────────────────────────────────────────────────

    local api = {}

    -- Reset all sequencing state (on load, or whenever the stance is forcibly
    -- cleared) so we don't fire a stale idle line on the next equip.
    function api.reset()
        wasActive  = false
        nextLineAt = math.huge
        lastLine   = nil
    end

    -- Main per-tick entry point.
    function api.update(activeStanceId, t)
        t = tonumber(t) or now()

        if not shouldSpeak(activeStanceId) then
            -- Stance ended (or feature off): mark inactive so re-entering the
            -- stance plays a fresh greeting.
            if wasActive then wasActive = false end
            return
        end

        local c = cfg()

        -- Transition into the stance: greet, then schedule the first idle line
        -- after the configured warm-up delay.
        if not wasActive then
            wasActive = true
            show(pickLine(c.greetings, c.avoidImmediateRepeat))
            local delay = tonumber(c.firstLineDelaySec) or 12
            scheduleNextIdle(c, t)
            -- Ensure the first idle line waits at least firstLineDelaySec.
            if nextLineAt < t + delay then nextLineAt = t + delay end
            return
        end

        -- Steady state: fire idle lines on schedule.
        if t >= nextLineAt then
            show(pickLine(c.idle, c.avoidImmediateRepeat))
            scheduleNextIdle(c, t)
        end
    end

    -- Optional: call right after the player lands a kill. Chance-gated so not
    -- every kill triggers a remark. Only fires while the stance is active.
    function api.onKill(activeStanceId)
        if not shouldSpeak(activeStanceId) then return end
        local c = cfg()
        local chance = tonumber(c.onKillChance) or 0.5
        if math.random() > chance then return end
        show(pickLine(c.onKill, c.avoidImmediateRepeat))
    end

    return api
end

return M
