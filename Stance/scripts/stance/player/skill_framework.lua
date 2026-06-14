--[[
    Stance! — Skill Framework integration (player/skill_framework.lua)

    Owns everything that talks to the Skill Framework (SF) interface:
      * registering the core "Stance" skill,
      * the class-specialization dynamic modifier,
      * the per-skill additive effectiveness modifiers, and
      * syncing the active stance's name/attribute/description/tooltip onto
        the SF skill each tick.

    All SF API calls are funnelled through this module so the build-version
    risk lives in one place. It requires no engine modules directly; init.lua
    injects everything via .new(ctx), including the engine handles (I, util)
    and the init.lua helper locals this code used to close over.

    Construction (in init.lua, at this section's original position so every
    injected local is already defined):
        local skillFramework = require('scripts.stance.player.skill_framework').new({ ... })

    Behaviour is identical to the former init.lua locals. Public API:
        skillFramework.isSkillRegistered()      -> bool  (the internal flag)
        skillFramework.isClassBonusApplied()     -> bool
        skillFramework.registerSkill()
        skillFramework.applyClassBonus()
        skillFramework.refreshEffectivenessModifiers()
        skillFramework.syncToActiveStance()
        skillFramework.markUnregistered()        -- reset flags on load/reload
]]

local M = {}

