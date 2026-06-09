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

local function formatStanceName(stanceId)
    local stance = getStanceConfig(stanceId)
    if not stance then return 'Unknown' end
    return stance.displayName
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
    thrownconcoctions   = 'integrateThrownConcoctions',
    veneficvials   = 'integrateVeneficVials',
    traps          = 'integrateTraps',
    oilflask       = 'integrateOilFlask',
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

local function safeArmorRecord(item)
    if not item then return nil end
    local ok, isArmor = pcall(types.Armor.objectIsInstance, item)
    if not ok or not isArmor then return nil end
    local okRec, rec = pcall(types.Armor.record, item)
    if not okRec then return nil end
    return rec
end

local function getRightHandWeapon()
    local equipment = types.Actor.getEquipment(self)
    if not equipment or not types.Actor.EQUIPMENT_SLOT then return nil end
    return equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
end

local function getEquippedShield()
    -- Shields live in CarriedLeft (the off-hand armor slot). Same pattern
    -- N'Garde uses.
    local equipment = types.Actor.getEquipment(self)
    if not equipment or not types.Actor.EQUIPMENT_SLOT then return nil end
    local item = equipment[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
    local rec = safeArmorRecord(item)
    if not rec then return nil end
    if rec.type ~= nil and types.Armor.TYPE and rec.type == types.Armor.TYPE.Shield then
        return item
    end
    return nil
end

local function getStanceMode()
    -- Returns 'weapon', 'spell', or 'nothing'. The function name on
    -- types.Actor varies across OpenMW builds (`stance` vs `getStance`).
    local stanceFn = types.Actor.getStance or types.Actor.stance
    if not stanceFn then return 'nothing' end
    local ok, st = pcall(stanceFn, self)
    if not ok then return 'nothing' end
    if types.Actor.STANCE then
        if st == types.Actor.STANCE.Spell  then return 'spell' end
        if st == types.Actor.STANCE.Weapon then return 'weapon' end
    end
    return 'nothing'
end

-- Weapon-type classifiers.
local WTYPE = types.Weapon and types.Weapon.TYPE or {}

local function isBowOrCrossbow(weaponRec)
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.MarksmanBow
        or weaponRec.type == WTYPE.MarksmanCrossbow
end

local function isThrown(weaponRec)
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.MarksmanThrown
end

local function isStave(weaponObj, weaponRec)
    -- Staves! identifies staves as BluntTwoWide.
    --
    -- GRIP compatibility:
    -- GRIP converts staffs into alternate weapon records whose runtime
    -- weapon type may no longer be BluntTwoWide. To preserve the
    -- Thaumaturge stance across conversions we test BOTH:
    --
    --   1) the current equipped weapon record
    --   2) the original GRIP source record
    --
    -- This mirrors the existing Pitman GRIP integration logic.

    if not weaponRec then
        return false
    end

    -- Current equipped record.
    if weaponRec.type == WTYPE.BluntTwoWide then
        return true
    end

    -- No weapon object means no GRIP lookup possible.
    if not weaponObj then
        return false
    end

    -- Resolve original GRIP source record.
    local originalId = nil

    pcall(function()
        originalId = gripOriginalRecordId(weaponObj.recordId)
    end)

    if not originalId then
        return false
    end

    local originalRec = nil

    pcall(function()
        originalRec = types.Weapon.records[originalId]
    end)

    if not originalRec then
        return false
    end

    return originalRec.type == WTYPE.BluntTwoWide
end

-- ─── GRIP integration ────────────────────────────────────────────────────
--
-- Forward-declare gripOriginalRecordId so isStave() (defined above) closes
-- over this local rather than resolving it as a global at call time.
-- The actual function is assigned below once the grip module is created.
local gripOriginalRecordId
--
-- GRIP converts weapons between 1H and 2H variants at runtime. It writes
-- two maps into the global section 'GRIPRecords':
--
--   OldToNewRecords[origId] = newId   (original → converted)
--   NewToOldRecords[newId]  = origId  (converted → original)
--
-- For stance classification we want to honor the player's INTENT — if
-- they're holding a GRIP-converted weapon, the original record type is
-- what they meant to wield. The WeaponUpgrade mod uses the same pattern
-- (see WeaponUpgrade_g.lua: gripOriginalWeapon function), so this is
-- canonical.
--
-- We cache the section handle and re-read the conversion table on each
-- lookup because GRIP can rewrite it between weapon swaps. The cost is
-- one storage read per stance evaluation, which is negligible.

local grip = require('scripts.stance.player.grip').new({
    integrationPresent = integrationPresent,
})

-- Assign to the forward-declared locals so isStave (and every call site below)
-- captures the correct function references.
gripOriginalRecordId        = grip.gripOriginalRecordId
local effectiveWeaponRecord = grip.effectiveWeaponRecord
local runtimeWeaponRecord   = grip.runtimeWeaponRecord

local function isOneHandedMelee(weaponRec)
    if not weaponRec then return false end
    local t = weaponRec.type
    return t == WTYPE.ShortBladeOneHand
        or t == WTYPE.LongBladeOneHand
        or t == WTYPE.BluntOneHand
        or t == WTYPE.AxeOneHand
end

local function isTwoHandedMelee(weaponRec)
    if not weaponRec then return false end
    local t = weaponRec.type
    return t == WTYPE.LongBladeTwoHand
        or t == WTYPE.AxeTwoHand
        or t == WTYPE.BluntTwoClose
        or t == WTYPE.BluntTwoWide
        or t == WTYPE.SpearTwoWide
end

-- Long-blade-only classifiers — used by Zweihänder and Soloist. The user
-- requirement is that those two stances are reserved for long blades, not
-- generic melee. Other one-handed weapons (short blades, blunts, axes) and
-- other two-handed weapons (axes, blunts, spears) still go through the
-- normal isOneHandedMelee / isTwoHandedMelee predicates above, which the
-- Dualist branch uses; but the Zweihänder and Soloist branches use these
-- stricter predicates instead.
local function isLongBladeOneHand(weaponRec)
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.LongBladeOneHand
end

