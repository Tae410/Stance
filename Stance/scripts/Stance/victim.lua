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

    ── Brawler + Iron Fist for OpenMW (optional) ───────────────────────────
    This script is otherwise read-only with respect to other mods, with ONE
    deliberate exception: when the attacker is the player, Brawler is the
    active stance, and the optional "Iron Fist for OpenMW" mod is installed
    and enabled, we add Brawler's OWN extra unarmed damage directly onto
    attack.damage.health — the same shared, multi-handler AttackInfo field
    Iron Fist's own player.lua already adds its bonus to (this is the
    intended, documented use of I.Combat.addOnHitHandler — many combat mods
    are expected to modify it, and ADDING to a number is safe regardless of
    handler registration order between mods).
    The tier (none/light/medium/heavy) is the SAME GMST-based hand-armor
    classification config.brawlerGauntlet's existing Hand-to-Hand bonus
    already uses (see player/prefixes.lua's classifyHandArmor — replicated
    here verbatim, since a local script cannot call a player-script's private
    function), so "Heavy" means the identical thing to both systems. The
    bonus is scaled by Brawler's stance-level progress using the exact ramp
    shape effectivenessSkillBonus uses elsewhere in this mod (a stepped 0..1
    fraction of config.leveling, not a separate knob set), and by the Iron
    Grip perk's (cl>=25) literal "+15% hand-to-hand damage" — previously only
    ever simulated via a Strength bonus; this is its first direct
    application. See config.brawlerGauntlet for every tunable number.
    Entirely inert without Iron Fist installed: IronFistRuntime (its own
    settings mirror, populated on every menu init whether or not the player
    ever opens its settings page) is checked for presence AND its own
    'enabled' value before anything here ever computes a bonus.
    This does not touch, gate on, or interact with the existing Gothic Style
    Knockout integration (Stance_BrawlerKnockdown / GKD_DoKnockdown) in any
    way — those events are untouched by this file.
]]

local types   = require('openmw.types')
local self    = require('openmw.self')
local core    = require('openmw.core')
local I       = require('openmw.interfaces')
local storage = require('openmw.storage')
local config  = require('scripts.stance.config')

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

-- ─── Brawler + Iron Fist amplification ──────────────────────────────────────
local function debugLog(msg)
    local ok, on = pcall(function() return storage.globalSection('Runtime_Stance'):get('debugIntegrationMessages') end)
    if ok and on then print('[Stance!] ' .. tostring(msg)) end
end

-- Read a numeric GMST defensively (mirrors player/prefixes.lua's gmstNum).
local function gmstNum(key, fallback)
    local v
    pcall(function() v = core.getGMST(key) end)
    v = tonumber(v)
    if v == nil then return fallback end
    return v
end

-- Classify a hand-armor record's weight class EXACTLY as player/prefixes.lua's
-- classifyHandArmor does (and, per its own comment, as the engine itself does
-- in mwclass/armor.cpp) — duplicated verbatim rather than shared, since this
-- script runs on a different actor and cannot call a player-script's private
-- function. Keeping the SAME thresholds means "Heavy" means the identical
-- thing to both the existing Hand-to-Hand bonus and this amplification.
local function classifyHandArmor(rec)
    local weight  = tonumber(rec and rec.weight) or 0
    local iWeight = math.floor(gmstNum('iGauntletWeight', 5))
    local fLight  = gmstNum('fLightMaxMod', 0.6)
    local fMed    = gmstNum('fMedMaxMod', 0.9)
    local epsilon = 0.0005
    if weight <= iWeight * fLight + epsilon then return 'light' end
    if weight <= iWeight * fMed  + epsilon then return 'medium' end
    return 'heavy'
end

local TIER_RANK = { none = 0, light = 1, medium = 2, heavy = 3 }

-- The heavier of the attacker's two hand-armor slots ('none' if neither holds
-- a gauntlet or bracer). Any Armor occupying a hand slot IS hand armor, same
-- assumption player/prefixes.lua's handSlotTier makes.
local function bestHandTier(attacker)
    local best = 'none'
    local ok, equipment = pcall(types.Actor.getEquipment, attacker)
    if not ok or not equipment or not types.Actor.EQUIPMENT_SLOT then return best end
    for _, slotKey in ipairs({ 'LeftGauntlet', 'RightGauntlet' }) do
        local slot = types.Actor.EQUIPMENT_SLOT[slotKey]
        local item = slot and equipment[slot]
        if item then
            local isArmor, rec = false, nil
            pcall(function() isArmor = types.Armor.objectIsInstance(item) end)
            if isArmor then pcall(function() rec = types.Armor.record(item) end) end
            if rec then
                local tier = classifyHandArmor(rec)
                if TIER_RANK[tier] > TIER_RANK[best] then best = tier end
            end
        end
    end
    return best
