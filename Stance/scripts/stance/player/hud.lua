--[[
    Stance! — HUD indicator + perk-feedback popups (player/hud.lua)

    Owns everything the player sees as non-diegetic UI:
      * Draggable stance-name HUD text element on the 'Modal' layer.
      * In-house perk-unlock notification popups (or vanilla ui.showMessage
        routing), with configurable position, duration, and stack limit.
      * `notify(text)` — the single entry-point for all stance-progression
        messages (level-ups, perk unlocks). init.lua should route every
        player-visible message through this.

    The HUD element lives on the 'Modal' layer (same as Toxicology) so it
    only receives mouse events when the cursor is visible. Dragging is gated
    on `canDragHud()`, which returns true only in inventory-like UI modes.
    Stored X/Y pixel coordinates live in the 'HUD' settings section; an
    unconfigured position defaults to the relative lower-left corner.

    Dependencies (injected via ctx):
        ui           — openmw.ui
        util         — openmw.util
        core         — openmw.core
        async        — openmw.async
        I            — openmw.interfaces  (for I.UI.getMode)
        readSetting  — function(group, key, default) → value
        settingSection — function(groupSuffix) → storage section
        getActiveStance  — function() → activeStanceId (string|nil)
        getStanceConfig  — function(stanceId) → stance table | nil

    Construction (in init.lua, after the HUD section's original position):
        local hud = require('scripts.stance.player.hud').new({
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

    The returned API matches the former init.lua locals exactly:
        hud.updateHud()
        hud.destroyHud()
        hud.feedbackReflow()
        hud.feedbackShow(text)
        hud.notify(text)
        hud.onUiModeChanged(data)
        hud.destroyAllFeedback()   — clears all popup entries (used in onUpdate disable branch)
]]

local M = {}

function M.new(ctx)
    ctx = ctx or {}

    local ui             = ctx.ui             or require('openmw.ui')
    local util           = ctx.util           or require('openmw.util')
    local core           = ctx.core           or require('openmw.core')
    local async          = ctx.async          or require('openmw.async')
    local I              = ctx.I              or require('openmw.interfaces')
    local readSetting    = ctx.readSetting    or function() end
    local settingSection = ctx.settingSection or function() return { set = function() end } end
    local getActiveStance = ctx.getActiveStance or function() return nil end
    local getStanceConfig = ctx.getStanceConfig or function() return nil end
    local formatStanceName = ctx.formatStanceName or function(id)
        local s = getStanceConfig(id); return (s and s.displayName) or 'Unknown'
    end

    -- ── HUD state ─────────────────────────────────────────────────────────

    local hudElement     = nil
    local currentUiMode  = nil

    -- Relative defaults — used only when the player hasn't explicitly placed
    -- the HUD anywhere yet. Lower-left feels least intrusive to combat.
    local HUD_DEFAULT_X_REL = 0.04
    local HUD_DEFAULT_Y_REL = 0.94

    -- ── HUD helpers ───────────────────────────────────────────────────────

    local function hudLayerSize()
        local ok, layerId = pcall(function() return ui.layers.indexOf('HUD') end)
        if ok and layerId and ui.layers[layerId] and ui.layers[layerId].size then
            return ui.layers[layerId].size
        end
        return util.vector2(1280, 720)
    end

    local function hudTextSize()
        local v = tonumber(readSetting('HUD', 'hudIndicatorIconSize', 22)) or 22
        if v < 8  then v = 8  end
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
        -- Same mode list Toxicology uses.
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
                -- Anchor (0,1) → position vector points at the element's
                -- bottom-left corner.
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
        local activeId = getActiveStance()
        if not activeId then return end
        local stance = getStanceConfig(activeId)
        if not stance then return end
        local el = ensureHud()
        -- ONLY the active stance name (with any Spellsword imbue prefix) —
        -- no level, no other decoration.
        el.layout.props.text     = formatStanceName(activeId)
        el.layout.props.textSize = hudTextSize()
        el.layout.props.position = hudPosition()
        el.layout.props.visible  = true
        el:update()
    end

    -- UiModeChanged: track the active UI mode so canDragHud() works, and
    -- forcibly drop any in-progress drag on a mode transition.
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

    -- ── Perk-feedback popup state ─────────────────────────────────────────

    local feedback = { entries = {} }

    -- Fixed gold-on-dark colour scheme.
    local FEEDBACK_TEXT_COLOR   = util.color.rgb(235 / 255, 217 / 255, 140 / 255)
    local FEEDBACK_SHADOW_COLOR = util.color.rgb(32  / 255, 16  / 255, 0   / 255)

    local FEEDBACK_LAYOUTS = {
        ['Top Left']      = { 0.04, 0.18, 0.0, 0.5 },
        ['Top Center']    = { 0.50, 0.18, 0.5, 0.5 },
        ['Center']        = { 0.50, 0.50, 0.5, 0.5 },
        ['Bottom Left']   = { 0.04, 0.72, 0.0, 0.5 },
        ['Bottom Center'] = { 0.50, 0.72, 0.5, 0.5 },
    }

    local function feedbackClamp(value, default, minV, maxV)
        value = tonumber(value) or default
        if value < minV then return minV end
        if value > maxV then return maxV end
        return value
    end

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
        -- 'Disabled' → suppress entirely.
        -- 'Message'  → vanilla ui.showMessage queue.
        -- 'Popup'    (default) → in-house notification element.
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

    -- Single public entry-point for all progression messages.
    local function notify(text)
        if not text or text == '' then return end
        feedbackShow(text)
    end

    -- Clear all popup entries — called from init.lua's "mod disabled" branch
    -- in onUpdate.
    local function destroyAllFeedback()
        for i = #feedback.entries, 1, -1 do
            local entry = feedback.entries[i]
            if entry and entry.element then entry.element:destroy() end
            table.remove(feedback.entries, i)
        end
    end

    return {
        updateHud          = updateHud,
        destroyHud         = destroyHud,
        feedbackReflow     = feedbackReflow,
        feedbackShow       = feedbackShow,
        notify             = notify,
        onUiModeChanged    = onUiModeChanged,
        destroyAllFeedback = destroyAllFeedback,
    }
end

return M
