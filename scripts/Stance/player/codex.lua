--[[
    Stance Codex — a hotkey-toggled overlay listing every stance and its
    current progress: level, perk-tier progress, and governing attribute, with
    the active stance highlighted. Purely informational; no clicking, no
    gameplay effect, nothing it reads is mutated.

    Built the same way the rest of this mod's UI is: ui.create on the 'Modal'
    layer (the same layer the HUD indicator and feedback popups already use),
    plain Text widgets with a shadow for legibility, no background panel (this
    mod has never used one, to avoid an unverified texture-path assumption).

    The hotkey is read fresh from settings on every onKeyPress (mirrors
    StanceWheel/wheel.lua's own activationKey pattern exactly — same
    "build a KEY_BY_NAME table, drop any name the running build's input.KEY
    doesn't actually expose" approach), so a settings change takes effect
    immediately without needing a reload.

    While open, the whole list rebuilds about once a second (see api.update)
    so level/perk changes during play show up live — throttled, not
    per-frame, since rebuilding ~20 rows every single frame would be wasteful
    for a feature that is pure information, not combat-critical feedback like
    the HUD indicator.
]]

local M = {}

function M.new(ctx)
    local ui      = ctx.ui
    local async   = ctx.async
    local util    = ctx.util
    local input   = ctx.input
    local config  = ctx.config
    local stanceEnabled     = ctx.stanceEnabled     or function() return true end
    local getStanceLevel    = ctx.getStanceLevel    or function() return 5 end
    local formatStanceName  = ctx.formatStanceName  or function(id) return tostring(id) end
    local getActiveStance   = ctx.getActiveStance   or function() return nil end
    local readSetting       = ctx.readSetting       or function(_, _, d) return d end

    local api = {}

    -- ── Key-name -> KeyCode map ─────────────────────────────────────────────
    -- Mirrors StanceWheel/wheel.lua's own KEY_BY_NAME construction exactly:
    -- only names the running build's input.KEY actually exposes survive, so a
    -- missing enum member just drops that option rather than erroring.
    local KEY_BY_NAME = {}
    do
        local pairsToTry = {
            K = 'K', L = 'L', O = 'O', P = 'P', U = 'U', I = 'I',
            G = 'G', H = 'H', J = 'J', N = 'N', M = 'M', C = 'C', V = 'V',
            B = 'B', X = 'X', Z = 'Z', R = 'R', T = 'T', Y = 'Y',
            ['Tab'] = 'Tab',
            ['Caps Lock'] = 'CapsLock',
            ['Left Bracket'] = 'LeftBracket',
            ['Right Bracket'] = 'RightBracket',
        }
        local KEY = (input and input.KEY) or {}
        for displayName, enumName in pairs(pairsToTry) do
            if KEY[enumName] ~= nil then
                KEY_BY_NAME[displayName] = KEY[enumName]
            end
        end
    end

    local function codexKeyCode()
        local name = readSetting('Interface', 'codexHotkey', 'K')
        return KEY_BY_NAME[name] or KEY_BY_NAME['K'] or (input and input.KEY and input.KEY.K)
    end

    local function isCodexKey(key)
        local code = codexKeyCode()
        return code ~= nil and key and key.code == code
    end

    -- ── State ────────────────────────────────────────────────────────────────
    local isOpen        = false
    local elements       = {}     -- every ui element currently on screen, in order
    local refreshAccum   = 0
    local REFRESH_INTERVAL = 1.0  -- seconds; while open, rebuild about this often

    local TITLE_COLOR    = util.color.rgb(0.92, 0.85, 0.55)
    local ACTIVE_COLOR   = util.color.rgb(1.00, 0.85, 0.35)
    local NORMAL_COLOR   = util.color.rgb(0.92, 0.92, 0.92)
    local DISABLED_COLOR = util.color.rgb(0.55, 0.55, 0.55)
    local HINT_COLOR     = util.color.rgb(0.65, 0.65, 0.65)

    local ROW_H  = 0.027
    local BASE_Y = 0.10

    local function closeCodex()
        for _, el in ipairs(elements) do
            pcall(function() el:destroy() end)
        end
        elements = {}
        isOpen = false
        refreshAccum = 0
    end
    api.close = closeCodex

    local function addLine(index, text, color)
        local ok, el = pcall(function()
            return ui.create {
                layer = 'Modal',
                type = ui.TYPE.Text,
                props = {
                    text             = text,
                    textSize         = 18,
                    textColor        = color,
                    textShadow       = true,
                    relativePosition = util.vector2(0.5, BASE_Y + (index - 1) * ROW_H),
                    anchor           = util.vector2(0.5, 0.5),
                    visible          = true,
                },
            }
        end)
        if ok and el then table.insert(elements, el) end
    end

    -- 0..4: how many of the 25/50/75/100 perk-tier thresholds this stance
    -- level has reached. Perks gate on the STANCE'S OWN level (see perks.lua's
    -- `cl = getStanceLevel(sid)`), the same value shown here, so this always
    -- agrees with what actually unlocks in play.
    local PERK_TIERS = { 25, 50, 75, 100 }
    local function perkTiersReached(level)
        local n = 0
        for _, threshold in ipairs(PERK_TIERS) do
            if level >= threshold then n = n + 1 end
        end
        return n
    end

    -- Builds (or rebuilds) the full list from scratch. Cheap enough to call
    -- about once a second (see api.update) — ~20 short-lived Text elements,
    -- not a per-frame operation.
    local function rebuild()
        for _, el in ipairs(elements) do
            pcall(function() el:destroy() end)
        end
        elements = {}

        local activeId = getActiveStance()
        local rows = {}
        for _, def in ipairs(config.stances or {}) do
            if def.id then
                table.insert(rows, { id = def.id, name = formatStanceName(def.id), attribute = def.attribute })
            end
        end
        table.sort(rows, function(a, b) return a.name < b.name end)

        local i = 1
        addLine(i, 'Stance Codex', TITLE_COLOR); i = i + 1
        addLine(i, string.format('%-15s %-8s %-10s %s', 'Stance', 'Level', 'Perks', 'Attribute'), HINT_COLOR); i = i + 1

        for _, row in ipairs(rows) do
            local level   = tonumber(getStanceLevel(row.id)) or 5
            local enabled = stanceEnabled(row.id)
            local tiers   = perkTiersReached(level)
            local isActive = (row.id == activeId)
            local marker = isActive and '> ' or '  '
            local attribute = row.attribute and (row.attribute:sub(1, 1):upper() .. row.attribute:sub(2)) or '-'
            local text = string.format('%s%-13s Lv %-5d Perks %d/4   %s',
                marker, row.name, level, tiers, attribute)
            if not enabled then text = text .. '  (disabled)' end
            local color = isActive and ACTIVE_COLOR or (enabled and NORMAL_COLOR or DISABLED_COLOR)
            addLine(i, text, color); i = i + 1
        end

        local keyName = readSetting('Interface', 'codexHotkey', 'K')
        addLine(i, string.format('(Press %s to close)', tostring(keyName)), HINT_COLOR)
    end

    local function openCodex()
        isOpen = true
        refreshAccum = 0
        rebuild()
    end

    local function toggleCodex()
        if isOpen then closeCodex() else openCodex() end
    end

    -- Throttled live refresh while open; a no-op entirely while closed.
    function api.update(dt)
        if not isOpen then return end
        refreshAccum = refreshAccum + (tonumber(dt) or 0)
        if refreshAccum < REFRESH_INTERVAL then return end
        refreshAccum = 0
        rebuild()
    end

    function api.onKeyPress(key)
        if not isCodexKey(key) then return end
        if readSetting('Interface', 'enableStanceCodex', true) == false then return end
        toggleCodex()
    end

    return api
end

return M
