--[[
    Stance! — Blademeister: Soul Resonance & Soul Exhaustion (player/blademeister.lua)

    A buildable combat-rhythm mechanic for the Blademeister stance (a Felthorn
    weapon equipped). Land hits with Felthorn to fill a Resonance meter; when it
    fills, Felthorn RESONATES — you and Felthorn cry out, your weapon skill (and so
    your damage) surges and incoming damage is blunted, and the meter steadily
    drains. When it empties Felthorn is EXHAUSTED: the buffs end and the meter
    cannot refill until a cooldown passes.

    ── State machine ──────────────────────────────────────────────────────────
        BUILDING  --(meter reaches max)-->  RESONANT
        RESONANT  --(meter drains to 0)-->  EXHAUSTED
        EXHAUSTED --(cooldown elapses)--->  BUILDING (meter at 0)

    State (phase / meter / cooldownEnds) PERSISTS in its own storage section, so
    picking Felthorn back up resumes where you left off. The numeric buffs are
    TRANSIENT delta-trackers (never persisted): the weapon-skill bonus rides the
    same native `.modifier` delta path as effectiveness/muse, and the damage
    mitigation rides a Shield active-effect modifier with the same delta-accounting
    Evasion! uses. clearBonuses() (called from onLoad) zeroes the trackers so the
    first post-load reapply starts from a clean baseline.

    Off-stance behaviour: while Blademeister is NOT the active stance the buffs are
    peeled immediately and the meter/phase are FROZEN (drain pauses). The exhaustion
    cooldown is timestamp-based, so it still lifts naturally with the passage of
    (game/sim) time whether or not the stance is active.

    All tuning lives in config.blademeister; all voice text in
    config.felthornAmbient (spoken via the felthorn_voice module).
]]

local M = {}

local STANCE_ID = 'blademeister'

