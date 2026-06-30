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
local world   = require('openmw.world')

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
    -- Fall back to the first player via the global world API.
    if world and world.players then
        for _, p in ipairs(world.players) do
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
-- Kill credit is now produced by the victim-side actor script
-- (scripts/stance/victim.lua), which KNOWS its own killer and only credits the
-- player when the player actually dealt a recent, fatal hit. That validated
-- path sends Stance_KillGrant straight to the player script.
--
-- The previous global-scope approach credited the player for ANY actor death
-- that reached global scope, without checking who the killer was — it
-- over-credited unrelated deaths (NPC-vs-NPC, environmental, other mods'
-- broadcasts). We therefore no longer forward those generic death events.
--
-- creditKill() is retained as an explicit opt-in entry point for external
-- callers that have ALREADY validated the player as the killer and send
-- Stance_PlayerValidatedKill on purpose. It is not wired to any speculative
-- engine/death broadcast.

local function creditKill(killerId)
    local player = getPlayer()
    if not player then return end
    pcall(function()
        player:sendEvent('Stance_KillGrant', { killerId = killerId })
    end)
end

-- Opt-in: only fires if some other script deliberately sends a pre-validated
-- kill to global scope. No generic death event is routed here anymore.
local function onValidatedKill(payload)
    local killerId = nil
    if type(payload) == 'table' and payload.killerId then
        killerId = payload.killerId
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

-- Oblivion-Style Lockpicking fires 'OSL_LockpickSuccess' as a GLOBAL event on
-- every successful pick/probe. Stance grants XP in the PLAYER script, so we
-- relay it there as 'Stance_LockpickSuccess', carrying the probe flag through
-- (probe = disarming a trap rather than picking a lock).
local function onOSLLockpickSuccess(payload)
    local player = getPlayer()
    if not player then return end
    pcall(function()
        -- Forward the probe flag and, if OSL reports the lock/trap strength under
        -- any of the common field names, a numeric difficulty so Locksmith XP can
        -- scale with it. Degrades gracefully to nil (flat XP) when none is present.
        local difficulty = nil
        if type(payload) == 'table' then
            difficulty = tonumber(payload.difficulty)
                or tonumber(payload.lockLevel)
                or tonumber(payload.lockStrength)
                or tonumber(payload.level)
                or tonumber(payload.trapLevel)
        end
        player:sendEvent('Stance_LockpickSuccess', {
            probe = payload and payload.probe or false,
            difficulty = difficulty,
        })
    end)
end

-- Commercium / Fair Trade fires 'FairTrade_Transaction' as a global event on
-- each barter deal. Relay to the player as 'Stance_CommerciumTransaction',
-- carrying the deal's absolute value and buy/sell flag for Commoner XP.
local function onFairTradeTransaction(payload)
    local player = getPlayer()
    if not player then return end
    pcall(function()
        player:sendEvent('Stance_CommerciumTransaction', {
            absValue = payload and tonumber(payload.absValue) or 0,
            isBuying = payload and payload.isBuying or false,
        })
    end)
end

-- Transcribe fires 'TRAN_doTranscribe' as a global event when the player
-- commits a spell transcription (the global handler always completes it).
-- Relay to the player as 'Stance_TranscribeSuccess' for Arcanist/Thaumaturge XP.
local function onTranscribeDone(_payload)
    local player = getPlayer()
    if not player then return end
    pcall(function()
        player:sendEvent('Stance_TranscribeSuccess', {})
    end)
end

-- Deployable-hazard credit. scripts/stance/hazard.lua runs on the hazard
-- OBJECT (an armed trap activator, or a burning oil-fire light), which can be
-- far from the player when it triggers, so it can't reach the player directly.
-- It sends 'Stance_HazardHit' { kind, victim } to global scope; we forward it
-- to the player, who credits the Thief (trap) or Apothecary (oil) stance.
local function onHazardHit(payload)
    local player = getPlayer()
    if not player then return end
    pcall(function()
        player:sendEvent('Stance_HazardHit', {
            kind   = payload and payload.kind,
            victim = payload and payload.victim,
        })
    end)
end