local function isLongBladeTwoHand(weaponRec)
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.LongBladeTwoHand
end

-- Specialised single-type classifiers for Guisarmier, Axeman, and Thief.
-- Each new stance keys off a specific weapon-type bucket so the player's
-- intent is matched precisely.
local function isSpear(weaponRec)
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.SpearTwoWide
end

local function isAxe(weaponRec)
    -- The user said "for having axes equipped" without distinguishing
    -- one- vs two-handed, so both axe types map to Axeman.
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.AxeOneHand
        or weaponRec.type == WTYPE.AxeTwoHand
end

-- Throwing-axe detection. A THROWN weapon (MarksmanThrown) whose record id or
-- display name contains "throwing axe" is treated as an axe and routed to the
-- Axeman stance instead of the generic thrown-weapon stance (Twirler). Mirrors
-- the Apothecary concoction special-case (a thrown weapon re-pointed at a
-- non-Twirler stance) and the Pitman name-matching helper. Real axes
-- (AxeOneHand/AxeTwoHand) are already Axeman via isAxe by TYPE; this only
-- rescues the thrown-typed "throwing axe" weapons that vanilla classification
-- would otherwise send to Twirler. The thrown-type gate keeps it scoped to
-- "any throwing weapon with 'throwing axe' in the name", as requested.
local function isThrowingAxe(weaponObj, weaponRec)
    if not weaponRec then return false end
    if not isThrown(weaponRec) then return false end

    local function containsThrowingAxeText(str)
        if type(str) ~= 'string' then return false end
        return str:lower():find('throwing axe', 1, true) ~= nil
    end

    -- Display name (the user-facing "name").
    if containsThrowingAxeText(weaponRec.name) then return true end

    -- Record id, as a fallback (e.g. "iron_throwing_axe").
    if weaponObj then
        local currentId = nil
        pcall(function() currentId = weaponObj.recordId end)
        if containsThrowingAxeText(currentId) then return true end
    end

    return false
end

local function isBluntMjolnir(weaponRec)
    -- Covers BluntOneHand (maces, clubs) and BluntTwoClose (warhammers,
    -- mauls). BluntTwoWide (staves) is intentionally excluded — those
    -- are caught by Thaumaturge at a higher detection priority.
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.BluntOneHand
        or weaponRec.type == WTYPE.BluntTwoClose
end

-- Pitman detection.
--
-- Any weapon whose record id OR display name contains:
--
--   * pick
--   * pickaxe
--
-- is treated as a mining tool and routed to the Pitman stance.
--
-- GRIP support:
--   GRIP generates replacement weapon records when converting between
--   one-handed and two-handed variants. Those generated ids usually do
--   NOT preserve the original naming convention, so we resolve BOTH:
--
--     1) the current equipped record
--     2) the original GRIP source record
--
--   and test both for pick/pickaxe naming.
--
-- This mirrors the existing Felthorn integration pattern and keeps
-- stance classification persistent across save/load cycles.
local function isPitmanWeapon(weaponObj, weaponRec)
    if not weaponObj or not weaponRec then
        return false
    end

    local function containsPickText(str)
        if type(str) ~= 'string' then
            return false
        end

        local lower = str:lower()

        return lower:find('pickaxe', 1, true) ~= nil
            or lower:find('pick', 1, true) ~= nil
    end

    -- Current equipped record id.
    local currentId = nil
    pcall(function()
        currentId = weaponObj.recordId
    end)

    if containsPickText(currentId) then
        return true
    end

    -- Current weapon display name.
    if containsPickText(weaponRec.name) then
        return true
    end

    -- GRIP original record support.
    --
    -- Converted GRIP weapons may lose their original naming scheme in
    -- the generated replacement record, so we resolve back to the
    -- original source record and test THAT as well.
    local originalId = gripOriginalRecordId(currentId)

    if containsPickText(originalId) then
        return true
    end

    -- Resolve original GRIP weapon record and test its display name.
    if originalId and types.Weapon and types.Weapon.records then
        local originalRecord = types.Weapon.records[originalId]

        if originalRecord and containsPickText(originalRecord.name) then
            return true
        end
    end

    return false
end


local function isShortBlade(weaponRec)
    if not weaponRec then return false end
    return weaponRec.type == WTYPE.ShortBladeOneHand
end

-- Angler stance detection: fishing poles from Fish With Fishing Poles
-- Expansion have the specific record ids "a_fishing_pole" and
-- "hb_fishing_pole". Detection mirrors the Pitmen pattern — we match
-- against the equipped object's record id (and the GRIP-resolved original
-- if present) rather than the weapon's type field, because the fishing pole
-- could have any underlying weapon type depending on how the mod author
-- classified it, and we do not want Thaumaturge or Guisarmier to steal it.
local ANGLER_RECORD_IDS = {
    ['a_fishing_pole']  = true,
    ['hb_fishing_pole'] = true,
}

local function isAnglerWeapon(weaponObj, weaponRec)
    if not weaponObj or not weaponRec then return false end

    -- Current equipped record id.
    local currentId = nil
    pcall(function() currentId = weaponObj.recordId end)

    if currentId and ANGLER_RECORD_IDS[currentId:lower()] then
        return true
    end

    -- GRIP original record support: a GRIP-converted fishing pole may have
    -- a generated record id; resolve back to the original and check that.
    local originalId = gripOriginalRecordId(currentId)
    if originalId and ANGLER_RECORD_IDS[originalId:lower()] then
        return true
    end

    return false
end

