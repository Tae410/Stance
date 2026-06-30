--[[
    Stance! — HUD indicator (icon + name) + perk-feedback popups (player/hud.lua)

    Owns everything the player sees as non-diegetic UI:
      * Draggable stance INDICATOR on the 'Modal' layer. The indicator is a
        vertical stack: a top row holding the active stance's icon (a .dds from
        icons/Stance/) followed by a small icon for each active name-prefix
        decoration (Spellsword imbue, Fortified, Sneaky) rendered BESIDE the
        stance icon, and — optionally — the stance name (carrying the same
        prefixes) beneath it. The prefix icons mirror the name decorations, so
        the two always agree. Icon size is configurable; the prefix icons and
        the name scale with it. If a stance has no icon, or the texture fails to
        load, the indicator degrades gracefully to a name-only label so it is
        never blank.
      * In-house perk-unlock notification popups (or vanilla ui.showMessage
        routing), with configurable position, duration, and stack limit.
      * `notify(text)` — the single entry-point for all stance-progression
        messages (level-ups, perk unlocks). init.lua routes every
        player-visible message through this.

    The indicator lives on the 'Modal' layer (same as Toxicology) so it only
    receives mouse events when the cursor is visible. Dragging is gated on
    `canDragHud()`, which returns true only in inventory-like UI modes. Stored
    X/Y pixel coordinates live in the 'HUD' settings section; an unconfigured
    position defaults to the relative lower-left corner.

    The icon is resolved from the stance config's `icon` field (a VFS path,
    e.g. 'icons/Stance/Arcanist.dds'). Textures are created once via
    ui.texture and cached by path. The indicator element is only rebuilt when
    its visible content actually changes (stance, icon presence, name,
    name-visibility, or icon size) — the common per-tick path is a cheap
    position refresh, with name-only changes patched in place.

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
        formatStanceName — function(stanceId) → decorated display name

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
    -- Ordered VFS icon paths for the name-prefix decorations active on the current
    -- stance (Sneaky / Fortified / Spellsword imbue). Mirrors the same conditions
    -- that decorate the stance NAME, so the icons and the name always agree. The
    -- icons are rendered in a row beside the stance icon (see buildChildren).
    local getActivePrefixIcons = ctx.getActivePrefixIcons or function() return {} end
    -- Ordered list of active buff bars to stack under the stance name. Each entry:
    -- { key, ratio (0..1), tex (vfs path), r, g, b }. nil/empty when none active.
    local getActiveBars = ctx.getActiveBars or function() return nil end
    -- Live Muse idle-performance status (song/stance/notes/time) or nil, for the
    -- in-HUD performance readout shown only while the Muse stance is performing.
    local getMusePerformanceStatus = ctx.getMusePerformanceStatus or function() return nil end
    -- Brawler gauntlet tier detection (none/light/medium/heavy) for dynamic icon.
    local getBrawlerGauntletTier = ctx.getBrawlerGauntletTier or function() return 'none' end
    local getMuseCurrentInstrument = ctx.getMuseCurrentInstrument or function() return nil end
    -- Bardcraft instrument profile name -> dedicated Muse icon. BassFlute and
    -- PanFlute (Bardcraft's two flute profiles) share the one Flute icon
    -- provided; instrument types with no dedicated icon (Harp, Lyre, ...)
    -- simply fall through to the stance's default icon below.
    local MUSE_INSTRUMENT_ICON = {
        Lute      = 'icons/Stance/Muse_Lute.dds',
        Drum      = 'icons/Stance/Muse_Drum.dds',
        Fiddle    = 'icons/Stance/Muse_Fiddle.dds',
        Ocarina   = 'icons/Stance/Muse_Ocarina.dds',
        BassFlute = 'icons/Stance/Muse_Flute.dds',
        PanFlute  = 'icons/Stance/Muse_Flute.dds',
    }

    -- ── HUD state ─────────────────────────────────────────────────────────

    local hudElement       = nil
    local currentUiMode    = nil
    local currentStructSig = nil   -- structural signature of what's on screen
    local currentName      = nil   -- last name text rendered (for in-place patch)
    local currentMuseText  = nil   -- last Muse performance line rendered (in-place patch)
    -- Live references for patching each stacked bar's fill width per tick without
    -- rebuilding the element. Captured at build time (props tables are held by
    -- reference in the layout, same as the StanceName patch). One entry per active
    -- bar: { props = fillProps, w, h, ratio }.
    local barFillList      = {}
    local textureCache     = {}    -- [vfsPath] = TextureResource | false (load failed)

    -- Relative defaults — used only when the player hasn't explicitly placed
    -- the indicator anywhere yet. Lower-left feels least intrusive to combat.
    local HUD_DEFAULT_X_REL = 0.04
    local HUD_DEFAULT_Y_REL = 0.94

    -- Gold-on-black to match the rest of the mod's UI.
    local NAME_TEXT_COLOR   = util.color.rgb(0.92, 0.85, 0.55)
    local NAME_SHADOW_COLOR = util.color.rgb(0, 0, 0)
    -- Stacked buff bars (resonance / smoker / muse): height as a fraction of the
    -- bar width, a dim track for the empty portion, and a small vertical gap. Each
    -- bar's FILL colour is supplied per-bar by getActiveBars (red/purple/light-blue
    -- for resonance phases, orange for smoking, yellow for muse).
    local BAR_HEIGHT_FRAC = 0.16
    local BAR_GAP_PX      = 1
    local BAR_TRACK_TINT  = util.color.rgb(0.28, 0.28, 0.30)
    local ICON_TINT         = util.color.rgb(1, 1, 1)
    -- Center children horizontally (cross axis) when the enum is available;
    -- if not, the key is simply absent and the engine defaults to Start.
    local CENTER_ALIGN      = (ui.ALIGNMENT and ui.ALIGNMENT.Center) or nil

    -- ── Prefix icons (rendered beside the stance icon) ────────────────────
    -- The active name-prefix decorations (Sneaky / Fortified / Spellsword imbue)
    -- are shown as small icons in a horizontal row immediately to the RIGHT of
    -- the stance icon — not overlaid inside it. Their VFS paths come from
    -- prefixes.getActivePrefixIcons(); each is loaded (and cached) through the
    -- same textureFor() path as the stance icons, so a missing/failed texture
    -- simply means that one icon is skipped — the matching name prefix still
    -- shows regardless. Sizing is a fraction of the stance icon so they read as
    -- secondary indicators; tweak the fraction here to taste.
    local PREFIX_ICON_FRAC     = 0.66   -- prefix icon edge as a fraction of the stance icon edge
    local PREFIX_ICON_MIN      = 14     -- ...but never smaller than this (px)
    local PREFIX_ICON_GAP_FRAC = 0.10   -- horizontal gap before each prefix icon, fraction of icon edge
    local PREFIX_ICON_GAP_MIN  = 2      -- ...minimum gap (px)

    -- ── Sizing ────────────────────────────────────────────────────────────

    -- The on-screen pixel size of the stance icon. Reuses the existing
    -- 'hudIndicatorIconSize' setting (whose key always implied an icon).
    local function hudIconSize()
        local v = tonumber(readSetting('HUD', 'hudIndicatorIconSize', 48)) or 48
        if v < 8  then v = 8  end
        if v > 96 then v = 96 end
        return math.floor(v)
    end

    -- Name label size, derived from the icon size so a single knob governs the
    -- whole indicator, but clamped so the name stays readable at any icon size.
    local function nameTextSize(iconPx)
        local v = math.floor(iconPx * 0.46 + 0.5)
        if v < 12 then v = 12 end
        if v > 28 then v = 28 end
        return v
    end

    local function showStanceName()
        if readSetting('HUD', 'hudShowStanceName', true) then return true end
        return false
    end

    -- ── Position helpers ──────────────────────────────────────────────────

    local function hudLayerSize()
        local ok, layerId = pcall(function() return ui.layers.indexOf('HUD') end)
        if ok and layerId and ui.layers[layerId] and ui.layers[layerId].size then
            return ui.layers[layerId].size
        end
        return util.vector2(1280, 720)
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

    -- ── UI-mode / drag gating ─────────────────────────────────────────────

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
        currentStructSig = nil
        currentName      = nil
    end

    -- ── Texture / icon resolution ─────────────────────────────────────────

    local function textureFor(path)
        if not path or path == '' then return nil end
        local cached = textureCache[path]
        if cached ~= nil then
            return cached or nil
        end
        local ok, tex = pcall(function() return ui.texture { path = path } end)
        if ok and tex then
            textureCache[path] = tex
            return tex
        end
        -- Remember the failure so we don't retry every tick.
        textureCache[path] = false
        return nil
    end

    local function iconPathFor(stanceId)
        local s = getStanceConfig(stanceId)
        local basePath = s and s.icon or nil
        
        -- Dynamic icon for Brawler stance based on equipped gauntlets
        if stanceId == 'brawler' and basePath then
            local tier = getBrawlerGauntletTier()
            if tier == 'light' then
                return 'icons/Stance/LightGauntlets.dds'
            elseif tier == 'medium' then
                return 'icons/Stance/MediumGauntlets.dds'
            elseif tier == 'heavy' then
                return 'icons/Stance/HeavyGauntlets.dds'
            end
            -- tier == 'none' falls through to return basePath
        end

        -- Dynamic icon for Muse stance based on the instrument currently
        -- being played (set the instant Bardcraft's PerformStart event
        -- fires; cleared on PerformStop, so nil outside any performance).
        if stanceId == 'muse' and basePath then
            local instrument = getMuseCurrentInstrument()
            local instIcon = instrument and MUSE_INSTRUMENT_ICON[instrument]
            if instIcon then return instIcon end
        end
        
        return basePath
    end

    -- ── Indicator construction ────────────────────────────────────────────

    local function rootLayout()
        return hudElement and hudElement.layout
    end

    -- Drag handlers operate on the root (Flex) layout. Child mouse events
    -- propagate up to the root, so dragging works anywhere on the indicator.
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

    -- Build the child layouts for the indicator: [icon-row?] then [name?].
    -- The name is shown when the toggle is on OR when there is no icon (so the
    -- indicator is never empty). When `prefixTexes` is a non-empty list (one or
    -- more active prefix decorations AND a stance icon is present), the stance
    -- icon and the prefix icons are laid in a horizontal Flex row, so the prefix
    -- icons sit BESIDE the stance icon rather than overlaid inside it. With no
    -- prefixes the stance icon is added bare, exactly as before, so the common
    -- case is unchanged. The name row below is unaffected either way.
    -- Compact one-line Muse performance readout for the HUD, or nil when no idle
    -- performance is in progress. Mirrors the tooltip data (song / inspired stance /
    -- note progress / time banked) in a single always-visible line so the player can
    -- track a performance without opening the skills menu.
    local function museStatusText()
        if not readSetting('HUD', 'hudShowMusePerformance', true) then return nil end
        local ps = getMusePerformanceStatus()
        if not ps then return nil end
        local t = math.max(0, math.floor((ps.accum or 0) + 0.5))
        local mm, ss = math.floor(t / 60), t % 60
        local target = ps.stance and formatStanceName(ps.stance) or '?'
        return string.format("Song: '%s' -> %s   %d/%d notes   %d:%02d",
            ps.songTitle or '?', target, ps.successes or 0, ps.notes or 0, mm, ss)
    end

    local function buildChildren(tex, iconPx, nameText, showName, prefixTexes, bars, museText)
        local children = {}
        if tex then
            local stanceIcon = {
                type = ui.TYPE.Image,
                name = 'StanceIcon',
                props = {
                    resource = tex,
                    size     = util.vector2(iconPx, iconPx),
                    color    = ICON_TINT,
                    visible  = true,
                },
            }
            if prefixTexes and #prefixTexes > 0 then
                -- Prefix icons are smaller secondary indicators, vertically centred
                -- against the stance icon, each preceded by a small spacer so they
                -- don't abut. The row autoSizes, so the indicator simply grows
                -- wider when prefixes are active.
                local prefixPx = math.floor(iconPx * PREFIX_ICON_FRAC + 0.5)
                if prefixPx < PREFIX_ICON_MIN then prefixPx = PREFIX_ICON_MIN end
                if prefixPx > iconPx          then prefixPx = iconPx          end
                local gap = math.floor(iconPx * PREFIX_ICON_GAP_FRAC + 0.5)
                if gap < PREFIX_ICON_GAP_MIN then gap = PREFIX_ICON_GAP_MIN end

                local row = { stanceIcon }
                for i, ptex in ipairs(prefixTexes) do
                    row[#row + 1] = {
                        type = ui.TYPE.Widget,
                        name = 'PrefixGap' .. i,
                        props = { size = util.vector2(gap, 1), visible = true },
                    }
                    row[#row + 1] = {
                        type = ui.TYPE.Image,
                        name = 'PrefixIcon' .. i,
                        props = {
                            resource = ptex,
                            size     = util.vector2(prefixPx, prefixPx),
                            color    = ICON_TINT,
                            visible  = true,
                        },
                    }
                end

                local rowProps = {
                    horizontal = true,
                    autoSize   = true,
                    visible    = true,
                }
                -- Center children on the cross (vertical) axis so the smaller
                -- prefix icons line up with the middle of the stance icon.
                if CENTER_ALIGN ~= nil then rowProps.arrange = CENTER_ALIGN end

                children[#children + 1] = {
                    type    = ui.TYPE.Flex,
                    name    = 'IconRow',
                    props   = rowProps,
                    content = ui.content(row),
                }
            else
                children[#children + 1] = stanceIcon
            end
        end
        if showName or not tex then
            children[#children + 1] = {
                type = ui.TYPE.Text,
                name = 'StanceName',
                props = {
                    text            = nameText or '',
                    textSize        = nameTextSize(iconPx),
                    textColor       = NAME_TEXT_COLOR,
                    textShadow      = true,
                    textShadowColor = NAME_SHADOW_COLOR,
                    visible         = true,
                },
            }
        end

        -- Stacked buff bars under the stance name. Each is a textured fill bar: a
        -- dim full-width track (the empty portion) with a bright fill that grows
        -- from the left to bar.ratio, tinted bar.r/g/b. Resonance uses its own
        -- textures (resonance / exhaustion); smoker and muse reuse the near-white
        -- resonance texture tinted orange / yellow. Each fill's props table is
        -- captured into barFillList so updateHud can patch its width per tick.
        barFillList = {}
        if bars then
            for i = 1, #bars do
                local bar = bars[i]
                local btex = bar and bar.tex and textureFor(bar.tex)
                if btex then
                    local barW = math.max(24, iconPx or 48)
                    local barH = math.max(5, math.floor(barW * BAR_HEIGHT_FRAC))
                    local ratio = bar.ratio or 0
                    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end

                    local trackProps = {
                        resource = btex,
                        size     = util.vector2(barW, barH),
                        color    = BAR_TRACK_TINT,
                        position = util.vector2(0, 0),
                    }
                    local fillProps = {
                        resource = btex,
                        size     = util.vector2(math.max(0, math.floor(barW * ratio)), barH),
                        color    = util.color.rgb(bar.r or 1, bar.g or 1, bar.b or 1),
                        position = util.vector2(0, 0),
                    }
                    barFillList[#barFillList + 1] = { props = fillProps, w = barW, h = barH, ratio = ratio }

                    children[#children + 1] = {
                        type = ui.TYPE.Widget,
                        name = 'StanceBar' .. i,
                        props = {
                            size = util.vector2(barW, barH),
                            -- small gap above each bar so stacked bars don't touch
                            position = util.vector2(0, (i == 1) and 1 or BAR_GAP_PX),
                        },
                        content = ui.content({
                            { type = ui.TYPE.Image, name = 'Track', props = trackProps },
                            { type = ui.TYPE.Image, name = 'Fill',  props = fillProps  },
                        }),
                    }
                end
            end
        end
        -- Muse performance readout (one line), below the bars. Present only while a
        -- performance is active; the TEXT changes every tick but is patched in place
        -- (like StanceName), so its presence — not its text — is what's structural.
        if museText then
            children[#children + 1] = {
                type = ui.TYPE.Text,
                name = 'MuseInfo',
                props = {
                    text            = museText,
                    textSize        = math.max(9, math.floor(nameTextSize(iconPx) * 0.78)),
                    textColor       = NAME_TEXT_COLOR,
                    textShadow      = true,
                    textShadowColor = NAME_SHADOW_COLOR,
                    visible         = true,
                },
            }
        end
        return children
    end

    local function buildHud(tex, iconPx, nameText, showName, prefixTexes, bars, museText)
        destroyHud()

        local props = {
            horizontal = false,            -- vertical column: icon over name
            autoSize   = true,             -- size to fit children
            position   = hudPosition(),
            -- Anchor (0,1) → position points at the indicator's bottom-left
            -- corner, matching the historical text-label placement so stored
            -- drag positions stay valid.
            anchor     = util.vector2(0, 1),
            visible    = true,
        }
        if CENTER_ALIGN ~= nil then props.arrange = CENTER_ALIGN end

        hudElement = ui.create {
            layer   = 'Modal',
            type    = ui.TYPE.Flex,
            name    = 'StanceHudIndicator',
            props   = props,
            userData = { dragging = false, lastMousePos = nil },
            content = ui.content(buildChildren(tex, iconPx, nameText, showName, prefixTexes, bars, museText)),
        }

        hudElement.layout.events = {
            mousePress   = async:callback(hudMousePress),
            mouseRelease = async:callback(hudMouseRelease),
            mouseMove    = async:callback(hudMouseMove),
        }

        currentName = nameText
        currentMuseText = museText
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

        local iconPx   = hudIconSize()
        local nameText = formatStanceName(activeId)
        local showName = showStanceName()
        local path     = iconPathFor(activeId)
        local tex      = textureFor(path)

        -- Active-prefix icons (Sneaky / Fortified / Spellsword imbue) are rendered
        -- in a row BESIDE the stance icon. getActivePrefixIcons returns the VFS
        -- paths for whichever prefixes are active on this stance (same conditions
        -- as the name prefix); each is resolved to a texture here, and any that
        -- fail to load are skipped so a missing asset just means that one icon is
        -- absent. Only drawn when the base stance icon is present (no icon →
        -- name-only mode is unchanged). The PATHS drive the structural signature
        -- (stable strings); the TEXTURES drive rendering.
        local prefixPaths = tex and getActivePrefixIcons(activeId) or {}
        local prefixTexes = {}
        for _, p in ipairs(prefixPaths) do
            local ptex = textureFor(p)
            if ptex then prefixTexes[#prefixTexes + 1] = ptex end
        end

        -- Stacked buff bars (resonance / smoker / muse). Their PRESENCE, ORDER,
        -- texture and colour are structural (folded into the signature as keys);
        -- each fill's WIDTH is patched in place per tick (below).
        local bars = getActiveBars(activeId)

        local barSig = 'B0'
        if bars and #bars > 0 then
            local keys = {}
            for i = 1, #bars do keys[i] = tostring(bars[i].key or bars[i].tex or i) end
            barSig = 'B:' .. table.concat(keys, ',')
        end

        -- Muse performance line: its PRESENCE is structural (adds/removes a child);
        -- its TEXT is patched in place each tick (like the name) so the live note /
        -- time counters don't churn the element.
        local museText = museStatusText()

        -- Structural signature: anything here changing requires a rebuild. The
        -- name text is handled separately (patched in place) so name-only prefix
        -- changes don't churn the whole element. The prefix icon set IS structural
        -- (it adds/removes children), so the active prefix paths are folded in
        -- here — but only ever change when a base icon is shown, so name-only mode
        -- never rebuilds on a prefix toggle.
        local structSig = table.concat({
            tostring(activeId),
            tostring(path or ''),
            tex and 'T' or 'F',
            showName and 'N1' or 'N0',
            tostring(iconPx),
            'P:' .. table.concat(prefixPaths, ','),
            barSig,
            museText and 'M1' or 'M0',
        }, '|')

        if structSig ~= currentStructSig or not hudElement then
            buildHud(tex, iconPx, nameText, showName, prefixTexes, bars, museText)
            currentStructSig = structSig
            return
        end

        -- Same structure on screen: patch the name in place (if it changed)
        -- and keep the position current (the HUD layer may have resized).
        local ok = pcall(function()
            if nameText ~= currentName then
                local content   = hudElement.layout.content
                local nameChild = content and content['StanceName']
                if nameChild then nameChild.props.text = nameText end
                currentName = nameText
            end
            -- Patch the Muse performance line in place (present while structSig is
            -- stable, i.e. museText is non-nil here; the counters update live).
            if museText ~= currentMuseText then
                local content    = hudElement.layout.content
                local museChild  = content and content['MuseInfo']
                if museChild then museChild.props.text = museText end
                currentMuseText = museText
            end
            -- Patch each stacked bar's fill width in place (same structure on
            -- screen; only fills' widths change). barFillList[i] lines up with
            -- bars[i] because the bar set is identical while structSig is stable.
            if bars then
                for i = 1, #barFillList do
                    local bf = barFillList[i]
                    local nb = bars[i]
                    if bf and nb and nb.ratio ~= bf.ratio then
                        local ratio = nb.ratio or 0
                        if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
                        bf.props.size = util.vector2(math.max(0, math.floor(bf.w * ratio)), bf.h)
                        bf.ratio = ratio
                    end
                end
            end
            hudElement.layout.props.position = hudPosition()
            hudElement:update()
        end)
        if not ok then
            -- Element went stale somehow — drop it and rebuild next pass.
            destroyHud()
        end
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
