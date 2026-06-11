--[[
    Stance! — Player Script (init.lua)

    Responsibilities:
      * Register one Skill Framework skill whose displayed name, governing
        attribute, and description mutate as the active stance changes.
      * Detect which stance the player is in every frame, using equipped
        items, the active combat/spell stance, and integrations with
        external mods (Dual Wielding, N'Garde, Bullseye, Throwing!,
        Staves!, Incantation, Meditation Skill, Gothic Style Knockout,
        WeaponUpgrade, ArmorUpgrade).
      * Track XP and level per-stance independently in player storage.
      * Apply a cascading XP curve: each stance level-up feeds XP back to
        the core Stance skill; the core Stance skill's level then scales
        the XP cost of future stance level-ups, so mastery slows over time.
      * Fire perk-unlocked feedback when a stance crosses 25/50/75/100.
      * Mirror settings into a Runtime_Stance global storage section.
      * Provide a minimal HUD indicator (active stance name only).
      * Provide console commands for skill manipulation and diagnostics.

    Architecture:
      All XP bookkeeping and stance detection live in the player script.
      Global.lua is intentionally thin: it stores cross-load mirror data,
      forwards kill events back to the player, and acts as a relay for
      future cross-actor signals.

      External-mod integrations are detection-only. Stance! reads other
      mods' public skill levels, public storage sections, and public
      events — it never writes to their state.
]]

local core    = require('openmw.core')
local I       = require('openmw.interfaces')
local self    = require('openmw.self')
local storage = require('openmw.storage')
local types   = require('openmw.types')
local ui      = require('openmw.ui')
local util    = require('openmw.util')
local async   = require('openmw.async')

local config = require('scripts.stance.config')
local Perks  = require('scripts.stance.perks')

local MODNAME = 'Stance'
local SKILL_ID = config.skillId

-- ─── Settings access ──────────────────────────────────────────────────────

local settingsSections = {}

local function settingSection(groupSuffix)
    local sectionName = 'Settings_' .. MODNAME
    if groupSuffix and groupSuffix ~= '' then
        sectionName = sectionName .. '_' .. groupSuffix
    end
    local section = settingsSections[sectionName]
    if not section then
        section = storage.playerSection(sectionName)
        settingsSections[sectionName] = section
    end
    return section
end

local function readSetting(groupSuffix, key, default)
    local val = settingSection(groupSuffix):get(key)
    if val == nil then return default end
    return val
end

