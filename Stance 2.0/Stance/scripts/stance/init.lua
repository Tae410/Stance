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

-- ─── Logging ──────────────────────────────────────────────────────────────

local function debugEnabled(category)
    if not readSetting('Debug', 'debugMessages', false) then return false end
    if not category then return true end
    return readSetting('Debug', category, false)
end

local function debugLog(msg, category)
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

local function getStanceLevel(stanceId)
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

local function getCoreSkillLevel()
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

local function integrationPresent(id)
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

local gripRecordsSection = nil

local function gripSection()
    if gripRecordsSection then return gripRecordsSection end
    if not integrationPresent('grip') then return nil end
    local ok, section = pcall(storage.globalSection, 'GRIPRecords')
    if ok and section then gripRecordsSection = section end
    return gripRecordsSection
end

-- Returns the "original" weapon record id for a converted weapon, or nil
-- when the weapon was not converted (or when GRIP isn't present).
local function gripOriginalRecordId(currentRecordId)
    if not currentRecordId then return nil end
    local section = gripSection()
    if not section then return nil end
    local ok, newToOld = pcall(function() return section:getCopy('NewToOldRecords') end)
    if not ok or type(newToOld) ~= 'table' then return nil end
    return newToOld[currentRecordId]
end

-- Effective weapon record. If GRIP converted the weapon, returns the
-- ORIGINAL record (so a converted 2H→1H weapon still classifies as 2H).
-- Otherwise returns the weapon's current record. Falls back to the
-- current record on any error.
--
-- Fast path: GRIP exposes I.GRIP.isConverted(weapon). When that interface
-- is available we ask it first — if the weapon is NOT converted there is
-- nothing to remap, so we return the current record immediately and skip
-- the storage lookup entirely. We only consult the GRIPRecords storage
-- map (to find the original record id) for weapons GRIP confirms were
-- converted. On builds/loadouts where the interface isn't present we fall
-- back to the storage-only path, preserving previous behavior.
local function gripIsConverted(weaponObj)
    if not (I.GRIP and I.GRIP.isConverted) then return nil end  -- unknown
    local ok, converted = pcall(I.GRIP.isConverted, weaponObj)
    if not ok then return nil end
    return converted == true
end


-- Effective weapon record.
--
-- GRIP creates a NEW weapon record when converting between 1H and 2H.
-- For stance detection we want the CURRENT converted weapon type, not
-- the original pre-conversion type.
--
-- Examples:
--   Iron Longsword      -> Iron Longsword (2H)
--   Silver Claymore     -> Silver Claymore (1H)
--
-- Therefore we intentionally return the CURRENT weapon record rather
-- than resolving back to the original GRIP source record.
local function effectiveWeaponRecord(weaponObj, weaponRec)
    if not weaponObj or not weaponRec then
        return weaponRec
    end
 -- Resolve original GRIP source record.
    local originalId = nil

    pcall(function()
        originalId = gripOriginalRecordId(weaponObj.recordId)
    end)

    -- Not a converted GRIP weapon.
    if not originalId then
        return weaponRec
    end

    local originalRec = nil

    pcall(function()
        originalRec = types.Weapon.records[originalId]
    end)

    -- Safety fallback.
    if not originalRec then
        return weaponRec
    end

    return originalRec
end

local function runtimeWeaponRecord(weaponObj, weaponRec)
    if not weaponRec then
        return nil
    end

    -- Runtime GRIP-converted record.
    -- Used for stances that intentionally depend on
    -- converted handedness behavior.
    return weaponRec
end

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

-- Lockpick / probe equip check for the Locksmith stance.
--
-- The player only needs ONE of (lockpick OR probe) equipped — either
-- counts as "doing locksmith work right now". Carrying tools in
-- inventory does NOT count; the engine has to report the tool as
-- actively equipped on the actor.
--
-- Detection strategy:
--   1) Fast path — read CarriedRight directly. The vanilla "Use" action
--      on a lockpick or probe puts it in this slot. One slot read.
--   2) Defensive path with Actor.hasEquipped — only runs if the fast
--      path didn't find an equipped tool. Sweeps inventory:getAll for
--      lockpicks then probes and calls hasEquipped on each. Catches
--      edge cases where a future build routes the tool through a
--      different slot.
--
-- A short cache (1s) keeps the readied/sheathed transition responsive
-- without scanning inventory four times per second.

local lockpickCacheValue = nil
local lockpickCacheTime = -math.huge

local function hasLockpickOrProbeEquipped()
    local now = core.getSimulationTime()
    if lockpickCacheValue ~= nil and (now - lockpickCacheTime) < 1.0 then
        return lockpickCacheValue
    end
    lockpickCacheTime = now

    -- Bail only if NEITHER type table exists at all. This used to also
    -- require types.Actor.hasEquipped, but that one's only needed for the
    -- defensive Method-2 path — Method 1 (direct CarriedRight read) works
    -- fine on older OpenMW builds that haven't shipped hasEquipped yet.
    -- The old hard guard was the bug: if hasEquipped wasn't present
    -- (e.g. wrong API version probed), the whole function returned false,
    -- which is why the Locksmith branch silently failed and the resolver
    -- fell through to Fortifier when the player had a shield equipped.
    if not (types.Lockpick or types.Probe) then
        lockpickCacheValue = false
        return false
    end

    local found = false

    -- ─── Method 1: direct equipment-slot read ────────────────────────────
    -- The vanilla "Use" action on a lockpick or probe puts the tool in
    -- the CarriedRight slot. This path does NOT need Actor.hasEquipped —
    -- if the engine reports a Lockpick/Probe object instance in that
    -- slot, it's equipped by definition.
    if types.Actor.EQUIPMENT_SLOT then
        local equipment = nil
        local okEq = pcall(function() equipment = types.Actor.getEquipment(self) end)
        if okEq and equipment then
            local right = equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
            if right then
                if types.Lockpick then
                    local okLP, isLP = pcall(types.Lockpick.objectIsInstance, right)
                    if okLP and isLP then found = true end
                end
                if not found and types.Probe then
                    local okPR, isPR = pcall(types.Probe.objectIsInstance, right)
                    if okPR and isPR then found = true end
                end
            end
        end
    end

    -- ─── Method 2: Actor.hasEquipped over filtered inventory ─────────────
    -- Defensive fallback. Catches edge cases where the engine routes a
    -- readied tool through a non-standard slot, or where the slot read
    -- in Method 1 returns nil for some reason. Skipped entirely on builds
    -- that don't expose Actor.hasEquipped.
    if not found and types.Actor.hasEquipped then
        local okInv, inv = pcall(types.Actor.inventory, self)
        if okInv and inv then
            if types.Lockpick then
                local okGet, picks = pcall(function() return inv:getAll(types.Lockpick) end)
                if okGet and type(picks) == 'table' then
                    for _, pick in ipairs(picks) do
                        local okHas, equipped = pcall(types.Actor.hasEquipped, self, pick)
                        if okHas and equipped then found = true; break end
                    end
                end
            end
            if not found and types.Probe then
                local okGetP, probes = pcall(function() return inv:getAll(types.Probe) end)
                if okGetP and type(probes) == 'table' then
                    for _, probe in ipairs(probes) do
                        local okHas, equipped = pcall(types.Actor.hasEquipped, self, probe)
                        if okHas and equipped then found = true; break end
                    end
                end
            end
        end
    end

    lockpickCacheValue = found
    return found
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
-- track the latest known SecondWeapon record id and the most recent event
-- timestamp. A 60-second staleness floor catches the rare case of a
-- save/load drift where the Remove event was missed.

