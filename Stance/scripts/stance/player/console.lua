--[[
    Stance! — Console commands (player/console.lua)

    Implements the `stance` console command: list / active / set core <lvl> /
    set <stanceId> <lvl> / reset / reload, plus the console print helpers.

    init.lua keeps the actual `onConsoleCommand` engine handler as a one-line
    wrapper that forwards to console.handle(...). The command parsing and all
    its output live here.

    Construction (in init.lua, at the console section's original position):
        local console = require('scripts.stance.player.console').new({ ... })

    The handle() function returns the same values the old onConsoleCommand did:
    true when the line was a "stance" command (handled), nil otherwise.

    Writes back into init.lua state are done through injected callbacks
    (setLastAnnouncedCoreLevel, resetStanceState, flagReload) so this module
    never touches init.lua locals directly.
]]

local M = {}

function M.new(ctx)
    ctx = ctx or {}

    local ui                      = ctx.ui
    local I                       = ctx.I
    local SKILL_ID                = ctx.SKILL_ID
    local config                  = ctx.config
    local getCoreSkillLevel       = ctx.getCoreSkillLevel
    local getActiveStance         = ctx.getActiveStance
    local formatStanceName        = ctx.formatStanceName
    local getStanceConfig         = ctx.getStanceConfig
    local stanceEnabled           = ctx.stanceEnabled
    local effectivenessSkillBonus = ctx.effectivenessSkillBonus
    local STANCE_SKILL_TARGET     = ctx.STANCE_SKILL_TARGET
    local getStanceLevel          = ctx.getStanceLevel
    local resolveStanceSkill      = ctx.resolveStanceSkill
    local nextPerk                = ctx.nextPerk
    local getStanceState          = ctx.getStanceState
    local saveStanceState         = ctx.saveStanceState
    -- Callbacks that mutate init.lua state.
    local setLastAnnouncedCoreLevel = ctx.setLastAnnouncedCoreLevel
    local resetStanceState          = ctx.resetStanceState
    local flagReload                = ctx.flagReload

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
            getActiveStance() and formatStanceName(getActiveStance()) or '(none)'))
        consolePrintInfo('Stances  (level · +bonus[skill] · on/off):')
        for _, st in ipairs(config.stances) do
            local active  = (st.id == getActiveStance()) and '  [ACTIVE]' or ''
            local enabled = stanceEnabled(st.id) and 'on' or 'off'
            local tgt     = STANCE_SKILL_TARGET[st.id]
            local skillLabel = (tgt and not tgt.dynamic and (tgt.vanilla or tgt.modded)) or '?'
            local bonus   = math.floor(effectivenessSkillBonus(st.id) + 0.5)
            consolePrintInfo(string.format('  %-12s lvl %-3d  +%-2d[%-12s]  %-3s%s',
                st.displayName, getStanceLevel(st.id), bonus, skillLabel, enabled, active))
        end
    end

    -- Set the CORE Stance skill to a level via Skill Framework.
    -- Per the SF docs, getSkillStat(id) returns a stat table whose .base
    -- field can be written directly to set the actor's current level.
    local function consoleSetCore(level)
        level = math.max(0, math.min(config.maxLevel, math.floor(tonumber(level) or 0)))
        if I.SkillFramework and I.SkillFramework.getSkillStat then
            local ok, stat = pcall(I.SkillFramework.getSkillStat, SKILL_ID)
            if ok and stat then
                pcall(function()
                    stat.base = level
                    stat.progress = 0
                end)
                return level
            end
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

    local function handle(mode, command, selectedObject)
        local trimmed = tostring(command or ''):match('^%s*(.-)%s*$') or ''
        local root, rest = trimmed:match('^(%S+)%s*(.-)$')

        -- Support BOTH:
        --   stance list
        -- and custom console mode:
        --   [stance] list
        if tostring(mode or ''):lower() == 'stance' then
            rest = trimmed
            root = 'stance'
        end

        if not root or string.lower(root) ~= 'stance' then
            return nil
        end

        if rest == '' or rest == 'help' then
            consolePrintInfo('Usage: stance [ list | active | set core <lvl> | set <stanceId> <lvl> | reset | reload ]')
            return true
        end

        if rest == 'list' then consoleListStances(); return true end

        if rest == 'active' or rest == 'info' then
            if getActiveStance() then
                local stance = getStanceConfig(getActiveStance())
                local bonus = math.floor(effectivenessSkillBonus(getActiveStance()) + 0.5)
                local targetSkill = resolveStanceSkill(getActiveStance()) or '—'
                consolePrintInfo(string.format('Active: %s  (stance lvl %d, core %d, +%d→%s, attr %s)',
                    formatStanceName(getActiveStance()), getStanceLevel(getActiveStance()),
                    getCoreSkillLevel(), bonus, targetSkill,
                    stance and stance.attribute or '?'))
                local np = nextPerk(getActiveStance())
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
                setLastAnnouncedCoreLevel(applied)  -- don't spam perk popups for the jump
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
            resetStanceState()
            consolePrintInfo('All stance levels reset to start. (Core skill unchanged — use "stance set core <lvl>".)')
            return true
        end

        if rest == 'reload' then
            flagReload()
            consolePrintInfo('Stance script flagged for re-registration on next tick.')
            return true
        end

        consolePrintError('Bad syntax. Try: stance help')
        return true
    end

    return {
        handle = handle,
    }
end

return M
