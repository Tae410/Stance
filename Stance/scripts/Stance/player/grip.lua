--[[
    Stance! — GRIP integration (player/grip.lua)

    GRIP converts weapons between 1H and 2H variants at runtime. It writes two
    maps into the global section 'GRIPRecords':

      OldToNewRecords[origId] = newId   (original → converted)
      NewToOldRecords[newId]  = origId  (converted → original)

    This module owns the GRIP storage lookup and the original-record mapping
    used by stance classification. It requires openmw.storage / types /
    interfaces directly (engine modules), and takes a single injected
    dependency — integrationPresent — so it never reaches back into init.lua.

    Construction (in init.lua, at the GRIP section's original position):
        local grip = require('scripts.stance.player.grip').new({
            integrationPresent = integrationPresent,
        })

    The returned API is behaviour-identical to the former init.lua locals:
        grip.gripOriginalRecordId(currentRecordId) -> originalId | nil
        grip.effectiveWeaponRecord(weaponObj, weaponRec) -> record
        grip.runtimeWeaponRecord(weaponObj, weaponRec) -> record | nil
        grip.gripIsConverted(weaponObj) -> bool | nil   (currently unused)
]]

local storage = require('openmw.storage')
local types   = require('openmw.types')
local I       = require('openmw.interfaces')

local M = {}

function M.new(ctx)
    ctx = ctx or {}
    local integrationPresent = ctx.integrationPresent
        or function() return false end

    -- Cached section handle. Re-read on each lookup because GRIP can rewrite
    -- the conversion table between weapon swaps; the cost is one storage read
    -- per stance evaluation, which is negligible.
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

    -- Fast path: GRIP exposes I.GRIP.isConverted(weapon). Returns nil ("unknown")
    -- when the interface isn't available. Currently unused by callers, kept for
    -- API parity with the pre-extraction code.
    local function gripIsConverted(weaponObj)
        if not (I.GRIP and I.GRIP.isConverted) then return nil end  -- unknown
        local ok, converted = pcall(I.GRIP.isConverted, weaponObj)
        if not ok then return nil end
        return converted == true
    end

    -- Effective weapon record.
    --
    -- GRIP creates a NEW weapon record when converting between 1H and 2H.
    -- If GRIP converted the weapon, returns the ORIGINAL record (so a converted
    -- weapon still classifies by the player's intended type); otherwise returns
    -- the weapon's current record. Falls back to the current record on error.
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

    -- Runtime GRIP-converted record. Used for stances that intentionally depend
    -- on converted handedness behavior — returns the current record as-is.
    local function runtimeWeaponRecord(weaponObj, weaponRec)
        if not weaponRec then
            return nil
        end
        return weaponRec
    end

    return {
        gripOriginalRecordId  = gripOriginalRecordId,
        effectiveWeaponRecord = effectiveWeaponRecord,
        runtimeWeaponRecord   = runtimeWeaponRecord,
        gripIsConverted       = gripIsConverted,
    }
end

return M