function M.new(ctx)
    ctx = ctx or {}

    local self        = ctx.self
    local types       = ctx.types
    local core        = ctx.core
    local config      = ctx.config or {}
    local storage     = ctx.storage
    local readSetting = ctx.readSetting or function() return true end
    local debugLog    = ctx.debugLog    or function() end
    local notify      = ctx.notify      or function() end
    local voice       = ctx.voice       or {}    -- felthorn_voice api (sayResonance/sayExhausted)
    local getActiveStance    = ctx.getActiveStance    or function() return nil end
    local resolveStanceSkill = ctx.resolveStanceSkill or function() return nil end
    local getCoreSkillLevel  = ctx.getCoreSkillLevel  or function() return 0 end
    local perksEnabled       = ctx.perksEnabled       or function() return true end

    local SECTION   = 'Stance_BlademeisterV1'
    local STATE_KEY = 'state'
    local SAVE_THROTTLE_SEC = 1.0

    -- Shield active-effect type (raises armor rating → mitigates physical damage),
    -- resolved defensively so a missing API can never break construction.
    local SHIELD_EFFECT = nil
    pcall(function() SHIELD_EFFECT = core.magic.EFFECT_TYPE.Shield end)

    local function cfg() return config.blademeister end

    -- A Blademeister perk is in force when its tier is unlocked on the CORE Stance
    -- level AND Blademeister perks are enabled. All four perks augment a phase of
    -- the Soul Resonance lifecycle (build / duration / cooldown / kill-cascade).
    local function perkUnlocked(level)
        return perksEnabled() and getCoreSkillLevel() >= level
    end

    local function perkCfg() return (cfg() and cfg().perks) or {} end

    local function featureOn()
        if readSetting('', 'enabled', true) ~= true then return false end
        local c = cfg()
        return c ~= nil and c.enabled ~= false
    end

    local function now()
        local t = 0
        pcall(function() t = core.getSimulationTime() end)
        return t
    end

    -- ─── Persisted state ──────────────────────────────────────────────────────

    local section = storage and storage.playerSection and storage.playerSection(SECTION) or nil
    local stateCache = nil
    local lastSaveAt = -math.huge

    local function defaultState()
        return { phase = 'building', meter = 0, cooldownEnds = 0, cooldownStart = 0 }
    end

    local function getState()
        if stateCache then return stateCache end
        local stored = section and section:get(STATE_KEY) or nil
        local s = defaultState()
        if type(stored) == 'table' then
            local ph = stored.phase
            if ph == 'building' or ph == 'resonant' or ph == 'exhausted' then s.phase = ph end
            s.meter         = tonumber(stored.meter) or 0
            s.cooldownEnds  = tonumber(stored.cooldownEnds) or 0
            s.cooldownStart = tonumber(stored.cooldownStart) or 0
        end
        local maxM = tonumber(cfg() and cfg().meterMax) or 100
        if s.meter < 0 then s.meter = 0 elseif s.meter > maxM then s.meter = maxM end
        stateCache = s
        return s
    end

    local function saveState(force)
        if not stateCache or not section then return end
        local t = now()
        if not force and (t - lastSaveAt) < SAVE_THROTTLE_SEC then return end
        lastSaveAt = t
        pcall(function() section:set(STATE_KEY, stateCache) end)
    end

    -- ─── Transient bonus application (delta-accounted) ────────────────────────

    local appliedBySkill = {}   -- skillId -> points we currently hold on it
    local appliedShield  = 0    -- Shield magnitude we currently hold

    local function vanillaSkillAccessor(skillId)
        if type(skillId) ~= 'string' then return nil end
        local t = types and types.NPC and types.NPC.stats and types.NPC.stats.skills
        local fn = t and t[skillId]
        if type(fn) ~= 'function' then return nil end
        return fn
    end

    -- Write `points` to a skill's native modifier, tracking only our own delta.
    local function applySkillDelta(skillId, points)
        local prev = appliedBySkill[skillId] or 0
        if prev == points then return end
        local fn = vanillaSkillAccessor(skillId)
        if not fn then
            appliedBySkill[skillId] = nil
            return
        end
        pcall(function()
            local stat = fn(self)
            if not stat then return end
            stat.modifier = math.max(0, (stat.modifier or 0) - prev + points)
        end)
        appliedBySkill[skillId] = (points ~= 0) and points or nil
    end

    -- Shield active-effect, delta-accounted exactly like evasion's Sanctuary.
    local function applyShieldDelta(points)
        if not SHIELD_EFFECT then return end
        local delta = points - appliedShield
        if delta == 0 then return end
        pcall(function()
            types.Actor.activeEffects(self):modify(delta, SHIELD_EFFECT)
        end)
        appliedShield = points
    end

    -- Peel ALL of our contributions back to zero (skill + shield).
    local function clearBonuses()
        for skillId in pairs(appliedBySkill) do
            applySkillDelta(skillId, 0)
        end
        applyShieldDelta(0)
    end

    -- Reset the transient trackers WITHOUT touching the engine — used on load,
    -- where the engine has already zeroed modifiers/effects and our trackers must
    -- match so the first reapply computes from a clean baseline.
    local function resetTrackers()
        appliedBySkill = {}
        appliedShield  = 0
    end

    -- ─── Resonant payoff magnitudes ───────────────────────────────────────────

    local function resonantSkillBonus()
        local base = tonumber(cfg() and cfg().weaponSkillBonus) or 20
        if perkUnlocked(100) then base = base * (tonumber(perkCfg().endlessResonantBoost) or 1.25) end
        return math.max(0, math.floor(base + 0.5))
    end

    local function resonantShield()
        local base = tonumber(cfg() and cfg().shieldPoints) or 30
        if perkUnlocked(100) then base = base * (tonumber(perkCfg().endlessResonantBoost) or 1.25) end
        return math.max(0, math.floor(base + 0.5))
    end

    -- Apply the resonant buffs to Felthorn's CURRENTLY resolved weapon skill
    -- (follows shapeshifts) + the Shield mitigation. Peels any skill we no longer
    -- target. Called every resonant tick so it self-heals after a load.
    local function applyResonantBonuses()
        local skillId = resolveStanceSkill(STANCE_ID)
        local want = skillId and resonantSkillBonus() or 0
        for held in pairs(appliedBySkill) do
            if held ~= skillId then applySkillDelta(held, 0) end
        end
        if skillId then applySkillDelta(skillId, want) end
        applyShieldDelta(resonantShield())
    end

    -- ─── Phase transitions ────────────────────────────────────────────────────

    local function enterResonant(active)
        local s = getState()
        local maxM = tonumber(cfg().meterMax) or 100
        s.phase = 'resonant'
        s.meter = maxM
        applyResonantBonuses()
        if cfg().voiceResonance ~= false and voice.sayResonance then
            pcall(voice.sayResonance, active)
        end
        -- flashOnResonance: reserved hook (no verified screen-flash API in this
        -- build); left as a config flag so a flash can be wired later without a
        -- behavioural change here.
        saveState(true)
        debugLog('Blademeister: SOUL RESONANCE — buffs applied, meter draining.', 'debugPerkMessages')
    end

    local function enterExhausted(active)
        local s = getState()
        s.phase = 'exhausted'
        s.meter = 0
        local cd = tonumber(cfg().cooldownSec) or 20
        if perkUnlocked(75) then cd = cd * (tonumber(perkCfg().tirelessCooldownMult) or 0.5) end  -- Tireless Pact
        s.cooldownStart = now()
        s.cooldownEnds  = s.cooldownStart + cd
        clearBonuses()
        if cfg().voiceExhaustion ~= false and voice.sayExhausted then
            pcall(voice.sayExhausted, active)
        end
        saveState(true)
        debugLog('Blademeister: SOUL EXHAUSTION — Felthorn spent, cooldown started.', 'debugPerkMessages')
    end

    -- ─── Meter building ───────────────────────────────────────────────────────

    local lastHitAt = -math.huge

    local function addMeter(amount, active)
        if amount <= 0 then return end
        local s = getState()
        if s.phase ~= 'building' then return end
        if perkUnlocked(25) then amount = amount * (tonumber(perkCfg().quickeningBuildMult) or 1.5) end  -- Quickening Hunger
        local maxM = tonumber(cfg().meterMax) or 100
        s.meter = math.min(maxM, (s.meter or 0) + amount)
        lastHitAt = now()
        if s.meter >= maxM then
            enterResonant(active)
        else
            saveState(false)
        end
    end

    -- ─── Public API ───────────────────────────────────────────────────────────

    local api = {}

    -- Landed a hit with Felthorn (gated on the active stance by the caller's
    -- context, re-checked here defensively).
    function api.onHit(activeStanceId)
        if not featureOn() then return end
        if activeStanceId ~= STANCE_ID then return end
        addMeter(tonumber(cfg().buildPerHit) or 12, activeStanceId)
    end

    -- Landed a kill with Felthorn.
    function api.onKill(activeStanceId)
        if not featureOn() then return end
        if activeStanceId ~= STANCE_ID then return end
        -- Endless Resonance (100): a kill taken AT THE HEIGHT of resonance refills
        -- the meter to full, extending the surge — chain kills to sustain it.
        local s = getState()
        if s.phase == 'resonant' and perkUnlocked(100)
            and (perkCfg().endlessKillCascade ~= false) then
            s.meter = tonumber(cfg().meterMax) or 100
            saveState(true)
            debugLog('Blademeister: Endless Resonance — kill refilled the meter mid-surge.', 'debugPerkMessages')
            return
        end
        addMeter(tonumber(cfg().buildPerKill) or 25, activeStanceId)
    end

    -- Per-tick state machine. Drives decay / drain / cooldown and reapplies the
    -- resonant buffs while resonant.
    function api.update(activeStanceId, dt)
        dt = tonumber(dt) or 0

        -- Feature off, or not the active stance: peel buffs and FREEZE the meter
        -- (drain pauses off-stance). Cooldown is timestamp-based, so an exhausted
        -- Felthorn still recovers with the passage of time even while away.
        if not featureOn() or activeStanceId ~= STANCE_ID then
            if next(appliedBySkill) ~= nil or appliedShield ~= 0 then clearBonuses() end
            return
        end

        local s = getState()
        local c = cfg()

        if s.phase == 'exhausted' then
            if now() >= (s.cooldownEnds or 0) then
                s.phase = 'building'
                s.meter = 0
                saveState(true)
                debugLog('Blademeister: Felthorn recovered — meter ready to build again.', 'debugPerkMessages')
            else
                if next(appliedBySkill) ~= nil or appliedShield ~= 0 then clearBonuses() end
            end

        elseif s.phase == 'resonant' then
            local drainRate = tonumber(c.drainPerSec) or 8
            if perkUnlocked(50) then drainRate = drainRate * (tonumber(perkCfg().sustainedDrainMult) or 0.667) end  -- Sustained Resonance
            s.meter = (s.meter or 0) - drainRate * dt
            if s.meter <= 0 then
                enterExhausted(activeStanceId)
            else
                applyResonantBonuses()   -- self-heals after a load
                saveState(false)
            end

        else  -- building
            if next(appliedBySkill) ~= nil or appliedShield ~= 0 then clearBonuses() end
            local grace = tonumber(c.decayGraceSec) or 3
            if (now() - lastHitAt) > grace and (s.meter or 0) > 0 then
                local decay = (tonumber(c.decayPerSec) or 4) * dt
                s.meter = math.max(0, (s.meter or 0) - decay)
                saveState(false)
            end
        end
    end

    -- Called from onLoad: the engine has zeroed modifiers/effects, so match our
    -- trackers to that. If we were resonant, the next update reapplies cleanly.
    function api.clearBonuses()
        resetTrackers()
    end

    -- HUD read. Returns nil unless Blademeister is the active stance, the feature
    -- is on, and there is something to show (hidden while idle at an empty meter).
    -- Otherwise returns { phase, ratio, tex } where `ratio` is the fill fraction
    -- for the phase and `tex` is the bar texture to use:
    --   building / resonant  -> resonance texture, ratio = meter / meterMax
    --   exhausted            -> exhaustion texture, ratio = recovery progress
    function api.getMeterInfo(activeStanceId)
        if not featureOn() then return nil end
        if activeStanceId ~= STANCE_ID then return nil end
        local s = getState()
        local c = cfg()
        local maxM = tonumber(c.meterMax) or 100

        if s.phase == 'exhausted' then
            local total = math.max(0.01, (s.cooldownEnds or 0) - (s.cooldownStart or 0))
            local recovered = (now() - (s.cooldownStart or 0)) / total
            if recovered < 0 then recovered = 0 elseif recovered > 1 then recovered = 1 end
            return {
                phase = 'exhausted',
                ratio = recovered,
                tex   = c.barExhaustionTexture or 'textures/Stance/lag_bar.png',
            }
        end

        local ratio = maxM > 0 and math.max(0, math.min(1, (s.meter or 0) / maxM)) or 0
        -- Hide the bar while idle with nothing built yet, to avoid clutter.
        if s.phase == 'building' and ratio <= 0 then return nil end
        return {
            phase = s.phase,
            ratio = ratio,
            tex   = c.barResonanceTexture or 'textures/Stance/resonance_bar.png',
        }
    end

    return api
end

return M