end

-- Brawler's stance-level progress as a 0..1 fraction, using the SAME stepped
-- min/max/step ramp shape effectivenessSkillBonus uses elsewhere in this mod
-- (config.leveling), not a separate knob set — replicated here because this
-- script cannot call that player-side function either.
local function brawlerProgressFraction(brawlerLevel)
    local L = config.leveling or {}
    local lo   = tonumber(config.startLevel) or 5
    local minB = tonumber(L.effectivenessMinBonus) or 2
    local maxB = tonumber(L.effectivenessMaxBonus) or 20
    local step = tonumber(L.effectivenessStepLevels) or 5
    local inc  = tonumber(L.effectivenessStepBonus) or 2
    if step < 1 then step = 1 end
    if maxB <= 0 then return 0 end
    local lvl = tonumber(brawlerLevel) or lo
    local steps = math.floor((lvl - lo) / step)
    if steps < 0 then steps = 0 end
    local bonus = minB + steps * inc
    if bonus > maxB then bonus = maxB end
    if bonus < 0 then bonus = 0 end
    return bonus / maxB
end

-- Adds Brawler's own extra unarmed damage to attack.damage.health when Iron
-- Fist for OpenMW is installed+enabled, Brawler is the active stance, and the
-- attacker (the player) has a gauntlet/bracer equipped. Every read defaults
-- to "on"/"enabled" if the mirror hasn't populated yet (a brief window right
-- after a fresh load), matching this mod's general default-on convention, so
-- the bonus is never stuck off by a transient nil.
local function applyBrawlerIronfistBonus(attack, attacker)
    if attack.weapon ~= nil then return end
    if I.Combat and I.Combat.ATTACK_SOURCE_TYPES
        and attack.sourceType ~= nil
        and attack.sourceType ~= I.Combat.ATTACK_SOURCE_TYPES.Melee then
        return
    end

    local ok, rt = pcall(storage.globalSection, 'Runtime_Stance')
    if not ok or not rt then return end
    if rt:get('enabled') == false then return end
    if rt:get('enableBrawler') == false then return end
    if rt:get('integrateIronfist') == false then return end
    if rt:get('activeStanceId') ~= 'brawler' then return end

    -- Presence + enabled check for Iron Fist itself: IronFistRuntime is its
    -- own settings mirror, populated on every menu init (see config.lua's
    -- integrations.ironfist comment) whether or not the player ever opens
    -- its settings page. An empty/absent section means the mod isn't
    -- installed at all; an explicit false means the player turned it off.
    local ifOk, ifRt = pcall(storage.globalSection, 'IronFistRuntime')
    if not ifOk or not ifRt then return end
    local presentOk, present = pcall(function() return next(ifRt:asTable()) ~= nil end)
    if not presentOk or not present then return end
    if ifRt:get('enabled') == false then return end

    local tier = bestHandTier(attacker)
    if tier == 'none' then return end

    local tierCfg = config.brawlerGauntlet and config.brawlerGauntlet[tier]
    local maxBonus = tierCfg and tonumber(tierCfg.ironfistBonusMax) or 0
    if maxBonus <= 0 then return end

    local brawlerLevel = tonumber(rt:get('brawlerLevel'))
    local bonus = maxBonus * brawlerProgressFraction(brawlerLevel)

    -- Iron Grip (cl>=25): the literal "+15% hand-to-hand damage" its
    -- description promises, applied to THIS term — previously only ever
    -- simulated via a Strength bonus elsewhere.
    if rt:get('enableBrawlerPerks') ~= false and (brawlerLevel or 0) >= 25 then
        local mult = (config.brawlerGauntlet and tonumber(config.brawlerGauntlet.ironGripMult)) or 1.0
        bonus = bonus * mult
    end

    if bonus <= 0 then return end

    pcall(function()
        if type(attack.damage) ~= 'table' then attack.damage = {} end
        attack.damage.health = (tonumber(attack.damage.health) or 0) + bonus
    end)
    debugLog(string.format('Brawler+Iron Fist: tier=%s level=%s bonus=+%.2f', tier, tostring(brawlerLevel), bonus))
end

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

    -- Add Brawler's own Iron Fist amplification BEFORE forwarding, so the
    -- forwarded damage reflects the complete total. A no-op whenever Iron
    -- Fist isn't installed, Brawler isn't active, or no gauntlet is worn.
    pcall(applyBrawlerIronfistBonus, attack, attacker)

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