function M.new(ctx)
    ctx = ctx or {}

    -- Engine handles + config (passed in directly).
    local I        = ctx.I
    local util     = ctx.util
    local config   = ctx.config
    local SKILL_ID = ctx.SKILL_ID

    -- init.lua helper locals (passed in directly — all defined before this
    -- module is constructed).
    local readSetting           = ctx.readSetting
    local debugLog              = ctx.debugLog
    local getStanceConfig       = ctx.getStanceConfig
    local formatStanceName      = ctx.formatStanceName
    local getCoreSkillLevel     = ctx.getCoreSkillLevel
    local getStanceLevel        = ctx.getStanceLevel
    local getStanceXp           = ctx.getStanceXp
    local effectivenessSkillBonus = ctx.effectivenessSkillBonus
    local getStanceEvasionBonus = ctx.getStanceEvasionBonus or function() return 0 end
    local getStanceTimedBonus       = ctx.getStanceTimedBonus       or function() return 0 end
    local getStanceWeightyBonus     = ctx.getStanceWeightyBonus     or function() return 0 end
    local getStanceTimedSignature   = ctx.getStanceTimedSignature   or function() return '' end
    local getStanceWeightySignature = ctx.getStanceWeightySignature or function() return '' end
    local getMuseBuffInfo            = ctx.getMuseBuffInfo            or function() return nil end
    local getMuseSongTitlesForStance = ctx.getMuseSongTitlesForStance or function() return {} end
    local getMusePerformanceStatus   = ctx.getMusePerformanceStatus   or function() return nil end
    -- Additive Block bonus while "fortified" (shield + one-handed melee stance).
    -- Returns 0 when not fortified / not provided. Replaces the deprecated
    -- Fortifier stance's Block effectiveness.
    local currentFortifiedBlockBonus = ctx.currentFortifiedBlockBonus
        or function() return 0 end
    -- Additive Hand-to-Hand bonus from hand armor worn in the Brawler stance
    -- (gauntlet/bracer weight class). Returns 0 when not Brawler / no hand armor /
    -- not provided. Folded into the handtohand contribution below, alongside the
    -- Brawler effectiveness bonus, through the same native delta-modifier path.
    local currentBrawlerGauntletHhBonus = ctx.currentBrawlerGauntletHhBonus
        or function() return 0 end
    -- Additive weapon-skill bonus while the Smoking buff is active (Hackle-Lo pipe
    -- held or its lingering window still running). Fixed at +10; level governs only
    -- the buff duration. Added on top of the effectiveness bonus for the active
    -- stance's target skill through the same native delta path, so it stacks with
    -- all other modifiers and clears the instant the buff expires.
    local currentSmokingWeaponBonus = ctx.currentSmokingWeaponBonus
        or function() return 0 end
    -- Returns tooltip note lines for the name prefixes active on a stance
    -- (Sneaky / Fortified / imbue element). Empty when none / not provided.
    local getActivePrefixNotes  = ctx.getActivePrefixNotes or function() return {} end
    -- Perk-ladder accessor: returns the subtype-appropriate ladder for Forager
    -- (gardening vs harvesting, by the tool in hand) and the single `perks` array
    -- for every other stance. Falls back to the stance's own `perks` if not provided.
    local getStancePerks        = ctx.getStancePerks or function(id)
        local s = getStanceConfig(id); return (s and s.perks) or {}
    end
    local xpForStanceLevel      = ctx.xpForStanceLevel
    local resolveStanceSkill    = ctx.resolveStanceSkill
    local perksEnabledForStance = ctx.perksEnabledForStance
    local integrationPresent    = ctx.integrationPresent or function() return false end
    -- Active stance id changes over time, so it is read through a getter.
    local getActiveStance       = ctx.getActiveStance
    local getSelf               = ctx.getSelf or function() return nil end
    local statAccess            = require('scripts.stance.player.stat_access')

    -- ── Module state (formerly init.lua file-level locals) ────────────────
    local skillRegistered = false
    local classBonusApplied = false
    local lastSkillSyncedName = nil
    local lastSkillSyncedAttribute = nil
    local lastSkillSyncedDescription = nil
    -- Tracks the shortenedName last pushed into statsWindowProps, so the stats
    -- window row (which displays shortenedName under the 'Stance' subsection)
    -- follows the active stance instead of staying the static registered name.
    local lastSkillSyncedShortName = nil
    -- Tracks the foreground glyph (fgr path) last pushed into the skill icon, so
    -- the icon is only re-sent to SF when the active stance's icon changes.
    local lastSkillSyncedIcon = nil

    -- ── Skill icon ────────────────────────────────────────────────────────
    -- The Stance skill icon is the standard combat-skill background frame (bgr,
    -- from the Skill Framework / Merlord's Skills Module asset) with the ACTIVE
    -- stance's icon as the foreground glyph (fgr) — the same icons/Stance/<X>.dds
    -- the HUD shows, so the stats menu and its hover tooltip match the HUD.
    -- SF's modifySkill replaces the nested icon table wholesale (it does not
    -- merge), so every push includes the bgr frame alongside the fgr; a stance
    -- with no icon falls back to a frame-only icon (never blank).
    local SKILL_ICON_BGR       = 'icons/SkillFramework/combat_blank.dds'
    local SKILL_ICON_BGR_COLOR = util.color.rgb(1, 1, 1)
    local SKILL_ICON_FGR_COLOR = util.color.rgb(1, 1, 1)

    -- The active stance's icon path (foreground glyph), or nil if it has none.
    local function stanceIconFgr(stanceId)
        local s = getStanceConfig(stanceId)
        return (s and s.icon) or nil
    end

    -- Build the full SF icon table: the bgr frame always, plus the stance glyph
    -- (fgr) when the stance has an icon. Sent whole on every update because SF
    -- replaces the nested icon table rather than merging it.
    local function buildSkillIcon(fgrPath)
        local icon = { bgr = SKILL_ICON_BGR, bgrColor = SKILL_ICON_BGR_COLOR }
        if fgrPath then
            icon.fgr      = fgrPath
            icon.fgrColor = SKILL_ICON_FGR_COLOR
        end
        return icon
    end

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
            -- Background frame + the current stance's glyph (fgr). The per-tick
            -- sync (syncToActiveStance) keeps fgr in step as the stance changes.
            icon = buildSkillIcon(stanceIconFgr(getActiveStance() or 'commoner')),
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

    -- ── Per-skill additive effectiveness modifiers ────────────────────────
    --
    -- The effectiveness bonus raises the skill tied to the active stance by a
    -- level-scaled amount (+2..+20). Two delivery paths, by skill kind:
    --
    --   VANILLA skills (longblade, shortblade, speechcraft, ...): applied via
    --     the engine-native skill `.modifier` field. Skill Framework's
    --     registerDynamicModifier only governs SF's own custom skills, so the
    --     previous version's getSkillRecord('longblade') check always failed
    --     and NO vanilla effectiveness bonus was ever applied — this is the
    --     core of the "additive skill bonuses not working" report.
    --
    --   MODDED SF skills (throwing, staves_staves, fishing_skill,
    --     mining_skill): these ARE SF-registered, so registerDynamicModifier
    --     works and we keep using it.
    --
    -- For vanilla skills we track our own per-skill contribution and adjust
    -- only our portion (delta accounting), exactly like the perk skill/attr
    -- contributions, so we stack cleanly with fortify/drain and never stomp
    -- another system's modifier.
    local effectivenessModifiersRegistered = {}   -- modded SF skills only
    local effVanillaContrib = {}                   -- [skillId] = our applied points

    local VANILLA_EFF_SKILLS = {
        'longblade', 'shortblade', 'bluntweapon', 'axe', 'spear',
        'marksman', 'handtohand', 'block', 'armorer', 'security', 'speechcraft',
        'mysticism', 'alchemy',
    }
    local MODDED_EFF_SKILLS = {
        -- Twirler's effectiveness bonus is delivered to the Throwing SF skill
        -- via SF's dynamic-modifier path (it works for SF custom skills).
        throwing      = 'throwing',
        staves        = 'staves_staves',
        fishing       = 'fishing_skill',
        simplymining  = 'mining_skill',
    }

    local function currentEffectiveBonusSkill()
        if not getActiveStance() then return nil, 0 end
        if not readSetting('', 'enabled', true) then return nil, 0 end
        local skill = resolveStanceSkill(getActiveStance())
        if not skill then return nil, 0 end
        local bonus = math.floor(effectivenessSkillBonus(getActiveStance()) + 0.5)
        return skill, bonus
    end

    -- Native delta apply for one vanilla skill (mirrors perks setSkillContrib).
    local function setVanillaEffContrib(skillId, newContrib)
        local prev = effVanillaContrib[skillId] or 0
        if prev == newContrib then return end
        local stat = statAccess.getSkillStat(getSelf(), skillId)
        if not stat then return end
        local curMod = 0
        pcall(function() curMod = stat.modifier or 0 end)
        pcall(function() stat.modifier = curMod - prev + newContrib end)
        effVanillaContrib[skillId] = newContrib
    end

    -- Modded SF skills: keep the dynamic-modifier path (works for custom skills).
    local function computeBonusForSkill(skillId)
        local skill, bonus = currentEffectiveBonusSkill()
        if skill ~= skillId then return 0 end
        return bonus
    end

    local function ensureEffectivenessModifier(skillId)
        if not skillId then return end
        if effectivenessModifiersRegistered[skillId] then return end
        if not (I.SkillFramework
            and I.SkillFramework.registerDynamicModifier
            and I.SkillFramework.getSkillRecord) then return end
        local ok, rec = pcall(I.SkillFramework.getSkillRecord, skillId)
        if not ok or rec == nil then return end  -- skill not yet available
        local modId = 'Stance_SkillBonus_' .. skillId
        local sid = skillId
        local ok2 = pcall(I.SkillFramework.registerDynamicModifier, sid, modId,
            function() return computeBonusForSkill(sid) end)
        if ok2 then
            effectivenessModifiersRegistered[sid] = true
            debugLog(string.format('Effectiveness modifier registered on modded skill "%s"', sid),
                'debugIntegrationMessages')
        end
    end

    -- Called every update from init.lua. Applies the vanilla bonus natively to
    -- whichever skill the active stance targets (zeroing all others), and
    -- lazily registers SF modifiers for present modded skills.
    local function refreshEffectivenessModifiers()
        if not skillRegistered then return end

        local targetSkill, targetBonus = currentEffectiveBonusSkill()

        -- Apply the active stance's bonus to its target skill, and reset every
        -- other vanilla skill we manage back to 0 so swapping stances moves the
        -- bonus cleanly. Marksman is treated like any other vanilla skill:
        -- Huntsman buffs it directly. (This is safe alongside the Throwing! mod
        -- because Twirler — the thrown-weapon stance — targets the Throwing
        -- skill, never Marksman, and Throwing!'s own Marksman handling is
        -- governed by its "Thrown Weapons Use Throwing Only" setting. Stance
        -- never writes Marksman except via Huntsman's normal bonus here.)
        --
        -- Block is special: it is no longer any stance's target skill (the
        -- Fortifier stance is deprecated), but it receives a flat additive
        -- bonus whenever the player is "fortified" (shield + one-handed melee
        -- stance). That bonus stacks on top of the target-skill bonus in the
        -- (unreachable) case Block were ever a target, and otherwise is simply
        -- Block's whole contribution. Applied through the same delta path so it
        -- stacks cleanly with fortify/drain and clears when the shield comes off.
        local blockBonus = math.floor((currentFortifiedBlockBonus() or 0) + 0.5)
        -- Brawler gauntlet (hand-armor) Hand-to-Hand bonus, kept RAW (unfloored)
        -- so it combines with the effectiveness bonus and rounds ONCE below,
        -- avoiding the double-round a separate floor would introduce on the
        -- fractional tiers (e.g. +2.5). 0 unless Brawler is active with hand armor
        -- (refreshBrawlerGauntlet gates the tier on stance + setting).
        local gauntletHhRaw = currentBrawlerGauntletHhBonus() or 0
        -- Smoking weapon-skill bonus: +10 flat while the Hackle-Lo buff is active.
        -- Applied as an integer addend on top of targetBonus (or the handtohand
        -- combo) so it stacks cleanly with effectiveness, fortified, and gauntlets.
        local smokingBonus = math.floor((currentSmokingWeaponBonus() or 0) + 0.5)
        -- Raw effectiveness for the active stance's target skill, used only for the
        -- handtohand combine (Brawler is the sole stance whose target is handtohand).
        local rawTargetEff = (targetSkill and effectivenessSkillBonus(getActiveStance())) or 0
        for _, sid in ipairs(VANILLA_EFF_SKILLS) do
            local contrib
            if sid == 'handtohand' then
                -- Effectiveness (only when handtohand is the target, i.e. Brawler) +
                -- gauntlet bonus + smoking bonus, summed RAW then rounded once. All
                -- addends are 0 outside Brawler, so handtohand clears to 0 like any
                -- other skill. With no gauntlets or smoking this equals the plain
                -- effectiveness bonus, so those non-Smoking Brawler cases are unchanged.
                local effPart  = (targetSkill == 'handtohand') and rawTargetEff or 0
                local smokHh   = (targetSkill == 'handtohand') and smokingBonus or 0
                contrib = math.floor(effPart + gauntletHhRaw + 0.5) + smokHh
            else
                -- For every other weapon skill: base effectiveness bonus + the flat
                -- smoking bonus (0 when not smoking). Block also accumulates the
                -- fortified shield bonus on top.
                contrib = (sid == targetSkill) and (targetBonus + smokingBonus) or 0
                if sid == 'block' then contrib = contrib + blockBonus end
            end
            setVanillaEffContrib(sid, contrib)
        end

        -- Modded SF skills: register once when their integration is present.
        for intId, sfSkill in pairs(MODDED_EFF_SKILLS) do
            if integrationPresent(intId) then ensureEffectivenessModifier(sfSkill) end
        end
    end

    -- Clear our vanilla contributions (used on load/unregister so the engine's
    -- post-load zeroed modifiers aren't shadowed by a stale tracker).
    local function clearVanillaEffContribs()
        for _, sid in ipairs(VANILLA_EFF_SKILLS) do
            effVanillaContrib[sid] = 0
        end
    end

    local function syncSfToActiveStance()
        if not skillRegistered then return end
        if not (I.SkillFramework and I.SkillFramework.modifySkill) then return end

        local stanceId = getActiveStance() or 'commoner'
        local stance = getStanceConfig(stanceId)
        if not stance then return end

        local displayName = formatStanceName(stanceId)
        local attribute = stance.attribute or config.defaultAttribute
        if readSetting('', 'enableAttributeSwap', true) == false then
            attribute = config.defaultAttribute
        end

        -- ─── Tooltip ─────────────────────────────────────────────────────
        -- Layout:
        --   <lore description>
        --
        --   <Name>   <Attribute>            (mechanic toggle)
        --   Lv N   Core N   +N <Skill>      (mechanic toggle)
        --   N / N xp  (or Mastered)         (mechanic toggle)
        --
        --   [*] Perk — Short description.
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
            mysticism     = 'Mysticism',
            throwing      = 'Throwing',
            staves_staves = 'Staves',
            fishing_skill = 'Fishing',
            mining_skill  = 'Mining',
        }

        local coreLevel = getCoreSkillLevel()
        local stLevel   = getStanceLevel(stanceId)
        local stXp      = getStanceXp(stanceId)
        local lines     = { stance.description }

        -- Append a short note for each name prefix currently active (Sneaky /
        -- Fortified / imbue element) so the description tracks the decorated
        -- name. Separated from the base lore by a blank line; omitted entirely
        -- when no prefix is active. The description string changes whenever a
        -- prefix toggles, so tryModify pushes the update the same tick.
        local prefixNotes = getActivePrefixNotes(stanceId)
        if #prefixNotes > 0 then
            table.insert(lines, '')
            for _, note in ipairs(prefixNotes) do
                table.insert(lines, note)
            end
        end

        if readSetting('Tooltip', 'showMechanicTooltips', true) then
            local attrLabel   = attribute:sub(1, 1):upper() .. attribute:sub(2)
            local targetSkill = resolveStanceSkill(stanceId)
            local bonus       = targetSkill and math.floor(effectivenessSkillBonus(stanceId) + 0.5) or 0
            -- Display-only association for stances that grant no effectiveness
            -- bonus (absent from STANCE_SKILL_TARGET) but are thematically tied
            -- to a skill we still want named. Affects the label only; bonus
            -- stays +0 and no skill modifier is ever written.
            local labelSkill  = targetSkill
            local skillLabel  = (labelSkill and SKILL_LABEL[labelSkill]) or labelSkill or 'none'
            local xpLine      = stLevel < config.maxLevel
                and string.format('%d / %d xp', math.floor(stXp), math.floor(xpForStanceLevel(stLevel)))
                or  'Mastered'

            -- Per-stance Sanctuary (evasion) bonus, scaled by stance level.
            local evasionBonus = math.floor(getStanceEvasionBonus(stanceId) + 0.5)
            -- When Evasion! is detected, annotate so the player knows the two
            -- bonuses stack on separate delta trackers and don't cancel each other.
            local evasionLabel = integrationPresent('evasion') and 'Sanctuary (Evasion!)' or 'Sanctuary'

            table.insert(lines, '')
            table.insert(lines, string.format('%s   %s', formatStanceName(stanceId), attrLabel))
            -- Build the stat line so neither bonus shows "+0".
            local statParts = { string.format('Lv %d   Core %d', stLevel, coreLevel) }
            if bonus > 0 then
                table.insert(statParts, string.format('+%d %s', bonus, skillLabel))
            end
            if evasionBonus > 0 then
                table.insert(statParts, string.format('+%d %s', evasionBonus, evasionLabel))
            end
            table.insert(lines, table.concat(statParts, '   '))

            -- Sol combat-mod mastery (timed directional / weighty charged
            -- attack), applied to the stance's own weapon skill. Shown on their
            -- OWN lines (not crammed onto the stat line, where they could wrap
            -- off-screen) and shown whenever the relevant Sol mod is DETECTED and
            -- this stance has that affinity — even at +0 — so the distinctiveness
            -- is legible from the start and visibly grows as the stance levels
            -- (the bonus ramps from 0 at the start level to its ceiling at 100).
            if skillLabel ~= 'none' then
                local timedSig = getStanceTimedSignature(stanceId)
                if integrationPresent('soltimeddirattacks') and timedSig ~= '' then
                    local timedBonus = math.floor((getStanceTimedBonus(stanceId) or 0) + 0.5)
                    table.insert(lines, string.format('+%d %s  (Timed - %s)', timedBonus, skillLabel, timedSig))
                end
                local weightySig = getStanceWeightySignature(stanceId)
                if integrationPresent('solweightychargeattacks') and weightySig ~= '' then
                    local weightyBonus = math.floor((getStanceWeightyBonus(stanceId) or 0) + 0.5)
                    table.insert(lines, string.format('+%d %s  (Weighty - %s)', weightyBonus, skillLabel, weightySig))
                end
            end
            table.insert(lines, xpLine)

            -- Move Like This: surface this stance's signature directional
            -- move(s) so the player can read what makes it distinct in combat.
            -- Descriptive only — MLT applies the effects itself; the active
            -- stance's weapon-skill mastery (effectiveness + Sol bonuses)
            -- sharpens the skill-scaled ones (crit / stagger / mobility / blind /
            -- cleave) as the stance levels.
            if integrationPresent('movelikethis') then
                local sig = config.mltSignature and config.mltSignature[stanceId]
                if sig and sig.moves then
                    table.insert(lines, string.format('Move Like This - %s', sig.moves))
                end
            end

            -- Muse (Bardcraft): a live inspiration-buff countdown on a buffed
            -- stance, which songs are known to buff this stance, and — on the
            -- Muse stance itself — the in-progress performance ledger. The
            -- description is rebuilt every tick, so the countdown updates live.
            if integrationPresent('bardcraft') then
                local buff = getMuseBuffInfo(stanceId)
                if buff then
                    local rem = math.max(0, math.floor((buff.remaining or 0) + 0.5))
                    local mm, ss = math.floor(rem / 60), rem % 60
                    local src = buff.songTitle and (" from '" .. buff.songTitle .. "'") or ''
                    table.insert(lines, string.format('Muse: +%d %s inspiration%s  (%d:%02d left)',
                        buff.magnitude or 0, skillLabel, src, mm, ss))
                end
                local titles = getMuseSongTitlesForStance(stanceId)
                if titles and #titles > 0 then
                    local shown = {}
                    for i = 1, math.min(#titles, 3) do shown[i] = titles[i] end
                    local more = (#titles > 3) and (' +' .. (#titles - 3) .. ' more') or ''
                    table.insert(lines, string.format('Muse songs: %s%s', table.concat(shown, ', '), more))
                end
                if stanceId == 'muse' then
                    local ps = getMusePerformanceStatus()
                    if ps then
                        local t = math.max(0, math.floor((ps.accum or 0) + 0.5))
                        table.insert(lines, string.format(
                            "Performing '%s' -> %s   buffer %ds   loop %d/%d   notes %d/%d",
                            ps.songTitle or '?', ps.stance or '?', t,
                            ps.loop or 0, ps.allowed or 1, ps.successes or 0, ps.notes or 0))
                    else
                        table.insert(lines, 'Play a song idly (Practice) to weave inspiration into a stance.')
                    end
                end
            end
        end

        -- Perks: name + short description only; no verbose sub-headers.
        if readSetting('Tooltip', 'showPerkTooltips', true) and perksEnabledForStance(stanceId) then
            local unlockedOnly = readSetting('Tooltip', 'tooltipUnlockedOnly', false)
            local first = true
            for _, perk in ipairs(getStancePerks(stanceId)) do
                local unlocked = coreLevel >= perk.level
                if unlocked or not unlockedOnly then
                    if first then table.insert(lines, ''); first = false end
                    local marker = unlocked and '*' or ('Lv' .. perk.level)
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

        -- Skill icon foreground glyph: the active stance's icon — the same one
        -- the HUD shows — so the stats-menu row and its hover tooltip track the
        -- stance. The FULL icon table is sent (the nested table is replaced, not
        -- merged, so bgr must accompany fgr), and only when the glyph path
        -- actually changes. Its own pcall keeps older SF builds that reject an
        -- `icon` modify from losing the other field updates above.
        local fgrPath = stanceIconFgr(stanceId)
        if fgrPath ~= lastSkillSyncedIcon then
            local ok, err = pcall(I.SkillFramework.modifySkill, SKILL_ID, {
                icon = buildSkillIcon(fgrPath),
            })
            if ok then
                lastSkillSyncedIcon = fgrPath
            else
                debugLog('modifySkill failed for icon: ' .. tostring(err),
                    'debugIntegrationMessages')
            end
        end

        -- The stats-window ROW shows statsWindowProps.shortenedName (the
        -- 'Stance' subsection header comes from .subsection), and that was
        -- only ever set at registration — so the window kept showing the
        -- static default name while the tooltip/full name changed. Push an
        -- updated statsWindowProps whenever the formatted name changes, so
        -- the row reads e.g. "Stance" → "Fortified Soloist". The FULL props
        -- table is sent each time (modifySkill may replace the nested table
        -- rather than merge it), preserving subsection and visibility.
        if displayName ~= lastSkillSyncedShortName then
            local ok, err = pcall(I.SkillFramework.modifySkill, SKILL_ID, {
                statsWindowProps = {
                    subsection = 'Stance',
                    shortenedName = displayName,
                    visible = true,
                },
            })
            if ok then
                lastSkillSyncedShortName = displayName
            else
                debugLog('modifySkill failed for statsWindowProps: ' .. tostring(err),
                    'debugIntegrationMessages')
            end
        end
    end

    -- Reset the registration flags. Matches what init.lua's onLoad and the
    -- console "reload" command used to do inline (the 5 flags; the
    -- effectiveness-modifier registry is intentionally NOT reset, exactly as
    -- before).
    local function markUnregistered()
        skillRegistered = false
        classBonusApplied = false
        lastSkillSyncedName = nil
        lastSkillSyncedAttribute = nil
        lastSkillSyncedDescription = nil
        lastSkillSyncedShortName = nil
        -- The engine zeroes skill modifiers on load. Drop our tracked vanilla
        -- effectiveness contributions to 0 so the next refresh re-applies the
        -- real bonus onto the freshly-zeroed modifier instead of believing it
        -- is already present (prev == new) and skipping it.
        clearVanillaEffContribs()
    end

    return {
        isSkillRegistered          = function() return skillRegistered end,
        isClassBonusApplied        = function() return classBonusApplied end,
        registerSkill              = registerSkill,
        applyClassBonus            = applyClassBonus,
        refreshEffectivenessModifiers = refreshEffectivenessModifiers,
        syncToActiveStance         = syncSfToActiveStance,
        markUnregistered           = markUnregistered,
    }
end

return M
