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
        getStanceLevel     — function(stanceId) → level (int)
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
    local getStanceLevel     = ctx.getStanceLevel or function() return config.startLevel or 5 end
    local getCoreSkillLevel  = ctx.getCoreSkillLevel or function() return config.startLevel or 5 end

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
    -- (locksmith), a repair hammer (reforger), and the Muse — a performance stance
    -- whose instrument is not a Spellsword-imbuable weapon, so it is excluded from
    -- the Spellsword integration's prefix entirely. Every other stance wields a
    -- weapon (or fists) Spellsword treats as imbuable.
    local NON_IMBUABLE_STANCES = {
        arcanist  = true,
        commoner  = true,
        locksmith = true,
        reforger  = true,
        muse      = true,
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

    -- ─── Smoking prefix + bonus (Hackle-Lo pipe) ─────────────────────────────
    -- Two distinct transient states, both recomputed every poll tick and never
    -- saved:
    --
    --   * pipeEquipped — a Hackle-Lo pipe variant is in the off-hand (CarriedLeft)
    --     slot. Used only for the "a pipe is at the ready" hint shown before you
    --     have smoked anything.
    --
    --   * smokingActive — a Hackle-Lo smoke potion is currently in effect. This
    --     alone drives BOTH the "Smoking" name prefix and the flat +10 weapon-skill
    --     bonus, so the buff lasts exactly as long as the smoke itself: it persists
    --     for the full smoke duration even after the pipe is put away, and it
    --     applies to EVERY stance (no stance is excluded). The pipe mod consumes a
    --     hackle-lo leaf on a successful smoke and applies a `pe_hackle-lo_smoke*`
    --     potion (an ALCH with a 60 s+ duration); the presence of that potion in the
    --     player's active spells is the authoritative "smoked a leaf" signal, and
    --     its remaining duration is the tooltip buff timer. The no-leaf fallback
    --     potion (`pe_hackle-lo_smoke_dagoth_empty`) is deliberately NOT in the set,
    --     so puffing the dried resins of an empty pipe grants no buff.
    --
    -- The prefix shows while smokingActive (the timer runs) OR while a pipe is held
    -- (ready to smoke); the +10 bonus is granted while smokingActive. Putting the
    -- pipe away no longer clears the buff — only the smoke effect ending does.
    -- (The pipe's own Speed-drain downside is likewise neutralised for exactly as
    -- long as the smoke effect lasts; see scanActiveSmoke / applySmokeSpeedOffset.)
    local HACKLE_LO_PIPE_IDS = {
        ['hackle-lo pipe']                  = true,
        ['hackle-lo pipe - mushroom']       = true,
        ['hackle-lo pipe - cherrywood']     = true,
        ['hackle-lo pipe - brass']          = true,
        ['hackle-lo pipe - stalhrim']       = true,
        ['hackle-lo pipe - silver']         = true,
        ['hackle-lo pipe - glass']          = true,
        ['hackle-lo pipe - wood']           = true,
        ['hackle-lo pipe - ashlander']      = true,
        ['hackle-lo pipe - dagoth']         = true,
        ['hackle-lo pipe - windwalker']     = true,
        ['hackle-lo pipe - peace']          = true,
        ['hackle-lo pipe - ancestral']      = true,
        ['hackle-lo pipe - carvedmushroom'] = true,
        ['hackle-lo pipe - dunmeri glass']  = true,
    }
    -- Smoke potions the pipe mod applies on a SUCCESSFUL smoke (a hackle-lo leaf
    -- was present and consumed). The no-leaf "_empty" fallback is intentionally
    -- absent — it represents smoking dried resins with no leaf, which must NOT
    -- grant the bonus. Matched case-insensitively against active-spell source ids.
    local SMOKE_POTION_IDS = {
        ['pe_hackle-lo_smoke']            = true,
        ['pe_hackle-lo_smoke_ancestral']  = true,
        ['pe_hackle-lo_smoke_dagoth']     = true,
        ['pe_hackle-lo_smoke_peace']      = true,
        ['pe_hackle-lo_smoke_vip']        = true,
        ['pe_hackle-lo_smoke_windwalker'] = true,
    }
    -- Per-potion Speed-drain magnitude the pipe mod's smoke applies (verified
    -- against the Hackle-Lo Pipe ESP). Only the base/cheap pipe smoke drains
    -- Speed — Drain Speed 50 for 60 s, the documented "cheaper pipes damage your
    -- speed" downside — and at magnitude 50 it floors a Speed≤50 character to 0,
    -- which immobilises the player. Each value here is the amount of Speed we ADD
    -- back while that smoke is active; setting it equal to the drain (50) fully
    -- cancels the penalty so smoking never saps movement. To keep a milder penalty
    -- instead, set the value BELOW the drain (e.g. 40 leaves a net −10 Speed while
    -- smoking); to restore the pipe's full original penalty, set 0 or remove the
    -- entry. Pipes not listed here drain no Speed in the first place.
    local SMOKE_SPEED_DRAIN = {
        ['pe_hackle-lo_smoke'] = 50,
    }
    local pipeEquipped     = false   -- Hackle-Lo pipe in the off-hand (drives prefix)
    local smokingActive    = false   -- actively smoking a leaf (drives +10 bonus)
    local smokeRemaining   = 0       -- seconds left on the active smoke buff (for the tooltip timer)
    local smokeSpeedContrib = 0      -- our own Speed-modifier delta (offsets the drain)
    -- Stance-managed smoke-BONUS window. The +weapon bonus no longer lasts the
    -- whole potion: it lasts a halved, core-level-gated window measured from when
    -- smoking began (see config.smoker / gatedSmokeWindow / refreshSmoking). The
    -- pipe's Speed-drain cancellation is unaffected and still lasts the full potion.
    local smokeBonusStart  = nil     -- core.getSimulationTime() when smoking began (nil = not smoking)
    local smokeBonusWindow = 0       -- gated window length captured at smoke start (seconds)
    local smokeBonusLive   = false   -- true while within the window AND still smoking

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
        -- Smoking outermost of all: shown while a hackle-lo smoke is active (the
        -- buff is running) OR a pipe is at the ready, on EVERY stance — the buff
        -- persists for the smoke's full duration regardless of the pipe, so the
        -- prefix follows the timer rather than the pipe.
        -- e.g. "Smoking Sneaky Fortified Soloist".
        if smokingActive or pipeEquipped then
            name = 'Smoking ' .. name
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

    -- ─── Brawler gauntlet tradeoff (hand-armor weight class while unarmed) ─────
    -- While Brawler is the active stance, hand-slot armor (gauntlets OR bracers)
    -- grants an additive Hand-to-Hand bonus and an unarmed attack-speed penalty
    -- that scale with the armor's weight class. The tier (none/light/medium/heavy)
    -- is cached here, refreshed once per poll tick by refreshBrawlerGauntlet()
    -- (declared below). 'none' = bare fists (no hand armor) → no bonus, no penalty.
    -- Declared up here so the tooltip-note builder and the bonus getters capture it
    -- as an upvalue. Transient (recomputed per tick), so nothing is persisted.
    local brawlerGauntletTier = 'none'
    local TIER_RANK = { none = 0, light = 1, medium = 2, heavy = 3 }

    -- Format a bonus number without a trailing ".0" (2.5 → "2.5", 5 → "5").
    local function fmtNum(n)
        n = tonumber(n) or 0
        if n == math.floor(n) then return string.format('%d', n) end
        return string.format('%.1f', n)
    end

    -- Read a numeric GMST with a defensive fallback (pcall-guarded so a missing
    -- GMST or non-numeric value can never raise here).
    local function gmstNum(key, fallback)
        local v
        pcall(function() v = core.getGMST(key) end)
        v = tonumber(v)
        if v == nil then return fallback end
        return v
    end

    -- Classify one hand-armor record's weight class EXACTLY as the engine does
    -- (mwclass/armor.cpp getEquipmentSkill): both gauntlets and bracers use the
    -- floored iGauntletWeight GMST as the slot weight, compared against
    -- fLightMaxMod / fMedMaxMod (defaults 0.6 / 0.9) with the same +epsilon.
    -- Returns 'light' | 'medium' | 'heavy'. GMSTs are read live so the documented
    -- vanilla way of re-tuning armor ranges (editing those GMSTs) is honoured.
    local function classifyHandArmor(rec)
        local weight  = tonumber(rec and rec.weight) or 0
        local iWeight = math.floor(gmstNum('iGauntletWeight', 5))
        local fLight  = gmstNum('fLightMaxMod', 0.6)
        local fMed    = gmstNum('fMedMaxMod', 0.9)
        local epsilon = 0.0005
        if weight <= iWeight * fLight + epsilon then return 'light' end
        if weight <= iWeight * fMed  + epsilon then return 'medium' end
        return 'heavy'
    end

    -- Weight class of the armor in one hand slot ('LeftGauntlet'/'RightGauntlet'),
    -- or 'none' when the slot is empty or holds something that isn't armor. Reuses
    -- safeArmorRecord (Armor-instance guard) defined above. Any armor that occupies
    -- a hand slot is hand armor (a gauntlet or bracer), so no type check is needed.
    local function handSlotTier(slotKey)
        local equipment = types.Actor.getEquipment(self)
        if not equipment or not types.Actor.EQUIPMENT_SLOT then return 'none' end
        local item = equipment[types.Actor.EQUIPMENT_SLOT[slotKey]]
        if not item then return 'none' end
        local rec = safeArmorRecord(item)
        if not rec then return 'none' end
        return classifyHandArmor(rec)
    end

    -- Refresh the cached Brawler gauntlet tier once per poll tick, BEFORE the
    -- effectiveness refresh (which folds in the Hand-to-Hand bonus) and the
    -- tooltip render. Gated on the enableBrawlerGauntlets setting AND the Brawler
    -- stance being active, so the bonus/penalty exist only when unarmed with fists
    -- up. The tier is the heavier of the two equipped hand pieces (mismatched
    -- left/right hand armor resolves to the heavier class). Logs only on transition.
    local function refreshBrawlerGauntlet()
        local prev = brawlerGauntletTier
        if (not readSetting('Stances', 'enableBrawlerGauntlets', true))
            or getActiveStance() ~= 'brawler' then
            brawlerGauntletTier = 'none'
        else
            local l = handSlotTier('LeftGauntlet')
            local r = handSlotTier('RightGauntlet')
            brawlerGauntletTier = (TIER_RANK[r] > TIER_RANK[l]) and r or l
        end
        if brawlerGauntletTier ~= prev then
            debugLog('Brawler gauntlet tier -> ' .. tostring(brawlerGauntletTier),
                'debugDetectionMessages')
        end
    end

    -- Current tier's additive Hand-to-Hand bonus (0 when 'none'/unconfigured).
    -- Consumed by the effectiveness system, which folds it into the handtohand
    -- skill modifier alongside the Brawler effectiveness bonus.
    local function currentBrawlerGauntletHhBonus()
        local t = config.brawlerGauntlet and config.brawlerGauntlet[brawlerGauntletTier]
        return (t and tonumber(t.hhBonus)) or 0
    end

    -- Current tier's attack-speed debuff as a fraction (0 when 'none').
    local function currentBrawlerGauntletSpeedDebuff()
        local t = config.brawlerGauntlet and config.brawlerGauntlet[brawlerGauntletTier]
        return (t and tonumber(t.speedDebuff)) or 0
    end

    -- Resulting unarmed attack-animation speed multiplier (1.0 = normal, lower =
    -- slower), floored by config.brawlerGauntlet.minSpeedMult so attacks can never
    -- freeze. 1.0 whenever no debuff applies — the onFrame applier treats >= 1.0 as
    -- "nothing to do", so the non-sticky animation speed simply resumes its default.
    local function currentBrawlerGauntletSpeedMult()
        local debuff = currentBrawlerGauntletSpeedDebuff()
        if debuff <= 0 then return 1.0 end
        local floorMult = (config.brawlerGauntlet
            and tonumber(config.brawlerGauntlet.minSpeedMult)) or 0.10
        local mult = 1.0 - debuff
        if mult < floorMult then mult = floorMult end
        return mult
    end

    -- ─── Smoking prefix + bonus computation ───────────────────────────────────

    -- True when any Hackle-Lo pipe variant is equipped in the off-hand (Light)
    -- slot. Pipes are LIGH records; the check uses types.Light.objectIsInstance to
    -- distinguish them from weapons, shields, and torches, then validates the
    -- record id against the known pipe set. Mirrors the shield detection pattern
    -- in getEquippedShield — pcall-guarded throughout so a missing types.Light
    -- can never raise here.
    local function isHackleLoPipeEquipped()
        if not types.Actor.EQUIPMENT_SLOT then return false end
        local ok, equipment = pcall(types.Actor.getEquipment, self)
        if not ok or not equipment then return false end
        local item = equipment[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
        if not item then return false end
        -- Must be a Light item (pipes are LIGH records, not weapons or armour).
        local okLight, isLight = pcall(function()
            return types.Light and types.Light.objectIsInstance(item)
        end)
        if not okLight or not isLight then return false end
        -- Match against the known pipe record id set (case-insensitive).
        local recordId = nil
        pcall(function() recordId = item.recordId end)
        if not recordId then return false end
        return HACKLE_LO_PIPE_IDS[recordId:lower()] == true
    end

    -- Scan the player's active spells ONCE and report two things:
    --   smoking    — whether a SUCCESSFUL-smoke potion (`pe_hackle-lo_smoke*`,
    --                excluding the no-leaf "_empty" fallback) is in effect. The
    --                pipe mod applies one only after consuming a hackle-lo leaf,
    --                so its presence is the authoritative "smoked a leaf" signal.
    --   speedDrain — the total Speed-drain magnitude those smoke potions impose
    --                (summed from SMOKE_SPEED_DRAIN), so we can neutralise it.
    -- Consumed potions appear in Actor.activeSpells keyed by the potion's record
    -- id (params.id). Fully pcall-guarded: if the API is unavailable or changes
    -- shape this degrades to (false, 0) rather than raising.
    local function scanActiveSmoke()
        local active = nil
        local ok = pcall(function() active = types.Actor.activeSpells(self) end)
        if not ok or not active then return false, 0, 0 end
        local smoking, speedDrain, remaining = false, 0, 0
        pcall(function()
            for _, params in pairs(active) do
                local id = params and params.id
                if type(id) == 'string' then
                    local lid = id:lower()
                    if SMOKE_POTION_IDS[lid] then
                        smoking    = true
                        speedDrain = speedDrain + (SMOKE_SPEED_DRAIN[lid] or 0)
                        -- Longest remaining effect duration of this smoke potion,
                        -- read straight from the engine's active-spell bookkeeping
                        -- so it counts down on its own in real time. The field is
                        -- `durationLeft` (older builds: `timeLeft`); if neither is
                        -- present this stays 0 and the timer is simply omitted.
                        if params.effects then
                            for _, eff in pairs(params.effects) do
                                local dl = eff and (eff.durationLeft or eff.timeLeft)
                                if type(dl) == 'number' and dl > remaining then
                                    remaining = dl
                                end
                            end
                        end
                    end
                end
            end
        end)
        return smoking, speedDrain, remaining
    end

    -- Apply our Speed-modifier contribution using the engine-native attribute
    -- `.modifier` field and the same delta formula the perks system uses
    -- (new = current - our_previous + our_new). Because every owner only adjusts
    -- the portion it tracks, this stacks cleanly with the pipe's own Drain Speed
    -- and with any perk/spell Speed modifiers without double-counting or stomping.
    -- `newContrib` is the amount we ADD to Speed (a positive value cancels an equal
    -- drain). pcall-guarded so a missing stats accessor can never raise here.
    local function applySmokeSpeedOffset(newContrib)
        if newContrib == smokeSpeedContrib then return end
        local attrTable = types.Actor.stats and types.Actor.stats.attributes
        if not attrTable or not attrTable.speed then return end
        local stat = nil
        pcall(function() stat = attrTable.speed(self) end)
        if not stat then return end
        local curMod = 0
        pcall(function() curMod = stat.modifier or 0 end)
        pcall(function() stat.modifier = curMod - smokeSpeedContrib + newContrib end)
        smokeSpeedContrib = newContrib
    end

    -- Reset our Speed-offset delta tracker. Called from init.lua's onLoad because
    -- the engine zeroes all active effects (and the attribute modifiers they drive)
    -- on load; our tracker must match or the first refresh would compute its delta
    -- against a stale baseline and over-apply. Mirrors clearEvasionBonus.
    local function clearSmokingSpeedOffset()
        smokeSpeedContrib = 0
    end

    -- Longest smoke-BONUS window the player's CORE Stance level currently
    -- permits: gateBaseSeconds at gateAtLevel, +gateAddSeconds every gatePerLevels
    -- core levels. (Independent of the potion's own duration; see refreshSmoking.)
    local function gatedSmokeWindow()
        local s = config.smoker or {}
        local baseS = tonumber(s.gateBaseSeconds) or 20
        local atLvl = tonumber(s.gateAtLevel)     or 5
        local perL  = tonumber(s.gatePerLevels)   or 10
        local addS  = tonumber(s.gateAddSeconds)  or 10
        if perL < 1 then perL = 1 end
        local lvl = getCoreSkillLevel()
        local steps = math.floor((lvl - atLvl) / perL)
        if steps < 0 then steps = 0 end
        local window = baseS + steps * addS
        if window < 0 then window = 0 end
        return window
    end

    -- Refresh the cached Smoking state once per poll tick.
    --   pipeEquipped  — a Hackle-Lo pipe is in the off-hand (drives the prefix).
    --   smokingActive — a smoke potion is currently in effect (drives the prefix
    --                   timer and the Speed-drain cancellation, which both last
    --                   the FULL potion duration).
    --   smokeBonusLive — the +weapon-skill bonus, which now lasts only a HALVED,
    --                   core-level-gated window measured from when smoking began.
    -- The Speed drain is neutralised for as long as the smoke effect itself lasts.
    -- Logs only on transition.
    local function refreshSmoking()
        local prevPipe  = pipeEquipped
        local prevSmoke = smokingActive

        -- Respect the Hackle-Lo Pipes integration toggle (Integrations settings).
        -- When disabled, the smoking prefix and its weapon-skill bonus are fully
        -- off: clear all cached state and peel any Speed offset we hold.
        if not integrationEnabled('hacklelopipes') then
            pipeEquipped     = false
            smokingActive    = false
            smokeBonusLive   = false
            smokeBonusStart  = nil
            smokeBonusWindow = 0
            smokeRemaining   = 0
            applySmokeSpeedOffset(0)
            if prevPipe or prevSmoke then
                debugLog('Smoking -> integration disabled; prefix/bonus cleared.',
                    'debugDetectionMessages')
            end
            return
        end

        pipeEquipped = isHackleLoPipeEquipped()

        local smokeActive, speedDrain, remaining = scanActiveSmoke()
        smokingActive = smokeActive

        local now = 0
        pcall(function() now = core.getSimulationTime() end)

        if smokingActive then
            -- On the smoking-begin transition, open a fresh bonus window: the
            -- lesser of the core-level gate and HALF the potion's remaining time
            -- at this moment (so both the gate and the "halve" rule bind).
            if not prevSmoke or smokeBonusStart == nil then
                smokeBonusStart = now
                local scale = tonumber(config.smoker and config.smoker.durationScale) or 0.5
                local halvedPotion = (tonumber(remaining) or 0) * scale
                local gate = gatedSmokeWindow()
                smokeBonusWindow = math.min(gate, halvedPotion)
                if smokeBonusWindow < 0 then smokeBonusWindow = 0 end
            end
            local elapsed = now - (smokeBonusStart or now)
            local windowLeft = (smokeBonusWindow or 0) - elapsed
            if windowLeft < 0 then windowLeft = 0 end
            smokeBonusLive = windowLeft > 0
            -- Tooltip timer shows the GATED bonus window remaining, capped by the
            -- potion's own remaining time so it never overstates either limit.
            smokeRemaining = math.min(windowLeft, tonumber(remaining) or 0)
        else
            smokeBonusStart  = nil
            smokeBonusWindow = 0
            smokeBonusLive   = false
            smokeRemaining   = 0
        end

        -- Cancel the pipe's Speed drain (positive offset == drain magnitude) for
        -- the full potion duration, independent of the bonus window above.
        applySmokeSpeedOffset(speedDrain)

        if pipeEquipped ~= prevPipe or smokingActive ~= prevSmoke then
            debugLog(string.format('Smoking -> pipe=%s active=%s bonusWindow=%.0fs (speedOffset=%d)',
                tostring(pipeEquipped), tostring(smokingActive), smokeBonusWindow or 0, speedDrain),
                'debugDetectionMessages')
        end
    end

    -- Additive weapon-skill bonus granted while the smoke-bonus WINDOW is live
    -- (config.smoker.weaponBonus, default 10). 0 once the halved, core-gated
    -- window elapses even if the potion itself lingers. Consumed by
    -- refreshEffectivenessModifiers in skill_framework.lua.
    local function currentSmokingWeaponBonus()
        if not smokeBonusLive then return 0 end
        return tonumber(config.smoker and config.smoker.weaponBonus) or 10
    end

    -- Public read of the cached Smoking flag for UI consumers: true while the
    -- bonus window is live (pipe smoked, within the gated window).
    local function isSmokingActive()
        return smokeBonusLive == true
    end

    -- Seconds remaining on the active smoke buff (0 when not actively smoking).
    -- Read live from the engine each tick, so consumers get a real-time countdown.
    local function currentSmokeRemaining()
        return smokingActive and (smokeRemaining or 0) or 0
    end

    -- Live smoke buff window for the tooltip timer and the HUD bar. Returns nil
    -- unless the gated bonus window is active; otherwise { remaining, window }
    -- (seconds) so a consumer can show a countdown or a remaining/window bar.
    local function getSmokingBuffInfo()
        if not smokeBonusLive then return nil end
        local window    = tonumber(smokeBonusWindow) or 0
        local remaining = tonumber(smokeRemaining) or 0
        if window <= 0 then return nil end
        if remaining < 0 then remaining = 0 end
        if remaining > window then remaining = window end
        return { remaining = remaining, window = window }
    end


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

    -- Public read of the cached "sneaky" (crouched) flag, for consumers that
    -- mirror the Sneaky prefix in non-text UI. The HUD overlays a Sneaky badge
    -- on the active stance's icon while this is true. It reflects the very same
    -- per-tick state that drives the "Sneaky" name prefix (refreshed by
    -- refreshSneaky and gated on the enableSneaky setting), so the icon badge and
    -- the name decoration can never disagree.
    local function isSneakyActive()
        return sneakyActive == true
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
        -- Brawler gauntlet tradeoff: shown only while Brawler is active with hand
        -- armor equipped (brawlerGauntletTier is gated to that in refreshBrawlerGauntlet).
        -- Reports the CURRENT tier's bonus and penalty so the note tracks the worn
        -- armor dynamically — switching gauntlets updates it the same tick.
        if brawlerGauntletTier ~= 'none' then
            local tierName = brawlerGauntletTier:sub(1, 1):upper() .. brawlerGauntletTier:sub(2)
            notes[#notes + 1] = string.format(
                '%s gauntlets: +%s Hand-to-Hand, but unarmed attacks swing %d%% slower.',
                tierName, fmtNum(currentBrawlerGauntletHhBonus()),
                math.floor(currentBrawlerGauntletSpeedDebuff() * 100 + 0.5))
        end
        -- Smoking: shown while a Hackle-Lo pipe is equipped (the prefix only needs
        -- the pipe in hand). The weapon-skill bonus applies only while the HALVED,
        -- core-gated bonus window is live (smokeBonusLive), which is shorter than
        -- the potion's own duration. Merely holding the pipe prompts the player to
        -- smoke; the timer below counts down the gated bonus window.
        if smokingActive or pipeEquipped then
            local bonusPts = tonumber(config.smoker and config.smoker.weaponBonus) or 10
            if smokeBonusLive then
                local rem = smokeRemaining or 0
                local timer = ''
                if rem > 0 then
                    timer = string.format(' (%d:%02d left)',
                        math.floor(rem / 60), math.floor(rem % 60))
                end
                notes[#notes + 1] = string.format(
                    "Smoking: hackle-lo smoke sharpens your focus — +%d to this stance's weapon skill%s.",
                    bonusPts, timer)
            elseif smokingActive then
                notes[#notes + 1] =
                    "Smoking: the focus from your smoke has faded. Smoke again to renew the weapon-skill bonus."
            else
                notes[#notes + 1] = string.format(
                    "Smoking: a Hackle-Lo pipe is at the ready. Smoke a hackle-lo leaf to gain +%d to this stance's weapon skill.",
                    bonusPts)
            end
        end
        return notes
    end

    -- ─── Prefix icons (for the HUD, rendered BESIDE the stance icon) ──────────
    -- VFS icon paths for each name-prefix decoration. The imbue element maps to
    -- its element icon; Smoking, Sneaky and Fortified have fixed icons. All assets
    -- live under icons/Stance/.
    local IMBUE_ICON_BY_PREFIX = {
        Blazed      = 'icons/Stance/Fire_Imbue.dds',
        Frozen      = 'icons/Stance/Frost_Imbue.dds',
        Electrified = 'icons/Stance/Shock_Imbue.dds',
    }
    local SMOKING_ICON_PATH   = 'icons/Stance/Smoking.dds'
    local SNEAKY_ICON_PATH    = 'icons/Stance/Sneaky.dds'
    local FORTIFIED_ICON_PATH = 'icons/Stance/Fortified.dds'

    -- Ordered list of VFS icon paths for the name-prefix decorations currently
    -- active on the ACTIVE stance, for the HUD to render in a row next to the
    -- stance icon. Conditions mirror formatStanceName / getActivePrefixNotes
    -- EXACTLY, and the order matches the name's reading order (Smoking, Sneaky,
    -- Fortified, imbue), so the icons and the decorated name can never disagree.
    -- Only the active stance is decorated (a non-active id returns an empty list).
    -- Returns paths only — the HUD owns texture loading and silently skips any
    -- that fail, so a missing asset simply means that one icon is absent.
    local function getActivePrefixIcons(stanceId)
        if stanceId ~= getActiveStance() then return {} end
        local icons = {}
        -- Smoking outermost (leftmost in the name): shown while a hackle-lo
        -- smoke is active OR a pipe is held, on every stance. Mirrors the prefix
        -- exactly (follows the timer, not the pipe).
        if smokingActive or pipeEquipped then
            icons[#icons + 1] = SMOKING_ICON_PATH
        end
        if sneakyActive then
            icons[#icons + 1] = SNEAKY_ICON_PATH
        end
        if fortifiedActive and FORTIFIABLE_STANCES[stanceId] then
            icons[#icons + 1] = FORTIFIED_ICON_PATH
        end
        if imbuePrefix and not NON_IMBUABLE_STANCES[stanceId] then
            local p = IMBUE_ICON_BY_PREFIX[imbuePrefix]
            if p then icons[#icons + 1] = p end
        end
        return icons
    end

    -- ─── Saved-loadout helpers (for the Loadouts mod) ─────────────────────────
    -- These let an external consumer (the Loadouts menu) decorate a stance name
    -- for a SAVED loadout. Unlike the live HUD, a saved loadout has no transient
    -- imbue element or crouch posture, so only the Fortified prefix can apply —
    -- and only when a real shield is stored in the off-hand. The imbue/Sneaky
    -- decorations are deliberately NOT applied here; they are runtime-only.

    -- Whether a stance can take the Fortified prefix at all (one of the one-handed
    -- melee combat stances). Reuses the single FORTIFIABLE_STANCES set above so the
    -- loadout preview and the live HUD never disagree about what "fortifiable" means.
    local function isFortifiable(stanceId)
        return FORTIFIABLE_STANCES[stanceId] == true
    end

    -- Whether a record id names a genuine shield — an Armor record of TYPE Shield.
    -- Mirrors the type test in getEquippedShield(), but keyed by record id (what a
    -- saved loadout stores in its off-hand slot) rather than a live equipped item.
    -- Torches, lanterns, misc off-hand items, and non-shield armor all return false.
    local function isShieldRecord(recordId)
        if type(recordId) ~= 'string' then return false end
        local rec = nil
        pcall(function() rec = types.Armor.records[recordId] end)
        if not rec then return false end
        local shieldType = types.Armor.TYPE and types.Armor.TYPE.Shield
        if shieldType == nil then return false end
        return rec.type == shieldType
    end

    -- Format a stance's display name for a saved loadout: the base name, with a
    -- "Fortified " prefix when (and only when) the caller has determined the
    -- loadout pairs a shield with a fortifiable weapon stance. No imbue/Sneaky.
    local function formatLoadoutStanceName(stanceId, fortified)
        local stance = getStanceConfig(stanceId)
        if not stance then return 'Unknown' end
        local name = stance.displayName
        if fortified and FORTIFIABLE_STANCES[stanceId] then
            name = 'Fortified ' .. name
        end
        return name
    end

    return {
        formatStanceName           = formatStanceName,
        refreshImbuePrefix         = refreshImbuePrefix,
        refreshFortified           = refreshFortified,
        refreshSneaky              = refreshSneaky,
        isSneakyActive             = isSneakyActive,
        currentFortifiedBlockBonus = currentFortifiedBlockBonus,
        getActivePrefixNotes       = getActivePrefixNotes,
        getActivePrefixIcons       = getActivePrefixIcons,
        -- Smoking prefix (pipe equipped) + bonus (actively smoking a leaf):
        refreshSmoking             = refreshSmoking,
        clearSmokingSpeedOffset    = clearSmokingSpeedOffset,
        currentSmokingWeaponBonus  = currentSmokingWeaponBonus,
        currentSmokeRemaining      = currentSmokeRemaining,
        getSmokingBuffInfo         = getSmokingBuffInfo,
        isSmokingActive            = isSmokingActive,
        -- Brawler gauntlet tradeoff (hand-armor weight class while unarmed):
        refreshBrawlerGauntlet            = refreshBrawlerGauntlet,
        getBrawlerGauntletTier            = function() return brawlerGauntletTier end,
        currentBrawlerGauntletHhBonus     = currentBrawlerGauntletHhBonus,
        currentBrawlerGauntletSpeedDebuff = currentBrawlerGauntletSpeedDebuff,
        currentBrawlerGauntletSpeedMult   = currentBrawlerGauntletSpeedMult,
        -- Saved-loadout helpers (consumed by init.lua's describeLoadout):
        isFortifiable              = isFortifiable,
        isShieldRecord             = isShieldRecord,
        formatLoadoutStanceName    = formatLoadoutStanceName,
    }
end

return M