local dualWieldingActive       = false
local dualWieldingWeaponRecord = nil
local dualWieldingAsOf         = -math.huge

local function isDualWielding(now)
    if not dualWieldingActive then return false end
    if (now - dualWieldingAsOf) > 60 then return false end
    if not integrationPresent('dualwielding') then return false end
    -- Sanity: Dual Wielding requires a one-handed primary in the right
    -- hand. We use the GRIP-aware effective record so a GRIP-converted
    -- weapon doesn't accidentally qualify as a 1H primary just because
    -- GRIP made it one — the player's original 2H weapon should NOT
    -- trigger Dualist.
    local right = getRightHandWeapon()
    if not right then return false end
    local rightRec = safeWeaponRecord(right)
    if not rightRec then return false end
    local effRec = effectiveWeaponRecord(right, rightRec)
    if not effRec then return false end
    if not isOneHandedMelee(effRec) then return false end
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
    twirler      = { vanilla = 'marksman',    modded = 'throwing',      integration = 'throwing' },
    thaumaturge  = { vanilla = 'bluntweapon', modded = 'staves_staves', integration = 'staves' },
    angler       = { vanilla = nil,           modded = 'fishing_skill', integration = 'fishing' },
    pitmen       = { vanilla = 'axe',         modded = 'mining_skill',  integration = 'simplymining' },
    -- Dynamic: resolve from the currently-equipped weapon type at runtime.
    -- Dualist boosts whichever 1H melee skill the primary weapon uses.
    -- Blademeister boosts whichever skill the current Felthorn form uses.
    dualist      = { dynamic = true },
    blademeister = { dynamic = true },
    -- Arcanist has no single weapon skill to amplify.
    arcanist     = nil,
}

-- Resolve the vanilla skill ID for a Dualist stance based on the primary
-- (right-hand) weapon. Returns nil when no 1H melee weapon is equipped.
local function getDualistSkill()
    local right = getRightHandWeapon()
    if not right then return nil end
    local rightRec = safeWeaponRecord(right)
    if not rightRec then return nil end
    local effRec = effectiveWeaponRecord(right, rightRec)
    if not effRec then return nil end
    local t = effRec.type
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
}

-- Are perks enabled for the given stance? Both the master `enableAllPerks`
-- toggle AND the per-stance toggle must be ON for perks to fire (popup
-- notification, tooltip listing). Levels still progress regardless.
local function perksEnabledForStance(stanceId)
    if readSetting('Perks', 'enableAllPerks', true) ~= true then return false end
    local key = PERK_SETTING_KEY[stanceId]
    if not key then return true end
    local val = settingSection('Perks'):get(key)
    if val == nil then return true end
    return val == true
end

local function stanceEnabled(stanceId)
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

    -- 1) Locksmith: a lockpick OR a probe is equipped on the player.
    --    Uses Actor.hasEquipped (plus a CarriedRight fast-path) to verify
    --    the player has actively readied at least one of the tools. Merely
    --    carrying tools in inventory does NOT count. Triggers regardless
    --    of stanceMode because equipping a lockpick or probe is itself a
    --    deliberate "I'm doing thief work right now" signal — and because
    --    the engine reports stanceMode == 'weapon' while a tool is readied,
    --    which would otherwise cause Brawler to claim the player when a
    --    tool (not a weapon record) is in hand.
    if hasLockpickOrProbeEquipped() then
        local r = pick('locksmith', 'lockpick or probe equipped')
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
    if effRec and isReforgerWeapon(right, effRec) then
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
    --    Comes before every weapon-type branch (Huntsman, Twirler, etc.)
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

    -- 8) Twirler: thrown weapon (effective type).
    if effRec and isThrown(effRec) then
        local r = pick('twirler', 'thrown weapon equipped')
        if r then return r end
    end

    -- 9) Thaumaturge: stave (effective type).
    if effRec and isStave(right, effRec) then
        local r = pick('thaumaturge', 'stave equipped')
        if r then return r end
    end

    -- 10) Dualist: Dual Wielding off-hand active. We use the effective
    --    type for the primary-hand 1H check so a GRIP-converted weapon
    --    still qualifies (e.g. a 2H weapon converted to 1H by GRIP is
    --    treated as 2H here, so it would NOT trigger Dualist).
    if effRec and isOneHandedMelee(effRec) and isDualWielding(now) then
        local r = pick('dualist', 'dual-wielding')
        if r then return r end
    end

    -- 11) Fortifier: a shield is equipped. The user requirement is "shield
    --    equipped" with no constraint on the weapon. In vanilla Morrowind
    --    a shield can only coexist with one-handed weapons (or no weapon
    --    at all) since 2H/bow/crossbow/stave/thrown all consume the left
    --    slot the shield would occupy — but we don't have to enforce that
    --    here; the engine already does. So the trigger is simply: shield
    --    present.
    if shield then
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
    if runtimeRec and isLongBladeTwoHand(runtimeRec) then
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