-- Apothecary stance detection: the Thrown Concoctions mod adds 17 throwable
-- "concoction" weapons (all MarksmanThrown). Detection mirrors the Angler /
-- Pitmen pattern — match the equipped object's record id (and the GRIP-resolved
-- original, if any) against the fixed set below, rather than the weapon's type
-- field, because the concoctions share the MarksmanThrown type with ordinary
-- thrown weapons and we do NOT want Twirler to steal them. The ids are the
-- exact record NAMEs from Thrown_ConcoctionsMP.esp, lower-cased here because
-- OpenMW record ids compare case-insensitively. `concoction_base` is the
-- un-enchanted template flask; the rest are the enchanted concoctions.
local APOTHECARY_RECORD_IDS = {
    ['concoction_base']        = true,
    ['grease_jar']             = true,
    ['restorative_waters']     = true,
    ['raw_magicka']            = true,
    ['cleansing_salve']        = true,
    ['flash_bang']             = true,
    ['kwama_queen_ph']         = true,
    ['anti_magicka_bottle']    = true,
    ['invigorating_aromatic']  = true,
    ['aromatic_of_focus']      = true,
    ['insulating_oil']         = true,
    ['singularity']            = true,
    ['smoke_bomb']             = true,
    ['liquid_stalhrim']        = true,
    ['plasma_jar']             = true,
    ['dwemer_candle']          = true,
    ['sapping_poison']         = true,
}

local function isApothecaryWeapon(weaponObj, weaponRec)
    if not weaponObj or not weaponRec then return false end

    -- Current equipped record id.
    local currentId = nil
    pcall(function() currentId = weaponObj.recordId end)

    if currentId and APOTHECARY_RECORD_IDS[currentId:lower()] then
        return true
    end

    -- GRIP original record support: a GRIP-converted concoction may have a
    -- generated record id; resolve back to the original and check that too.
    local originalId = gripOriginalRecordId(currentId)
    if originalId and APOTHECARY_RECORD_IDS[originalId:lower()] then
        return true
    end

    return false
end

-- Venefic Vial (thrown) detection. The Venefic Vials mod's throwable variant
-- 'vv_vial_th' is a MarksmanThrown flask, so like the concoctions it routes to
-- the Apothecary stance (gated on its own integration toggle, separate from
-- Thrown Concoctions). Kept as its own id set + helper so the two apothecary
-- throwable sources can be enabled/disabled independently.
local VENEFIC_VIAL_RECORD_IDS = {
    ['vv_vial_th'] = true,
}

local function isVeneficVialWeapon(weaponObj, weaponRec)
    if not weaponObj or not weaponRec then return false end

    local currentId = nil
    pcall(function() currentId = weaponObj.recordId end)

    if currentId and VENEFIC_VIAL_RECORD_IDS[currentId:lower()] then
        return true
    end

    local originalId = gripOriginalRecordId(currentId)
    if originalId and VENEFIC_VIAL_RECORD_IDS[originalId:lower()] then
        return true
    end

    return false
end

-- Lockpick / probe equip check for the Locksmith stance.
--
-- The player only needs ONE of (lockpick OR probe) readied in the right hand.
-- Carrying tools in inventory does NOT count.
--
-- Detection is the live CarriedRight slot ONLY, read fresh each call. The
-- previous version cached the result for one second, which let Locksmith
-- linger as "active" for up to a tick after the player sheathed the tool, so
-- Brawler (which requires a truly empty right hand) could never take over.
-- The read is a single equipment lookup — the resolver already reads equipment
-- for the weapon/shield branches — so there is no need to cache it, and not
-- caching means an emptied right hand is reflected immediately. The resolver
-- additionally gates this on stanceMode == 'weapon' (drawn), so a sheathed-but-
-- still-equipped tool does not keep Locksmith active.
local function hasLockpickOrProbeEquipped()
    if not (types.Lockpick or types.Probe) then return false end
    if not types.Actor.EQUIPMENT_SLOT then return false end

    local equipment = nil
    local okEq = pcall(function() equipment = types.Actor.getEquipment(self) end)
    if not okEq or not equipment then return false end

    local right = equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
    if not right then return false end

    if types.Lockpick then
        local okLP, isLP = pcall(types.Lockpick.objectIsInstance, right)
        if okLP and isLP then return true end
    end
    if types.Probe then
        local okPR, isPR = pcall(types.Probe.objectIsInstance, right)
        if okPR and isPR then return true end
    end
    return false
end

-- Reforger detection: the WeaponUpgrade/ArmorUpgrade mods both gate on
-- `weapon.recordId == "repair_hammer_weapon"`. We test the same record id
-- in the right hand. The hammer is technically a one-handed weapon, but
-- because the upgrade gate uses an exact record id match, our detection
-- can be just as precise.
local function isReforgerWeapon(weaponObj, weaponRec)
    if not weaponRec then
        return false
    end

    local function matches(rec)
        if not rec then
            return false
        end

        local id = string.lower(
            rec.id
            or rec.recordId
            or ""
        )

        return
            id == "ab_w_toolsmithhammer"
            or id == "am_hammer"
            or id == "_gg_repair_master_01"
            or id == "repair_hammer_weapon"
            or string.find(id, "toolsmithhammer", 1, true)
            or string.find(id, "smithhammer", 1, true)
            or string.find(id, "forgehammer", 1, true)
            or string.find(id, "armorerhammer", 1, true)
            or string.find(id, "blacksmithhammer", 1, true)
    end

    -- Current equipped weapon.
    if matches(weaponRec) then
        return true
    end

    -- No weapon object available.
    if not weaponObj then
        return false
    end

    -- Resolve original GRIP source record.
    local originalId = nil

    pcall(function()
        originalId = gripOriginalRecordId(weaponObj.recordId)
    end)

    if not originalId then
        return false
    end

    local originalRec = nil

    pcall(function()
        originalRec = types.Weapon.records[originalId]
    end)

    if not originalRec then
        return false
    end

    return matches(originalRec)
end



