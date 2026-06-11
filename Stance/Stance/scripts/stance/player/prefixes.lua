--[[
    Stance! — stance-name prefixes (player/prefixes.lua)

    Owns the three transient decorations applied to the ACTIVE stance's
    displayed name, plus the tooltip notes that describe them:
      * Spellsword imbue element — Blazed / Frozen / Electrified (cosmetic)
      * Fortified — shield + one-handed melee (cosmetic + a Block bonus,
        scaled by the player's own Block skill base)
      * Sneaky — player crouched / sneaking (cosmetic)

    All module state (imbuePrefix, fortifiedActive, sneakyActive) is
    TRANSIENT: recomputed every poll tick from live game state, never
    persisted. Moving it here is therefore mid-save safe by construction —
    nothing in a save file references this module.

    Dependencies (injected via ctx):
        self, types, storage, core — engine handles (init.lua's requires)
        config             — scripts.stance.config
        readSetting        — function(group, key, default) → value
        debugLog           — function(msg, debugFlagKey)
        getStanceConfig    — function(stanceId) → stance table | nil
        integrationEnabled — function(integrationId) → boolean
        getActiveStance    — function() → activeStanceId (string|nil)
]]

local M = {}

function M.new(ctx)
    local self    = ctx.self
    local types   = ctx.types
    local storage = ctx.storage
    local core    = ctx.core
    local config  = ctx.config
    local readSetting        = ctx.readSetting
    local debugLog           = ctx.debugLog
    local getStanceConfig    = ctx.getStanceConfig
    local integrationEnabled = ctx.integrationEnabled
    local getActiveStance    = ctx.getActiveStance

    -- ─── Spellsword imbue prefix (purely cosmetic) ────────────────────────────
    -- When the Spellsword mod has an active weapon imbuement, formatStanceName()
    -- prepends a cosmetic element prefix (Blazed / Frozen / Electrified) to the
    -- active stance's display name — but ONLY for stances that wield an imbuable
    -- weapon. `imbuePrefix` is the cached prefix string (or nil) refreshed once per
    -- poll tick by refreshImbuePrefix() (defined lower, after integrationEnabled).
    -- It is declared up here so formatStanceName captures it as an upvalue. This is
    -- display-only: it never affects stance resolution, XP, perks, or the imbue
    -- itself (which is wholly Spellsword's; we only read its state).
    local imbuePrefix = nil

    -- Stances with no imbuable weapon, so they never take a prefix: a readied spell
    -- (arcanist), the empty/sheathed fallback (commoner), a lockpick/probe
    -- (locksmith), and a repair hammer (reforger) — none of which Spellsword glows
    -- on or imbues. Every other stance wields a weapon (or fists) Spellsword treats
    -- as imbuable.
    local NON_IMBUABLE_STANCES = {
        arcanist  = true,
        commoner  = true,
        locksmith = true,
        reforger  = true,
    }

    -- ─── Fortified prefix (shield + one-handed melee) ─────────────────────────
    -- The Fortifier stance is deprecated. Instead, when a shield is equipped
    -- alongside a one-handed MELEE weapon, formatStanceName() prepends a "Fortified"
    -- prefix to that weapon's stance (e.g. "Fortified Soloist", "Fortified
    -- Blademeister") and a Block skill bonus is applied while so equipped (see
    -- refreshFortified / the effectiveness system). Only these one-handed melee
    -- combat stances can be fortified — every other stance is either two-handed,
    -- ranged, dual-wielding, unarmed, or non-combat, none of which pair a shield
    -- with a "compatible weapon". `fortifiedActive` is the cached flag refreshed
    -- once per poll tick by refreshFortified() (defined lower, after the shield
    -- helper); it is declared up here so formatStanceName captures it as an upvalue.
    local FORTIFIABLE_STANCES = {
        soloist     = true,   -- long blade, one-handed
        thief       = true,   -- short blade
        mjolnir     = true,   -- blunt, one-handed
        axeman      = true,   -- axe, one-handed
        blademeister = true,  -- Felthorn long blade, one-handed
    }
    local fortifiedActive = false

    -- ─── Sneaky prefix (player crouched / sneaking) ───────────────────────────
    -- When the player is crouched (sneaking), formatStanceName() prepends a
    -- "Sneaky" prefix to the active stance's name — e.g. "Sneaky Huntsman",
    -- "Sneaky Soloist". Unlike Fortified, this applies to ANY stance, since
    -- crouching is a posture independent of the weapon held. `sneakyActive` is the
    -- cached flag refreshed once per poll tick by refreshSneaky() (defined lower);
    -- declared here so formatStanceName captures it as an upvalue. Display-only.
    local sneakyActive = false

    local function formatStanceName(stanceId)
        local stance = getStanceConfig(stanceId)
        if not stance then return 'Unknown' end
        local name = stance.displayName
        -- Imbue prefix first (innermost, nearest the base name).
        if imbuePrefix and not NON_IMBUABLE_STANCES[stanceId] then
            name = imbuePrefix .. ' ' .. name
        end
        -- Fortified next (only the one-handed melee stances).
        if fortifiedActive and FORTIFIABLE_STANCES[stanceId] then
            name = 'Fortified ' .. name
        end
        -- Sneaky outermost, on any stance while crouched:
        -- e.g. "Sneaky Fortified Blazed Soloist".
        if sneakyActive then
            name = 'Sneaky ' .. name
        end
        return name
    end

    -- ─── Spellsword imbue prefix computation ──────────────────────────────────
    -- element magic-effect id -> cosmetic stance-name prefix.
    local IMBUE_PREFIX_BY_EFFECT = {
        firedamage  = 'Blazed',
        frostdamage = 'Frozen',
        shockdamage = 'Electrified',
    }

    -- Read Spellsword's authoritative imbue state and derive the cosmetic prefix.
    -- Spellsword stores the active imbuement in the global storage section
    -- 'IW_ActiveSpell' under key 'activeSpell' = { id, name, charges, ... } (set on
    -- a successful imbue, cleared when charges deplete / on dispel / nil otherwise).
    -- We look up that spell record and map its first fire/frost/shock damage effect
    -- to a prefix. Returns nil when no imbue is active, the integration is off, the
    -- spell can't be resolved, or it carries none of the three named elements
    -- (e.g. a poison imbue) — in which case no prefix is shown. Everything is
    -- pcall-guarded so a missing Spellsword can never raise here.
    local function computeImbuePrefix()
        if not integrationEnabled('spellsword') then return nil end

        -- Spellsword's own scripts read this exact section/key, and storage:get
        -- returns table values as a READ-ONLY view. We only index it (never iterate
        -- it), and avoid asserting type=='table' so a read-only proxy/userdata view
        -- is still accepted. All accesses are pcall-guarded.
        local spellData
        pcall(function()
            spellData = storage.globalSection('IW_ActiveSpell'):get('activeSpell')
        end)
        if spellData == nil then return nil end

        local spellId
        pcall(function() spellId = spellData.id end)
        if not spellId then return nil end

        local rec
        pcall(function() rec = core.magic.spells.records[spellId] end)
        if not rec or not rec.effects then return nil end

        -- IMPORTANT: iterate with pairs, NOT ipairs. OpenMW runs Lua 5.1, whose
        -- global ipairs uses raw integer indexing; a record's effects list is a
        -- read-only proxy whose entries live behind a metamethod, so ipairs would
        -- iterate nothing and never match. Spellsword itself uses pairs here.
        local prefix
        pcall(function()
            for _, effect in pairs(rec.effects) do
                local p = effect and effect.id and IMBUE_PREFIX_BY_EFFECT[effect.id]
                if p then prefix = p; return end
            end
        end)
        return prefix
    end

    -- Refresh the cached prefix. Called once per poll tick (before the HUD and
    -- tooltip re-render), so the prefix appears/disappears within one tick of the
    -- imbue being applied or ending, without any per-frame storage reads elsewhere.
    -- Logs only on transition (enable "detection" debug messages to trace it).
    local function refreshImbuePrefix()
        local newPrefix = computeImbuePrefix()
        if newPrefix ~= imbuePrefix then
            imbuePrefix = newPrefix
            debugLog('Spellsword imbue prefix -> ' .. tostring(imbuePrefix), 'debugDetectionMessages')
        end
    end

    local function safeArmorRecord(item)
        if not item then return nil end
        local ok, isArmor = pcall(types.Armor.objectIsInstance, item)
        if not ok or not isArmor then return nil end
        local okRec, rec = pcall(types.Armor.record, item)
        if not okRec then return nil end
        return rec
    end

    local function getEquippedShield()
        -- The off-hand (CarriedLeft) slot holds shields, but ALSO torches, lanterns,
        -- and whatever modded off-hand items exist. ONLY a genuine shield counts for
        -- the Fortified prefix/bonus: an Armor instance whose record type is Shield.
        -- Everything else is rejected — Light (torches/lanterns), Misc, Weapon, etc.
        local equipment = types.Actor.getEquipment(self)
        if not equipment or not types.Actor.EQUIPMENT_SLOT then return nil end
        local item = equipment[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
        if not item then return nil end

        -- Explicit early-out for Light items (torches and most lanterns). Light and
        -- Armor are mutually exclusive, so this can never reject a real shield — it
        -- just makes the intent unmistakable and guards modded light sources. The
        -- access is wrapped in the pcall closure so a missing types.Light is safe.
        local okLight, isLight = pcall(function()
            return types.Light and types.Light.objectIsInstance(item)
        end)
        if okLight and isLight then return nil end

        -- Must be an Armor instance (this alone already rejects Light, Misc,
        -- Weapon, Clothing, tools, etc. — anything that isn't armor).
        local rec = safeArmorRecord(item)
        if not rec then return nil end

        -- ...and specifically of armor TYPE Shield (a non-shield armor — which can't
        -- actually occupy CarriedLeft anyway — is rejected). If the type enum is
        -- somehow unavailable we treat it as "not a shield" rather than risk a
        -- false positive.
        local shieldType = types.Armor.TYPE and types.Armor.TYPE.Shield
        if shieldType == nil then return nil end
        if rec.type ~= shieldType then return nil end

        return item
    end

    -- Refresh the cached "fortified" flag: true when a shield is equipped AND the
    -- active stance is a one-handed melee stance (FORTIFIABLE_STANCES). Drives both
    -- the "Fortified" name prefix (formatStanceName) and the Block bonus. Called
    -- once per poll tick before the effectiveness refresh and the HUD/tooltip render
    -- (so a shield equipped/removed without a stance change still updates promptly).
    -- Gated on the enableFortified setting (replaces the old Fortifier toggle).
    -- Diagnostic only: the record id of whatever is in the off-hand (CarriedLeft)
    -- slot, or 'none'. Used by the fortified transition log so a stray modded item
    -- that wrongly (or rightly) triggers the prefix can be identified by name.
    local function offHandRecordId()
        local ok, equipment = pcall(types.Actor.getEquipment, self)
        if not ok or not equipment or not types.Actor.EQUIPMENT_SLOT then return 'none' end
        local item = equipment[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
        if not item then return 'none' end
        local okId, rid = pcall(function() return item.recordId end)
        return (okId and rid) or '?'
    end

    local function refreshFortified()
        local prev = fortifiedActive
        if not readSetting('Stances', 'enableFortified', true) then
            fortifiedActive = false
        else
            fortifiedActive = (FORTIFIABLE_STANCES[getActiveStance()] == true)
                and (getEquippedShield() ~= nil)
        end
        -- Log only on transition (enable "detection" debug messages to trace it).
        -- Reports the off-hand item so a torch/lantern/modded item can be checked.
        if fortifiedActive ~= prev then
            debugLog(string.format('Fortified -> %s (stance=%s, off-hand=%s)',
                tostring(fortifiedActive), tostring(getActiveStance()), offHandRecordId()),
                'debugDetectionMessages')
        end
    end

    -- Additive Block skill-point bonus while fortified (0 otherwise). Consumed by
    -- the effectiveness system, which writes it to the Block skill via the same
    -- native delta-modifier path used for the per-stance effectiveness bonuses.
    -- Additive Block bonus while fortified, SCALED by the player's own Block
    -- skill — the better you block, the more the raised shield gives back. Uses
    -- the exact same additive ramp as the weapon-skill effectiveness bonus
    -- (effectivenessMinBonus → effectivenessMaxBonus, i.e. +2 → +20, across the
    -- startLevel → maxLevel range), but driven by the BLOCK skill instead of a
    -- stance level. Delivered through the same delta-accounted modifier path in
    -- refreshEffectivenessModifiers, so it stacks with fortify/drain and clears
    -- the instant the shield comes off.
    --
    -- IMPORTANT: reads Block's BASE, not its modified value. The bonus itself is
    -- written into Block's modifier, so scaling off `modified` would feed the
    -- bonus back into its own input and ratchet upward every tick. Base is the
    -- trained skill, which is exactly "the player's core blocking skill".
    local function currentFortifiedBlockBonus()
        if not fortifiedActive then return 0 end
        local blockBase = 0
        pcall(function()
            local skills = types.NPC and types.NPC.stats and types.NPC.stats.skills
            local stat = skills and skills.block and skills.block(self)
            if stat then blockBase = tonumber(stat.base) or 0 end
        end)
        local lo   = config.startLevel or 5
        local hi   = config.maxLevel   or 100
        local minB = tonumber(config.leveling and config.leveling.effectivenessMinBonus) or 2
        local maxB = tonumber(config.leveling and config.leveling.effectivenessMaxBonus) or 20
        if hi <= lo then return minB end
        local t = (blockBase - lo) / (hi - lo)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        return minB + (maxB - minB) * t
    end

    -- True when the player is crouched (sneaking). OpenMW exposes the sneak state
    -- of the player's own actor as the boolean self.controls.sneak ("If true -
    -- sneak"); this reflects the resolved crouch state (hold OR toggle sneak) on
    -- 0.49+. There is no core "isSneaking" query, so this is the canonical signal.
    -- Read defensively: if controls are unavailable for any reason, report false.
    local function isPlayerSneaking()
        local ok, sneaking = pcall(function()
            return self.controls ~= nil and self.controls.sneak == true
        end)
        return ok and sneaking == true
    end

    -- Refresh the cached "sneaky" flag once per poll tick (before the HUD/tooltip
    -- re-render), so the "Sneaky" prefix appears/disappears within one tick of the
    -- player crouching/standing. Gated on the enableSneaky setting. Logs only on
    -- transition (enable "detection" debug messages to trace it).
    local function refreshSneaky()
        local prev = sneakyActive
        if not readSetting('Stances', 'enableSneaky', true) then
            sneakyActive = false
        else
            sneakyActive = isPlayerSneaking()
        end
        if sneakyActive ~= prev then
            debugLog('Sneaky -> ' .. tostring(sneakyActive), 'debugDetectionMessages')
        end
    end

    -- ─── Prefix tooltip notes ─────────────────────────────────────────────────
    -- Short lines describing the name prefixes currently active on the ACTIVE
    -- stance, appended under the base lore in the skill tooltip so the description
    -- reflects the decorated name: while "Fortified Blazed Soloist" shows in the
    -- HUD, the tooltip also explains the Block bonus and the fire imbue. Conditions
    -- mirror formatStanceName exactly, so a note appears iff its prefix is on the
    -- name. Only the active stance is annotated.
    local IMBUE_TOOLTIP_NOTE = {
        Blazed      = 'Blazed: the weapon is imbued with fire (Spellsword) — every strike carries flame.',
        Frozen      = 'Frozen: the weapon is imbued with frost (Spellsword) — every strike carries cold.',
        Electrified = 'Electrified: the weapon is imbued with shock (Spellsword) — every strike carries lightning.',
    }

    local function getActivePrefixNotes(stanceId)
        -- Prefixes describe what is being wielded/done right now, so only the active
        -- stance is annotated (a non-active id passed in returns nothing).
        if stanceId ~= getActiveStance() then return {} end
        local notes = {}
        -- Same order the name composes (Sneaky outermost): Sneaky, Fortified, imbue.
        if sneakyActive then
            notes[#notes + 1] = 'Sneaky: you hold this form crouched — moving low and quiet.'
        end
        if fortifiedActive and FORTIFIABLE_STANCES[stanceId] then
            notes[#notes + 1] = string.format(
                'Fortified: a shield is raised alongside the weapon, lending +%d Block while it is held (scales with your Block skill).',
                math.floor(currentFortifiedBlockBonus() + 0.5))
        end
        if imbuePrefix and not NON_IMBUABLE_STANCES[stanceId] then
            local note = IMBUE_TOOLTIP_NOTE[imbuePrefix]
            if note then notes[#notes + 1] = note end
        end
        return notes
    end

    return {
        formatStanceName           = formatStanceName,
        refreshImbuePrefix         = refreshImbuePrefix,
        refreshFortified           = refreshFortified,
        refreshSneaky              = refreshSneaky,
        currentFortifiedBlockBonus = currentFortifiedBlockBonus,
        getActivePrefixNotes       = getActivePrefixNotes,
    }
end

return M