-- Bardcraft fires 'BC_PerformerNoteHandled' as a GLOBAL event for every note a
-- performer plays (carrying { success, performer, mod }), but NOT for Ambient
-- performances. The Muse stance lives in the player script, so we filter to the
-- player's own notes and relay them as 'Stance_BardNote' { success } for the
-- Muse buff-timer ledger. (PerformStart/Stop reach the player directly as
-- BO_ConductorEvent, so only the per-note signal needs this global bounce.)
local function onBardPerformerNote(payload)
    if type(payload) ~= 'table' then return end
    local player = getPlayer()
    if not player then return end
    local performer = payload.performer
    if not performer then return end
    -- Only the player's own notes drive the Muse ledger.
    local sameAsPlayer = false
    pcall(function() sameAsPlayer = (performer.id == player.id) end)
    if not sameAsPlayer then return end
    pcall(function()
        player:sendEvent('Stance_BardNote', { success = payload.success == true })
    end)
end


-- Dispatched from perks.lua's sendEffect() helper. We are in global scope
-- here, which means we can write to types.Actor.activeEffects on any actor
-- in the world — the player script cannot do this because it lacks world
-- scope. Each effect is applied via a minimal spell-effect record so the
-- engine's existing magic resolution handles duration, resistances, and
-- magnitude correctly.
--
-- Effect payload fields (from perks.lua sendEffect):
--   target     — the actor object to apply the effect to
--   effectId   — integer MGEF id (e.g. EFF.DamageHealth = 21)
--   effectName — string label used as the fallback branch key
--   magnitude  — integer or float magnitude
--   duration   — float duration in seconds (0 = instant)

-- ── Timed magic-effect reversal (Paralyze/Burden perk effects) ────────────
-- ActorActiveEffects:modify(value, effectId) applies a PERMANENT delta with
-- no duration of its own — confirmed against the OpenMW Lua API stubs: the
-- only EXPIRING mechanism, ActorActiveSpells:add, requires `id` to be an
-- EXISTING spell/potion/ingredient record and `effects` to be plain integer
-- INDEXES into that record's effect list ("@field effects integer[] Indexes
-- of the effects to apply"). It cannot create an ad-hoc custom effect from a
-- made-up id with its own magnitude/duration — which is exactly what this
-- function used to attempt (a record id like 'stance_perk_effect_14' matches
-- nothing in the game's data, and `effects` was a table of option-tables, not
-- integer indexes). That call was wrapped in pcall with no failure logging,
-- so it has been silently failing on every single use: Burden, Paralyze, and
-- the elemental (Fire/Frost/Shock) damage bonus have never actually applied.
--
-- The fix: a genuine timed status effect (Burden, Paralyze) is built here as
-- modify(+magnitude) now, tracked in this list, and modify(-magnitude) once
-- `duration` elapses — polled every tick, unconditionally, near the top of
-- onUpdate (see below). Everything else (instant damage/restore, including
-- the elemental types, which this codebase only ever calls with duration=0)
-- is a direct one-time dynamic-stat mutation, which is the correct primary
-- mechanism for "deal N damage now" and needs no record or tracking at all.
--
-- HONEST CAVEAT: this list is NOT persisted to storage. Every duration here
-- is short (0.5-3 seconds), so the window for "game saved mid-effect" is
-- tiny; if it happens, the reversal is lost on reload and the actor keeps a
-- small stray Burden/Paralyze modifier permanently until the same perk procs
-- on them again (whose own correct add+reversal cycle does not fix a
-- pre-existing stray one, but does not make it worse either). Magnitudes are
-- modest (Paralyze 1, Burden 30-40), so this is a narrow, low-severity edge
-- case, not an accumulating one — but it is not zero-risk.
local pendingEffectReversals = {}

local function scheduleEffectReversal(target, effectId, magnitude, duration)
    table.insert(pendingEffectReversals, {
        target    = target,
        effectId  = effectId,
        magnitude = magnitude,
        expiresAt = core.getSimulationTime() + duration,
    })
end

local function pollEffectReversals()
    if #pendingEffectReversals == 0 then return end
    local now = core.getSimulationTime()
    local keep = {}
    for _, e in ipairs(pendingEffectReversals) do
        if now >= e.expiresAt then
            pcall(function() types.Actor.activeEffects(e.target):modify(-e.magnitude, e.effectId) end)
        else
            table.insert(keep, e)
        end
    end
    pendingEffectReversals = keep
end

-- Effect names that represent a genuine TIMED STATUS EFFECT (movement/action
-- impairment for the duration), as opposed to an instant stat change. Matched
-- on the lower-cased effectName payload field so this is independent of
-- whichever numeric MGEF id scheme produced effectId (vanilla-table fallback
-- vs core.magic.EFFECT_TYPE).
local TIMED_STATUS_EFFECTS = { burden = true, paralyze = true }