local activeStanceId       = nil
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

local function xpMultiplier()
    local v = tonumber(readSetting('Progression', 'xpMultiplier', 100)) or 100
    if v < 0 then v = 0 end
    return v * 0.01
end

local XP_SOURCE_GATE = {
    hit        = 'xpOnHit',
    kill       = 'xpOnKill',
    spell      = 'xpOnSpellCast',
    block      = 'xpOnBlock',
    time       = 'xpOnTime',
    merchant   = 'xpOnMerchant',
    meditate   = 'xpOnTime',
    upgrade    = 'xpOnUpgrade',
    mining     = 'xpOnMining',
    fishing    = 'xpOnFishing',
}

-- Feed the core Stance skill via Skill Framework. Called with HALF the
-- stance XP whenever the active stance gains XP.
local function feedCoreSkill(amount)
    if amount <= 0 then return end
    if I.SkillFramework and I.SkillFramework.skillUsed then
        pcall(I.SkillFramework.skillUsed, SKILL_ID, { useType = 1, skillGain = amount })
    end
end

-- pendingStanceLevelUps queues stance level-up messages drained in onUpdate
-- (so the message system stays in one place — see drainStanceLevelUps).
local pendingStanceLevelUps = {}

-- Grant XP to a stance. XP is ONLY credited when that stance is the
-- currently active stance — a stance does not progress in the background.
-- The core Stance skill simultaneously gains HALF the (multiplier-scaled)
-- amount and levels independently via Skill Framework.
local function grantStanceXp(amount, source, stanceId)
    if not amount or amount == 0 then return end
    if not stanceId then return end
    -- Only the active stance gains XP.
    if stanceId ~= activeStanceId then return end
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

-- ─── Skill Framework registration ─────────────────────────────────────────

local skillRegistered = false
local classBonusApplied = false
local lastSkillSyncedName = nil
local lastSkillSyncedAttribute = nil
local lastSkillSyncedDescription = nil

local function skillIsRegistered()
    return I.SkillFramework
        and I.SkillFramework.getSkillRecord
        and I.SkillFramework.getSkillRecord(SKILL_ID) ~= nil
end

local function registerSkill()
    if not readSetting('', 'enableSkillRegistration', true) then return false end
    if not I.SkillFramework then
        debugLog('Skill Framework not found — Stance skill will not appear.',
            'debugIntegrationMessages')
        return false
    end
    if skillIsRegistered() then
        skillRegistered = true
        return true
    end

    local specialization = I.SkillFramework.SPECIALIZATION
        and I.SkillFramework.SPECIALIZATION.Combat or nil

    I.SkillFramework.registerSkill(SKILL_ID, {
        name = config.defaultDisplayName,
        description = 'Stance reflects the form you currently hold. As you fight, cast, parry, barter, or reforge, the ACTIVE stance gains experience and levels on its own — and the core Stance skill gains half as much, leveling independently. Each stance is governed by a different attribute. Perks unlock from the core Stance skill level (25/50/75/100) across every stance, while each stance\'s own level raises its effectiveness.',
        attribute = config.defaultAttribute,
        specialization = specialization,
        startLevel = config.startLevel,
        maxLevel = config.maxLevel,
        skillGain = { [1] = 1.0 },
        statsWindowProps = {
            subsection = 'Stance',
            shortenedName = config.defaultDisplayName,
            visible = true,
        },
        icon = {
            bgr = 'icons/SkillFramework/combat_blank.dds',
            bgrColor = util.color.rgb(1, 1, 1),
        },
    })

    if readSetting('Progression', 'enableRaceBonuses', true) then
        -- Small uniform bonus across all races — Stance applies to
        -- everyone; specialised builds still come from per-stance grind.
        local races = {
            'imperial', 'breton', 'redguard', 'nord', 'dunmer',
            'altmer', 'bosmer', 'orc', 'khajiit', 'argonian',
            'T_Bm_Naga', 'T_Yne_Ynesai', 'T_Sky_Reachman', 'T_Pya_SeaElf',
        }
        for _, r in ipairs(races) do
            pcall(I.SkillFramework.registerRaceModifier, SKILL_ID, r, 5)
        end
    end

    debugLog('Stance skill registered.', 'debugIntegrationMessages')
    skillRegistered = true

    return true
end

local function getClassSpecializationBonus()
    if not readSetting('Progression', 'enableClassBonus', true) then return 0 end
    return config.classBonus or 0
end

local function applyClassBonus()
    if classBonusApplied then return end
    if not (I.SkillFramework and I.SkillFramework.registerDynamicModifier and skillIsRegistered()) then
        return
    end
    pcall(I.SkillFramework.registerDynamicModifier, SKILL_ID,
        'Stance_ClassSpecializationBonus', getClassSpecializationBonus)
    classBonusApplied = true
    debugLog('Class specialisation bonus modifier registered.',
        'debugIntegrationMessages')
end

