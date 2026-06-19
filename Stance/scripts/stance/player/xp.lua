--[[
    Stance! — XP system (player/xp.lua)

    Owns all stance XP bookkeeping:
      * xpMultiplier()         — reads the player's XP multiplier setting
      * grantStanceXp()        — credit XP to the active stance, resolve level-ups,
                                 feed the core Stance skill, and queue level-up messages
      * handleTimeTick(dt)     — accumulate passage-of-time XP for the active stance
      * pendingStanceLevelUps  — drained each tick in init.lua's onUpdate

    Dependencies (injected via ctx):
        I                — openmw.interfaces (for SkillFramework.skillUsed)
        config           — scripts.stance.config
        SKILL_ID         — string, the core Stance skill id
        readSetting      — function(group, key, default) → value
        debugLog         — function(msg, category)
        getActiveStance  — function() → activeStanceId (string|nil)
        stanceEnabled    — function(stanceId) → bool
        getStanceState   — function() → mutable state table
        saveStanceState  — function()
        xpForStanceLevel — function(level) → number  (XP needed to advance from level)

    Construction (in init.lua, after the XP section's original position):
        local xp = require('scripts.stance.player.xp').new({
            I               = I,
            config          = config,
            SKILL_ID        = SKILL_ID,
            readSetting     = readSetting,
            debugLog        = debugLog,
            getActiveStance = function() return activeStanceId end,
            stanceEnabled   = stanceEnabled,
            getStanceState  = getStanceState,
            saveStanceState = saveStanceState,
            xpForStanceLevel = xpForStanceLevel,
        })

    The returned API is behaviour-identical to the former init.lua locals:
        xp.grantStanceXp(amount, source, stanceId)
        xp.handleTimeTick(dt)
        xp.drainPendingLevelUps() → table of { stanceId, level } entries (clears the queue)
        xp.resetAccumulator()     → resets the time-tick accumulator (called on load)
]]

local M = {}

function M.new(ctx)
    ctx = ctx or {}

    local I               = ctx.I               or require('openmw.interfaces')
    local config          = ctx.config          or {}
    local SKILL_ID        = ctx.SKILL_ID        or 'stance'
    local readSetting     = ctx.readSetting     or function() end
    local debugLog        = ctx.debugLog        or function() end
    local getActiveStance = ctx.getActiveStance or function() return nil end
    local stanceEnabled   = ctx.stanceEnabled   or function() return true end
    local getStanceState  = ctx.getStanceState  or function() return {} end
    local saveStanceState = ctx.saveStanceState or function() end
    local xpForStanceLevel = ctx.xpForStanceLevel or function() return 8 end
    -- Rest-gated core leveling deps (optional; absent → gating inert).
    local getCoreBank      = ctx.getCoreBank      or function() return { banked = 0, pending = false } end
    local saveCoreBank     = ctx.saveCoreBank     or function() end
    local getCoreSkillLevel = ctx.getCoreSkillLevel or function() return config.startLevel or 5 end
    local notify           = ctx.notify          or function() end

    -- ── XP source → settings key gate ────────────────────────────────────

    local XP_SOURCE_GATE = {
        hit        = 'xpOnHit',
        kill       = 'xpOnKill',
        spell      = 'xpOnSpellCast',
        block      = 'xpOnBlock',
        parry        = 'xpOnParry',
        perfectparry = 'xpOnParry',
        time       = 'xpOnTime',
        merchant   = 'xpOnMerchant',
        meditate   = 'xpOnTime',
        upgrade    = 'xpOnUpgrade',
        mining     = 'xpOnMining',
        fishing    = 'xpOnFishing',
        lockpick   = 'xpOnLockpick',
        talk       = 'xpOnTalk',
        disenchant = 'xpOnDisenchant',
        commercium = 'xpOnCommercium',
        transcribe = 'xpOnTranscribe',
        concoction = 'xpOnConcoctionHit',
        trap       = 'xpOnTrapHit',
        oilburn    = 'xpOnOilBurn',
    }

    -- ── Multiplier ────────────────────────────────────────────────────────

    local function xpMultiplier()
        local v = tonumber(readSetting('Progression', 'xpMultiplier', 100)) or 100
        if v < 0 then v = 0 end
        return v * 0.01
    end

    -- ── Core skill feeder ─────────────────────────────────────────────────
    -- Called with HALF the stance XP whenever the active stance gains XP, then
    -- divided by the progression slowdown so the shared core skill takes the
    -- same multiple longer to advance as the individual stances do.

    local function coreSlowdown()
        local s = tonumber(config.leveling and config.leveling.progressionSlowdown) or 1
        if s < 1 then s = 1 end
        return s
    end

    -- ── Rest-gated core leveling ──────────────────────────────────────────
    -- When config.coreRestGating.enabled, the half-stance core feed is BANKED
    -- instead of fed to Skill Framework. Once the bank reaches the next core
    -- level's requirement the core skill is "ready" (pending) and ALL stance XP
    -- is blocked (see creditStance) until the player rests, at which point
    -- flushCoreBankOnRest() feeds the bank to SF and the core skill levels.

    local function restGatingOn()
        return (config.coreRestGating and config.coreRestGating.enabled) == true
    end

    -- Bank required for the core skill's NEXT level. Mirrors xpForStanceLevel and
    -- carries the progression slowdown, so the core skill takes the slowdown
    -- multiple longer to advance.
    local function coreXpForLevel(level)
        local g = config.coreRestGating or {}
        local base  = tonumber(g.baseXpToLevel) or 12
        local ramp  = tonumber(g.rampPerLevel) or 0.07
        local maxXp = tonumber(g.maxXpToLevel) or 500
        local lo    = config.startLevel or 5
        local req = base * (1 + math.max(0, (tonumber(level) or lo) - lo) * ramp)
        if req > maxXp then req = maxXp end
        req = req * coreSlowdown()
        if req < 1 then req = 1 end
        return req
    end

    local function feedSkillFramework(amount)
        if amount <= 0 then return end
        if I.SkillFramework and I.SkillFramework.skillUsed then
            pcall(I.SkillFramework.skillUsed, SKILL_ID, { useType = 1, skillGain = amount })
        end
    end

    -- Core feed: the shared core "Stance" skill gains a SMALL fraction of the
    -- stance's XP whenever an active stance gains XP. creditStance passes half the
    -- scaled stance XP, and this divides it again by the progression slowdown, so
    -- the core advances at roughly one-sixth the stance's per-event rate (half ÷ 3
    -- at the default slowdown). That keeps the core trailing WELL behind the active
    -- stance — it is a slow running measure of overall mastery, not a fast-levelling
    -- skill. The core then levels normally, like any other Skill Framework skill.
    local function feedCoreSkill(amount)
        if amount <= 0 then return end
        feedSkillFramework(amount / coreSlowdown())
    end

    -- Retained as harmless no-ops for any external callers (the rest-gate was
    -- removed): nothing blocks stance XP, and there is no bank to flush.
    local function coreLevelPending() return false end
    local function flushCoreBankOnRest() return false end

    -- ── Level-up queue ────────────────────────────────────────────────────
    -- Filled by grantStanceXp; drained by init.lua's onUpdate via
    -- drainPendingLevelUps().

    local pendingStanceLevelUps = {}

    -- ── XP grant ──────────────────────────────────────────────────────────
    -- creditStance() is the shared implementation. grantStanceXp credits ONLY
    -- when stanceId is the currently active stance (the normal case for combat,
    -- spell, time, etc.). grantStanceXpDirect credits a FIXED stance regardless
    -- of what is active — used for environmental/event sources that belong to a
    -- specific stance no matter what the player happens to be wielding when the
    -- hit lands (a trap kill always trains Thief; an oil-fire burn always trains
    -- Apothecary). Both resolve level-ups immediately and queue announcements,
    -- and both feed the core Stance skill with half the (scaled) value.

    local function creditStance(amount, source, stanceId, allowInactive)
        if not amount or amount == 0 then return end
        if not stanceId then return end
        -- Only the active stance gains XP, unless the caller explicitly opts out
        -- (direct/event credit to a fixed stance).
        if not allowInactive and stanceId ~= getActiveStance() then return end
        if not stanceEnabled(stanceId) then return end

        local gate = XP_SOURCE_GATE[source or 'hit']
        if gate and readSetting('Progression', gate, true) ~= true then return end

        local scaled = amount * xpMultiplier()

        -- Dualist splits its attention between two weapons, so its hit/kill XP is
        -- halved, and "blocking" while juggling two weapons is likewise worth half.
        -- A N'Garde parry IS the block in a dual-wield context (weapon parries work
        -- without a shield), so the parry sources are scaled by the block factor.
        -- Gated strictly on the Dualist stance, so no other stance is affected.
        if stanceId == 'dualist' then
            local xpc = config.xp or {}
            if source == 'hit' or source == 'kill' then
                scaled = scaled * (tonumber(xpc.dualistHitXpScale) or 0.5)
            elseif source == 'block' or source == 'parry' or source == 'perfectparry' then
                scaled = scaled * (tonumber(xpc.dualistBlockXpScale) or 0.5)
            end
        end

        if scaled <= 0 then return end

        -- Credit the stance's own pool and resolve any level-ups.
        local state = getStanceState()
        local entry = state[stanceId]
        if not entry then return end
        entry.xp = (entry.xp or 0) + scaled

        while entry.level < config.maxLevel do
            local need = xpForStanceLevel(entry.level)
            if entry.xp < need then break end
            entry.xp = entry.xp - need
            entry.level = entry.level + 1
            table.insert(pendingStanceLevelUps, { stanceId = stanceId, level = entry.level })
        end
        if entry.level >= config.maxLevel then
            entry.level = config.maxLevel
            entry.xp = 0
        end
        saveStanceState()

        -- Core skill gains HALF the stance's scaled XP, then feedCoreSkill divides
        -- that again by the progression slowdown (so ~1/6 the stance's rate at the
        -- default slowdown of 3). The core trails the active stance, by design.
        feedCoreSkill(scaled * 0.5)

        debugLog(string.format('Stance XP +%0.2f → %s [%s] (lvl %d, xp %0.1f); core +%0.3f',
            scaled, stanceId, source or '?', entry.level, entry.xp, (scaled * 0.5) / coreSlowdown()),
            'debugXpMessages')
    end

    -- Active-stance credit (the common path).
    local function grantStanceXp(amount, source, stanceId)
        return creditStance(amount, source, stanceId, false)
    end

    -- Fixed-stance credit, independent of the active stance. For event sources
    -- tied to a specific stance (trap kills → Thief, oil-fire burns → Apothecary).
    local function grantStanceXpDirect(amount, source, stanceId)
        return creditStance(amount, source, stanceId, true)
    end

    -- ── Time-based XP tick ────────────────────────────────────────────────

    local timeTickAccumulator = 0

    local function handleTimeTick(dt)
        timeTickAccumulator = timeTickAccumulator + (dt or 0)
        local interval = (config.xp and config.xp.stanceTimeIntervalSec) or 10
        while timeTickAccumulator >= interval do
            timeTickAccumulator = timeTickAccumulator - interval
            local activeId = getActiveStance()
            if activeId then
                grantStanceXp((config.xp and config.xp.stanceTimeTick) or 0.1, 'time', activeId)
            end
        end
    end

    -- ── Level-up queue drain ──────────────────────────────────────────────
    -- Returns (and clears) the current queue. Callers are responsible for
    -- displaying the messages.

    local function drainPendingLevelUps()
        if #pendingStanceLevelUps == 0 then return {} end
        local batch = pendingStanceLevelUps
        pendingStanceLevelUps = {}
        return batch
    end

    -- ── Accumulator reset (call on load) ──────────────────────────────────

    local function resetAccumulator()
        timeTickAccumulator = 0
    end

    return {
        grantStanceXp       = grantStanceXp,
        grantStanceXpDirect = grantStanceXpDirect,
        handleTimeTick      = handleTimeTick,
        drainPendingLevelUps = drainPendingLevelUps,
        resetAccumulator    = resetAccumulator,
        flushCoreBankOnRest = flushCoreBankOnRest,
        coreLevelPending    = coreLevelPending,
    }
end

return M