local function onPerkEffect(payload)
    if type(payload) ~= 'table' then return end
    if not readRuntime('enabled') then return end

    local target    = payload.target
    local effectId  = payload.effectId
    local magnitude = tonumber(payload.magnitude) or 0
    local duration  = tonumber(payload.duration)  or 0
    local lname     = tostring(payload.effectName or ''):lower()

    if not target or not effectId then return end
    if magnitude == 0 and duration == 0 then return end

    if duration > 0 and TIMED_STATUS_EFFECTS[lname] then
        local ok = pcall(function() types.Actor.activeEffects(target):modify(magnitude, effectId) end)
        if ok then scheduleEffectReversal(target, effectId, magnitude, duration) end
        return
    end

    -- Instant stat mutation: the correct primary mechanism for "deal N
    -- damage/restoration now" — DynamicStat (health/fatigue/magicka) has no
    -- "self only" restriction (that note is specific to AttributeStat /
    -- SkillStat / AIStat / ReputationStat), so this is valid from global
    -- scope on an arbitrary target, which combat damage inherently requires.
    local dyn = types.Actor.stats and types.Actor.stats.dynamic
    if not dyn then return end
    if lname == 'damagehealth' or lname == 'firedamage' or lname == 'frostdamage' or lname == 'shockdamage' then
        if dyn.health then
            pcall(function()
                local hp = dyn.health(target)
                hp.current = math.max(0, hp.current - magnitude)
            end)
        end
    elseif lname == 'damagefatigue' then
        if dyn.fatigue then
            pcall(function()
                local fat = dyn.fatigue(target)
                fat.current = math.max(0, fat.current - magnitude)
            end)
        end
    elseif lname == 'restorefatigue' then
        if dyn.fatigue then
            pcall(function()
                local fat = dyn.fatigue(target)
                fat.current = math.min(fat.modified, fat.current + magnitude)
            end)
        end
    end
end

-- ─── Engine integration helpers ────────────────────────────────────────────
-- Kill credit is handled on the victim side (scripts/stance/victim.lua), which
-- validates the killer before crediting. The only kill entry point left in
-- global scope is the opt-in Stance_PlayerValidatedKill event below, for
-- external scripts that have already confirmed a player kill themselves.

-- ─── Gardening / Farming progress bridge (Forager XP) ──────────────────────
-- The Gardening and Farming mod is pure MWScript+ESP content; on OpenMW its
-- scripts still run, and it tracks ALL gardening progress in one MWScript global
-- float, `tribGardner`. That global is raised by the mod itself: +0.1 each time
-- the player PLANTS a seed (drops it — see trib_<crop>_seed) and +0.2 each time
-- the player HARVESTS a grown plant with the Harvest Hoe or a Scythe (see
-- trib_<crop>_plant). Reading runtime MWScript globals requires world scope
-- (world.mwscript.getGlobalVariables()), which only exists in this global
-- script — the player script can't see it — so we watch the value here and
-- forward each increase to the player as Stance_GardeningProgress { delta }.
-- The player credits Forager delta*gardeningProgressScale XP, so planting and
-- harvesting both feed Forager exactly as they feed the source mod's own skill.
--
-- Robustness:
--   * First read each session only baselines (no grant) — gardening done in a
--     previous session, already reflected in the loaded global, isn't re-paid.
--   * A decrease (loading an earlier save in a fresh Lua state, or any reset)
--     silently re-baselines; we never grant on a decrease.
--   * If the mod isn't installed the global is unreadable/absent → cur is nil →
--     we simply never forward anything. All reads are pcall-guarded.
local lastGardnerValue = nil
local gardenPollAccum  = 0
local GARDEN_POLL_INTERVAL = 0.5   -- seconds between polls; plant/harvest are slow actions

local function readTribGardner()
    local gv = nil
    local ok = pcall(function() gv = world.mwscript.getGlobalVariables() end)
    if not ok or gv == nil then return nil end
    -- MWScript globals are case-insensitive; the record id is 'tribGardner'.
    -- Try the canonical spelling, then a lowercase fallback, each guarded.
    local v = nil
    ok = pcall(function() v = gv.tribGardner end)
    if ok and type(v) == 'number' then return v end
    ok = pcall(function() v = gv.tribgardner end)
    if ok and type(v) == 'number' then return v end
    return nil