-- ─── Per-skill additive effectiveness modifiers ───────────────────────────
--
-- Each stance grants an additive bonus to a specific skill (see
-- STANCE_SKILL_TARGET). The bonus is injected via Skill Framework's
-- registerDynamicModifier on the TARGET skill — NOT on the Stance skill
-- itself. This means the player's Long Blade stat (or throwing, staves_staves,
-- fishing_skill, etc.) rises while the relevant stance is active.
--
-- Registration is lazy:
--   * Vanilla Morrowind skills are registered immediately after the Stance
--     skill itself is registered (they're always present in SF).
--   * Modded skills (throwing, staves_staves, fishing_skill, mining_skill)
--     are registered the first time their integration is detected as present,
--     since SF only knows about them once that mod has registered its skill.
--
-- computeBonusForSkill is the shared callback: it checks which stance is
-- active, resolves its effective target skill, and returns the bonus only
-- when it matches the skill the modifier is registered on. All other skills
-- get 0 from the same callback, so there is never double-dipping.

local effectivenessModifiersRegistered = {}

local function computeBonusForSkill(skillId)
    if not activeStanceId then return 0 end
    if not readSetting('', 'enabled', true) then return 0 end
    local effectiveSkill = resolveStanceSkill(activeStanceId)
    if effectiveSkill ~= skillId then return 0 end
    -- Round to nearest integer so vanilla skill displays stay clean.
    return math.floor(effectivenessSkillBonus(activeStanceId) + 0.5)
end

local function ensureEffectivenessModifier(skillId)
    if not skillId then return end
    if effectivenessModifiersRegistered[skillId] then return end
    if not (I.SkillFramework
        and I.SkillFramework.registerDynamicModifier
        and I.SkillFramework.getSkillRecord) then return end
    -- Verify the skill is registered in SF before attaching a modifier.
    local ok, rec = pcall(I.SkillFramework.getSkillRecord, skillId)
    if not ok or rec == nil then return end  -- skill not yet available
    local modId = 'Stance_SkillBonus_' .. skillId
    -- The closure captures `skillId` by value so each modifier tests only
    -- its own skill column.
    local sid = skillId
    local ok2 = pcall(I.SkillFramework.registerDynamicModifier, sid, modId,
        function() return computeBonusForSkill(sid) end)
    if ok2 then
        effectivenessModifiersRegistered[sid] = true
        debugLog(string.format('Effectiveness modifier registered on skill "%s"', sid),
            'debugIntegrationMessages')
    end
end

-- Called every poll tick. Vanilla skills are registered on the first pass
-- (SF always has them once the Stance skill itself is registered).
-- Modded skills are attempted once their integration is detected, and the
-- guard in ensureEffectivenessModifier makes subsequent calls free.
local function refreshEffectivenessModifiers()
    if not skillRegistered then return end
    -- Vanilla Morrowind skills — always attempt (no-op once registered).
    local VANILLA_SKILLS = {
        'longblade', 'shortblade', 'bluntweapon', 'axe', 'spear',
        'marksman', 'handtohand', 'block', 'armorer', 'security', 'speechcraft',
    }
    for _, sid in ipairs(VANILLA_SKILLS) do
        ensureEffectivenessModifier(sid)
    end
    -- Modded skills — only attempt once the integration is present.
    if integrationPresent('throwing')     then ensureEffectivenessModifier('throwing')      end
    if integrationPresent('staves')       then ensureEffectivenessModifier('staves_staves') end
    if integrationPresent('fishing')      then ensureEffectivenessModifier('fishing_skill') end
    if integrationPresent('simplymining') then ensureEffectivenessModifier('mining_skill')  end
end


local function syncSfToActiveStance()
    if not skillRegistered then return end
    if not (I.SkillFramework and I.SkillFramework.modifySkill) then return end

    local stanceId = activeStanceId or 'commoner'
    local stance = getStanceConfig(stanceId)
    if not stance then return end

    local displayName = formatStanceName(stanceId)
    local attribute = stance.attribute or config.defaultAttribute
    if readSetting('', 'enableAttributeSwap', true) == false then
        attribute = config.defaultAttribute
    end

    -- ─── Tooltip ─────────────────────────────────────────────────────────
    -- Layout:
    --   <lore description>
    --
    --   <Name>   <Attribute>            (mechanic toggle)
    --   Lv N   Core N   +N <Skill>      (mechanic toggle)
    --   N / N xp  (or Mastered)         (mechanic toggle)
    --
    --   [✓] Perk — Short description.
    --   [LvN] Perk — Short description.

    -- Friendly display names for all skill IDs used as bonus targets.
    -- Keeps the tooltip readable without exposing raw SF identifiers.
    local SKILL_LABEL = {
        longblade     = 'Long Blade',
        shortblade    = 'Short Blade',
        bluntweapon   = 'Blunt Weapon',
        axe           = 'Axe',
        spear         = 'Spear',
        marksman      = 'Marksman',
        handtohand    = 'Hand to Hand',
        block         = 'Block',
        armorer       = 'Armorer',
        security      = 'Security',
        speechcraft   = 'Speechcraft',
        throwing      = 'Throwing',
        staves_staves = 'Staves',
        fishing_skill = 'Fishing',
        mining_skill  = 'Mining',
    }

    local coreLevel = getCoreSkillLevel()
    local stLevel   = getStanceLevel(stanceId)
    local stXp      = getStanceXp(stanceId)
    local lines     = { stance.description }

    if readSetting('Tooltip', 'showMechanicTooltips', true) then
        local attrLabel   = attribute:sub(1, 1):upper() .. attribute:sub(2)
        local bonus       = math.floor(effectivenessSkillBonus(stanceId) + 0.5)
        local targetSkill = resolveStanceSkill(stanceId)
        local skillLabel  = (targetSkill and SKILL_LABEL[targetSkill]) or targetSkill or 'none'
        local xpLine      = stLevel < config.maxLevel
            and string.format('%d / %d xp', math.floor(stXp), math.floor(xpForStanceLevel(stLevel)))
            or  'Mastered'

        table.insert(lines, '')
        table.insert(lines, string.format('%s   %s', stance.displayName, attrLabel))
        table.insert(lines, string.format('Lv %d   Core %d   +%d %s', stLevel, coreLevel, bonus, skillLabel))
        table.insert(lines, xpLine)
    end

    -- Perks: name + short description only; no verbose sub-headers.
    if readSetting('Tooltip', 'showPerkTooltips', true) and perksEnabledForStance(stanceId) then
        local unlockedOnly = readSetting('Tooltip', 'tooltipUnlockedOnly', false)
        local first = true
        for _, perk in ipairs(stance.perks) do
            local unlocked = coreLevel >= perk.level
            if unlocked or not unlockedOnly then
                if first then table.insert(lines, ''); first = false end
                local marker = unlocked and '✓' or ('Lv' .. perk.level)
                table.insert(lines, string.format('  [%s] %s — %s',
                    marker, perk.name, perk.description))
            end
        end
    end

    local description = table.concat(lines, '\n')

    -- Each modifySkill field is wrapped in its own pcall so older SF
    -- versions that only accept `description` still get the most
    -- important update without rejecting the whole call.
    local function tryModify(field, value, cached)
        if value == cached then return cached end
        local ok, err = pcall(I.SkillFramework.modifySkill, SKILL_ID, { [field] = value })
        if ok then return value end
        debugLog(string.format('modifySkill failed for field "%s": %s', field, tostring(err)),
            'debugIntegrationMessages')
        return cached
    end

    lastSkillSyncedDescription = tryModify('description', description, lastSkillSyncedDescription)
    lastSkillSyncedName        = tryModify('name', displayName, lastSkillSyncedName)
    lastSkillSyncedAttribute   = tryModify('attribute', attribute, lastSkillSyncedAttribute)
end

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
    { 'Progression', 'xpOnTime' },
    { 'Progression', 'xpOnMerchant' },
    { 'Progression', 'xpOnUpgrade' },
    { 'Progression', 'xpOnMining' },
    { 'Progression', 'xpOnFishing' },
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

-- ─── Perk popup feedback ──────────────────────────────────────────────────

local feedback = { entries = {} }

local function feedbackClamp(value, default, minV, maxV)
    value = tonumber(value) or default
    if value < minV then return minV end
    if value > maxV then return maxV end
    return value
end

-- The notification popup uses a fixed gold-on-dark colour scheme. The
-- previous design exposed six separate R/G/B sliders for text and shadow
-- colour; those settings were almost never touched and bloated the UI, so
-- they're hardcoded here as constants. Anyone who needs different colours
-- can edit these two values directly.
local FEEDBACK_TEXT_COLOR   = util.color.rgb(235 / 255, 217 / 255, 140 / 255)
local FEEDBACK_SHADOW_COLOR = util.color.rgb(32  / 255, 16  / 255, 0   / 255)

-- Lookup: string position label → (relativeX, relativeY, anchorX, anchorY).
-- The label values match the items list in settings.lua's Notifications
-- group, so the player picks them from the dropdown and we resolve here.
local FEEDBACK_LAYOUTS = {
    ['Top Left']      = { 0.04, 0.18, 0.0, 0.5 },
    ['Top Center']    = { 0.50, 0.18, 0.5, 0.5 },
    ['Center']        = { 0.50, 0.50, 0.5, 0.5 },
    ['Bottom Left']   = { 0.04, 0.72, 0.0, 0.5 },
    ['Bottom Center'] = { 0.50, 0.72, 0.5, 0.5 },
}

local function feedbackLayoutForPosition(label)
    local layout = FEEDBACK_LAYOUTS[label] or FEEDBACK_LAYOUTS['Bottom Center']
    return layout[1], layout[2], layout[3], layout[4]
end

local function feedbackReflow()
    local now = core.getSimulationTime()
    for i = #feedback.entries, 1, -1 do
        local entry = feedback.entries[i]
        if not entry or not entry.element or (entry.expiresAt and entry.expiresAt <= now) then
            if entry and entry.element then entry.element:destroy() end
            table.remove(feedback.entries, i)
        end
    end
    local maxVisible = feedbackClamp(readSetting('Notifications', 'popupMaxVisible', 5), 5, 1, 10)
    while #feedback.entries > maxVisible do
        local last = feedback.entries[#feedback.entries]
        if last and last.element then last.element:destroy() end
        table.remove(feedback.entries, #feedback.entries)
    end
    local baseX, baseY, anchorX, anchorY = feedbackLayoutForPosition(
        readSetting('Notifications', 'popupPosition', 'Bottom Center'))
    for i, entry in ipairs(feedback.entries) do
        entry.element.layout.props.relativePosition = util.vector2(baseX, baseY + (i - 1) * 0.045)
        entry.element.layout.props.anchor = util.vector2(anchorX, anchorY)
        entry.element.layout.props.visible = true
        entry.element:update()
    end
end

local function feedbackShow(text)
    if not text or text == '' then return end
    -- 'Disabled' suppresses the notification entirely.
    -- 'Message'  routes through the vanilla ui.showMessage queue.
    -- 'Popup'    (default) renders the in-house notification element below.
    local style = readSetting('Notifications', 'perkMessageStyle', 'Popup')
    if style == 'Disabled' then return end
    if style == 'Message' then
        pcall(ui.showMessage, text)
        return
    end

    local duration = feedbackClamp(readSetting('Notifications', 'popupDuration', 1.35), 1.35, 0.5, 10)
    local element = ui.create {
        layer = 'Notification',
        type = ui.TYPE.Text,
        props = {
            text = text,
            textSize = 22,
            textColor = FEEDBACK_TEXT_COLOR,
            textShadow = true,
            textShadowColor = FEEDBACK_SHADOW_COLOR,
            relativePosition = util.vector2(0.5, 0.72),
            anchor = util.vector2(0.5, 0.5),
            visible = true,
        },
    }
    table.insert(feedback.entries, 1, {
        element = element,
        expiresAt = core.getSimulationTime() + duration,
    })
    feedbackReflow()
end

-- ─── Messaging (single, simple path) ──────────────────────────────────────
-- Everything the player sees about progression goes through `notify`,
-- which respects the Notifications style setting (Popup / Message / off).
-- Two queues drain each tick:
--   * pendingStanceLevelUps — "Commoner is now level 12"
--   * pendingPerkAnnouncements — "Stance 25: Commoner — Merchant's Eye"

local function notify(text)
    if not text or text == '' then return end
    feedbackShow(text)
end

local function drainStanceLevelUps()
    if #pendingStanceLevelUps == 0 then return end
    for _, up in ipairs(pendingStanceLevelUps) do
        local stance = getStanceConfig(up.stanceId)
        local name = (stance and stance.displayName) or up.stanceId
        notify(string.format('%s level %d', name, up.level))
        debugLog(string.format('Stance level-up: %s → %d', up.stanceId, up.level),
            'debugXpMessages')
    end
    pendingStanceLevelUps = {}
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
-- stance gains at that threshold. Perks are tied to the core level, so
-- this is the single place unlock popups originate. Cheap: one
-- getCoreSkillLevel() read per call, only acts on an actual increase.
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

-- ─── HUD indicator (active stance name only, draggable) ──────────────────
--
-- A single-element text overlay that shows the name of the currently
-- active stance. Built on the same draggable pattern Toxicology uses:
--
--   * The HUD lives on the 'Modal' layer so its mouse-event callbacks
--     receive input only when the cursor is visible (inventory/menu modes).
--   * Drag is gated on `canDragHud()` which returns true only when the
--     player is in an inventory-like UI mode, so combat doesn't move it.
--   * Stored X/Y pixel coordinates are kept in player settings via the
--     UI section; an unconfigured position defaults to the relative
--     position (HUD_DEFAULT_X_REL, HUD_DEFAULT_Y_REL) which the user can
--     drag away from. Stored values are clamped to the HUD layer size.
--   * UiModeChanged also fires for hudElement to drop any in-progress
--     drag (no orphaned "still pressed" state across menu transitions).

local hudElement = nil
local currentUiMode = nil

-- Relative defaults — used only when the player hasn't explicitly placed
-- the HUD anywhere yet. Lower-left feels least intrusive to combat.
local HUD_DEFAULT_X_REL = 0.04
local HUD_DEFAULT_Y_REL = 0.94

local function hudLayerSize()
    local ok, layerId = pcall(function() return ui.layers.indexOf('HUD') end)
    if ok and layerId and ui.layers[layerId] and ui.layers[layerId].size then
        return ui.layers[layerId].size
    end
    return util.vector2(1280, 720)
end

local function hudTextSize()
    local v = tonumber(readSetting('HUD', 'hudIndicatorIconSize', 22)) or 22
    if v < 8 then v = 8 end
    if v > 96 then v = 96 end
    return v
end

local function clampHudPosition(pos)
    local layerSize = hudLayerSize()
    return util.vector2(
        math.floor(math.max(0, math.min(pos.x, layerSize.x))),
        math.floor(math.max(0, math.min(pos.y, layerSize.y)))
    )
end

local function hudPosition()
    local layerSize = hudLayerSize()
    local storedX = tonumber(readSetting('HUD', 'hudIndicatorX', 0)) or 0
    local storedY = tonumber(readSetting('HUD', 'hudIndicatorY', 0)) or 0
    -- 0 means "use the default" — matches Toxicology's semantics.
    local x = storedX > 0 and storedX or math.floor(layerSize.x * HUD_DEFAULT_X_REL)
    local y = storedY > 0 and storedY or math.floor(layerSize.y * HUD_DEFAULT_Y_REL)
    return clampHudPosition(util.vector2(x, y))
end

local function storeHudPosition(pos)
    local clamped = clampHudPosition(pos)
    local uiSettings = settingSection('HUD')
    uiSettings:set('hudIndicatorX', clamped.x)
    uiSettings:set('hudIndicatorY', clamped.y)
    return clamped
end

local function isInventoryLikeMode(mode)
    -- Same mode list Toxicology uses. OpenMW reports the regular
    -- inventory/stat/magic/map screen as "Interface", not "Inventory".
    return mode == 'Interface'
        or mode == 'Inventory'
        or mode == 'Container'
        or mode == 'Barter'
        or mode == 'Companion'
end

local function currentModeName()
    local uiInterface = I and I.UI
    if not uiInterface then return nil end
    if uiInterface.getMode then
        local ok, mode = pcall(uiInterface.getMode)
        if ok and mode ~= nil then return mode end
    end
    if currentUiMode ~= nil then return currentUiMode end
    local modes = uiInterface.modes
    if type(modes) == 'table' then return modes[#modes] end
    return nil
end

local function canDragHud()
    if readSetting('HUD', 'hudIndicatorLockPosition', false) then return false end
    return isInventoryLikeMode(currentModeName())
end

local function destroyHud()
    if hudElement then hudElement:destroy(); hudElement = nil end
end

local function ensureHud()
    if hudElement then return hudElement end

    hudElement = ui.create {
        -- Modal layer so mouse events route here when the cursor is up.
        -- Matches Toxicology's HUD layer choice for the same reason.
        layer = 'Modal',
        type = ui.TYPE.Text,
        name = 'StanceHudIndicator',
        props = {
            text = '',
            textSize = hudTextSize(),
            textColor = util.color.rgb(0.92, 0.85, 0.55),
            textShadow = true,
            textShadowColor = util.color.rgb(0, 0, 0),
            position = hudPosition(),
            -- Anchor (0, 1) means the position vector points at the
            -- element's bottom-left corner — the player can drag it
            -- freely without the text getting "stuck" off the screen.
            anchor = util.vector2(0, 1),
            visible = true,
        },
        userData = {
            dragging = false,
            lastMousePos = nil,
        },
    }

    local function rootLayout()
        return hudElement and hudElement.layout
    end

    local function hudMousePress(data, _)
        if not data or data.button ~= 1 or not canDragHud() then return end
        local layout = rootLayout()
        if not layout then return end
        layout.userData = layout.userData or {}
        layout.userData.dragging = true
        layout.userData.lastMousePos = data.position
    end

    local function hudMouseRelease(_, _)
        local layout = rootLayout()
        if layout and layout.userData then
            layout.userData.dragging = false
            layout.userData.lastMousePos = nil
        end
    end

    local function hudMouseMove(data, _)
        local layout = rootLayout()
        if not data or not layout or not layout.userData
            or not layout.userData.dragging or not layout.userData.lastMousePos then return end
        if not canDragHud() then
            layout.userData.dragging = false
            layout.userData.lastMousePos = nil
            return
        end
        local delta = data.position - layout.userData.lastMousePos
        layout.userData.lastMousePos = data.position
        local currentPosition = layout.props.position or hudPosition()
        layout.props.position = storeHudPosition(currentPosition + delta)
        hudElement:update()
    end

    hudElement.layout.events = {
        mousePress   = async:callback(hudMousePress),
        mouseRelease = async:callback(hudMouseRelease),
        mouseMove    = async:callback(hudMouseMove),
    }

    return hudElement
end

local function updateHud()
    if not readSetting('HUD', 'showHudIndicator', true) then
        destroyHud()
        return
    end
    if not activeStanceId then return end
    local stance = getStanceConfig(activeStanceId)
    if not stance then return end
    local el = ensureHud()
    -- ONLY the active stance name — no level, no decoration.
    el.layout.props.text = stance.displayName
    el.layout.props.textSize = hudTextSize()
    el.layout.props.position = hudPosition()
    el.layout.props.visible = true
    el:update()
end

-- UiModeChanged: track the active UI mode so canDragHud() works, and
-- forcibly drop any in-progress drag on a mode transition so we don't
-- leave a "still pressed" flag behind.
local function onUiModeChanged(data)
    if data and data.newMode ~= nil then
        currentUiMode = data.newMode
    elseif data and data.oldMode ~= nil then
        currentUiMode = nil
    end
    if hudElement and hudElement.layout and hudElement.layout.userData then
        hudElement.layout.userData.dragging = false
        hudElement.layout.userData.lastMousePos = nil
    end
end

-- ─── Time-based XP tick ───────────────────────────────────────────────────

local timeTickAccumulator = 0

local function handleTimeTick(dt)
    timeTickAccumulator = timeTickAccumulator + (dt or 0)
    local interval = config.xp.stanceTimeIntervalSec or 10
    while timeTickAccumulator >= interval do
        timeTickAccumulator = timeTickAccumulator - interval
        if activeStanceId then
            grantStanceXp(config.xp.stanceTimeTick or 0.1, 'time', activeStanceId)
        end
    end
end

-- ─── Combat hit handler ───────────────────────────────────────────────────

local combatHitRegistered = false

local function onPlayerCombatHit(attack)
    if not readSetting('', 'enabled', true) then return end
    if not attack then return end
    if attack.attacker and attack.attacker ~= self.object then return end
    if not activeStanceId then return end
    grantStanceXp(config.xp.combatHit or 1.0, 'hit', activeStanceId)
end

local function registerCombatHook()
    if combatHitRegistered then return end
    if not (I.Combat and I.Combat.addOnHitHandler) then return end
    pcall(I.Combat.addOnHitHandler, onPlayerCombatHit)
    combatHitRegistered = true
    debugLog('Registered I.Combat hit handler.', 'debugIntegrationMessages')
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

local function onNGardeParrySuccess(_payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId then
        grantStanceXp(config.xp.blockSuccess or 1.2, 'block', activeStanceId)
    end
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

local function onDualWieldingEquip(payload)
    -- Triggered when Dual Wielding hands the player an off-hand weapon.
    -- payload.Weapon is the Weapon object reference.
    dualWieldingActive = true
    dualWieldingAsOf = core.getSimulationTime()
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
    dualWieldingActive = false
    dualWieldingWeaponRecord = nil
    dualWieldingAsOf = core.getSimulationTime()
    debugLog('Dual Wielding off-hand dismissed.', 'debugDetectionMessages')
end

local function onStanceKillGrant(_payload)
    if not readSetting('', 'enabled', true) then return end
    if activeStanceId then
        grantStanceXp(config.xp.combatKill or 2.0, 'kill', activeStanceId)
    end
end

local function onMerchantTransaction(_payload)
    if not readSetting('', 'enabled', true) then return end
    -- Commoner XP only credits while Commoner is the active stance
    -- (grantStanceXp self-guards, but checking here avoids a wasted call).
    if activeStanceId == 'commoner' then
        grantStanceXp(config.xp.merchantTransaction or 1.5, 'merchant', 'commoner')
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

local function consolePrintInfo(msg)
    if ui.printToConsole and ui.CONSOLE_COLOR then
        ui.printToConsole('[Stance] ' .. tostring(msg), ui.CONSOLE_COLOR.Info)
    else
        print('[Stance] ' .. tostring(msg))
    end
end

local function consolePrintError(msg)
    if ui.printToConsole and ui.CONSOLE_COLOR then
        ui.printToConsole('[Stance] ' .. tostring(msg), ui.CONSOLE_COLOR.Error)
    else
        print('[Stance] ' .. tostring(msg))
    end
end

local function consoleListStances()
    consolePrintInfo(string.format('Core Stance skill level: %d', getCoreSkillLevel()))
    consolePrintInfo(string.format('Active stance: %s',
        activeStanceId and formatStanceName(activeStanceId) or '(none)'))
    consolePrintInfo('Stances  (level · +bonus[skill] · on/off):')
    for _, st in ipairs(config.stances) do
        local active  = (st.id == activeStanceId) and '  [ACTIVE]' or ''
        local enabled = stanceEnabled(st.id) and 'on' or 'off'
        local bonus   = math.floor(effectivenessSkillBonus(st.id) + 0.5)
        local tgt     = STANCE_SKILL_TARGET[st.id]
        local skillLabel = (tgt and not tgt.dynamic and (tgt.vanilla or tgt.modded)) or '?'
        consolePrintInfo(string.format('  %-12s lvl %-3d  +%-2d[%-12s]  %-3s%s',
            st.displayName, getStanceLevel(st.id), bonus, skillLabel, enabled, active))
    end
end

-- Set the CORE Stance skill to a level via Skill Framework.
local function consoleSetCore(level)
    level = math.max(0, math.min(config.maxLevel, math.floor(tonumber(level) or 0)))
    if I.SkillFramework and I.SkillFramework.setSkillLevel then
        local ok = pcall(I.SkillFramework.setSkillLevel, SKILL_ID, level)
        if ok then return level end
    end
    if I.SkillFramework and I.SkillFramework.modifySkill then
        pcall(I.SkillFramework.modifySkill, SKILL_ID, { level = level })
        return level
    end
    return nil
end

-- Set a specific stance's OWN level (and clear its partial XP).
local function consoleSetStance(stanceId, level)
    local state = getStanceState()
    if not state[stanceId] then return false end
    state[stanceId].level = math.max(0, math.min(config.maxLevel, math.floor(tonumber(level) or 0)))
    state[stanceId].xp = 0
    saveStanceState()
    return true
end

local function onConsoleCommand(mode, command, selectedObject)
    local trimmed = tostring(command or ''):match('^%s*(.-)%s*$') or ''
    local root, rest = trimmed:match('^(%S+)%s*(.-)$')
    if root ~= 'stance' then return end

    if rest == '' or rest == 'help' then
        consolePrintInfo('Usage: stance [ list | active | set core <lvl> | set <stanceId> <lvl> | reset | reload ]')
        return true
    end

    if rest == 'list' then consoleListStances(); return true end

    if rest == 'active' or rest == 'info' then
        if activeStanceId then
            local stance = getStanceConfig(activeStanceId)
            local bonus = math.floor(effectivenessSkillBonus(activeStanceId) + 0.5)
            local targetSkill = resolveStanceSkill(activeStanceId) or '—'
            consolePrintInfo(string.format('Active: %s  (stance lvl %d, core %d, +%d→%s, attr %s)',
                formatStanceName(activeStanceId), getStanceLevel(activeStanceId),
                getCoreSkillLevel(), bonus, targetSkill,
                stance and stance.attribute or '?'))
            local np = nextPerk(activeStanceId)
            if np then
                consolePrintInfo(string.format('  Next perk: %s at core Stance skill %d',
                    np.name, np.level))
            else
                consolePrintInfo('  All perks unlocked at the current core skill level.')
            end
        else
            consolePrintInfo('No active stance.')
        end
        return true
    end

    -- set core <level>
    local coreLevel = rest:match('^set%s+core%s+(%-?%d+)$')
    if coreLevel then
        local applied = consoleSetCore(tonumber(coreLevel))
        if applied then
            lastAnnouncedCoreLevel = applied  -- don't spam perk popups for the jump
            consolePrintInfo(string.format('Core Stance skill set to %d', applied))
        else
            consolePrintError('Could not set core skill (Skill Framework setter unavailable).')
        end
        return true
    end

    -- set <stanceId> <level>
    local sId, sLevel = rest:match('^set%s+(%S+)%s+(%-?%d+)$')
    if sId and sLevel then
        if consoleSetStance(sId, tonumber(sLevel)) then
            consolePrintInfo(string.format('%s stance level set to %d',
                formatStanceName(sId), tonumber(sLevel)))
        else
            consolePrintError(string.format('Unknown stance id "%s". Try: stance list', sId))
        end
        return true
    end

    if rest == 'reset' then
        stanceStateCache = defaultStanceState()
        saveStanceState()
        consolePrintInfo('All stance levels reset to start. (Core skill unchanged — use "stance set core <lvl>".)')
        return true
    end

    if rest == 'reload' then
        skillRegistered = false
        classBonusApplied = false
        lastSkillSyncedName = nil
        lastSkillSyncedAttribute = nil
        lastSkillSyncedDescription = nil
        consolePrintInfo('Stance script flagged for re-registration on next tick.')
        return true
    end

    consolePrintError('Bad syntax. Try: stance help')
    return true
end

-- ─── Frame update ─────────────────────────────────────────────────────────

local updateTimer            = config.pollIntervalSec or 0.25
local initRequested          = false
local accumulatedSettingsSync = 0

local function onUpdate(dt)
    dt = tonumber(dt) or 0
    if not readSetting('', 'enabled', true) then
        destroyHud()

        for i = #feedback.entries, 1, -1 do
        local entry = feedback.entries[i]
        if entry and entry.element then
            entry.element:destroy()
        end
        table.remove(feedback.entries, i)
    end
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

    if accumulatedSettingsSync >= 0.5 then
        syncSettingsToGlobal(not initRequested)
        accumulatedSettingsSync = 0
    end

    refreshIntegrations(now)

    if not skillRegistered then registerSkill() end
    if skillRegistered and not classBonusApplied then applyClassBonus() end
    refreshEffectivenessModifiers()

    if not initRequested then
        core.sendGlobalEvent('Stance_RequestInit', { player = self.object })
        initRequested = true
    end

    local resolved = resolveStance(now)
    if resolved then
        applyActiveStance(resolved.id, resolved.reason, now, false)
    end

    syncSfToActiveStance()
    updateHud()
    feedbackReflow()
    checkCoreLevelPerkUnlocks()
    drainStanceLevelUps()
    drainPerkAnnouncements()
end

-- ─── Persistence ──────────────────────────────────────────────────────────

local function onSave()
    return { version = 2 }
end

local function onLoad(_data)
    classBonusApplied = false
    skillRegistered = false
    lastSkillSyncedName = nil
    lastSkillSyncedAttribute = nil
    lastSkillSyncedDescription = nil
    lastSyncedSettingsPayload = nil
    initRequested = false
    timeTickAccumulator = 0
    dualWieldingActive = false
    dualWieldingWeaponRecord = nil
    dualWieldingAsOf = -math.huge
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
    registerCombatHook()
    registerSpellHook()
end

if I.SkillProgression and I.SkillProgression.addSkillUsedHandler then
    pcall(I.SkillProgression.addSkillUsedHandler, onForeignSkillUsed)
end

-- Register "stance" as a console command override. Without this, OpenMW's
-- default console tries to evaluate `stance list` as Lua/mwscript and
-- errors out before our onConsoleCommand handler ever sees it — which is
-- why the console commands appeared dead. addCommandOverride tells the
-- console to treat any line whose first word is "stance" as ours and
-- forward it verbatim to onConsoleCommand. Guarded with pcall because
-- I.Console only exists on OpenMW builds that include the console Lua
-- interface (0.49+); on older builds the commands simply stay unavailable.
if I.Console and I.Console.addCommandOverride then
    pcall(I.Console.addCommandOverride, 'stance')
end

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
        -- UI mode tracking so the HUD knows when it can be dragged.
        UiModeChanged = onUiModeChanged,
    },
    eventHandlers = {
        Stance_KillGrant            = onStanceKillGrant,
        Stance_MerchantTransaction  = onMerchantTransaction,

        -- External mod hooks.
        ngarde_ParrySuccess         = onNGardeParrySuccess,
        -- Simply Mining hooks: credit Pitmen XP on successful ore mines and
        -- broadcast perk-bonus data when mining starts.
        SimplyMining_notifyItem     = onSimplyMiningOreSuccess,
        SimplyMining_startMining    = onSimplyMiningStartMining,
        -- Fishing hooks: credit Angler XP on successful fish catches and
        -- broadcast perk-bonus data for bridge scripts.
        -- NOTE: If your Fishing mod fires a different event name, add an
        -- alias here pointing at the same onFishingCatch handler.
        Fishing_playerCaughtFish    = onFishingCatch,
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
