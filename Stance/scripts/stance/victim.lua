--[[
    Stance! — Victim-side combat bridge (victim.lua)

    Attached to every NPC and creature via Stance.omwscripts:
        NPC, CREATURE: scripts/stance/victim.lua

    ── Why this script exists ──────────────────────────────────────────────
    I.Combat.addOnHitHandler fires on the actor that is HIT (the victim), and
    the AttackInfo it receives exposes `attacker`, `weapon`, `damage`, etc.,
    but NOT a `target` (the victim is the script's own actor). Registering the
    handler on the PLAYER therefore only catches blows the player TAKES — it
    can never see the player DEALING a hit. That is why combat-hit XP and the
    on-hit perks were inert when driven purely from the player script.

    The only place to learn "the player just struck THIS actor" is a script
    running on the victim. When the attacker is the player we forward the blow
    to the player's Stance script as `Stance_PlayerDealtHit`, carrying this
    actor (self.object) as `target` plus the weapon used. The player script
    (init.lua) grants hit XP and runs the on-hit perk dispatch from that event.

    ── Kill credit (validated) ─────────────────────────────────────────────
    Because this script runs on the victim, it KNOWS who killed it. Once the
    player has hit us within a recent window, we watch our own health and, on
    death, send a validated `Stance_KillGrant` to the player. This replaces the
    old global.lua approach that credited the player for ANY actor death in the
    cell, even kills the player had nothing to do with.

    Polling only begins after a player hit, so actors the player never touches
    cost nothing. The grant fires at most once per actor.

    This script is read-only with respect to other mods: it reads its own
    actor's health/equipment and sends two events to the player. It never
    modifies other mods' state.
]]

local types = require('openmw.types')
local self  = require('openmw.self')
local core  = require('openmw.core')
local I     = require('openmw.interfaces')

local function isPlayer(obj)
    if not obj then return false end
    local ok, res = pcall(types.Player.objectIsInstance, obj)
    return ok and res == true
end

-- ─── Kill-credit bookkeeping ───────────────────────────────────────────────
local playerAttacker = nil       -- player object that last hit us
local lastHitTime    = -math.huge
local watchForDeath  = false     -- only poll health after a player hit
local creditedDeath  = false
local KILL_CREDIT_WINDOW = 10.0  -- seconds: max gap from last player hit to death for the kill to count

-- ─── Victim-side onHit ─────────────────────────────────────────────────────
-- Fires on THIS actor when it is struck by anyone. We only act when the
-- attacker is the player.
local function onHit(attack)
    if type(attack) ~= 'table' then return end
    -- Skip misses / fully-blocked blows when the engine reports them.
    if attack.successful == false then return end
    local attacker = attack.attacker
    if not isPlayer(attacker) then return end

    playerAttacker = attacker
    lastHitTime    = core.getSimulationTime()
    watchForDeath  = true
    creditedDeath  = false

    -- Forward to the player's Stance script with this actor as the target.
    -- Perks.onHit only needs `target` (the victim) and `weapon` (for the
    -- ranged-attack test); the rest is passed along for completeness so the
    -- player side can extend behavior without another protocol change.
    pcall(function()
        attacker:sendEvent('Stance_PlayerDealtHit', {
            target     = self.object,
            weapon     = attack.weapon,
            damage     = attack.damage,
            sourceType = attack.sourceType,
            attackType = attack.type,
        })
    end)
end

if I.Combat and I.Combat.addOnHitHandler then
    I.Combat.addOnHitHandler(onHit)
end

-- ─── Death watch (validated kill credit) ───────────────────────────────────
-- Throttled health poll, active only after a player hit and only until one
-- death is credited. ~4 polls/sec is plenty for a death edge.
local deathAccum = 0

local function onUpdate(dt)
    if creditedDeath or not watchForDeath then return end
    deathAccum = deathAccum + (tonumber(dt) or 0)
    if deathAccum < 0.25 then return end
    deathAccum = 0

    local hp = nil
    local ok = pcall(function() hp = types.Actor.stats.dynamic.health(self).current end)
    if not ok or hp == nil then return end
    if hp > 0 then return end

    creditedDeath = true
    watchForDeath = false
    if isPlayer(playerAttacker)
        and (core.getSimulationTime() - lastHitTime) <= KILL_CREDIT_WINDOW then
        pcall(function()
            playerAttacker:sendEvent('Stance_KillGrant', { victim = self.object })
        end)
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
