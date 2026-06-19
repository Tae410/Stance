--[[
    Stance! — the Muse stance + Bardcraft integration (player/muse.lua)

    Adds a brand-new stance, MUSE, that is active only while the player is
    performing a song *idly* (a Bardcraft Practice performance — playing for
    yourself, no venue, no crowd). Performing a song to completion grants a
    timed "inspiration" buff to ONE other stance — the stance that song is
    coherently associated with — and the Muse stance itself levels from playing
    idle songs and from successfully administering those buffs.

    THE LOOP
    ────────
      • Start an idle (Practice) performance → Muse becomes the active stance.
        The current song is mapped to a target stance (see association below),
        and a per-performance note ledger opens.
      • Each note Bardcraft reports:
          - SUCCESS → + config.muse.successSeconds to the buff timer, and drains
                      config.muse.successFatigue (2) fatigue.
          - FAIL    → − config.muse.failSeconds   from the buff timer, and drains
                      config.muse.failFatigue   (4) fatigue.
        Only notes within the first N loops of the song count toward the timer
        (N = the Muse loop allowance, which grows with Muse level — see below).
      • When the song finishes, the accumulated time is clamped at >= 0 and, if
        positive, applied as the buff duration to the associated stance. Muse XP
        is granted for completing the idle song and (if a buff landed) for
        administering it.

    THE BUFF
    ────────
    A buffed stance receives a temporary additive bonus to its own weapon skill
    — "Muse's Inspiration" — applied through the same delta-accounted native
    skill-modifier path the effectiveness / Sol bonuses use (so it stacks
    cleanly and never stomps another system). The magnitude scales with Muse
    level; the DURATION is whatever the performance's note ledger earned. The
    buffed stance's tooltip shows the inspiration, a live countdown of the
    remaining time, and which song inspired it. (Two stances that share a weapon
    skill — e.g. Soloist and Zweihänder both on Long Blade — sum their buffs on
    that skill.)

    SONG → STANCE ASSOCIATION ("every song now buffs a specific stance")
    ───────────────────────────────────────────────────────────────────
    Each song maps to exactly one buffable stance, consistently:
      1. config.muse.songOverrides — a curated map, matched first by exact song
         id, then by a lowercased substring of the song title (for thematic
         hand-tuning, e.g. a war ballad → a heavy stance).
      2. Otherwise a stable hash of the song id selects one of
         config.muse.buffableStances. The same song always maps to the same
         stance, so "every song buffs a specific stance."
    Songs the player has actually performed are remembered (id → stance, title)
    so each buffable stance's tooltip can list "what song will buff that stance."

    LOOP ALLOWANCE ("higher Muse levels increase the loopable buffs")
    ────────────────────────────────────────────────────────────────
    A song can loop during a performance. The number of loops whose notes count
    toward the buff timer is:
        config.muse.baseLoops + floor(museLevel / config.muse.loopMilestoneInterval)
    capped at config.muse.maxLoops — i.e. +1 loopable buff per Muse milestone.
    Loop boundaries are detected from Bardcraft's NewBar conductor events (the
    bar index resets to 0 when a song loops).

    MID-SAVE SAFETY
    ───────────────
    Persisted state (active buffs + known song associations) lives in this
    module's own player-storage section, which is saved with the game. The
    skill-modifier delta trackers are TRANSIENT and are zeroed via
    clearMuseSkillBonuses() from init.lua's onLoad (the engine zeroes skill
    modifiers on load), exactly like clearEvasionBonus / clearSolBonuses. The
    in-progress performance ledger is session-only by design — a save/load
    mid-song simply abandons that performance's pending timer, which is the
    sane outcome.

    Dependencies (injected via ctx):
        self, types, core    — engine handles
        config               — scripts.stance.config
        readSetting          — function(group, key, default) → value
        debugLog             — function(msg, debugFlagKey)
        integrationPresent   — function(integrationId) → boolean
        integrationEnabled   — function(integrationId) → boolean
        stanceEnabled        — function(stanceId) → boolean
        grantStanceXp        — function(amount, source, stanceId)
        getStanceLevel       — function(stanceId) → number
        resolveStanceSkill   — function(stanceId) → vanilla skill id | modded id | nil
        getActiveStance      — function() → activeStanceId (string|nil)
        storage              — openmw.storage
]]

