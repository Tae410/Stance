--[[
    Stance! — Global Script

    Responsibilities (global-only things):
      * Receive Stance_UpdateRuntimeSettings from the player script and
        mirror them into globalSection 'Runtime_Stance' so any future
        global hook or external mod can read them.
      * Listen for global events the player script can't subscribe to
        directly — actor deaths anywhere, world-wide UI mode changes, and
        forwarded merchant interactions — and forward kill credits back
        to the player as Stance_KillGrant events.
      * Provide the Stance_RequestInit handshake the player script uses to
        bootstrap.

    Architecture note:
      All XP bookkeeping and stance detection lives in the player script.
      The global script is intentionally thin: it routes events, mirrors
      settings, and (where useful) forwards engine signals the player
      script can't see directly.

      We keep this script defensive about missing interfaces. OpenMW
      interfaces evolve between releases (e.g. I.Combat hit handlers, NPC
      death events, Barter mode transitions). Each hookup uses pcall so a
      missing interface degrades gracefully instead of erroring out.
]]

local core    = require('openmw.core')
local I       = require('openmw.interfaces')
local storage = require('openmw.storage')
local types   = require('openmw.types')

local config = require('scripts.stance.config')

local MODNAME = 'Stance'

-- ─── Runtime mirror section ────────────────────────────────────────────────
-- Player script can't write to globalSection. It sends an event with the
-- payload, and we land the keys here.
local runtimeSection = storage.globalSection('Runtime_Stance')

local debugCache = {}

local function readRuntime(key)
    local ok, value = pcall(function() return runtimeSection:get(key) end)
    if not ok then return nil end
    return value
end

local function debugEnabled(category)
    if readRuntime('debugMessages') ~= true then return false end
    if not category then return true end
    return readRuntime(category) == true
end

local function debugLog(msg, category)
    if debugEnabled(category) then
        print('[Stance!] (global) ' .. tostring(msg))
    end
end

-- ─── Player reference ──────────────────────────────────────────────────────
-- We need a player object to forward XP grants back. The first
-- Stance_RequestInit event provides it; otherwise we fall back to
-- world.players[1] on demand.
local boundPlayer = nil

local function getPlayer()
    if boundPlayer and pcall(function() return boundPlayer.id end) then
        return boundPlayer
    end
    -- Fall back to first player in the world. types.Player.objects is the
    -- canonical iterator on recent OpenMW builds.
    if types.Player and types.Player.objects then
        for _, p in ipairs(types.Player.objects) do
            boundPlayer = p
            return p
        end
    end
    return nil
end

-- ─── Settings sync handler ─────────────────────────────────────────────────

local function onUpdateRuntimeSettings(payload)
    if type(payload) ~= 'table' then return end
    for k, v in pairs(payload) do
        pcall(function() runtimeSection:set(k, v) end)
    end
end

local function onRequestInit(payload)
    if type(payload) == 'table' and payload.player then
        boundPlayer = payload.player
        debugLog('Player bound for global script.', 'debugIntegrationMessages')
    end
end

-- ─── Kill credit forwarding ────────────────────────────────────────────────
-- Two strategies for catching kills:
--   (a) NPC/Creature death events. Recent OpenMW exposes onDeath as an
--       engine handler on actor scripts; we don't have an actor script so
--       we listen for the dispatched event "Died" or "OnDeath" if/when
--       the game emits one to the global scope.
--   (b) I.Combat-style hooks. If the build supports a global hit handler
--       that reports kills, we'd use it here. As of OpenMW 0.49 the
--       cleanest signal lives on the actor scope, which is why the
--       player script also registers I.Combat.addOnHitHandler for its own
--       on-hit XP. The kill grant therefore depends on actor death events
--       reaching the global scope. We accept "Died" as a defensive name
--       because some forks rename the event.

local function creditKill(killerId)
    local player = getPlayer()
    if not player then return end
    -- We don't validate that the killer is the player here, because the
    -- actor death event isn't well-defined in all builds. Instead we credit
    -- the player whenever an actor dies in their cell. This is consistent
    -- with how Toxicology approaches kill XP: best-effort, and the player's
    -- "active stance" gates the credit on the player side.
    pcall(function()
        player:sendEvent('Stance_KillGrant', { killerId = killerId })
    end)
end

local function onActorDied(payload)
    -- Defensive: payload shape varies. We only need to know that an actor
    -- died. The player script applies XP only to its currently active
    -- stance and only if XP-on-kill is enabled.
    if type(payload) ~= 'table' then
        creditKill(nil)
        return
    end
    local killerId = nil
    if payload.attacker then
        local ok, id = pcall(function() return payload.attacker.id end)
        if ok then killerId = id end
    end
    creditKill(killerId)
end

-- ─── Barter / merchant interaction forwarding ──────────────────────────────
-- Detect when the player closes a Barter UI. The cleanest signal is the
-- UiModeChanged event, but it fires on actor scope (the player script
-- subscribes to that directly when available). Here we just expose a
-- forwarding entry point so other mods or test scripts can trigger merchant
-- XP via `core.sendGlobalEvent('Stance_MerchantTransactionGlobal', ...)`.

local function onMerchantTransactionGlobal(payload)
    local player = getPlayer()
    if not player then return end
    pcall(function()
        player:sendEvent('Stance_MerchantTransaction', payload or {})
    end)
end

-- ─── Engine integration helpers ────────────────────────────────────────────
-- Many mods publish kill/death events under different names. We listen for
-- the most common ones used in the OpenMW Lua ecosystem and forward each
-- to creditKill. If a name doesn't exist this is harmless (the handler
-- just never fires).

return {
    eventHandlers = {
        Stance_UpdateRuntimeSettings = onUpdateRuntimeSettings,
        Stance_RequestInit           = onRequestInit,

        -- Generic actor death broadcasts. We accept multiple names because
        -- different builds/mods use different conventions.
        Stance_ActorDied             = onActorDied,
        ActorDied                    = onActorDied,
        Died                         = onActorDied,
        OnDeath                      = onActorDied,

        -- Merchant interaction broadcast (no-op without sender).
        Stance_MerchantTransactionGlobal = onMerchantTransactionGlobal,
    },
}