end

local function onUpdate(dt)
    -- Always honor any already-scheduled Paralyze/Burden reversal, even if the
    -- mod gets disabled mid-effect — onPerkEffect itself already won't START
    -- a NEW one while disabled (it checks readRuntime('enabled') first), but
    -- leaving an existing one stuck permanently on an actor would be worse
    -- than completing this one last cleanup obligation.
    pollEffectReversals()

    -- Respect the master enable mirror; skip all other work when the mod is off.
    if readRuntime('enabled') ~= true then return end

    gardenPollAccum = gardenPollAccum + (dt or 0)
    if gardenPollAccum < GARDEN_POLL_INTERVAL then return end
    gardenPollAccum = 0

    local cur = readTribGardner()
    if cur == nil then return end            -- mod absent / global unreadable

    if lastGardnerValue == nil then          -- first sighting this session: baseline only
        lastGardnerValue = cur
        return
    end

    if cur > lastGardnerValue then
        local delta = cur - lastGardnerValue
        lastGardnerValue = cur
        local player = getPlayer()
        if player then
            pcall(function()
                player:sendEvent('Stance_GardeningProgress', { delta = delta })
            end)
        end
        debugLog('Gardening progress +' .. tostring(delta) .. ' forwarded to player.',
            'debugIntegrationMessages')
    elseif cur < lastGardnerValue then
        -- Value went down (earlier save loaded, external reset): re-baseline, no grant.
        lastGardnerValue = cur
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        Stance_UpdateRuntimeSettings = onUpdateRuntimeSettings,
        Stance_RequestInit           = onRequestInit,

        -- Pre-validated kill forwarding ONLY. Generic actor-death broadcasts
        -- (ActorDied/Died/OnDeath) are intentionally not handled here anymore:
        -- they could not confirm the player was the killer and over-credited
        -- unrelated deaths. Validated kills now arrive on the player script
        -- directly from scripts/stance/victim.lua.
        Stance_PlayerValidatedKill   = onValidatedKill,

        -- Merchant interaction broadcast (no-op without sender).
        Stance_MerchantTransactionGlobal = onMerchantTransactionGlobal,

        -- Oblivion-Style Lockpicking success (global event) → relayed to the
        -- player for Locksmith XP.
        OSL_LockpickSuccess          = onOSLLockpickSuccess,

        -- Commercium / Fair Trade barter transaction (global) → relayed to the
        -- player for Commoner XP.
        FairTrade_Transaction        = onFairTradeTransaction,

        -- Transcribe spell-transcription commit (global) → relayed to the
        -- player for Arcanist/Thaumaturge XP.
        TRAN_doTranscribe            = onTranscribeDone,

        -- Deployable-hazard credit (Traps/Oil Flask), sent by hazard.lua from
        -- the hazard object → relayed to the player (Thief / Apothecary XP).
        Stance_HazardHit             = onHazardHit,

        -- Perk on-hit effect application (dispatched by perks.lua via
        -- core.sendGlobalEvent so we have world scope to write activeEffects).
        Stance_PerkEffect            = onPerkEffect,

        -- Bardcraft per-note signal (global) → relayed to the player as
        -- Stance_BardNote for the Muse buff-timer ledger (player notes only).
        BC_PerformerNoteHandled      = onBardPerformerNote,

        -- Stance Wheel slow-motion: world.setSimulationTimeScale is global-scope
        -- only (like world.advanceTime above), so the wheel (player scope) sends
        -- the desired scale here as a plain number. Confirmed against the OpenMW
        -- Lua API stubs: world.getSimulationTime() is explicitly documented as
        -- scaling with this exact setting ("Simulation time... The scale of
        -- simulation time relative to real time."), which is also what every
        -- buff-timer fix in this mod (Soul Resonance, Muse inspiration) relies on
        -- — so this closes a real, previously-flagged gap: the wheel's slow-mo
        -- request had no listener until now, with no functional impact on
        -- anything else (every other simulation-time consumer keeps working
        -- exactly as before; this just makes 1.0x the rate again on close).
        SetSimulationTimeScale       = function(scale)
            local ok, err = pcall(function() world.setSimulationTimeScale(tonumber(scale) or 1.0) end)
            if not ok then debugLog('world.setSimulationTimeScale errored: ' .. tostring(err), 'debugIntegrationMessages') end
        end,
    },
}
