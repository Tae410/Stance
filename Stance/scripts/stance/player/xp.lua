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
    -- Called with HALF the stance XP whenever the active stance gains XP.

    local function feedCoreSkill(amount)
        if amount <= 0 then return end
        if I.SkillFramework and I.SkillFramework.skillUsed then
            pcall(I.SkillFramework.skillUsed, SKILL_ID, { useType = 1, skillGain = amount })
        end
    end

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

        -- Core skill gets half the additive value, fed independently.
        feedCoreSkill(scaled * 0.5)

        debugLog(string.format('Stance XP +%0.2f → %s [%s] (lvl %d, xp %0.1f); core +%0.2f',
            scaled, stanceId, source or '?', entry.level, entry.xp, scaled * 0.5),
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
    }
end

return M
