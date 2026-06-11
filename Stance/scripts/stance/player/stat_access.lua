--[[
    Stance! — Stat Access (player/stat_access.lua)

    A tiny, dependency-free wrapper around the OpenMW stat APIs that several
    Stance modules touch (attribute stats and dynamic stats). Centralising the
    `types.Actor.stats.*` calls keeps the build-version risk in one place: if a
    future OpenMW release renames or moves these accessors, this is the only
    file that has to change.

    OpenMW stat accessor shape (0.49+):
      types.Actor.stats.attributes          → table of per-attribute accessor fns
      types.Actor.stats.attributes.strength(actor) → stat table { base, modified, damage, modifier }
      types.Actor.stats.dynamic.health(actor)      → stat table { base, modified, current }

    This module requires `openmw.types` directly (engine module, no injection needed).
]]

local types = require('openmw.types')

local M = {}

-- Returns a table {attrName → stat} for the given actor, or nil on any error.
-- Uses the correct OpenMW accessor form: types.Actor.stats.attributes[name](actor).
function M.getActorAttrs(actor)
    if not actor then return nil end
    local attrTable = types.Actor.stats and types.Actor.stats.attributes
    if not attrTable then return nil end

    local result = {}
    local ATTR_NAMES = {
        'strength', 'intelligence', 'willpower',
        'agility', 'speed', 'endurance',
        'personality', 'luck',
    }
    local anyOk = false
    for _, name in ipairs(ATTR_NAMES) do
        local accessor = attrTable[name]
        if accessor then
            local ok, stat = pcall(accessor, actor)
            if ok and stat then
                result[name] = stat
                anyOk = true
            end
        end
    end
    if not anyOk then
        -- NPC-specific fallback for builds that separate NPC from generic Actor.
        local npcAttrTable = types.NPC and types.NPC.stats and types.NPC.stats.attributes
        if npcAttrTable then
            for _, name in ipairs(ATTR_NAMES) do
                local accessor = npcAttrTable[name]
                if accessor then
                    local ok, stat = pcall(accessor, actor)
                    if ok and stat then result[name] = stat; anyOk = true end
                end
            end
        end
    end
    return anyOk and result or nil
end

-- Returns a table of dynamic stat accessors { health, magicka, fatigue }
-- using the correct OpenMW form: types.Actor.stats.dynamic.health(actor).
-- No internal pcall by design: callers keep their existing pcall around both
-- the read and the write so error behaviour is unchanged.
function M.dynamic(actor)
    local dyn = types.Actor.stats and types.Actor.stats.dynamic
    if not dyn then return {} end
    return {
        health  = dyn.health  and dyn.health(actor),
        magicka = dyn.magicka and dyn.magicka(actor),
        fatigue = dyn.fatigue and dyn.fatigue(actor),
    }
end

-- Returns the SkillStat for one vanilla skill on the actor, or nil on error.
-- Uses the engine-native accessor types.NPC.stats.skills.<id>(actor), whose
-- returned table has a writable `.modifier` field (and an auto-recalculated
-- `.modified`) — the same shape as attribute stats. This is how a skill bonus
-- is applied reliably to a VANILLA skill; Skill Framework's
-- registerDynamicModifier only governs SF's own custom skills.
function M.getSkillStat(actor, skillId)
    if not actor or not skillId then return nil end
    local skillTable = types.NPC and types.NPC.stats and types.NPC.stats.skills
    if not skillTable then return nil end
    local accessor = skillTable[skillId]
    if not accessor then return nil end
    local ok, stat = pcall(accessor, actor)
    if ok and stat then return stat end
    return nil
end

return M