-- Blademeister detection: Felthorn (the Soul-Eater-themed shapeshifting
-- weapon from the Blademeister mod) has no single canonical record id —
-- the mod defines 180+ weapon records, one per shapeshifted form, all
-- sharing the `sd_` prefix used exclusively by Blademeister.
--
-- Examples of valid forms:
--   sd_IronRapier0, sd_DaedricClaymore4, sd_CatgirlRapier, sd_SaintSword2,
--   sd_DremoraAxe1, sd_GlassLongsword3, sd_BonemoldLongbow2, ...
--
-- A prefix match catches every Felthorn form the player can wield. The
-- comparison is case-insensitive because OpenMW record ids are themselves
-- case-insensitive at the engine level — sd_, Sd_, SD_ all refer to the
-- same record.
local function isFelthorn(weaponObj)
    if not weaponObj then
        return false
    end

    local prefix = (config.blademeisterRecordPrefix or 'sd_'):lower()

    local currentId = nil
    local ok = pcall(function()
        currentId = weaponObj.recordId
    end)

    if not ok or type(currentId) ~= 'string' then
        return false
    end

    -- Direct Felthorn match.
    if currentId:lower():sub(1, #prefix) == prefix then
        return true
    end

    -- GRIP conversion support.
    --
    -- When GRIP converts Felthorn, the active record id changes into a
    -- generated GRIP record. We resolve back to the original record id
    -- and test THAT against the Felthorn prefix.
    local originalId = gripOriginalRecordId(currentId)

    if not originalId or type(originalId) ~= 'string' then
        return false
    end

    return originalId:lower():sub(1, #prefix) == prefix
end

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

local function isDualWielding(now)
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
local function isFelthornInOffhand()
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
    -- Unarmed / shield
    brawler      = { vanilla = 'handtohand' },
    fortifier    = { vanilla = 'block' },
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
    fortifier    = 'enableFortifier',
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
    fortifier    = 'enableFortifierPerks',
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

local function resolveStance(now)
    local stanceMode = getStanceMode()
    local right = getRightHandWeapon()
    local rightRec = safeWeaponRecord(right)
    -- GRIP-aware record used for type classification (bow/stave/1H/2H).
    -- For everything OTHER than the Reforger hammer check (which uses
    -- the literal record id, since the upgrade mods match on it), this
    -- is the record we want.
    local effRec = effectiveWeaponRecord(right, rightRec)
    local runtimeRec = runtimeWeaponRecord(right, rightRec)
    local shield = getEquippedShield()

    local function pick(id, reason)
        if not stanceEnabled(id) then return nil end
        return { id = id, reason = reason }
    end

    -- 1) Locksmith: a lockpick OR a probe is READIED in the right hand.
    --    Sheathing keeps the tool in the CarriedRight slot (equipping is
    --    separate from drawing in OpenMW), so a slot read alone would keep
    --    Locksmith active forever after one use. We therefore also require the
    --    weapon stance to be DRAWN (stanceMode == 'weapon'); when the player
    --    sheathes, getStance() reports Nothing and we fall through to Commoner
    --    below. Merely carrying tools in inventory never counts.
    if stanceMode == 'weapon' and hasLockpickOrProbeEquipped() then
        local r = pick('locksmith', 'lockpick or probe readied')
        if r then return r end
    end

    -- 2) Commoner: nothing readied (Locksmith fallback).
    if stanceMode == 'nothing' then
        local r = pick('commoner', 'weapons sheathed')
        if r then return r end
    end

    -- 3) Arcanist: spell stance.
    if stanceMode == 'spell' then
        local r = pick('arcanist', 'spellcasting stance')
        if r then return r end
    end

    -- 4) Reforger: repair hammer in right hand AND weapon stance up.
    --    Uses the literal record id (NOT the GRIP-original), because the
    --    WeaponUpgrade and ArmorUpgrade mods themselves match on the
    --    current record id. If GRIP somehow converted the hammer, the
    --    upgrade mods wouldn't fire either, so we follow their logic.
    --
    --    Explicitly excluded when Felthorn is in the off-hand: without this
    --    guard the hammer in the right hand wins at priority 4 and the
    --    Blademeister check at priority 5 is never reached, leaving Reforger
    --    active for the entire dual-wield session.
    if effRec and isReforgerWeapon(right, effRec) and not isFelthornInOffhand() then
        local r = pick('reforger', 'reforger weapon equipped')
        if r then return r end
    end

    -- 5) Blademeister: Felthorn equipped in any of its shapeshifted forms,
    --    in EITHER hand. Uses a record-id prefix match (`sd_`) — the
    --    Blademeister mod's 180+ Felthorn shapeshift records all share
    --    that prefix. Doesn't gate on stanceMode because the player
    --    wields Felthorn whether fists-down or weapon-stance-up; equipping
    --    it is itself the signal.
    --
    --    Comes before every weapon-type branch (Huntsman, etc.)
    --    so the meister identity wins over the underlying weapon type: a
    --    Felthorn-claymore form (sd_DaedricClaymore3) would otherwise
    --    classify as Zweihänder, a Felthorn-shortsword form would trigger
    --    Thief, a Felthorn-bow form would trigger Huntsman, and so on.
    --
    --    The off-hand check uses isFelthornInOffhand() which reads the
    --    record id captured from the Dual Wielding mod's EquipSecondWeapon
    --    event. Without this branch, Felthorn-in-off-hand + main-hand 1H
    --    weapon would route to Dualist (priority 7) instead of Blademeister.
    if (right and isFelthorn(right)) or isFelthornInOffhand() then
        local r = pick('blademeister', 'Felthorn equipped')
        if r then return r end
    end

    -- 6) Angler: fishing pole equipped (record ids "a_fishing_pole" or
    --    "hb_fishing_pole" from Fish With Fishing Poles Expansion). Sits
    --    immediately after Blademeister so the fishing pole is claimed by
    --    record-id matching before any weapon-type branch (Thaumaturge,
    --    Guisarmier, etc.) can intercept it — the underlying weapon type
    --    of the fishing pole is irrelevant to us. When Angler is disabled
    --    the pole falls through to whatever weapon-type branch applies.
    if right and effRec and isAnglerWeapon(right, effRec) then
        local r = pick('angler', 'fishing pole equipped')
        if r then return r end
    end

    -- 7) Huntsman: bow or crossbow (effective type).
    if effRec and isBowOrCrossbow(effRec) then
        local r = pick('huntsman', 'bow/crossbow equipped')
        if r then return r end
    end

    -- 7b) Apothecary: a thrown APOTHECARY item is equipped — a Thrown Concoction
    --     OR a Throwning Venefic Vial. Both are MarksmanThrown weapons, so
    --     without this branch they would be claimed by the generic Twirler
    --     thrown-weapon branch (8) below. Each source is gated on its OWN
    --     integration toggle, so disabling one (e.g. Thrown Concoctions) still
    --     lets the other (Venefic Vials) route to Apothecary, and disabling both
    --     — or the Apothecary stance itself (pick → stanceEnabled) — lets the
    --     item fall through to Twirler. Sits here, after Huntsman and before
    --     Twirler, exactly as Angler (6) and Pitmen (13) sit above the broad
    --     weapon-type branch they would otherwise hit.
    if right and effRec then
        local apoMatch =
            (integrationEnabled('thrownconcoctions') and isApothecaryWeapon(right, effRec))
            or (integrationEnabled('veneficvials') and isVeneficVialWeapon(right, effRec))
        if apoMatch then
            local r = pick('apothecary', 'thrown apothecary item equipped')
            if r then return r end
        end
    end

    -- 7c) Axeman (throwing axe): a THROWN weapon whose name marks it a throwing
    --     axe routes to Axeman rather than the generic Twirler thrown-weapon
    --     branch (8) below, so throwing axes train and score as axes. Same shape
    --     as the Apothecary concoction branch (7b) above and Angler/Pitmen: a
    --     record-level match sits just above the broad weapon-type branch it
    --     would otherwise fall into. Falls through to Twirler when Axeman is
    --     disabled (pick → stanceEnabled). (Real axe-TYPE weapons are still
    --     handled by the type-based Axeman branch at 14.)
    if right and effRec and isThrowingAxe(right, effRec) then
        local r = pick('axeman', 'throwing axe equipped')
        if r then return r end
    end

    -- 8) Twirler: thrown weapon (effective type). Separate stance from Huntsman;
    --    boosts the Throwing skill (not Marksman).
    if effRec and isThrown(effRec) then
        local r = pick('twirler', 'thrown weapon equipped')
        if r then return r end
    end

    -- 9) Thaumaturge: stave (effective type).
    if effRec and isStave(right, effRec) then
        local r = pick('thaumaturge', 'stave equipped')
        if r then return r end
    end

    -- 10) Dualist: Dual Wielding off-hand active with a one-handed primary.
    --    We use the RUNTIME record (what is actually equipped right now), not
    --    the GRIP-original, so a weapon GRIP-converted TO one-handed in order
    --    to be dual-wielded correctly triggers Dualist. (Conversely a 1H weapon
    --    GRIP-converted to 2H would read as 2H here and fall through, which is
    --    also correct — you can't dual-wield a 2H weapon.)
    if runtimeRec and isOneHandedMelee(runtimeRec) and isDualWielding(now) then
        local r = pick('dualist', 'dual-wielding')
        if r then return r end
    end

    -- 11) Fortifier: a shield is equipped ALONGSIDE a weapon (sword-and-board
    --    and the like). The right-hand requirement is the fix for "Fortifier
    --    persisting over Brawler": with empty fists + shield the player wants
    --    the unarmed Brawler stance, not Fortifier, so we require `right` to be
    --    present here and let the bare-shield case fall through to Brawler (19).
    --    In vanilla a shield can only coexist with a one-handed weapon (or no
    --    weapon) since 2H/bow/crossbow/stave/thrown all consume the left slot
    --    the shield would occupy, so `right` at this point is a 1H weapon —
    --    which is exactly the sword-and-board case Fortifier represents. (Note
    --    this still sits above the 1H weapon-type branches, so a 1H weapon +
    --    shield is Fortifier rather than Soloist/Axeman/etc., as intended:
    --    "Soloist" means solo, i.e. no shield.)
    if shield and right then
        local r = pick('fortifier', 'shield equipped')
        if r then return r end
    end

    -- 12) Guisarmier: spear (SpearTwoWide). Comes before Zweihänder so a
    --     spear's classification is unambiguous; comes after Fortifier so
    --     the (effectively impossible in vanilla) spear-plus-shield case
    --     would still route to Fortifier the way the user requested.
    if effRec and isSpear(effRec) then
        local r = pick('guisarmier', 'spear equipped')
        if r then return r end
    end

    -- 13) Pitmen: the Miner's Pick specifically (record id "miner's pick",
    --     a two-handed axe). Sits above generic Axeman so the miner's pick
    --     always routes here rather than falling into the axe bucket. When
    --     Pitmen is disabled the pick naturally falls through to Axeman (13).
    if right and effRec and isPitmanWeapon(right, effRec) then
        local r = pick('pitmen', "pick/pickaxe equipped")
        if r then return r end
    end

    -- 14) Axeman: any axe — one-handed or two-handed (AxeOneHand or
    --     AxeTwoHand). Comes before the long-blade branches so an axe
    --     never accidentally trickles to Commoner.
    if effRec and isAxe(effRec) then
        local r = pick('axeman', 'axe equipped')
        if r then return r end
    end

    -- 15) Mjolnir: blunt one-handed (BluntOneHand) or blunt two-handed close
    --     (BluntTwoClose) — maces, clubs, warhammers, mauls. Comes after
    --     Thaumaturge (BluntTwoWide, priority 9) and Axeman (priority 14)
    --     so staves route correctly and axes never fall through here.
    if effRec and not isReforgerWeapon(right, effRec) and isBluntMjolnir(effRec) then
        local r = pick('mjolnir', 'blunt weapon equipped')
        if r then return r end
    end

    -- 16) Zweihänder: long-blade two-handed weapon ONLY. Other two-handed
    --    weapons (battleaxes [now caught by Axeman above], warhammers
    --    [now caught by Mjolnir above], spears [now caught by Guisarmier
    --    above]) intentionally fall through to Commoner.
    --
    --    GRIP exclusion: Morrowind has no "ShortBladeTwoHand" type, so when
    --    GRIP converts a 1H short blade to a 2H form the converted (runtime)
    --    record is typed LongBladeTwoHand — which would wrongly route a
    --    GRIP'd shortsword to Zweihänder instead of Thief. We therefore skip
    --    Zweihänder when the GRIP-ORIGINAL record (effRec) is a short blade,
    --    letting it fall through to the Thief branch below.
    if runtimeRec and isLongBladeTwoHand(runtimeRec)
        and not (effRec and isShortBlade(effRec)) then
        local r = pick('zweihander', 'long-blade 2H')
        if r then return r end
    end

    -- 17) Soloist: long-blade one-handed weapon ONLY. Other one-handed
    --     weapons (short blades [now caught by Thief below], blunts
    --     [now caught by Mjolnir above], axes [now caught by Axeman above])
    --     intentionally fall through to Commoner.
    if runtimeRec and isLongBladeOneHand(runtimeRec) then
        local r = pick('soloist', 'long-blade 1H solo')
        if r then return r end
    end

    -- 18) Thief: short blade (ShortBladeOneHand). Comes after Soloist so
    --     a long-blade 1H stays Soloist while a short blade routes here.
    if effRec and isShortBlade(effRec) then
        local r = pick('thief', 'short blade equipped')
        if r then return r end
    end

    -- 19) Brawler: fists up, right hand truly empty (no weapon and no
    --     other item like a lockpick / probe / repair tool either).
    --     The previous version checked `not rightRec` (no Weapon record),
    --     which incorrectly fired when the right hand held a lockpick or
    --     probe — those have no weapon record but `right` is still a real
    --     item. We re-check `right` directly so the only way Brawler
    --     triggers is when the slot is genuinely empty.
    if not right and stanceMode == 'weapon' then
        local r = pick('brawler', 'unarmed, fists up')
        if r then return r end
    end

    -- 20) Final fallback.
    local r = pick('commoner', 'fallback')
    if r then return r end

    return { id = 'commoner', reason = 'all stances disabled' }
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
    { 'Perks',   'enableFortifierPerks' },
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
    { 'Stances', 'enableFortifier' },
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
    -- Per-stance hit XP. Three cases:
    --   * Fortifier earns NOTHING from landing hits — its XP comes exclusively
    --     from N'Garde parries / perfect parries (see onNGardeParrySuccess).
    --   * Apothecary earns the dedicated concoction weight under the
    --     'concoction' source (gated by xpOnConcoctionHit). Apothecary is only
    --     ever active with a Thrown Concoction equipped, so any hit credited to
    --     it is necessarily a landed concoction throw.
    --   * Every other stance earns the standard combatHit weight.
    -- All stances still run their on-hit perks below regardless.
    if activeStanceId == 'fortifier' then
        -- no hit XP
    elseif activeStanceId == 'apothecary' then
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

    -- Meditation Skill → Arcanist tick (only while Arcanist active).
    if foreignSkillId == 'meditation_skill' then
        if activeStanceId == 'arcanist' and integrationPresent('meditation') then
            grantStanceXp(config.xp.meditateTick or 0.4, 'meditate', 'arcanist')
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