local M = {}

local MUSE_SECTION = 'Stance_MuseV1'
local STATE_KEY    = 'state'

function M.new(ctx)
    local self  = ctx.self
    local types = ctx.types
    local core  = ctx.core
    local config = ctx.config
    local ui     = ctx.ui
    local readSetting        = ctx.readSetting
    local debugLog           = ctx.debugLog
    local integrationPresent = ctx.integrationPresent
    local integrationEnabled = ctx.integrationEnabled
    local stanceEnabled      = ctx.stanceEnabled
    local grantStanceXp      = ctx.grantStanceXp
    local getStanceLevel     = ctx.getStanceLevel
    -- Level fed to the Muse buff magnitude: the player's BARDCRAFT skill (threaded
    -- from init.lua as getBonusLevel('muse')), so a better bard plays stronger
    -- inspiration. Falls back to Muse's stance level if not provided.
    local getBonusLevel      = ctx.getBonusLevel or ctx.getStanceLevel
    local getCoreSkillLevel  = ctx.getCoreSkillLevel  or function() return 0 end
    local resolveStanceSkill = ctx.resolveStanceSkill
    local getActiveStance    = ctx.getActiveStance
    local storage            = ctx.storage

    local museCfg = config.muse or {}

    -- Friendly stance display names (id -> displayName), built from config so
    -- the end-of-song summary reads "Zweihänder", not "zweihander".
    local stanceNames = {}
    for _, st in ipairs(config.stances or {}) do
        if st.id then stanceNames[st.id] = st.displayName or st.id end
    end
    local function stanceName(id) return id and (stanceNames[id] or id) or '?' end

    -- Seconds -> "M:SS".
    local function fmtTime(secs)
        local s = math.max(0, math.floor((tonumber(secs) or 0) + 0.5))
        return string.format('%d:%02d', math.floor(s / 60), s % 60)
    end

    -- ─── Persisted state ──────────────────────────────────────────────────
    -- { activeBuffs = { [stanceId] = {remaining, magnitude, songTitle, skillId} },
    --   knownSongs  = { [songId]   = {stance, title} } }
    local section = storage.playerSection(MUSE_SECTION)
    local stateCache = nil

    local function defaultState() return { activeBuffs = {}, knownSongs = {} } end

    local function getState()
        if stateCache then return stateCache end
        local stored = section:get(STATE_KEY)
        if type(stored) == 'table' then
            stateCache = {
                activeBuffs = (type(stored.activeBuffs) == 'table') and stored.activeBuffs or {},
                knownSongs  = (type(stored.knownSongs)  == 'table') and stored.knownSongs  or {},
            }
        else
            stateCache = defaultState()
        end
        return stateCache
    end

    local function saveState()
        if not stateCache then return end
        pcall(function() section:set(STATE_KEY, stateCache) end)
    end

    -- ─── Transient session state ──────────────────────────────────────────
    local perf = nil               -- in-progress performance ledger
    local isPerforming = false     -- drives the resolver's Muse branch
    local appliedBySkill = {}      -- [skillId] = points we currently applied (delta tracker)
    local persistAccum = 0         -- throttle for periodic persistence of countdowns

    -- ─── Helpers ──────────────────────────────────────────────────────────

    local function museEnabled()
        if not readSetting('', 'enabled', true) then return false end
        if not integrationPresent('bardcraft') then return false end
        if not stanceEnabled('muse') then return false end
        return true
    end

    -- Idle performance types that activate Muse (default: Practice = 3).
    local function isIdleType(perfType)
        local set = museCfg.idlePerfTypes or { [3] = true }
        return set[perfType] == true
    end

    local function buffableList()
        local list = museCfg.buffableStances
        if type(list) ~= 'table' or #list == 0 then return nil end
        return list
    end

    -- Deterministic, stable string hash (djb2-ish) → non-negative integer.
    local function hashString(s)
        local h = 5381
        for i = 1, #s do
            h = (h * 33 + string.byte(s, i)) % 2147483647
        end
        return h
    end

    -- Map a song to its buffable stance: curated override (by id, then title
    -- substring), else a stable hash over the buffable list.
    local function associateStance(songId, songTitle)
        local list = buffableList()
        if not list then return nil end
        local overrides = museCfg.songOverrides
        if type(overrides) == 'table' then
            if songId and overrides[songId] then return overrides[songId] end
            if songTitle then
                local lt = tostring(songTitle):lower()
                for key, stanceId in pairs(overrides) do
                    -- Only treat non-id keys as title substrings (ids are matched above).
                    if type(key) == 'string' and key ~= songId and lt:find(key:lower(), 1, true) then
                        return stanceId
                    end
                end
            end
        end
        local key = tostring(songId or songTitle or 'unknown')
        return list[1 + (hashString(key) % #list)]
    end

    -- Loop allowance grows +1 per Muse milestone.
    local function allowedLoops()
        local base = tonumber(museCfg.baseLoops) or 1
        local interval = tonumber(museCfg.loopMilestoneInterval) or 25
        local maxL = tonumber(museCfg.maxLoops) or 5
        local lvl = getStanceLevel('muse')
        local n = base
        if interval > 0 then n = base + math.floor(lvl / interval) end
        if n > maxL then n = maxL end
        if n < 1 then n = 1 end
        return n
    end

    -- Muse perks unlock on the CORE Stance level (like every other ladder).
    local function musePerkUnlocked(perkLevel)
        return getCoreSkillLevel() >= perkLevel
    end

    -- The longest inspiration window the Muse's own level currently permits:
    -- gateBaseSeconds at gateAtLevel, +gateAddSeconds every gatePerLevels Muse
    -- levels. The 'Lingering Chord' perk (lv 75) extends every window by 25%.
    local function gatedBuffWindow()
        local baseS = tonumber(museCfg.gateBaseSeconds) or 10
        local atLvl = tonumber(museCfg.gateAtLevel)     or 5
        local perL  = tonumber(museCfg.gatePerLevels)   or 10
        local addS  = tonumber(museCfg.gateAddSeconds)  or 10
        if perL < 1 then perL = 1 end
        local lvl = getStanceLevel('muse')
        local steps = math.floor((lvl - atLvl) / perL)
        if steps < 0 then steps = 0 end
        local window = baseS + steps * addS
        if musePerkUnlocked(75) then window = window * 1.25 end  -- Lingering Chord
        if window < 0 then window = 0 end
        return window
    end

    -- Turn a raw note-ledger buffer (seconds) into the final buff duration:
    -- halved by buffDurationScale, then capped by the level gate. The
    -- 'Composer's Voice' capstone (lv 100) lifts the cap ENTIRELY, but only for a
    -- song of the player's OWN composition (isComposed) — preset songs stay gated.
    local function finalBuffDuration(rawSeconds, isComposed)
        local scale = tonumber(museCfg.buffDurationScale) or 0.5
        local dur = math.max(0, rawSeconds) * scale
        local bypassGate = musePerkUnlocked(100) and isComposed == true
        if not bypassGate then
            local cap = gatedBuffWindow()
            if dur > cap then dur = cap end
        end
        if dur < 0 then dur = 0 end
        return dur
    end

    -- Buff magnitude (skill points), scaled by the player's BARDCRAFT skill.
    local function buffMagnitude()
        local b = tonumber(museCfg.buffMagnitudeBase) or 5
        local per = tonumber(museCfg.buffMagnitudePerLevel) or 0.1
        local cap = tonumber(museCfg.buffMagnitudeMax) or 20
        local lvl = getBonusLevel('muse')
        local mag = math.floor(b + per * lvl + 0.5)
        if mag > cap then mag = cap end
        if mag < 1 then mag = 1 end
        return mag
    end

    -- Native vanilla skill accessor for a stance's target skill, or nil for
    -- modded SF skills (those aren't on types.NPC.stats.skills).
    local function vanillaSkillAccessor(skillId)
        if type(skillId) ~= 'string' then return nil end
        local t = types.NPC and types.NPC.stats and types.NPC.stats.skills
        local fn = t and t[skillId]
        if type(fn) ~= 'function' then return nil end
        return fn
    end

    local function drainFatigue(amount)
        if not amount or amount <= 0 then return end
        pcall(function()
            local fat = types.Actor.stats.dynamic.fatigue(self)
            if fat then fat.current = math.max(0, (fat.current or 0) - amount) end
        end)
    end

    -- ─── Skill-modifier application (delta, summed per skill) ─────────────
    -- Apply `points` to a vanilla skill's native modifier, tracked per skill so
    -- only our own contribution is ever adjusted (write = cur - prev + new).
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
        if points == 0 then
            appliedBySkill[skillId] = nil
        else
            appliedBySkill[skillId] = points
        end
    end

    -- ─── Buff lifecycle ───────────────────────────────────────────────────

    local function applyBuff(stanceId, seconds, songTitle, magScale)
        if not stanceId or seconds <= 0 then return false end
        local skillId = resolveStanceSkill(stanceId)
        local scale = tonumber(magScale) or 1
        local mag = math.floor(buffMagnitude() * scale + 0.5)
        if mag < 1 then mag = 1 end
        local st = getState()
        st.activeBuffs[stanceId] = {
            remaining = seconds,
            duration  = seconds,   -- total window length, for the HUD bar ratio
            magnitude = mag,
            songTitle = songTitle,
            skillId   = skillId,
        }
        saveState()
        return true
    end

    -- Recompute desired per-skill totals from all live buffs and delta-apply.
    local function reapplyAllBuffs()
        local st = getState()
        local desired = {}
        for _, buff in pairs(st.activeBuffs) do
            if buff.remaining and buff.remaining > 0 and buff.skillId then
                desired[buff.skillId] = (desired[buff.skillId] or 0) + (buff.magnitude or 0)
            end
        end
        -- Apply desired; zero any skill we previously touched but no longer want.
        for skillId in pairs(appliedBySkill) do
            if desired[skillId] == nil then applySkillDelta(skillId, 0) end
        end
        for skillId, pts in pairs(desired) do
            applySkillDelta(skillId, pts)
        end
    end

    -- ─── Performance event handling ───────────────────────────────────────

    local function beginPerformance(songId, songTitle, perfType, isComposed)
        if not museEnabled() then return end
        if not isIdleType(perfType) then return end           -- only idle (Practice) play
        perf = {
            songId    = songId,
            songTitle = songTitle or 'a song',
            stance    = associateStance(songId, songTitle),
            isComposed = isComposed == true,   -- player-authored (Bardcraft editor) vs preset
            accum     = 0,
            loop      = 0,
            lastBar   = -1,
            allowed   = allowedLoops(),
            notes     = 0,
            successes = 0,
        }
        isPerforming = true
        debugLog(string.format('Muse: idle performance of "%s" → buffs %s (loops allowed: %d)',
            perf.songTitle, tostring(perf.stance), perf.allowed), 'debugDetectionMessages')
    end

    local function noteBar(bar)
        if not perf or type(bar) ~= 'number' then return end
        if bar < perf.lastBar then perf.loop = perf.loop + 1 end
        perf.lastBar = bar
    end

    local function handleNote(success)
        if not perf then return end
        -- Fatigue is drained for every note actually played. The 'Easy Breath'
        -- perk (lv 25) cuts that drain by a third.
        local fat = success and (museCfg.successFatigue or 2) or (museCfg.failFatigue or 4)
        if musePerkUnlocked(25) then fat = fat * (2 / 3) end
        drainFatigue(fat)
        -- Only the first `allowed` loops contribute to the buff timer.
        if perf.loop >= perf.allowed then return end
        perf.notes = perf.notes + 1
        if success then
            perf.successes = perf.successes + 1
            perf.accum = perf.accum + (tonumber(museCfg.successSeconds) or 1.5)
        else
            perf.accum = perf.accum - (tonumber(museCfg.failSeconds) or 1.0)
        end
    end

    local function finishPerformance(completion)
        if not perf then isPerforming = false; return end
        local p = perf
        perf = nil
        isPerforming = false

        -- Remember the association so the buffed stance's tooltip can name it.
        if p.songId and p.stance then
            local st = getState()
            st.knownSongs[p.songId] = { stance = p.stance, title = p.songTitle }
            saveState()
        end

        -- XP for completing the idle song, scaled gently by how complete it was.
        local comp = tonumber(completion) or 0
        if comp >= (tonumber(museCfg.minCompletionForXp) or 0.5) then
            grantStanceXp(config.xp.museSongComplete or 3.0, 'song', 'muse')
        end

        -- Raw note-ledger time, then halved and capped by the Muse level gate
        -- (see finalBuffDuration). 'Composer's Voice' (lv 100) lifts the cap for
        -- the player's own compositions. A long, clean performance can otherwise
        -- only ever buy as much inspiration time as the Muse's own mastery permits.
        local bufferTime = finalBuffDuration(p.accum, p.isComposed)
        local buffed = false
        if p.stance and bufferTime > 0 then
            if applyBuff(p.stance, bufferTime, p.songTitle) then
                buffed = true
                grantStanceXp(config.xp.museBuffAdminister or 2.0, 'buff', 'muse')

                -- 'Shared Refrain' (lv 50): also inspire a kindred stance at half
                -- magnitude (same duration). No-op when the buffed stance has no
                -- kin mapped or the perk is not yet unlocked.
                if musePerkUnlocked(50) then
                    local kin = (museCfg.kindredStance or {})[p.stance]
                    if kin and kin ~= p.stance then
                        applyBuff(kin, bufferTime, p.songTitle, 0.5)
                        debugLog(string.format('Muse Shared Refrain: kindred %s buffed at half for %.0fs',
                            tostring(kin), bufferTime), 'debugPerkMessages')
                    end
                end

                reapplyAllBuffs()
                debugLog(string.format('Muse: "%s" → +%d %s inspiration for %.0fs (%d/%d notes)%s',
                    p.songTitle, buffMagnitude(), tostring(p.stance), bufferTime,
                    p.successes, p.notes, p.isComposed and ' [composed]' or ''), 'debugPerkMessages')
            end
        end

        -- End-of-song summary box: relevant buff + time-buffed info. Gated on a
        -- setting (default on); only shown when an idle song actually ran a note
        -- ledger (p.notes > 0) so a no-op start/stop stays quiet.
        if ui and ui.showMessage
            and readSetting('', 'announceMuseSummary', true)
            and (p.notes or 0) > 0 then
            local title = p.songTitle or 'a song'
            local msg
            if buffed then
                msg = string.format(
                    'Muse: "%s" inspires %s — +%d for %s.  (%d/%d notes clean, %d loop%s)',
                    title, stanceName(p.stance), buffMagnitude(), fmtTime(bufferTime),
                    p.successes or 0, p.notes or 0,
                    (p.loop or 0) + 1, ((p.loop or 0) + 1) == 1 and '' or 's')
            elseif p.stance then
                msg = string.format(
                    'Muse: "%s" was too rough to inspire %s.  (%d/%d notes clean)',
                    title, stanceName(p.stance), p.successes or 0, p.notes or 0)
            else
                msg = string.format('Muse: "%s" ends. (no stance to inspire)', title)
            end
            pcall(ui.showMessage, msg)
        end
    end

    -- Bardcraft sends BO_ConductorEvent to the performer (the player) with a
    -- `type` discriminator. We care about PerformStart / NewBar / PerformStop.
    local function onConductorEvent(e)
        if type(e) ~= 'table' then return end
        if e.type == 'PerformStart' then
            local song = e.song
            -- Bardcraft tags preset (MIDI) songs with song.isPreset = true; songs
            -- authored in the editor (stored under songs/custom) do not carry it.
            -- So a player composition is simply "not a preset".
            local isComposed = song and (song.isPreset ~= true) or false
            beginPerformance(song and song.id, song and song.title, e.perfType, isComposed)
        elseif e.type == 'NewBar' then
            noteBar(e.bar)
        elseif e.type == 'PerformStop' then
            finishPerformance(e.completion)
        end
    end

    -- Per-note success/fail, relayed from global.lua (BC_PerformerNoteHandled is
    -- a global event; global.lua filters to player notes and forwards here).
    local function onNote(payload)
        if type(payload) ~= 'table' then return end
        handleNote(payload.success == true)
    end

    -- ─── Per-frame upkeep ─────────────────────────────────────────────────
    local function update(dt)
        dt = tonumber(dt) or 0
        local st = getState()
        local changed = false
        local anyLive = false
        for stanceId, buff in pairs(st.activeBuffs) do
            if buff.remaining then
                buff.remaining = buff.remaining - dt
                if buff.remaining <= 0 then
                    st.activeBuffs[stanceId] = nil
                    changed = true
                else
                    anyLive = true
                end
            end
        end
        reapplyAllBuffs()
        -- Throttled persistence so a save/load mid-buff keeps a fresh-ish remaining.
        if anyLive then
            persistAccum = persistAccum + dt
            if persistAccum >= 3.0 then persistAccum = 0; saveState() end
        end
        if changed then saveState() end
    end

    -- Zero our transient skill-modifier trackers without writing to the engine.
    -- Called from onLoad (the engine zeroes skill modifiers on load); the next
    -- update's reapplyAllBuffs re-applies from a clean baseline.
    local function clearMuseSkillBonuses()
        appliedBySkill = {}
    end

    -- ─── Public accessors (resolver + tooltip) ────────────────────────────

    local function isPerformingMusically()
        return isPerforming and museEnabled()
    end

    -- Active buff on a stance (for its tooltip), or nil.
    local function getBuffInfo(stanceId)
        local st = getState()
        local b = st.activeBuffs[stanceId]
        if b and b.remaining and b.remaining > 0 then return b end
        return nil
    end

    -- Titles of known songs that buff this stance (most-recently-seen first is
    -- not tracked; insertion order is undefined, so we just collect + sort).
    local function getSongTitlesForStance(stanceId)
        local st = getState()
        local out = {}
        for _, info in pairs(st.knownSongs) do
            if info.stance == stanceId and info.title then out[#out + 1] = info.title end
        end
        table.sort(out)
        return out
    end

    -- Status line for the Muse stance's own tooltip while performing.
    local function getPerformanceStatus()
        if not perf then return nil end
        return {
            songTitle = perf.songTitle,
            stance    = perf.stance,
            accum     = perf.accum,
            loop      = perf.loop,
            allowed   = perf.allowed,
            successes = perf.successes,
            notes     = perf.notes,
        }
    end

    return {
        onConductorEvent       = onConductorEvent,
        onNote                 = onNote,
        update                 = update,
        clearMuseSkillBonuses  = clearMuseSkillBonuses,
        isPerformingMusically  = isPerformingMusically,
        getBuffInfo            = getBuffInfo,
        getSongTitlesForStance = getSongTitlesForStance,
        getPerformanceStatus   = getPerformanceStatus,
        associateStance        = associateStance,
        allowedLoops           = allowedLoops,
    }
end

return M