-- Leveling model:
--   * Each stance has its OWN xp + level, persisted in player storage.
--     A stance only gains XP while it is the ACTIVE stance.
--   * When the active stance gains N xp, the core Stance skill (owned by
--     Skill Framework) gains N/2 — fed directly via skillUsed. The core
--     skill therefore levels independently and more slowly than any one
--     stance.
--   * Switching stances simply leaves the previous stance's xp/level
--     saved in storage (it's already persisted on every grant); the core
--     skill is untouched by switching.
--   * Perks are gated on the CORE Stance skill level: when the core skill
--     hits 25, every stance's level-25 perk becomes available, etc.
local stanceStateSection = storage.playerSection('Stance_StateV2')
local STANCE_STATE_KEY   = 'stanceLevels'

-- In-memory marker of the highest core level we've already announced
-- perks for, so we don't repeat unlock popups within a session.
local lastAnnouncedCoreLevel = nil

-- ─── Perks module bootstrap ───────────────────────────────────────────────
-- Perks.init() needs context accessors defined further down in this file.
-- Forward-declare them here so the ensurePerksInit() closure captures the
-- locals themselves (not unresolved globals). Each local is assigned at its
-- natural definition site below.
local activeStanceId       -- assigned in "Active stance tracking" section
local getCoreSkillLevel    -- assigned in "Core Stance skill access" section
local getStanceLevel       -- assigned in "Per-stance state" section
local integrationPresent   -- assigned in "Integration detection" section
local stanceEnabled        -- assigned in stance-setting helpers section
local isDualWielding       -- assigned in "Dual wielding detection" section
local isFelthornInOffhand  -- assigned in "Dual wielding detection" section
local perksEnabledForStance -- assigned in perk-setting helpers section
local debugLog             -- assigned in "Logging" section

local perksInitialized = false

local function ensurePerksInit()
    if perksInitialized then return end
    perksInitialized = true

    -- Build the context table that Perks uses to reach back into init.lua.
    local perkContext = {
        getActiveStance      = function() return activeStanceId end,
        getCoreLevel         = function() return getCoreSkillLevel() end,
        getStanceLevel       = function(id) return getStanceLevel(id) end,
        integrationPresent   = function(id) return integrationPresent(id) end,
        readSetting          = function(g, k, d) return readSetting(g, k, d) end,
        stanceEnabled        = function(id) return stanceEnabled(id) end,
        perksEnabled         = function(id) return perksEnabledForStance(id) end,
        getSelf              = function() return self end,
        getStanceStorage     = function() return stanceStateSection end,
    }
    Perks.init(perkContext)
    debugLog('Perks module initialised.', 'debugIntegrationMessages')
end

-- ─── Logging ──────────────────────────────────────────────────────────────

local function debugEnabled(category)
    if not readSetting('Debug', 'debugMessages', false) then return false end
    if not category then return true end
    return readSetting('Debug', category, false)
end

-- debugLog forward-declared above (needed by ensurePerksInit closure).
debugLog = function(msg, category)
    if debugEnabled(category) then
        print('[Stance!] ' .. tostring(msg))
    end
end

-- ─── Stance lookup ────────────────────────────────────────────────────────

local stanceById = {}
for _, st in ipairs(config.stances) do
    stanceById[st.id] = st
end

local function getStanceConfig(stanceId)
    return stanceById[stanceId]
end

-- ─── Per-stance state (xp + level), persisted ─────────────────────────────

local function defaultStanceState()
    local state = {}
    for _, st in ipairs(config.stances) do
        state[st.id] = { xp = 0, level = config.startLevel }
    end
    return state
end

local stanceStateCache = nil

local function getStanceState()
    if stanceStateCache then return stanceStateCache end
    local stored = stanceStateSection:get(STANCE_STATE_KEY)
    local result = defaultStanceState()
    if type(stored) == 'table' then
        for id, entry in pairs(stored) do
            if result[id] and type(entry) == 'table' then
                result[id].xp = tonumber(entry.xp) or 0
                result[id].level = tonumber(entry.level) or config.startLevel
            end
        end
    end
    stanceStateCache = result
    return result
end

local function saveStanceState()
    if not stanceStateCache then return end
    stanceStateSection:set(STANCE_STATE_KEY, stanceStateCache)
end

-- getStanceLevel forward-declared above (needed by ensurePerksInit closure).
getStanceLevel = function(stanceId)
    local entry = getStanceState()[stanceId]
    if not entry then return config.startLevel end
    return math.floor(entry.level or config.startLevel)
end

local function getStanceXp(stanceId)
    local entry = getStanceState()[stanceId]
    if not entry then return 0 end
    return tonumber(entry.xp) or 0
end

-- Effectiveness skill bonus driven by a stance's OWN level. Ramps linearly
-- from leveling.effectivenessMinBonus at startLevel to
-- leveling.effectivenessMaxBonus at maxLevel. This bonus is applied as an
-- additive Skill Framework dynamic modifier on the skill tied to the stance's
-- weapon type or modded integration (see STANCE_SKILL_TARGET and
-- refreshEffectivenessModifiers). Surfaced in the tooltip and exposed on the
-- script interface so source-mod integrations or the player can read it.
local function effectivenessSkillBonus(stanceId)
    local lvl  = getStanceLevel(stanceId)
    local lo   = config.startLevel or 5
    local hi   = config.maxLevel   or 100
    local minB = tonumber(config.leveling and config.leveling.effectivenessMinBonus) or 2
    local maxB = tonumber(config.leveling and config.leveling.effectivenessMaxBonus) or 20
    if hi <= lo then return minB end
    local t = (lvl - lo) / (hi - lo)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return minB + (maxB - minB) * t
end

-- XP required to advance a stance from `level` to `level+1`. Stances are
-- meant to level FASTER than the core skill, so this curve is gentle:
-- a flat base with a mild per-level ramp, capped. No dependence on the
-- core skill (that coupling was the convoluted part we removed).
local function xpForStanceLevel(level)
    local L = config.leveling or {}
    local base  = tonumber(L.baseXpToLevel) or 8
    local ramp  = tonumber(L.xpRampPerLevel) or 0.06
    local maxXp = tonumber(L.maxXpToLevel) or 400
    local req = base * (1 + math.max(0, (tonumber(level) or 0) - config.startLevel) * ramp)
    if req > maxXp then req = maxXp end
    if req < 1 then req = 1 end
    return req
end

-- ─── Core Stance skill access ─────────────────────────────────────────────
--
-- The core Stance skill is owned and persisted by Skill Framework. It
-- gains half of whatever XP the active stance gains, fed via skillUsed,
-- and levels independently. getCoreSkillLevel reads it directly.

-- getCoreSkillLevel forward-declared above (needed by ensurePerksInit closure).
getCoreSkillLevel = function()
    if I.SkillFramework and I.SkillFramework.getSkillStat then
        local ok, stat = pcall(I.SkillFramework.getSkillStat, SKILL_ID)
        if ok and stat then
            return math.floor(tonumber(stat.base or stat.modified) or config.startLevel)
        end
    end
    return config.startLevel
end

-- ─── Perks unlocked ───────────────────────────────────────────────────────
--
-- A stance's perks unlock based on the CORE Stance skill level. So at
-- Stance skill 50, whichever stance is active shows its level-25 and
-- level-50 perks as active. Switching stances swaps the perk ladder but
-- the unlock tier stays tied to the one shared skill level.

local PERK_THRESHOLDS = { 25, 50, 75, 100 }

local function unlockedPerks(stanceId)
    local stance = getStanceConfig(stanceId)
    if not stance then return {} end
    local level = getCoreSkillLevel()
    local result = {}
    for _, perk in ipairs(stance.perks) do
        if level >= perk.level then table.insert(result, perk) end
    end
    return result
end

local function nextPerk(stanceId)
    local stance = getStanceConfig(stanceId)
    if not stance then return nil end
    local level = getCoreSkillLevel()
    for _, perk in ipairs(stance.perks) do
        if level < perk.level then return perk end
    end
    return nil
end

-- ─── Integration detection ────────────────────────────────────────────────

local integrationState = {}
for id, _ in pairs(config.integrations) do
    integrationState[id] = { present = false, detected = false, lastChecked = -1, backoff = 2.0 }
end

local INTEGRATION_SETTING_KEY = {
    toxicology     = 'integrateToxicology',
    simplymining   = 'integrateSimplyMining',
    fishing        = 'integrateFishing',
    throwing       = 'integrateThrowing',
    staves         = 'integrateStaves',
    meditation     = 'integrateMeditation',
    incantation    = 'integrateIncantation',
    bullseye       = 'integrateBullseye',
    ngarde         = 'integrateNGarde',
    dualwielding   = 'integrateDualWielding',
    gothicknockout = 'integrateGothicKnockout',
    weaponupgrade  = 'integrateWeaponUpgrade',
    armorupgrade   = 'integrateArmorUpgrade',
    grip           = 'integrateGRIP',
    blademeister   = 'integrateBlademeister',
    evasion        = 'integrateEvasion',
    thrownconcoctions   = 'integrateThrownConcoctions',
    veneficvials   = 'integrateVeneficVials',
    traps          = 'integrateTraps',
    oilflask       = 'integrateOilFlask',
    spellsword     = 'integrateSpellsword',
    oblivionlockpicking = 'integrateOblivionLockpicking',
    talkingtrains  = 'integrateTalkingTrains',
    disenchanting  = 'integrateDisenchanting',
    commercium     = 'integrateCommercium',
    transcribe     = 'integrateTranscribe',
}

local function integrationEnabled(integrationId)
    local key = INTEGRATION_SETTING_KEY[integrationId]
    if not key then return true end
    local val = settingSection('Integrations'):get(key)
    if val == nil then return true end
    return val == true
end

local function detectIntegration(integrationId)
    local cfg = config.integrations[integrationId]
    if not cfg then return false end

    if cfg.skillId and I.SkillFramework and I.SkillFramework.getSkillRecord then
        local ok, rec = pcall(I.SkillFramework.getSkillRecord, cfg.skillId)
        if ok and rec ~= nil then return true end
    end

    if cfg.storageSection then
        local ok, section = pcall(storage.globalSection, cfg.storageSection)
        if ok and section then
            local okTable, snap = pcall(function() return section:asTable() end)
            if okTable and type(snap) == 'table' then
                for _ in pairs(snap) do return true end
            end
        end
    end

    if cfg.settingsGroup then
        -- These can live in either playerSection or globalSection. We
        -- probe both — whichever returns a non-empty table wins.
        for _, accessor in ipairs({ storage.playerSection, storage.globalSection }) do
            local ok, section = pcall(accessor, cfg.settingsGroup)
            if ok and section then
                local okTable, snap = pcall(function() return section:asTable() end)
                if okTable and type(snap) == 'table' then
                    for _ in pairs(snap) do return true end
                end
            end
        end
    end

    -- Record-id-prefix probe. Used for mods that register their own
    -- weapon/item records but don't expose a Skill Framework skill, a
    -- global storage section, or a settings group we can probe. We sample
    -- types.Weapon.records and return true if any record id starts with
    -- the configured prefix. The sampling is bounded so the check is
    -- cheap even on large modlists — once we find one matching record
    -- we exit. Used by Blademeister (prefix `sd_` matches every Felthorn
    -- shapeshifted form).
    if cfg.recordIdPrefix and types.Weapon and types.Weapon.records then
        local prefix = cfg.recordIdPrefix
        local prefixLower = prefix:lower()
        local ok = pcall(function()
            for _, rec in pairs(types.Weapon.records) do
                local id = rec and rec.id
                if type(id) == 'string' and id:lower():sub(1, #prefixLower) == prefixLower then
                    error('FOUND') -- short-circuit out of the for-loop
                end
            end
        end)
        -- pcall returns ok=false when our 'FOUND' sentinel was raised.
        if not ok then return true end
    end

    -- Exact weapon-record probe. Used for pure-content mods that add named
    -- weapon records but expose no Skill Framework skill, global storage
    -- section, settings group, or event (e.g. Thrown Concoctions). We look the
    -- single sentinel record id up directly in types.Weapon.records (an O(1)
    -- keyed lookup, case-insensitive in OpenMW) rather than scanning, so the
    -- check is trivially cheap. Present iff the record resolves.
    if cfg.weaponRecordId and types.Weapon and types.Weapon.records then
        local ok, rec = pcall(function() return types.Weapon.records[cfg.weaponRecordId] end)
        if ok and rec ~= nil then return true end
    end

    -- Exact activator-record probe. Like weaponRecordId but for ACTIVATOR
    -- records — used by deployable content mods (e.g. Traps' 'trap_open', Oil
    -- Flask's 'oil_pool') that expose no skill, storage, settings group, or
    -- event. Present iff the record resolves.
    if cfg.activatorRecordId and types.Activator and types.Activator.records then
        local ok, rec = pcall(function() return types.Activator.records[cfg.activatorRecordId] end)
        if ok and rec ~= nil then return true end
    end

    -- Spell-record probe. For pure-Lua content mods that add no item records
    -- but do register spell records (e.g. Spellsword's 'spellsword_fire'
    -- imbue spell, always defined when the mod is loaded). Present iff the
    -- spell record resolves.
    if cfg.spellRecordId and core.magic and core.magic.spells and core.magic.spells.records then
        local ok, rec = pcall(function() return core.magic.spells.records[cfg.spellRecordId] end)
        if ok and rec ~= nil then return true end
    end

    return false
end

-- Integration detection runs on a throttle, but once a mod is detected
-- present we stop probing for it entirely: a content mod cannot unload
-- mid-session, so re-running detection (especially the types.Weapon.records
-- scan used by record-id-prefix integrations like Blademeister) would be
-- pure waste. We only keep polling integrations not yet found, and we
-- back off the poll interval over time so a never-present integration
-- isn't probed forever at full frequency.
local function refreshIntegrations(now)
    for id, st in pairs(integrationState) do
        -- Skip anything already found — mods stay loaded for the session.
        if not st.present then
            local interval = st.backoff or 2.0
            if now - (st.lastChecked or -1) >= interval then
                st.lastChecked = now
                local found = detectIntegration(id)
                if found then
                    -- A present mod still has to be enabled in settings to
                    -- count, but we cache the raw detection so toggling the
                    -- setting back on doesn't require a re-scan.
                    st.detected = true
                end
                local enabledNow = st.detected and integrationEnabled(id)
                if enabledNow then
                    st.present = true
                    debugLog(string.format('Integration "%s" detected', id),
                        'debugIntegrationMessages')
                else
                    -- Grow the backoff up to 10s so absent mods are probed
                    -- less and less often instead of every 2s forever.
                    st.backoff = math.min((st.backoff or 2.0) * 1.5, 10.0)
                end
            end
        elseif not integrationEnabled(id) then
            -- The mod is loaded but the player turned its integration OFF
            -- in settings. Honor that without re-probing the world.
            st.present = false
        end
    end
end

-- integrationPresent forward-declared above (needed by ensurePerksInit closure).
integrationPresent = function(id)
    local st = integrationState[id]
    return st and st.present == true
end

-- ─── Equipment helpers ────────────────────────────────────────────────────

local function safeWeaponRecord(item)
    if not item then return nil end
    local ok, isWeapon = pcall(types.Weapon.objectIsInstance, item)
    if not ok or not isWeapon then return nil end
    local okRec, rec = pcall(types.Weapon.record, item)
    if not okRec then return nil end
    return rec
end

local function getRightHandWeapon()
    local equipment = types.Actor.getEquipment(self)
    if not equipment or not types.Actor.EQUIPMENT_SLOT then return nil end
    return equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
end

-- ─── Evasion — per-stance Sanctuary bonus (module) ───────────────────────
-- Lives in player/evasion.lua; the delta tracker there is transient and is
-- zeroed via clearEvasionBonus() from onLoad, exactly as before.
local evasion = require('scripts.stance.player.evasion').new({
    self = self, types = types, core = core,
    config = config,
    readSetting     = readSetting,
    getStanceConfig = getStanceConfig,
    getStanceLevel  = getStanceLevel,
    getActiveStance = function() return activeStanceId end,
})
local getStanceEvasionBonus = evasion.getStanceEvasionBonus
local refreshEvasionBonus   = evasion.refreshEvasionBonus
local clearEvasionBonus     = evasion.clearEvasionBonus

-- ─── Stance-name prefixes (module) ───────────────────────────────────────
-- Imbue / Fortified / Sneaky decoration of the active stance's displayed
-- name, the Fortified Block bonus, and the prefix tooltip notes all live in
-- player/prefixes.lua. State there is transient (recomputed per tick), so
-- this owns nothing persisted. Locals are re-bound here so every downstream
-- reference in this file is unchanged.
local prefixes = require('scripts.stance.player.prefixes').new({
    self = self, types = types, storage = storage, core = core,
    config = config,
    readSetting        = readSetting,
    debugLog           = debugLog,
    getStanceConfig    = getStanceConfig,
    integrationEnabled = integrationEnabled,
    getActiveStance    = function() return activeStanceId end,
})
local formatStanceName           = prefixes.formatStanceName
local refreshImbuePrefix         = prefixes.refreshImbuePrefix
local refreshFortified           = prefixes.refreshFortified
local refreshSneaky              = prefixes.refreshSneaky
local currentFortifiedBlockBonus = prefixes.currentFortifiedBlockBonus
local getActivePrefixNotes       = prefixes.getActivePrefixNotes

-- ─── Weapon classifiers + stance resolver (module) ───────────────────────
-- All classification and the resolveStance waterfall live in
-- player/resolver.lua (which also constructs the grip record-mapping module
-- internally). The module is pure: persisted state (dual-wield flags) stays
-- in this file and is reached through the closures below, which capture the
-- forward-declared locals assigned further down. The DW detection section
-- below still needs two helpers, re-bound here.
local WTYPE = types.Weapon and types.Weapon.TYPE or {}  -- also used by resolveStanceSkill below
local resolver = require('scripts.stance.player.resolver').new({
    self = self, types = types, core = core,
    config = config,
    readSetting        = readSetting,
    debugLog           = debugLog,
    stanceEnabled      = function(id) return stanceEnabled(id) end,
    integrationEnabled = integrationEnabled,
    integrationPresent = function(id) return integrationPresent(id) end,
    isDualWielding     = function(now) return isDualWielding(now) end,
    isFelthornInOffhand = function() return isFelthornInOffhand() end,
    getRightHandWeapon = getRightHandWeapon,
    safeWeaponRecord   = safeWeaponRecord,
})
local resolveStance         = resolver.resolveStance
local isOneHandedMelee      = resolver.isOneHandedMelee
local runtimeWeaponRecord   = resolver.runtimeWeaponRecord

-- ─── Dual wielding detection ──────────────────────────────────────────────
--
-- Dual Wielding (mod) works by storing an off-hand `SecondWeapon` outside
-- the engine's equipment slots. The mod fires:
--   * `EquipSecondWeapon` on the actor with the chosen Weapon item
--   * `RemoveSecondWeapon` on the actor when the off-hand is dismissed
--   * `EquipSecondWeaponKey` globally on key press (with a `Bolean` field)
--
-- The off-hand weapon never appears in CarriedLeft (which still holds a
-- shield if any). So the only reliable signal is the event sequence. We
-- track the latest known SecondWeapon record id and a freshness timestamp
-- (dualWieldingAsOf) that is refreshed every tick the dual-wield conditions
-- still hold (see isDualWielding). A 60-second staleness floor — measured
-- from when the conditions LAST held, not from first equip — catches the rare
-- save/load drift where a Remove event was missed; it never interrupts an
-- ongoing dual-wield session.

local dualWieldingActive       = false
local dualWieldingWeaponRecord = nil
local dualWieldingAsOf         = -math.huge
-- GRIP compatibility: when GRIP converts the off-hand weapon it unequips the
-- original and re-equips the converted record, which makes the Dual Wielding
-- mod fire RemoveSecondWeapon immediately followed by EquipSecondWeapon. If we
-- cleared dual-wield state on that transient Remove, Dualist would briefly drop
-- and the resolver would fall through to Soloist (1H primary) — and depending
-- on event ordering the state could stay cleared. So a Remove does not clear
-- state immediately; it arms a short grace timer. A re-equip within the window
-- cancels it (the GRIP swap); if the window lapses with no re-equip, the
-- off-hand really was dismissed and we clear. nil = no pending remove.
local dualWieldingRemovePendingAt = nil
local DUAL_WIELD_REMOVE_GRACE_SEC = 0.5

-- isDualWielding forward-declared above (the resolver module's ctx closure
-- must capture the local, not resolve a global at call time).
isDualWielding = function(now)
    -- Expire a pending remove whose grace window has lapsed (the off-hand was
    -- genuinely dismissed, not GRIP-swapped). This is also expired in onUpdate
    -- so it resolves even when isDualWielding isn't being called.
    if dualWieldingRemovePendingAt
        and (now - dualWieldingRemovePendingAt) > DUAL_WIELD_REMOVE_GRACE_SEC then
        dualWieldingActive = false
        dualWieldingWeaponRecord = nil
        dualWieldingRemovePendingAt = nil
    end

    if not dualWieldingActive then return false end
    -- Stale-state guard (NOT a session timer). dualWieldingAsOf is refreshed to
    -- `now` on every tick the full dual-wield conditions hold (see the refresh
    -- just before `return true` below) as well as by Dual Wielding's key-press
    -- heartbeat, so during a continuous dual-wield session this never elapses:
    -- Dualist persists for as long as the off-hand stays mounted and a 1H
    -- primary is held, no matter how long ago the off-hand was first equipped.
    -- It only trips when the conditions have NOT held for 60s — e.g. a Remove
    -- event was missed (a known save/load drift) and the player has since moved
    -- on — in which case we clear the orphaned flag.
    if (now - dualWieldingAsOf) > 60 then
        dualWieldingActive = false
        dualWieldingWeaponRecord = nil
        return false
    end
    if not integrationPresent('dualwielding') then return false end
    -- Sanity: Dual Wielding requires a one-handed primary in the right hand.
    -- We check the RUNTIME record (what is actually equipped now), so a weapon
    -- GRIP-converted to one-handed for dual-wielding qualifies. A weapon whose
    -- current form is two-handed cannot be dual-wielded, so it correctly fails.
    local right = getRightHandWeapon()
    if not right then return false end
    local rightRec = safeWeaponRecord(right)
    if not rightRec then return false end
    local runtimeRec = runtimeWeaponRecord(right, rightRec)
    if not runtimeRec then return false end
    if not isOneHandedMelee(runtimeRec) then return false end
    -- All conditions hold → refresh the freshness stamp so the stale-state guard
    -- above can only ever trip once the conditions have lapsed, never mid-fight.
    dualWieldingAsOf = now
    return true
end

-- Felthorn-in-off-hand: when Dual Wielding equips Felthorn (in any of its
-- 180+ shapeshifted forms) as the second weapon, the off-hand record id
-- is captured into `dualWieldingWeaponRecord` via the EquipSecondWeapon
-- event handler. OpenMW's engine doesn't expose the off-hand weapon
-- through standard equipment slots, so this is the canonical signal.
--
-- Used by the Blademeister branch in resolveStance so that equipping
-- Felthorn into the off-hand still activates Blademeister rather than
-- falling through to Dualist (which would steal it because Dualist
-- triggers on "main hand 1H + dual wielding active" without inspecting
-- which weapon the off-hand actually is).
-- isFelthornInOffhand forward-declared above (the resolver module's ctx
-- closure must capture the local, not resolve a global at call time).
isFelthornInOffhand = function()
    if not dualWieldingActive then return false end
    if type(dualWieldingWeaponRecord) ~= 'string' then return false end
    local prefix = (config.blademeisterRecordPrefix or 'sd_'):lower()
    return dualWieldingWeaponRecord:lower():sub(1, #prefix) == prefix
end

-- ─── Top-level stance resolver ────────────────────────────────────────────

-- ─── Effectiveness skill target table ────────────────────────────────────
--
-- Maps each stance id to the Skill Framework skill that receives the
-- additive effectiveness bonus (see effectivenessSkillBonus / computeBonusForSkill).
--
-- Entry shapes:
--   { vanilla = 'skillId' }
--       → always boosts this vanilla skill
--   { vanilla = 'fallback', modded = 'sfSkillId', integration = 'intId' }
--       → boosts `modded` skill when `integration` is present; otherwise `vanilla`
--   { dynamic = true }
--       → resolved at runtime by getDualistSkill() / getBlademeisterSkill()
--         (reads the currently-equipped weapon type)
--   nil → no bonus applies for this stance

local STANCE_SKILL_TARGET = {
    -- Long-blade stances
    soloist      = { vanilla = 'longblade' },
    zweihander   = { vanilla = 'longblade' },
    -- Other vanilla melee
    thief        = { vanilla = 'shortblade' },
    mjolnir      = { vanilla = 'bluntweapon' },
    axeman       = { vanilla = 'axe' },
    guisarmier   = { vanilla = 'spear' },
    -- Ranged
    huntsman     = { vanilla = 'marksman' },
    -- Unarmed
    brawler      = { vanilla = 'handtohand' },
    -- (Fortifier deprecated: Block is no longer a stance-mapped skill; the
    --  fortified state applies a Block bonus directly — see refreshFortified.)
    -- Tool / utility
    reforger     = { vanilla = 'armorer' },
    locksmith    = { vanilla = 'security' },
    -- Social
    commoner     = { vanilla = 'speechcraft' },
    -- Modded-skill stances: prefer the mod's own skill when its
    -- integration is active, fall back to the vanilla equivalent.
    --
    -- Twirler targets the Throwing SF skill (thrown weapons are a separate
    -- stance from Huntsman, which targets Marksman). This is safe to buff:
    -- with Throwing!'s "Thrown Weapons Use Throwing Only" (replaceMarksman)
    -- setting OFF, Throwing! does not touch the Marksman modifier, so there is
    -- no marksman feedback to worry about. The bonus is delivered to the
    -- 'throwing' SF skill via the modded dynamic-modifier path below. NOTE: if
    -- you re-enable replaceMarksman in Throwing!, Throwing! will mirror the
    -- (now Stance-buffed) Throwing value onto Marksman — that is Throwing!'s
    -- intended behavior and is stable as long as Stance does not also write
    -- Marksman (it doesn't).
    twirler      = { vanilla = 'throwing',     modded = 'throwing',      integration = 'throwing' },
    thaumaturge  = { vanilla = 'bluntweapon', modded = 'staves_staves', integration = 'staves' },
    angler       = { vanilla = nil,           modded = 'fishing_skill', integration = 'fishing' },
    pitmen       = { vanilla = 'axe',         modded = 'mining_skill',  integration = 'simplymining' },
    -- Dynamic: resolve from the currently-equipped weapon type at runtime.
    -- Dualist boosts whichever 1H melee skill the primary weapon uses.
    -- Blademeister boosts whichever skill the current Felthorn form uses.
    dualist      = { dynamic = true },
    blademeister = { dynamic = true },
    -- Arcanist: mysticism is the intelligence-governed spellcasting meta-skill
    -- (soul trap, dispel, spell absorption) and the natural effectiveness target
    -- for the spellcasting stance.
    arcanist     = { vanilla = 'mysticism' },
    -- Apothecary: Thrown Concoctions is a pure-content mod with no Skill
    -- Framework skill of its own, so the effectiveness bonus targets vanilla
    -- Alchemy directly — the alchemist's craft, not the throw itself (the
    -- Marksman side of a thrown concoction is Twirler's domain). This is a
    -- temporary, delta-accounted stat MODIFIER (not real Alchemy progress), so
    -- it never collides with the player's actual Alchemy training.
    apothecary   = { vanilla = 'alchemy' },
}

-- Resolve the vanilla skill ID for a Dualist stance based on the primary
-- (right-hand) weapon. Returns nil when no 1H melee weapon is equipped.
local function getDualistSkill()
    local right = getRightHandWeapon()
    if not right then return nil end
    local rightRec = safeWeaponRecord(right)
    if not rightRec then return nil end
    -- Use the runtime record (the weapon's CURRENT form) so a GRIP-converted
    -- weapon maps to the skill of whatever it is now — matching the runtime
    -- check the Dualist resolver branch uses to select this stance.
    local runtimeRec = runtimeWeaponRecord(right, rightRec)
    if not runtimeRec then return nil end
    local t = runtimeRec.type
    if t == WTYPE.LongBladeOneHand  then return 'longblade'   end
    if t == WTYPE.ShortBladeOneHand then return 'shortblade'  end
    if t == WTYPE.BluntOneHand      then return 'bluntweapon' end
    if t == WTYPE.AxeOneHand        then return 'axe'         end
    return nil
end

-- Resolve the skill ID for a Blademeister stance based on the current
-- Felthorn shapeshifted form. Falls back to 'longblade' for unknown forms.
local function getBlademeisterSkill()
    local right = getRightHandWeapon()
    if not right then return 'longblade' end
    local rightRec = safeWeaponRecord(right)
    if not rightRec then return 'longblade' end
    -- Use the runtime record (not the GRIP-resolved original) so the bonus
    -- goes to whichever skill the current Felthorn form actually maps to.
    local t = rightRec.type
    if t == WTYPE.LongBladeOneHand  or t == WTYPE.LongBladeTwoHand  then return 'longblade'   end
    if t == WTYPE.ShortBladeOneHand                                  then return 'shortblade'  end
    if t == WTYPE.AxeOneHand        or t == WTYPE.AxeTwoHand        then return 'axe'         end
    if t == WTYPE.BluntOneHand      or t == WTYPE.BluntTwoClose
                                    or t == WTYPE.BluntTwoWide      then return 'bluntweapon' end
    if t == WTYPE.SpearTwoWide                                       then return 'spear'       end
    if t == WTYPE.MarksmanBow       or t == WTYPE.MarksmanCrossbow  then return 'marksman'    end
    if t == WTYPE.MarksmanThrown then
        if integrationPresent('throwing') then return 'throwing' end
        return 'marksman'
    end
    return 'longblade'  -- fallback for any unexpected form
end

-- Return the effective target skill ID for the given stance, factoring in
-- integration presence for modded-skill stances and dynamic weapon resolution
-- for Dualist / Blademeister.
local function resolveStanceSkill(stanceId)
    local target = STANCE_SKILL_TARGET[stanceId]
    if not target then return nil end

    if target.dynamic then
        if stanceId == 'dualist'      then return getDualistSkill()      end
        if stanceId == 'blademeister' then return getBlademeisterSkill() end
        return nil
    end

    if target.modded and target.integration and integrationPresent(target.integration) then
        return target.modded
    end
    return target.vanilla
end


local STANCE_SETTING_KEY = {
    arcanist     = 'enableArcanist',
    reforger     = 'enableReforger',
    blademeister = 'enableBlademeister',
    huntsman     = 'enableHuntsman',
    twirler      = 'enableTwirler',
    thaumaturge  = 'enableThaumaturge',
    dualist      = 'enableDualist',
    guisarmier   = 'enableGuisarmier',
    axeman       = 'enableAxeman',
    pitmen       = 'enablePitmen',
    angler       = 'enableAngler',
    mjolnir      = 'enableMjolnir',
    zweihander   = 'enableZweihander',
    soloist      = 'enableSoloist',
    thief        = 'enableThief',
    locksmith    = 'enableLocksmith',
    brawler      = 'enableBrawler',
    commoner     = 'enableCommoner',
    apothecary   = 'enableApothecary',
}

-- Per-stance perk toggle lookup. Mirrors STANCE_SETTING_KEY above but uses
-- the Perks group keys instead. Used by perksEnabledForStance() to decide
-- whether to fire perk-unlock notifications and whether to include the
-- perk ladder in the dynamic tooltip.
local PERK_SETTING_KEY = {
    arcanist     = 'enableArcanistPerks',
    reforger     = 'enableReforgerPerks',
    blademeister = 'enableBlademeisterPerks',
    huntsman     = 'enableHuntsmanPerks',
    twirler      = 'enableTwirlerPerks',
    thaumaturge  = 'enableThaumaturgePerks',
    dualist      = 'enableDualistPerks',
    guisarmier   = 'enableGuisarmierPerks',
    axeman       = 'enableAxemanPerks',
    pitmen       = 'enablePitmenPerks',
    angler       = 'enableAnglerPerks',
    mjolnir      = 'enableMjolnirPerks',
    zweihander   = 'enableZweihanderPerks',
    soloist      = 'enableSoloistPerks',
    thief        = 'enableThiefPerks',
    locksmith    = 'enableLocksmithPerks',
    brawler      = 'enableBrawlerPerks',
    commoner     = 'enableCommonerPerks',
    apothecary   = 'enableApothecaryPerks',
}

-- perksEnabledForStance forward-declared above (needed by ensurePerksInit closure).
perksEnabledForStance = function(stanceId)
    if readSetting('Perks', 'enableAllPerks', true) ~= true then return false end
    local key = PERK_SETTING_KEY[stanceId]
    if not key then return true end
    local val = settingSection('Perks'):get(key)
    if val == nil then return true end
    return val == true
end

-- stanceEnabled forward-declared above (needed by ensurePerksInit closure).
stanceEnabled = function(stanceId)
    local key = STANCE_SETTING_KEY[stanceId]
    if not key then return true end
    local val = settingSection('Stances'):get(key)
    if val == nil then return true end
    return val == true
end

-- ─── Active stance tracking ───────────────────────────────────────────────

-- activeStanceId forward-declared above (needed by ensurePerksInit closure).
activeStanceId       = nil
local activeStanceReason   = nil
local lastStanceChangeAt   = -math.huge
local pendingPerkAnnouncements = {}

local function announceStanceChange(stanceId)
    if not readSetting('', 'announceStanceChange', true) then return end
    pcall(ui.showMessage, string.format('Stance: %s', formatStanceName(stanceId)))
end

local function applyActiveStance(newId, reason, now, force)
    if not force and (now - lastStanceChangeAt) < (config.stanceChangeDebounceSec or 0.35) then
        if newId == activeStanceId then return end
    end
    if newId == activeStanceId then return end
    activeStanceId = newId
    activeStanceReason = reason
    lastStanceChangeAt = now
    debugLog(string.format('Active stance → %s (%s)', newId, tostring(reason)),
        'debugDetectionMessages')
    announceStanceChange(newId)
end

-- ─── XP grant ─────────────────────────────────────────────────────────────

local xpModule = require('scripts.stance.player.xp').new({
    I                = I,
    config           = config,
    SKILL_ID         = SKILL_ID,
    readSetting      = readSetting,
    debugLog         = debugLog,
    getActiveStance  = function() return activeStanceId end,
    stanceEnabled    = stanceEnabled,
    getStanceState   = getStanceState,
    saveStanceState  = saveStanceState,
    xpForStanceLevel = xpForStanceLevel,
})

local grantStanceXp = xpModule.grantStanceXp
local grantStanceXpDirect = xpModule.grantStanceXpDirect

-- ─── Felthorn ambient voice (cosmetic) ────────────────────────────────────
-- Speaks lore-flavored vanilla messages while the Blademeister stance is
-- active. Fully self-contained; all text/timing live in config.felthornAmbient.
local felthornVoice = require('scripts.stance.player.felthorn_voice').new({
    config      = config,
    ui          = ui,
    core        = core,
    readSetting = readSetting,
})

-- ─── Skill Framework registration ─────────────────────────────────────────

local skillFramework = require('scripts.stance.player.skill_framework').new({
    I                       = I,
    util                    = util,
    config                  = config,
    SKILL_ID                = SKILL_ID,
    readSetting             = readSetting,
    debugLog                = debugLog,
    getStanceConfig         = getStanceConfig,
    formatStanceName        = formatStanceName,
    getCoreSkillLevel       = getCoreSkillLevel,
    getStanceLevel          = getStanceLevel,
    getStanceXp             = getStanceXp,
    effectivenessSkillBonus = effectivenessSkillBonus,
    getStanceEvasionBonus   = getStanceEvasionBonus,
    currentFortifiedBlockBonus = currentFortifiedBlockBonus,
    getActivePrefixNotes    = getActivePrefixNotes,
    xpForStanceLevel        = xpForStanceLevel,
    resolveStanceSkill      = resolveStanceSkill,
    perksEnabledForStance   = perksEnabledForStance,
    integrationPresent      = integrationPresent,
    getActiveStance         = function() return activeStanceId end,
    getSelf                 = function() return self end,
})

-- ─── Mirror settings to global.lua ────────────────────────────────────────

local lastSyncedSettingsPayload = nil

local function settingsPayloadChanged(payload)
    if not lastSyncedSettingsPayload then return true end
    for k, v in pairs(payload) do
        if lastSyncedSettingsPayload[k] ~= v then return true end
    end
    for k, _ in pairs(lastSyncedSettingsPayload) do
        if payload[k] == nil then return true end
    end
    return false
end

local SYNCED_KEYS = {
    { '',        'enabled' },
    { '',        'enableSkillRegistration' },
    { '',        'enableAttributeSwap' },
    { '',        'announceStanceChange' },
    { 'Progression', 'xpMultiplier' },
    { 'Progression', 'xpOnHit' },
    { 'Progression', 'xpOnKill' },
    { 'Progression', 'xpOnSpellCast' },
    { 'Progression', 'xpOnBlock' },
    { 'Progression', 'xpOnParry' },
    { 'Progression', 'xpOnTime' },
    { 'Progression', 'xpOnMerchant' },
    { 'Progression', 'xpOnUpgrade' },
    { 'Progression', 'xpOnMining' },
    { 'Progression', 'xpOnFishing' },
    { 'Progression', 'xpOnLockpick' },
    { 'Progression', 'xpOnTalk' },
    { 'Progression', 'xpOnDisenchant' },
    { 'Progression', 'xpOnCommercium' },
    { 'Progression', 'xpOnTranscribe' },
    { 'Progression', 'xpOnConcoctionHit' },
    { 'Progression', 'xpOnTrapHit' },
    { 'Progression', 'xpOnOilBurn' },
    { 'Perks',   'enableAllPerks' },
    { 'Perks',   'enableLocksmithPerks' },
    { 'Perks',   'enableCommonerPerks' },
    { 'Perks',   'enableArcanistPerks' },
    { 'Perks',   'enableReforgerPerks' },
    { 'Perks',   'enableBlademeisterPerks' },
    { 'Perks',   'enableHuntsmanPerks' },
    { 'Perks',   'enableTwirlerPerks' },
    { 'Perks',   'enableThaumaturgePerks' },
    { 'Perks',   'enableDualistPerks' },
    { 'Perks',   'enableGuisarmierPerks' },
    { 'Perks',   'enableAxemanPerks' },
    { 'Perks',   'enableAnglerPerks' },
    { 'Perks',   'enableZweihanderPerks' },
    { 'Perks',   'enableSoloistPerks' },
    { 'Perks',   'enableThiefPerks' },
    { 'Perks',   'enableBrawlerPerks' },
    { 'Perks',   'enableApothecaryPerks' },
    { 'Stances', 'enableArcanist' },
    { 'Stances', 'enableReforger' },
    { 'Stances', 'enableBlademeister' },
    { 'Stances', 'enableHuntsman' },
    { 'Stances', 'enableTwirler' },
    { 'Stances', 'enableThaumaturge' },
    { 'Stances', 'enableDualist' },
    { 'Stances', 'enableFortified' },
    { 'Stances', 'enableSneaky' },
    { 'Stances', 'enableGuisarmier' },
    { 'Stances', 'enableAxeman' },
    { 'Stances', 'enableAngler' },
    { 'Stances', 'enableZweihander' },
    { 'Stances', 'enableSoloist' },
    { 'Stances', 'enableThief' },
    { 'Stances', 'enableLocksmith' },
    { 'Stances', 'enableBrawler' },
    { 'Stances', 'enableCommoner' },
    { 'Stances', 'enableApothecary' },
    { 'Debug',   'debugMessages' },
    { 'Debug',   'debugDetectionMessages' },
    { 'Debug',   'debugXpMessages' },
    { 'Debug',   'debugPerkMessages' },
    { 'Debug',   'debugIntegrationMessages' },
    { 'Debug',   'debugUiMessages' },
}

local function syncSettingsToGlobal(force)
    local payload = {}
    for _, e in ipairs(SYNCED_KEYS) do
        payload[e[2]] = settingSection(e[1]):get(e[2])
    end
    payload.activeStanceId = activeStanceId
    if not force and not settingsPayloadChanged(payload) then return end
    core.sendGlobalEvent('Stance_UpdateRuntimeSettings', payload)
    lastSyncedSettingsPayload = payload
end

-- ─── HUD indicator + perk-feedback popups ────────────────────────────────

local hudModule = require('scripts.stance.player.hud').new({
    ui             = ui,
    util           = util,
    core           = core,
    async          = async,
    I              = I,
    readSetting    = readSetting,
    settingSection = settingSection,
    getActiveStance = function() return activeStanceId end,
    getStanceConfig = getStanceConfig,
    formatStanceName = formatStanceName,
})

local updateHud          = hudModule.updateHud
local destroyHud         = hudModule.destroyHud
local feedbackReflow     = hudModule.feedbackReflow
local notify             = hudModule.notify
local onUiModeChanged    = hudModule.onUiModeChanged

-- ─── Messaging (single, simple path) ──────────────────────────────────────

local function drainStanceLevelUps()
    local ups = xpModule.drainPendingLevelUps()
    if #ups == 0 then return end
    for _, up in ipairs(ups) do
        local stance = getStanceConfig(up.stanceId)
        local name = (stance and stance.displayName) or up.stanceId
        notify(string.format('%s level %d', name, up.level))
        debugLog(string.format('Stance level-up: %s → %d', up.stanceId, up.level),
            'debugXpMessages')
    end
end

local function drainPerkAnnouncements()
    if #pendingPerkAnnouncements == 0 then return end
    for _, ann in ipairs(pendingPerkAnnouncements) do
        local stance = getStanceConfig(ann.stanceId)
        local stanceName = (stance and stance.displayName) or ann.stanceId
        if perksEnabledForStance(ann.stanceId) then
            notify(string.format('%s perk unlocked: %s', stanceName, ann.name))
        end
        debugLog(string.format('Perk unlocked: %s/%s', ann.stanceId, ann.perkId),
            'debugPerkMessages')
    end
    pendingPerkAnnouncements = {}
end

-- Watch the CORE Stance skill level. When it crosses a perk threshold
-- (25/50/75/100), queue an unlock announcement for the perk the ACTIVE
-- stance gains at that threshold.
local function checkCoreLevelPerkUnlocks()
    local level = getCoreSkillLevel()
    if lastAnnouncedCoreLevel == nil then
        lastAnnouncedCoreLevel = level
        return
    end
    if level <= lastAnnouncedCoreLevel then return end

    local stanceId = activeStanceId or 'commoner'
    local stance = getStanceConfig(stanceId)
    if stance then
        for _, perk in ipairs(stance.perks) do
            if perk.level > lastAnnouncedCoreLevel and perk.level <= level then
                table.insert(pendingPerkAnnouncements, {
                    stanceId = stanceId,
                    perkId = perk.id,
                    name = perk.name,
                    level = perk.level,
                })
            end
        end
    end
    lastAnnouncedCoreLevel = level
end

-- ─── Time-based XP tick ───────────────────────────────────────────────────

local handleTimeTick = xpModule.handleTimeTick

-- ─── Combat hit handler ───────────────────────────────────────────────────
--
-- I.Combat.addOnHitHandler fires on the actor that is HIT (the victim), and
-- the AttackInfo it passes has `attacker` but no `target`. Registering it on
-- the PLAYER therefore only catches blows the player TAKES — the old code then
-- rejected them all (attacker ~= self), so player-dealt hit XP and every
-- on-hit perk were dead.
--
-- The correct signal comes from the victim-side actor script (scripts/stance/
-- victim.lua, attached to every NPC and creature). When the player lands a
-- hit, that script sends us `Stance_PlayerDealtHit` carrying the struck actor
-- as `target` plus the weapon used. We grant hit XP and dispatch on-hit perks
-- here, reconstructing the minimal attack table Perks.onHit expects
-- (it reads only attack.target and attack.weapon).

local function onPlayerDealtHit(data)
    if not readSetting('', 'enabled', true) then return end
    if type(data) ~= 'table' or not data.target then return end
    if not activeStanceId then return end
    -- Per-stance hit XP. Two cases:
    --   * Apothecary earns the dedicated concoction weight under the
    --     'concoction' source (gated by xpOnConcoctionHit). Apothecary is only
    --     ever active with a Thrown Concoction equipped, so any hit credited to
    --     it is necessarily a landed concoction throw.
    --   * Every other stance earns the standard combatHit weight. (This now
    --     includes a sword-and-board fighter, who is simply in the weapon's
    --     stance — e.g. "Fortified Soloist" — and earns Soloist hit XP; the
    --     deprecated Fortifier stance used to be exempt here.)
    -- All stances still run their on-hit perks below regardless.
    if activeStanceId == 'apothecary' then
        grantStanceXp(config.xp.concoctionThrowHit or 2.5, 'concoction', 'apothecary')
    else
        grantStanceXp(config.xp.combatHit or 1.0, 'hit', activeStanceId)
    end
    Perks.onHit({
        target = data.target,
        weapon = data.weapon,
    })
end

-- ─── Spell cast handler (text-key path, like Incantation uses) ────────────

local spellCastRegistered = false

local function onSpellcastTextKey(groupname, key)
    if groupname ~= 'spellcast' then return end
    if not readSetting('', 'enabled', true) then return end
    if key ~= 'self start' and key ~= 'touch start' and key ~= 'target start' then
        return
    end
    if activeStanceId == 'arcanist' and stanceEnabled('arcanist') then
        grantStanceXp(config.xp.spellCast or 0.8, 'spell', 'arcanist')
    end
end

local function registerSpellHook()
    if spellCastRegistered then return end
    if not (I.AnimationController and I.AnimationController.addTextKeyHandler) then
        return
    end
    local ok = pcall(I.AnimationController.addTextKeyHandler, '', onSpellcastTextKey)
    if ok then
        spellCastRegistered = true
        debugLog('Registered AnimationController spellcast text-key handler.',
            'debugIntegrationMessages')
    end
end

-- ─── Cross-mod XP redirects via SkillProgression ──────────────────────────

local function onForeignSkillUsed(foreignSkillId, params)
    if not readSetting('', 'enabled', true) then return end
    if not foreignSkillId then return end

    -- Meditation Skill → Arcanist tick (regardless of active stance, half rate).
    if foreignSkillId == 'meditation_skill' then
        if integrationPresent('meditation') and stanceEnabled('arcanist') then
            grantStanceXpDirect((config.xp.meditateTick or 0.4) / 2, 'meditate', 'arcanist')
        end
        return
    end

    -- Incantation → Arcanist spellcraft bonus (only while Arcanist active).
    if foreignSkillId == 'incantation_skill' then
        if activeStanceId == 'arcanist' and integrationPresent('incantation') then
            grantStanceXp((config.xp.spellCast or 0.8) * 0.5, 'spell', 'arcanist')
        end
        return
    end

    -- Armorer skill → Reforger. Both WeaponUpgrade and ArmorUpgrade run
    -- upgrades through types.Player.stats.skills.armorer, but they don't
    -- always emit a separate XP signal we can listen to directly. The
    -- Armorer skill is gained from the standard vanilla repair use; when
    -- the player upgrades a weapon/armor successfully, vanilla also
    -- credits Armorer for the repair-hammer use. We use that as a soft
    -- signal: Armorer XP gained while in Reforger stance feeds Reforger
    -- as well.
    if foreignSkillId == 'armorer' then
        if activeStanceId == 'reforger' and stanceEnabled('reforger') then
            grantStanceXp(config.xp.upgradeSuccess or 4.0, 'upgrade', 'reforger')
        end
        return
    end
end

-- ─── Upgrade success/failure inference (Reforger XP) ──────────────────────
-- WeaponUpgrade and ArmorUpgrade both send `actor:sendEvent('ShowMessage', ...)`
-- with text-message payloads. We listen for those and use the message body
-- to distinguish success ("Weapon upgraded succesfully." /
-- "Armor upgraded succesfully.") from failure (other strings). This is
-- string-sniffing, which isn't ideal — but the upgrade mods don't expose a
-- cleaner signal, so this is the canonical hook.

local function isUpgradeSuccessText(text)
    if type(text) ~= 'string' then return false end
    -- The mods' literal strings ship with the typo "succesfully" — we
    -- match both spellings just in case a future patch fixes the typo.
    return text:find('upgraded succesfully', 1, true)
        or text:find('upgraded successfully', 1, true)
end

local function isUpgradeFailureText(text)
    if type(text) ~= 'string' then return false end
    return text:find('Failed to upgrade', 1, true)
end

local function maybeCreditReforgerFromMessage(payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId ~= 'reforger' then return end
    if not stanceEnabled('reforger') then return end
    if type(payload) ~= 'table' then return end
    -- The two mods use different field names: WeaponUpgrade uses `message`,
    -- ArmorUpgrade uses `text`. Check both.
    local text = payload.message or payload.text
    if isUpgradeSuccessText(text) then
        grantStanceXp(config.xp.upgradeSuccess or 4.0, 'upgrade', 'reforger')
        debugLog('Reforger credited for successful upgrade.', 'debugPerkMessages')
    elseif isUpgradeFailureText(text) then
        grantStanceXp(config.xp.upgradeFailure or 0.5, 'upgrade', 'reforger')
        debugLog('Reforger credited for failed upgrade attempt.', 'debugPerkMessages')
    end
end

-- ─── External event handlers ──────────────────────────────────────────────

-- The per-integration XP handlers live in player/integrations_xp.lua; event
-- registration below binds the SAME event names to these rebound locals, so
-- nothing about the event surface (and therefore nothing a save references)
-- changes. grantStanceXp/grantStanceXpDirect and the level getters are
-- already defined above this point.
local integrationsXp = require('scripts.stance.player.integrations_xp').new({
    self = self, types = types, core = core,
    config = config, Perks = Perks,
    readSetting         = readSetting,
    debugLog            = debugLog,
    stanceEnabled       = stanceEnabled,
    integrationEnabled  = integrationEnabled,
    grantStanceXp       = grantStanceXp,
    grantStanceXpDirect = grantStanceXpDirect,
    getCoreSkillLevel   = getCoreSkillLevel,
    getStanceLevel      = getStanceLevel,
    getActiveStance     = function() return activeStanceId end,
})
local onNGardeParrySuccess      = integrationsXp.onNGardeParrySuccess
local onSimplyMiningOreSuccess  = integrationsXp.onSimplyMiningOreSuccess
local onSimplyMiningStartMining = integrationsXp.onSimplyMiningStartMining
local onFishingCatch            = integrationsXp.onFishingCatch
local onLockpickSuccess         = integrationsXp.onLockpickSuccess
local onHazardHit               = integrationsXp.onHazardHit
local onMerchantTransaction     = integrationsXp.onMerchantTransaction
local onDisenchantFinished      = integrationsXp.onDisenchantFinished
local onCommerciumTransaction   = integrationsXp.onCommerciumTransaction
local onTranscribeSuccess       = integrationsXp.onTranscribeSuccess
local onDialogueStarted         = integrationsXp.onDialogueStarted
local onGskKnockdown            = integrationsXp.onGskKnockdown

-- Debounce for the Commoner talking-XP source. Owned here because its only
-- writer is the combined UiModeChanged wrapper below.
local talkDebounce = false

local function onDualWieldingEquip(payload)
    -- Triggered when Dual Wielding hands the player an off-hand weapon.
    -- payload.Weapon is the Weapon object reference.
    dualWieldingActive = true
    dualWieldingAsOf = core.getSimulationTime()
    -- Cancel any pending remove: a re-equip means either a normal mount or the
    -- second half of a GRIP conversion swap. Either way the off-hand is in use.
    dualWieldingRemovePendingAt = nil
    if type(payload) == 'table' and payload.Weapon then
        local ok, rec = pcall(function() return payload.Weapon.recordId end)
        if ok then dualWieldingWeaponRecord = rec end
    end
    debugLog('Dual Wielding off-hand mounted.', 'debugDetectionMessages')
end

local function onDualWieldingEquipKey(payload)
    -- The mod broadcasts this on key press. The boolean payload tracks
    -- press/release; we treat it as a heartbeat, since the actual mount
    -- happens on the EquipSecondWeapon event with the weapon reference.
    dualWieldingAsOf = core.getSimulationTime()
end

local function onDualWieldingRemove(_payload)
    -- Do NOT clear immediately. GRIP converting the off-hand weapon fires a
    -- Remove followed by an Equip; clearing now would drop Dualist (falling
    -- through to Soloist for a 1H primary) and, depending on event ordering,
    -- could leave the state cleared. Arm a short grace window instead — a
    -- re-equip within it (onDualWieldingEquip) cancels the clear; otherwise the
    -- pending remove is expired in isDualWielding / onUpdate.
    dualWieldingRemovePendingAt = core.getSimulationTime()
    debugLog('Dual Wielding off-hand remove pending (grace window armed).', 'debugDetectionMessages')
end

local function onStanceKillGrant(_payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId then
        grantStanceXp(config.xp.combatKill or 2.0, 'kill', activeStanceId)
    end
    -- Felthorn's post-kill remark (no-op unless Blademeister is active).
    felthornVoice.onKill(activeStanceId)
    -- Reserved hook for future kill-triggered perk effects.
    Perks.onKill()
end

-- Combined UiModeChanged engine handler: keeps the HUD's drag-state tracking
-- AND drives the Commoner talking-XP source.
local function onUiModeChangedCombined(data)
    pcall(function() if onUiModeChanged then onUiModeChanged(data) end end)

    if type(data) ~= 'table' then return end
    if data.newMode == 'Dialogue' and data.oldMode == nil then
        if not talkDebounce then
            talkDebounce = true
            onDialogueStarted(data.arg)
        end
    elseif data.oldMode == 'Dialogue' and data.newMode == nil then
        talkDebounce = false
    end
end

-- WeaponUpgrade and ArmorUpgrade dispatch `ShowMessage` to the player
-- script. We listen for it but pass through to the visual layer too — we
-- never want to suppress the message; we only inspect it.
local function onUpgradeShowMessage(payload)
    maybeCreditReforgerFromMessage(payload)
end

-- ─── Console commands ─────────────────────────────────────────────────────

local console = require('scripts.stance.player.console').new({
    ui                        = ui,
    I                         = I,
    SKILL_ID                  = SKILL_ID,
    config                    = config,
    getCoreSkillLevel         = getCoreSkillLevel,
    getActiveStance           = function() return activeStanceId end,
    formatStanceName          = formatStanceName,
    getStanceConfig           = getStanceConfig,
    stanceEnabled             = stanceEnabled,
    effectivenessSkillBonus   = effectivenessSkillBonus,
    getStanceEvasionBonus     = getStanceEvasionBonus,
    STANCE_SKILL_TARGET       = STANCE_SKILL_TARGET,
    getStanceLevel            = getStanceLevel,
    resolveStanceSkill        = resolveStanceSkill,
    nextPerk                  = nextPerk,
    getStanceState            = getStanceState,
    saveStanceState           = saveStanceState,
    setLastAnnouncedCoreLevel = function(v) lastAnnouncedCoreLevel = v end,
    resetStanceState          = function() stanceStateCache = defaultStanceState(); saveStanceState() end,
    flagReload                = function() skillFramework.markUnregistered() end,
})

local function onConsoleCommand(mode, command, selectedObject)
    return console.handle(mode, command, selectedObject)
end

-- ─── Frame update ─────────────────────────────────────────────────────────

local updateTimer            = config.pollIntervalSec or 0.25
local initRequested          = false
local accumulatedSettingsSync = 0

local function onUpdate(dt)
    dt = tonumber(dt) or 0
    if not readSetting('', 'enabled', true) then
        destroyHud()
        hudModule.destroyAllFeedback()
        return
    end

    handleTimeTick(dt)

    accumulatedSettingsSync = accumulatedSettingsSync + dt
    updateTimer = updateTimer + dt
    if updateTimer < (config.pollIntervalSec or 0.25) then
        drainStanceLevelUps()
        drainPerkAnnouncements()
        return
    end
    while updateTimer >= (config.pollIntervalSec or 0.25) do
        updateTimer = updateTimer - (config.pollIntervalSec or 0.25)
    end

    local now = core.getSimulationTime()

    -- Resolve a lapsed Dual Wielding remove grace window (off-hand genuinely
    -- dismissed). Mirrors the check in isDualWielding so the state settles even
    -- on ticks where isDualWielding isn't consulted.
    if dualWieldingRemovePendingAt
        and (now - dualWieldingRemovePendingAt) > DUAL_WIELD_REMOVE_GRACE_SEC then
        dualWieldingActive = false
        dualWieldingWeaponRecord = nil
        dualWieldingRemovePendingAt = nil
    end

    if accumulatedSettingsSync >= 0.5 then
        syncSettingsToGlobal(not initRequested)
        accumulatedSettingsSync = 0
    end

    refreshIntegrations(now)

    if not skillFramework.isSkillRegistered() then skillFramework.registerSkill() end
    if skillFramework.isSkillRegistered() and not skillFramework.isClassBonusApplied() then skillFramework.applyClassBonus() end
    if not initRequested then
        core.sendGlobalEvent('Stance_RequestInit', { player = self.object })
        initRequested = true
    end

    -- Lazily initialise the Perks module once all locals are in scope.
    ensurePerksInit()

    local resolved = resolveStance(now)
    if resolved then
        applyActiveStance(resolved.id, resolved.reason, now, false)
    end

    -- Refresh the "fortified" flag (shield + one-handed melee stance) right
    -- after resolving the active stance, so it is current for BOTH the Block
    -- bonus applied in refreshEffectivenessModifiers just below AND the
    -- "Fortified" name prefix rendered by the tooltip/HUD further down — a
    -- shield equipped/removed without a stance change still updates this tick.
    refreshFortified()

    -- Refresh the "sneaky" (crouched) flag on the same tick, so the "Sneaky"
    -- prefix is current for the tooltip/HUD render further down. Purely cosmetic
    -- (no skill/XP effect), so its placement relative to the effectiveness
    -- refresh below doesn't matter — only that it runs before the render.
    refreshSneaky()

    -- Refresh effectiveness modifiers AFTER resolving the active stance so
    -- the skill bonus always reflects the current stance on the same tick it
    -- changes. Previously this ran before applyActiveStance, causing a
    -- one-tick lag where the outgoing stance's skill bonus persisted.
    skillFramework.refreshEffectivenessModifiers()

    -- Apply the per-stance Sanctuary (dodge) bonus. Uses the same
    -- delta-accounting pattern as Evasion! so the two contributions stack
    -- cleanly without interfering with each other.
    refreshEvasionBonus()

    -- Felthorn's ambient voice (no-op unless Blademeister is active).
    felthornVoice.update(activeStanceId, now)

    -- Refresh the Spellsword imbue prefix BEFORE the tooltip + HUD re-render,
    -- so formatStanceName() returns the current decoration this same tick.
    refreshImbuePrefix()
    skillFramework.syncToActiveStance()
    updateHud()
    feedbackReflow()
    checkCoreLevelPerkUnlocks()
    drainStanceLevelUps()
    drainPerkAnnouncements()
    -- Update attribute bonuses, SF skill mods, and integration broadcasts.
    Perks.update(now)
end

-- ─── Persistence ──────────────────────────────────────────────────────────

local function onSave()
    -- Persist the per-stance xp/level table directly in the save data. This is
    -- the engine's guaranteed round-trip (onSave -> onLoad) and does not depend
    -- on the storage section surviving, so stance progress is never lost across
    -- save/load or reloadlua. getStanceState() returns the live cache (or reads
    -- the section if the cache is cold).
    local state = getStanceState()
    local snapshot = {}
    if type(state) == 'table' then
        for id, entry in pairs(state) do
            if type(entry) == 'table' then
                snapshot[id] = {
                    xp    = tonumber(entry.xp) or 0,
                    level = tonumber(entry.level) or config.startLevel,
                }
            end
        end
    end
    -- Dual Wielding: the mod does not re-fire EquipSecondWeapon on load, so
    -- we must persist the flag ourselves. Without this, Dualist is always lost
    -- after a save/load even when the off-hand is still mounted.
    return {
        version = 3,
        stanceState = snapshot,
        dualWieldingActive       = dualWieldingActive,
        dualWieldingWeaponRecord = dualWieldingWeaponRecord,
    }
end

local function onLoad(data)
    skillFramework.markUnregistered()
    lastSyncedSettingsPayload = nil
    initRequested = false
    -- Reset Perks so ensurePerksInit re-runs and Perks.init restores
    -- the persisted attribute contributions from storage (prevents
    -- double-counting saved bonuses across save/load cycles).
    perksInitialized = false
    xpModule.resetAccumulator()
    felthornVoice.reset()
    -- The engine zeroes all active effects on load. Reset our evasion delta
    -- tracker so the first refreshEvasionBonus re-applies from zero rather
    -- than believing the old bonus is still in place.
    clearEvasionBonus()
    dualWieldingActive = false
    dualWieldingWeaponRecord = nil
    dualWieldingAsOf = -math.huge
    dualWieldingRemovePendingAt = nil
    -- Restore dual-wield state from save. The Dual Wielding mod does NOT
    -- re-fire EquipSecondWeapon on load, so we save and restore the flag
    -- manually. dualWieldingAsOf is refreshed to the current simulation time
    -- so the 60-second stale-state guard in isDualWielding doesn't clear the
    -- restored flag immediately on the first tick.
    if type(data) == 'table' and data.dualWieldingActive == true then
        dualWieldingActive       = true
        dualWieldingWeaponRecord = data.dualWieldingWeaponRecord
        dualWieldingAsOf         = core.getSimulationTime()
        debugLog('Dual-wield state restored from save.', 'debugDetectionMessages')
    end

    -- Restore per-stance xp/level from the save data. This is authoritative:
    -- onSave wrote it, and reading it here guarantees progress survives even if
    -- the storage section did not persist. We rebuild the cache from defaults
    -- merged with the saved snapshot, then write it back to the storage section
    -- so both paths agree. If the save predates this field (data.stanceState
    -- nil), fall through to whatever the storage section holds.
    if type(data) == 'table' and type(data.stanceState) == 'table' then
        local restored = defaultStanceState()
        for id, entry in pairs(data.stanceState) do
            if restored[id] and type(entry) == 'table' then
                restored[id].xp    = tonumber(entry.xp) or 0
                restored[id].level = tonumber(entry.level) or config.startLevel
            end
        end
        stanceStateCache = restored
        pcall(function() stanceStateSection:set(STANCE_STATE_KEY, stanceStateCache) end)
    else
        -- No saved snapshot: drop the in-memory cache so the next getStanceState
        -- re-reads from the storage section (handles older saves and reloadlua).
        stanceStateCache = nil
    end
    -- Re-baseline perk-unlock tracking on load so we don't replay every
    -- threshold the player already passed. The first checkCoreLevelPerkUnlocks
    -- after load records the current level as the baseline.
    lastAnnouncedCoreLevel = nil
    -- Reset integration detection so a freshly-loaded session re-probes
    -- from scratch (backoff timers and cached detection cleared).
    for _, st in pairs(integrationState) do
        st.present = false
        st.detected = false
        st.lastChecked = -1
        st.backoff = 2.0
    end
end

-- ─── Top-level engine hook registrations ──────────────────────────────────

do
    -- Player-dealt combat hits now arrive as the Stance_PlayerDealtHit event
    -- from the victim-side actor script (scripts/stance/victim.lua), so there
    -- is no player-side I.Combat hook to register here.
    registerSpellHook()
end

if I.SkillProgression and I.SkillProgression.addSkillUsedHandler then
    local ok = pcall(I.SkillProgression.addSkillUsedHandler, onForeignSkillUsed)
    if not ok then
        print('[Stance!] Warning: failed to register SkillProgression handler.')
    end
end

-- Route "stance ..." console input through openmw.ui.setConsoleMode. When a
-- non-empty mode string is set the engine forwards console input to the
-- onConsoleCommand engine handler instead of evaluating it as Lua/mwscript.
-- We only activate this when the user types a line beginning with "stance";
-- the handler itself returns nil for anything else so the engine falls through
-- normally. Using pcall because the API may be absent on very old builds.
-- Console mode patch:
-- Do NOT force the console into 'stance' mode globally.
-- This was causing vanilla console commands to be intercepted.
-- Stance commands can still be handled through OpenMW's command routing.


return {
    interfaceName = 'Stance',
    interface = {
        version = 1,
        -- Read-only accessors other scripts (or source-mod integrations)
        -- can use to react to the player's current stance state.
        getActiveStance      = function() return activeStanceId end,
        getStanceLevel       = function(id) return getStanceLevel(id or activeStanceId) end,
        getCoreLevel         = function() return getCoreSkillLevel() end,
        -- Returns the additive skill-point bonus for the given stance (or
        -- the active stance when no id is passed). This is the value that
        -- gets injected into the target skill via the SF dynamic modifier.
        getSkillBonus        = function(id) return effectivenessSkillBonus(id or activeStanceId) end,
        -- Returns the Sanctuary bonus applied by the active (or named) stance.
        -- Scales from 0 at startLevel to stance.evasionBonus at maxLevel.
        getEvasionBonus      = function(id) return getStanceEvasionBonus(id or activeStanceId) end,
        -- Returns the target skill ID the bonus is applied to for the
        -- active (or named) stance. Nil when no bonus applies.
        getTargetSkill       = function(id) return resolveStanceSkill(id or activeStanceId) end,
        -- Backwards-compat alias: external scripts that previously read
        -- getEffectiveness as a multiplier now receive the additive bonus
        -- in points instead. Callers that multiplied by a damage value
        -- should switch to getSkillBonus.
        getEffectiveness     = function(id) return effectivenessSkillBonus(id or activeStanceId) end,
        isPerkUnlocked       = function(id, perkLevel)
            return getCoreSkillLevel() >= (tonumber(perkLevel) or math.huge)
                and getStanceConfig(id or activeStanceId) ~= nil
        end,
    },
    engineHandlers = {
        onConsoleCommand = onConsoleCommand,
        onUpdate = onUpdate,
        onSave = onSave,
        onLoad = onLoad,
        onInit = onLoad,
        -- UI mode tracking: keeps the HUD's drag-state in sync AND drives the
        -- Commoner talking-XP source (dialogue opened with an NPC).
        UiModeChanged = onUiModeChangedCombined,
    },
    eventHandlers = {
        Stance_KillGrant            = onStanceKillGrant,
        Stance_MerchantTransaction  = onMerchantTransaction,
        -- Player-dealt melee/ranged hits, forwarded by the victim-side actor
        -- script (scripts/stance/victim.lua) with the struck actor as target.
        Stance_PlayerDealtHit       = onPlayerDealtHit,

        -- External mod hooks.
        -- N'Garde parry on the player (carries isPerfect) → Fortifier parry XP.
        -- This is sent to the parrying actor, so it lands here directly.
        ngarde_parrySelf            = onNGardeParrySuccess,
        -- Simply Mining hooks: credit Pitmen XP on successful ore mines and
        -- broadcast perk-bonus data when mining starts.
        SimplyMining_notifyItem     = onSimplyMiningOreSuccess,
        SimplyMining_startMining    = onSimplyMiningStartMining,
        -- Fishing hooks: credit Angler XP on successful fish catches and
        -- broadcast perk-bonus data for bridge scripts.
        -- NOTE: If your Fishing mod fires a different event name, add an
        -- alias here pointing at the same onFishingCatch handler.
        Fishing_playerCaughtFish    = onFishingCatch,
        -- Locksmith lockpick/probe success, relayed from OSL via global.lua.
        Stance_LockpickSuccess      = onLockpickSuccess,
        -- Deployable-hazard credit, relayed from hazard.lua via global.lua:
        -- a trap catching an enemy → Thief, a burning oil pool → Apothecary.
        Stance_HazardHit            = onHazardHit,
        -- Apothecary (Thrown Concoctions) needs NO event hooks: a thrown
        -- concoction is an ordinary MarksmanThrown weapon, so its hits arrive
        -- through the same victim-side combat bridge (Stance_PlayerDealtHit,
        -- registered above) as every other weapon stance, and the stance is
        -- selected purely from the equipped concoction record (see the
        -- isApothecaryWeapon resolver branch).
        -- Disenchanting: Arcanist/Thaumaturge XP on a successful disenchant.
        -- This is a player-targeted event, so it lands here directly.
        disenchanting_finishedDisenchanting = onDisenchantFinished,
        -- Commercium / Fair Trade barter, relayed from global.lua.
        Stance_CommerciumTransaction = onCommerciumTransaction,
        -- Transcribe spell-transcription, relayed from global.lua.
        Stance_TranscribeSuccess     = onTranscribeSuccess,
        EquipSecondWeapon           = onDualWieldingEquip,
        EquipSecondWeaponKey        = onDualWieldingEquipKey,
        RemoveSecondWeapon          = onDualWieldingRemove,
        RemoveSecondWeaponUI        = onDualWieldingRemove,
        GKD_DoKnockdown             = onGskKnockdown,
        -- WeaponUpgrade and ArmorUpgrade both dispatch ShowMessage to the
        -- player. We listen and inspect the body to credit Reforger XP.
        ShowMessage                 = onUpgradeShowMessage,
    },
}