local function onNGardeParrySuccess(payload)
    if not readSetting('', 'enabled', true) then return end
    if not readSetting('Progression', 'xpOnParry', true) then return end

    -- N'Garde sends 'ngarde_parrySelf' to the parrying actor (the player, when
    -- the player parries) with { damageRemainingRatio, isPerfect, originalDamage }.
    -- 'isPerfect' is the authoritative perfect-parry flag (confirmed in
    -- N'Garde 1.3.0 controllers/parry.lua). The global 'ngarde_ParrySuccess'
    -- event is sound/VFX only and carries no perfect flag, so we do NOT use it.
    local perfect = (type(payload) == 'table') and payload.isPerfect or false

    if activeStanceId then
        if perfect then
            grantStanceXp(config.xp.perfectParrySuccess or 2.4, 'perfectparry', activeStanceId)
        else
            grantStanceXp(config.xp.parrySuccess or 1.2, 'parry', activeStanceId)
        end
        debugLog(string.format('%s credited for a %sparry.',
            activeStanceId, perfect and 'perfect ' or ''), 'debugPerkMessages')
    end

    -- Dispatch Fortifier parry perks (Warden Stance, Perfect Guard, Bulwark).
    Perks.onParry()
end

-- ─── SimplyMining integration ─────────────────────────────────────────────
-- SimplyMining fires SimplyMining_notifyItem at the player whenever an ore
-- mine completes successfully (regardless of tool used). We only act when:
--   * the Pitmen stance is active (miner's pick equipped)
--   * the SimplyMining integration is enabled in settings
-- On success we grant mining XP and, if the relevant perks are unlocked,
-- expose them via the Stance interface so SimplyMining (or a bridge mod)
-- can read and apply the bonuses.
local function onSimplyMiningOreSuccess(_payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId ~= 'pitmen' then return end
    if not stanceEnabled('pitmen') then return end
    -- Integration gate: respect the player's toggle in settings.
    if not integrationEnabled('simplymining') then return end

    grantStanceXp(config.xp.miningSuccess or 3.0, 'mining', 'pitmen')
    debugLog('Pitmen credited for successful ore mine.', 'debugPerkMessages')
end

-- SimplyMining_startMining fires when the player begins mining a node.
-- Pitmen checks whether the active perks should modify the mining duration
-- and broadcasts a Stance_PitmenMiningStart event that a SimplyMining patch
-- or bridge script can consume to adjust speed/yield accordingly.
local function onSimplyMiningStartMining(_payload)
    if activeStanceId ~= 'pitmen' then return end
    if not stanceEnabled('pitmen') then return end
    if not integrationEnabled('simplymining') then return end

    local coreLevel = getCoreSkillLevel()
    -- Vein Reader (level 50): 20% faster mining.
    local speedBonus  = (coreLevel >= 50)  and 0.20 or 0.0
    -- Pit Boss (level 100): stacks another 10% (total 30%).
    if coreLevel >= 100 then speedBonus = speedBonus + 0.10 end
    -- Prospector (level 75): 15% ore yield bonus.
    local yieldBonus  = (coreLevel >= 75)  and 0.15 or 0.0

    -- Broadcast for any interested listener (SimplyMining bridge, etc.).
    core.sendGlobalEvent('Stance_PitmenMiningStart', {
        speedBonus  = speedBonus,
        yieldBonus  = yieldBonus,
        stanceLevel = getStanceLevel('pitmen'),
        coreLevel   = coreLevel,
    })
end

-- ─── Fishing integration ──────────────────────────────────────────────────
-- The Fishing mod fires 'Fishing_playerCaughtFish' at the player whenever a
-- fish is successfully landed. We only act when:
--   * the Angler stance is active (fishing pole equipped)
--   * the Fishing integration is enabled in settings
-- On success we grant fishing XP and, if the relevant perks are unlocked,
-- broadcast a 'Stance_AnglerCatch' event that the Fishing mod (or a bridge)
-- can consume to apply the Catch and Release / Trophy Cast bonuses.
--
-- NOTE: If your Fishing mod fires a different event name (e.g.
-- 'Fishing_CaughtFish', 'Fishing_notifyItem'), add an alias entry in
-- the eventHandlers table at the bottom of this file.
local function onFishingCatch(payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId ~= 'angler' then return end
    if not stanceEnabled('angler') then return end
    if not integrationEnabled('fishing') then return end

    grantStanceXp(config.xp.fishingCatch or 3.0, 'fishing', 'angler')
    debugLog('Angler credited for successful fish catch.', 'debugPerkMessages')

    -- Broadcast perk-bonus data for any listener (Fishing bridge, etc.).
    local coreLevel = getCoreSkillLevel()
    -- Catch and Release (level 50): +10% bonus-fish chance.
    local bonusFishChance = (coreLevel >= 50) and 0.10 or 0.0
    -- Trophy Cast (level 75): treat Fishing skill as 10 points higher.
    local skillBonus      = (coreLevel >= 75) and 10  or 0
    -- Master Angler (level 100): 20% faster cast time.
    local castSpeedBonus  = (coreLevel >= 100) and 0.20 or 0.0

    core.sendGlobalEvent('Stance_AnglerCatch', {
        bonusFishChance = bonusFishChance,
        skillBonus      = skillBonus,
        castSpeedBonus  = castSpeedBonus,
        stanceLevel     = getStanceLevel('angler'),
        coreLevel       = coreLevel,
    })
end

-- Oblivion-Style Lockpicking integration.
-- OSL fires 'OSL_LockpickSuccess' (global) on every successful pick/probe;
-- Stance's global script relays it here as 'Stance_LockpickSuccess'. We grant
-- Locksmith XP when Locksmith is the active stance (which it is whenever a
-- lockpick or probe is readied, since that's exactly how Locksmith is
-- detected). The `probe` flag distinguishes trap-disarming from lock-picking;
-- both grant the same XP here, but it's passed through for future use.
local function onLockpickSuccess(payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId ~= 'locksmith' then return end
    if not stanceEnabled('locksmith') then return end
    if not integrationEnabled('oblivionlockpicking') then return end
    if not readSetting('Progression', 'xpOnLockpick', true) then return end

    grantStanceXp(config.xp.lockpickSuccess or 2.0, 'lockpick', 'locksmith')
    local what = (type(payload) == 'table' and payload.probe) and 'trap disarm' or 'lock pick'
    debugLog('Locksmith credited for successful ' .. what .. '.', 'debugPerkMessages')
end

-- Deployable-hazard integrations (Traps → Thief, Oil Flask → Apothecary).
-- scripts/stance/hazard.lua (a local script on ACTIVATOR/LIGHT objects) detects
-- a non-player actor caught by an armed trap or standing in a burning oil pool
-- and fires 'Stance_HazardHit' { kind, victim }; the global script relays it
-- here. Unlike the weapon stances, these hazards are deployed and trigger while
-- the player may be wielding anything, so they credit a FIXED stance directly
-- (grantStanceXpDirect) rather than the active one — trapping is Thief's craft,
-- a lit oil pool is Apothecary's. Each credit is gated on the relevant
-- integration toggle, the stance being enabled, and its Progression XP toggle
-- (the gate is enforced inside grantStanceXpDirect via the source key).
local function onHazardHit(payload)
    if not readSetting('', 'enabled', true) then return end
    if type(payload) ~= 'table' then return end
    local kind = payload.kind

    if kind == 'trap' then
        if not integrationEnabled('traps') then return end
        if not stanceEnabled('thief') then return end
        grantStanceXpDirect(config.xp.trapHit or 3.0, 'trap', 'thief')
        debugLog('A trap caught an enemy — Thief credited.', 'debugPerkMessages')
    elseif kind == 'oil' then
        if not integrationEnabled('oilflask') then return end
        if not stanceEnabled('apothecary') then return end
        grantStanceXpDirect(config.xp.oilBurnTick or 0.5, 'oilburn', 'apothecary')
        debugLog('An enemy burned in an oil fire — Apothecary credited.', 'debugPerkMessages')
    end
end

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

local function onMerchantTransaction(_payload)
    if not readSetting('', 'enabled', true) then return end
    -- Commoner XP only credits while Commoner is the active stance
    -- (grantStanceXp self-guards, but checking here avoids a wasted call).
    if activeStanceId == 'commoner' then
        grantStanceXp(config.xp.merchantTransaction or 1.5, 'merchant', 'commoner')
    end
end

-- ── Disenchanting integration (Arcanist + Thaumaturge) ────────────────────
-- The Disenchanting mod fires the PLAYER event
-- 'disenchanting_finishedDisenchanting' { enchPoints, effects, ... } on every
-- SUCCESSFUL disenchant. Unravelling an enchantment is arcane work, so both
-- the Arcanist (spellcasting) and Thaumaturge (stave) stances earn from it —
-- whichever is active at the time. The reward is a flat base plus a capped
-- bonus scaled by the enchantment magnitude (enchPoints).
local DISENCHANT_STANCES = { arcanist = true, thaumaturge = true }

local function onDisenchantFinished(payload)
    if not readSetting('', 'enabled', true) then return end
    if not DISENCHANT_STANCES[activeStanceId] then return end
    if not stanceEnabled(activeStanceId) then return end
    if not integrationEnabled('disenchanting') then return end
    if not readSetting('Progression', 'xpOnDisenchant', true) then return end

    local points = 0
    if type(payload) == 'table' then points = tonumber(payload.enchPoints) or 0 end
    local base  = config.xp.disenchantBase or 1.5
    local bonus = math.min((config.xp.disenchantMaxBonus or 6.0),
                           points * (config.xp.disenchantPerPoint or 0.05))
    grantStanceXp(base + bonus, 'disenchant', activeStanceId)
    debugLog(string.format('%s credited for a disenchant (%.1f points).',
        activeStanceId, points), 'debugPerkMessages')
end

-- ── Commercium / Fair Trade integration (Commoner) ────────────────────────
-- Relayed from the FairTrade_Transaction global event via global.lua as
-- 'Stance_CommerciumTransaction' { absValue, isBuying }. Driving a hard bargain
-- is a Commoner's craft, so it earns Commoner XP: a flat base plus a capped
-- bonus scaled by the value of the deal. This is independent of the vanilla
-- merchant XP source (onMerchantTransaction) — with Commercium installed,
-- transactions flow through Commercium's event instead, and this handles them.
local function onCommerciumTransaction(payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId ~= 'commoner' then return end
    if not stanceEnabled('commoner') then return end
    if not integrationEnabled('commercium') then return end
    if not readSetting('Progression', 'xpOnCommercium', true) then return end

    local value = 0
    if type(payload) == 'table' then value = tonumber(payload.absValue) or 0 end
    local base  = config.xp.commerciumBase or 1.5
    local bonus = math.min((config.xp.commerciumMaxBonus or 4.0),
                           value * (config.xp.commerciumPerValue or 0.002))
    grantStanceXp(base + bonus, 'commercium', 'commoner')
    debugLog(string.format('Commoner credited for a Commercium deal (value %d).',
        math.floor(value)), 'debugPerkMessages')
end

-- ── Transcribe integration (Arcanist + Thaumaturge) ───────────────────────
-- Relayed from the TRAN_doTranscribe global event via global.lua as
-- 'Stance_TranscribeSuccess'. Copying an enchantment into a castable spell is
-- arcane work, so whichever of Arcanist or Thaumaturge is active earns XP.
local function onTranscribeSuccess(_payload)
    if not readSetting('', 'enabled', true) then return end
    if not DISENCHANT_STANCES[activeStanceId] then return end  -- arcanist/thaumaturge
    if not stanceEnabled(activeStanceId) then return end
    if not integrationEnabled('transcribe') then return end
    if not readSetting('Progression', 'xpOnTranscribe', true) then return end

    grantStanceXp(config.xp.transcribeSuccess or 3.0, 'transcribe', activeStanceId)
    debugLog(activeStanceId .. ' credited for a spell transcription.', 'debugPerkMessages')
end

-- ── Commoner: talking to NPCs (pairs with Talking Trains Speechcraft) ─────
-- A conversation is a Commoner's stock-in-trade. When the player opens dialogue
-- with an NPC while Commoner is the active stance (weapons sheathed), grant
-- Commoner XP. The first conversation with a given NPC is worth more than
-- repeat visits, so grinding one NPC isn't optimal.
--
-- Driven by the engine UiModeChanged signal (newMode == 'Dialogue', oldMode ==
-- nil, NPC in data.arg) — the same signal the Talking Trains Speechcraft mod
-- uses. This source therefore works whether or not Talking Trains is installed;
-- when both are present, vanilla Speechcraft and Commoner XP both advance.
-- talkDebounce prevents a double-grant for one open; the spoken-NPC set is
-- session-scoped (resets on load) to keep the save clean while still rewarding
-- breadth over repetition.
local talkSpokenNPCs = {}
local talkDebounce = false

local function onDialogueStarted(npc)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId ~= 'commoner' then return end
    if not stanceEnabled('commoner') then return end
    if not readSetting('Progression', 'xpOnTalk', true) then return end

    local npcId = nil
    if npc then
        local ok = pcall(function()
            if npc.type == types.NPC then npcId = npc.id end
        end)
        if not ok then npcId = nil end
    end

    local isFirst = true
    if npcId then
        if talkSpokenNPCs[npcId] then isFirst = false else talkSpokenNPCs[npcId] = true end
    end

    local amount = isFirst and (config.xp.dialogueTalkFirst or 1.0)
                            or  (config.xp.dialogueTalkRepeat or 0.25)
    grantStanceXp(amount, 'talk', 'commoner')
    debugLog(string.format('Commoner credited for %s conversation%s.',
        isFirst and 'a new' or 'a repeat',
        npcId and (' with ' .. tostring(npcId)) or ''), 'debugPerkMessages')
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

local function onGskKnockdown(payload)
    if not readSetting('', 'enabled', true) then return end
    if type(payload) ~= 'table' then return end
    local attacker = payload.attacker
    if not attacker then return end
    local attackerId, playerId
    pcall(function() attackerId = attacker.id end)
    pcall(function() playerId = self.object.id end)
    if not attackerId or attackerId ~= playerId then return end
    if activeStanceId == 'brawler' and stanceEnabled('brawler') then
        grantStanceXp(config.xp.combatKill or 2.0, 'kill', 'brawler')
        debugLog('GSK knockout credited to Brawler.', 'debugPerkMessages')
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
    skillFramework.refreshEffectivenessModifiers()

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

    -- Felthorn's ambient voice (no-op unless Blademeister is active).
    felthornVoice.update(activeStanceId, now)

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
    return { version = 2, stanceState = snapshot }
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
    dualWieldingActive = false
    dualWieldingWeaponRecord = nil
    dualWieldingAsOf = -math.huge
    dualWieldingRemovePendingAt = nil

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
