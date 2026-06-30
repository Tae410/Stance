--[[
    Stance! — Deployable-hazard listener (hazard.lua)

    Attached to every ACTIVATOR and every LIGHT via Stance.omwscripts:
        ACTIVATOR, LIGHT: scripts/stance/hazard.lua

    ── Why this script exists ──────────────────────────────────────────────
    Two of the supported integrations are NOT equipped weapons, so they can't
    drive a weapon stance the way concoctions / venefic vials do. They are
    deployable MISC items (by Arcimaestro Antares) whose armed form is a world
    object that damages whoever stands on it via an MWScript HurtStandingActor:

        * Traps      — armed trap is the ACTIVATOR 'trap_open'; one massive
                       one-shot hit when an actor stands on it.
        * Oil Flask  — a broken flask is the ACTIVATOR 'oil_pool'; once IGNITED
                       it spawns the LIGHT 'oil_fire' and burns standing actors
                       over time. The 'oil_fire' object exists ONLY while the
                       pool is lit, so its presence is a clean "is burning"
                       signal — which is exactly why we attach to it (rather
                       than 'oil_pool') for the oil case: it makes the credit
                       fire only when an enemy is actually being burned.

    HurtStandingActor has no Lua hit-hook, so we detect the hit by proximity:
    when a NON-player actor is standing within the hazard's footprint, we send
    'Stance_HazardHit' { kind, victim } to global scope. The global script
    relays it to the player, who credits the Thief stance (trap) or the
    Apothecary stance (oil). The footprint is approximate (the engine's
    GetStandingActor is exact collision); for an XP reward hook that is fine,
    and the slightly generous radius makes us fire WHILE the hazard is still
    enabled rather than racing its self-disable. Both constants are easy to tune.

    ── Cost ────────────────────────────────────────────────────────────────
    This script is attached to ALL activators and lights, but every object
    whose record is not a hazard returns NO handlers below, so it does nothing
    and costs nothing after the one-time record check at attach. Only the few
    'trap_open' / 'oil_fire' objects in an active cell ever run onUpdate.

    Read-only w.r.t. other mods: it reads nearby actor positions and sends one
    event. It never modifies any object (a local script may only modify itself).
]]

local self = require('openmw.self')

-- Identify the hazard kind from the record id. Anything else: register nothing.
local rid  = (self.recordId or ''):lower()
local KIND = (rid == 'trap_open' and 'trap')
          or (rid == 'oil_fire'  and 'oil')
          or nil

if not KIND then
    return {}  -- not a hazard object — no handlers, zero ongoing cost
end

local nearby = require('openmw.nearby')
local core   = require('openmw.core')
local types  = require('openmw.types')

-- ── Tunables ───────────────────────────────────────────────────────────────
-- Horizontal footprint (squared, to avoid a sqrt) and vertical tolerance for
-- "standing on / in" the hazard. The trap and oil-pool meshes are ~64-128
-- units across; 90 covers stepping onto them without reaching far past the edge.
local FOOTPRINT_XY     = 90
local FOOTPRINT_XY_SQ  = FOOTPRINT_XY * FOOTPRINT_XY
local FOOTPRINT_Z      = 120          -- actor's origin within this of the hazard's

-- A trap is a single-use snap (it hurts once then disarms), so we credit once
-- per armed instance. A burning oil pool damages continuously, so we re-credit
-- each caught actor at most this often while it keeps burning.
local ONE_SHOT     = (KIND == 'trap')
local RECREDIT_SEC = 1.0

-- ── State ──────────────────────────────────────────────────────────────────
local fired      = false   -- ONE_SHOT latch (per armed trap instance)
local lastCredit = {}      -- oil: [actorId] = last sim time we credited

local function isPlayer(o)
    if not o then return false end
    local ok, r = pcall(types.Player.objectIsInstance, o)
    return ok and r == true
end

local function onUpdate(_dt)
    if ONE_SHOT and fired then return end

    -- Skip when the hazard object is disabled: a sprung trap and a burnt-out
    -- oil fire both disable themselves (the source MWScripts call `disable`),
    -- and we must not keep crediting after that.
    if not self.enabled then return end

    -- self.position is unavailable while the object is inactive; if so we just
    -- do nothing this frame.
    local sp = self.position
    if not sp then return end

    local now = core.getSimulationTime()

    -- BUGFIX: every official OpenMW Lua example iterates an ObjectList with the
    -- GLOBAL ipairs(list) function (e.g. `for _, p in ipairs(world.players)`,
    -- `for _, a in ipairs(world.activeActors)`) — never a `:ipairs()` METHOD
    -- call. core.lua's own doc for this exact list type says "Behaves as an
    -- array; supports #, numeric indexing, ipairs, and pairs" with no mention
    -- of a colon-callable method. The previous `nearby.actors:ipairs()` was
    -- the only such usage anywhere in this codebase (everywhere else already
    -- used the correct global-function form) and ran every frame, unguarded,
    -- for every Activator/Light object — if the method genuinely doesn't
    -- exist, that's a hazard-detection-breaking error on every tick.
    for _, a in ipairs(nearby.actors) do
        if a and not isPlayer(a) then
            local ap = a.position
            if ap then
                local dx, dy = ap.x - sp.x, ap.y - sp.y
                local dz = ap.z - sp.z
                if (dx * dx + dy * dy) <= FOOTPRINT_XY_SQ
                    and dz <= FOOTPRINT_Z and dz >= -FOOTPRINT_Z then
                    -- This non-player actor is standing on / in the hazard.
                    if ONE_SHOT then
                        fired = true
                        pcall(function()
                            core.sendGlobalEvent('Stance_HazardHit', { kind = KIND, victim = a })
                        end)
                        return
                    else
                        local last = lastCredit[a.id] or -math.huge
                        if (now - last) >= RECREDIT_SEC then
                            lastCredit[a.id] = now
                            pcall(function()
                                core.sendGlobalEvent('Stance_HazardHit', { kind = KIND, victim = a })
                            end)
                        end
                    end
                end
            end
        end
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
