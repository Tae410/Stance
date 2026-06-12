--[[
    Stance! — weapon classifiers + the stance resolver (player/resolver.lua)

    Owns the per-tick decision "which stance is the player in":
      * getStanceMode (weapon / spell / nothing)
      * every weapon-type / special-item classifier (isAxe, isFelthorn,
        isApothecaryWeapon, hasLockpickOrProbeEquipped, ...)
      * the GRIP record mapping (constructs player/grip.lua internally) and
        the effective/runtime record helpers
      * resolveStance(now) — the priority waterfall itself

    Mid-save safety: this module is PURE CLASSIFICATION. It owns no state at
    all beyond derived constants (WTYPE, record-id sets); persisted state
    (dual-wield flags, per-stance XP) stays in init.lua and is reached
    through injected closures. The resolver's output contract — pick() →
    { id, reason } gated on stanceEnabled — is unchanged.

    Dependencies (injected via ctx):
        self, types, core    — engine handles
        config               — scripts.stance.config
        readSetting          — function(group, key, default) → value
        debugLog             — function(msg, debugFlagKey)
        stanceEnabled        — function(stanceId) → boolean   (closure)
        integrationEnabled   — function(integrationId) → boolean
        integrationPresent   — function(integrationId) → boolean (closure;
                               handed through to the grip module)
        isDualWielding       — function(now) → boolean        (closure)
        isFelthornInOffhand  — function() → boolean           (closure; reads
                               the persisted dual-wield record kept in init)
        getRightHandWeapon   — function() → object|nil
        safeWeaponRecord     — function(item) → weapon record|nil
]]

local M = {}

function M.new(ctx)
    local self  = ctx.self
    local types = ctx.types
    local core  = ctx.core
    local config = ctx.config
    local readSetting        = ctx.readSetting
    local debugLog           = ctx.debugLog
    local stanceEnabled      = ctx.stanceEnabled
    local integrationEnabled = ctx.integrationEnabled
    local integrationPresent = ctx.integrationPresent
    local isDualWielding     = ctx.isDualWielding
    local isFelthornInOffhand = ctx.isFelthornInOffhand
    local getRightHandWeapon = ctx.getRightHandWeapon
    local safeWeaponRecord   = ctx.safeWeaponRecord

    -- Returns 'weapon', 'spell', or 'nothing' — whether a weapon/spell is drawn.
    local function getStanceMode()
        -- The function name on types.Actor varies across OpenMW builds
        -- (`stance` vs `getStance`).
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
    -- Forward-declare gripOriginalRecordId so isStave() (defined above) closes
    -- over this local rather than resolving it as a global at call time.
    -- The actual function is assigned below once the grip module is created.
    local gripOriginalRecordId
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

    local grip = require('scripts.stance.player.grip').new({
        integrationPresent = integrationPresent,
    })

    -- Assign to the forward-declared locals so isStave (and every call site below)
    -- captures the correct function references.
    gripOriginalRecordId        = grip.gripOriginalRecordId
    local effectiveWeaponRecord = grip.effectiveWeaponRecord
    local runtimeWeaponRecord   = grip.runtimeWeaponRecord

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

    -- Throwing-axe detection. A THROWN weapon (MarksmanThrown) whose record id or
    -- display name contains "throwing axe" is treated as an axe and routed to the
    -- Axeman stance instead of the generic thrown-weapon stance (Twirler). Mirrors
    -- the Apothecary concoction special-case (a thrown weapon re-pointed at a
    -- non-Twirler stance) and the Pitman name-matching helper. Real axes
    -- (AxeOneHand/AxeTwoHand) are already Axeman via isAxe by TYPE; this only
    -- rescues the thrown-typed "throwing axe" weapons that vanilla classification
    -- would otherwise send to Twirler. The thrown-type gate keeps it scoped to
    -- "any throwing weapon with 'throwing axe' in the name", as requested.
    local function isThrowingAxe(weaponObj, weaponRec)
        if not weaponRec then return false end
        if not isThrown(weaponRec) then return false end

        local function containsThrowingAxeText(str)
            if type(str) ~= 'string' then return false end
            return str:lower():find('throwing axe', 1, true) ~= nil
        end

        -- Display name (the user-facing "name").
        if containsThrowingAxeText(weaponRec.name) then return true end

        -- Record id, as a fallback (e.g. "iron_throwing_axe").
        if weaponObj then
            local currentId = nil
            pcall(function() currentId = weaponObj.recordId end)
            if containsThrowingAxeText(currentId) then return true end
        end

        return false
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

    -- Apothecary stance detection: the Thrown Concoctions mod adds 17 throwable
    -- "concoction" weapons (all MarksmanThrown). Detection mirrors the Angler /
    -- Pitmen pattern — match the equipped object's record id (and the GRIP-resolved
    -- original, if any) against the fixed set below, rather than the weapon's type
    -- field, because the concoctions share the MarksmanThrown type with ordinary
    -- thrown weapons and we do NOT want Twirler to steal them. The ids are the
    -- exact record NAMEs from Thrown_ConcoctionsMP.esp, lower-cased here because
    -- OpenMW record ids compare case-insensitively. `concoction_base` is the
    -- un-enchanted template flask; the rest are the enchanted concoctions.
    local APOTHECARY_RECORD_IDS = {
        ['concoction_base']        = true,
        ['grease_jar']             = true,
        ['restorative_waters']     = true,
        ['raw_magicka']            = true,
        ['cleansing_salve']        = true,
        ['flash_bang']             = true,
        ['kwama_queen_ph']         = true,
        ['anti_magicka_bottle']    = true,
        ['invigorating_aromatic']  = true,
        ['aromatic_of_focus']      = true,
        ['insulating_oil']         = true,
        ['singularity']            = true,
        ['smoke_bomb']             = true,
        ['liquid_stalhrim']        = true,
        ['plasma_jar']             = true,
        ['dwemer_candle']          = true,
        ['sapping_poison']         = true,
    }

    local function isApothecaryWeapon(weaponObj, weaponRec)
        if not weaponObj or not weaponRec then return false end

        -- Current equipped record id.
        local currentId = nil
        pcall(function() currentId = weaponObj.recordId end)

        if currentId and APOTHECARY_RECORD_IDS[currentId:lower()] then
            return true
        end

        -- GRIP original record support: a GRIP-converted concoction may have a
        -- generated record id; resolve back to the original and check that too.
        local originalId = gripOriginalRecordId(currentId)
        if originalId and APOTHECARY_RECORD_IDS[originalId:lower()] then
            return true
        end

        return false
    end

    -- Venefic Vial (thrown) detection. The Venefic Vials mod's throwable variant
    -- 'vv_vial_th' is a MarksmanThrown flask, so like the concoctions it routes to
    -- the Apothecary stance (gated on its own integration toggle, separate from
    -- Thrown Concoctions). Kept as its own id set + helper so the two apothecary
    -- throwable sources can be enabled/disabled independently.
    local VENEFIC_VIAL_RECORD_IDS = {
        ['vv_vial_th'] = true,
    }

    local function isVeneficVialWeapon(weaponObj, weaponRec)
        if not weaponObj or not weaponRec then return false end

        local currentId = nil
        pcall(function() currentId = weaponObj.recordId end)

        if currentId and VENEFIC_VIAL_RECORD_IDS[currentId:lower()] then
            return true
        end

        local originalId = gripOriginalRecordId(currentId)
        if originalId and VENEFIC_VIAL_RECORD_IDS[originalId:lower()] then
            return true
        end

        return false
    end

    -- Forager stance detection: the Gardening and Farming mod (TribalLu) adds
    -- 11 tool/weapon records, split into two functional families. Detection
    -- mirrors the Angler / Apothecary / Pitmen pattern — match the equipped
    -- object's record id (and the GRIP-resolved original, if any) against the
    -- fixed sets below, rather than the weapon's type field, because the tools
    -- span several underlying weapon types (axe, blunt, short blade, spear) and
    -- we do NOT want Axeman / Mjolnir / Thief / Guisarmier to steal them. The ids
    -- are the exact record NAMEs from GardeningandFarming.esp, lower-cased here
    -- because OpenMW record ids compare case-insensitively.
    --
    --   GARDENING family (plant-tending tools) → the gardening perk set:
    --     Gardening Hammer / Shovel / Shears / Waterskin / Waterskin (Large).
    --   HARVESTING family (gathering tools + the four combat Farming Scythes) →
    --     the harvesting perk set: Harvest Hoe / Harvest Scythe and the
    --     Imperial / Ivory / Glass / Daedric Farming Scythes.
    local FORAGER_GARDENING_IDS = {
        ['trib_tool_hammer']     = true,  -- Gardening Hammer    (blunt 1H)
        ['trib_tool_shovel']     = true,  -- Gardening Shovel    (spear)
        ['trib_tool_shears']     = true,  -- Gardening Shears    (short blade)
        ['trib_waterskin']       = true,  -- Gardening Waterskin (short blade)
        ['trib_waterskin_large'] = true,  -- Gardening Waterskin (Large)
    }
    local FORAGER_HARVESTING_IDS = {
        ['trib_garden_hoe']      = true,  -- Harvest Hoe          (axe 2H)
        ['trib_farm_scythe']     = true,  -- Harvest Scythe       (axe 2H)
        ['trib_scythe_imperial'] = true,  -- Imperial Farming Scythe
        ['trib_scythe_ivory']    = true,  -- Ivory Farming Scythe
        ['trib_scythe_glass']    = true,  -- Glass Farming Scythe
        ['trib_scythe_daedric']  = true,  -- Daedric Farming Scythe
    }

    -- Subtype for a given record id: 'gardening' | 'harvesting' | nil. Checks the
    -- literal id first, then the GRIP-resolved original (a GRIP-converted tool may
    -- carry a generated id). Returns nil for anything that isn't a Forager weapon.
    local function foragerSubtypeForId(recordId)
        if type(recordId) ~= 'string' then return nil end
        local lid = recordId:lower()
        if FORAGER_GARDENING_IDS[lid]  then return 'gardening'  end
        if FORAGER_HARVESTING_IDS[lid] then return 'harvesting' end
        local orig = gripOriginalRecordId(recordId)
        if orig then
            orig = orig:lower()
            if FORAGER_GARDENING_IDS[orig]  then return 'gardening'  end
            if FORAGER_HARVESTING_IDS[orig] then return 'harvesting' end
        end
        return nil
    end

    -- True when the equipped right-hand weapon is any Forager tool/weapon.
    local function isForagerWeapon(weaponObj, weaponRec)
        if not weaponObj or not weaponRec then return false end
        local currentId = nil
        pcall(function() currentId = weaponObj.recordId end)
        return foragerSubtypeForId(currentId) ~= nil
    end

    -- Live query of the active Forager weapon subtype, for the perk-set switch.
    -- Reads the CURRENT right-hand weapon and returns 'gardening' | 'harvesting',
    -- or nil when no Forager weapon is equipped. Consumed (via init.lua's injected
    -- closure) by the perk-display accessor and the perk-effect gating in perks.lua,
    -- so the displayed perk ladder and the applied perk effects both follow the
    -- weapon currently in hand.
    local function getActiveForagerSubtype()
        local right = getRightHandWeapon()
        if not right then return nil end
        local currentId = nil
        pcall(function() currentId = right.recordId end)
        return foragerSubtypeForId(currentId)
    end

    -- Lockpick / probe equip check for the Locksmith stance.
    --
    -- The player only needs ONE of (lockpick OR probe) readied in the right hand.
    -- Carrying tools in inventory does NOT count.
    --
    -- Detection is the live CarriedRight slot ONLY, read fresh each call. The
    -- previous version cached the result for one second, which let Locksmith
    -- linger as "active" for up to a tick after the player sheathed the tool, so
    -- Brawler (which requires a truly empty right hand) could never take over.
    -- The read is a single equipment lookup — the resolver already reads equipment
    -- for the weapon/shield branches — so there is no need to cache it, and not
    -- caching means an emptied right hand is reflected immediately. The resolver
    -- additionally gates this on stanceMode == 'weapon' (drawn), so a sheathed-but-
    -- still-equipped tool does not keep Locksmith active.
    local function hasLockpickOrProbeEquipped()
        if not (types.Lockpick or types.Probe) then return false end
        if not types.Actor.EQUIPMENT_SLOT then return false end

        local equipment = nil
        local okEq = pcall(function() equipment = types.Actor.getEquipment(self) end)
        if not okEq or not equipment then return false end

        local right = equipment[types.Actor.EQUIPMENT_SLOT.CarriedRight]
        if not right then return false end

        if types.Lockpick then
            local okLP, isLP = pcall(types.Lockpick.objectIsInstance, right)
            if okLP and isLP then return true end
        end
        if types.Probe then
            local okPR, isPR = pcall(types.Probe.objectIsInstance, right)
            if okPR and isPR then return true end
        end
        return false
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

    -- ─── Saved-loadout classification (record-id driven) ─────────────────────
    --
    -- classifyRecord answers the same question as resolveStance — "which stance
    -- is this?" — but for a SAVED loadout (the Loadouts mod) rather than the
    -- live equipment. A loadout stores record ids, not live GameObjects, and has
    -- no notion of the transient runtime state resolveStance leans on (whether a
    -- weapon/spell is drawn, the live dual-wield flag, the live crouch posture).
    -- So this walks the SAME priority order using the SAME pure classifiers, but
    -- driven by explicit record ids:
    --
    --   opts.rightId  — CarriedRight record id (the main weapon / tool)
    --   opts.secondId — Dual Wielding off-hand weapon record id (→ Dualist /
    --                   off-hand Felthorn), or nil
    --
    -- Every object-based classifier in this module reads ONLY weaponObj.recordId
    -- (each access pcall-guarded), so a bare { recordId = id } table is a faithful
    -- stand-in for a live weapon object here — no engine object is required.
    --
    -- Runtime-only states a saved loadout cannot carry are handled as follows:
    --   * Arcanist (a readied spell) and the sheathed-Commoner shortcut have no
    --     loadout signal, so they are simply not tested here.
    --   * Brawler (drawn fists, empty hand) likewise has no signal; a weaponless
    --     loadout therefore resolves to Commoner (the neutral fallback) rather
    --     than Brawler.
    --   * Locksmith is detected by record TYPE (a saved lockpick/probe), since a
    --     loadout can store one in the CarriedRight slot.
    --
    -- Each branch is still gated through pick() → stanceEnabled(id), and the
    -- integration branches through integrationEnabled(...), exactly as the live
    -- resolver — so a loadout preview honours the player's per-stance and
    -- per-integration toggles identically. Returns { id = stanceId }.
    local function classifyRecord(opts)
        opts = opts or {}
        local rightId  = opts.rightId
        local secondId = opts.secondId

        local right = rightId and { recordId = rightId } or nil
        local rightRec = nil
        if rightId then
            pcall(function() rightRec = types.Weapon.records[rightId] end)
        end
        local effRec     = effectiveWeaponRecord(right, rightRec)
        local runtimeRec = runtimeWeaponRecord(right, rightRec)

        -- A Dual-Wielding off-hand only triggers Dualist when it is itself a
        -- weapon (the live resolver's isDualWielding implies an equipped off-hand
        -- weapon). A non-weapon off-hand record never counts.
        local secondIsWeapon = false
        if secondId then
            pcall(function() secondIsWeapon = types.Weapon.records[secondId] ~= nil end)
        end
        local secondObj = secondId and { recordId = secondId } or nil

        local function pick(id)
            if not stanceEnabled(id) then return nil end
            return { id = id }
        end

        -- 1) Locksmith: a lockpick OR probe saved in the right hand. Detected by
        --    record type because lockpicks/probes are not Weapon records (rightRec
        --    is nil for them). The live resolver additionally requires the tool to
        --    be DRAWN, which a saved loadout cannot express, so a saved tool is
        --    taken as Locksmith intent.
        if rightId then
            local isTool = false
            pcall(function()
                isTool = (types.Lockpick and types.Lockpick.records[rightId] ~= nil)
                    or (types.Probe and types.Probe.records[rightId] ~= nil)
            end)
            if isTool then
                local r = pick('locksmith'); if r then return r end
            end
        end

        -- (Arcanist / sheathed-Commoner are runtime-only — see header — skipped.)

        -- 4) Reforger: repair hammer saved in the right hand.
        if effRec and isReforgerWeapon(right, effRec) then
            local r = pick('reforger'); if r then return r end
        end

        -- 5) Blademeister: Felthorn (sd_-prefixed) in either hand.
        if (right and isFelthorn(right)) or (secondObj and isFelthorn(secondObj)) then
            local r = pick('blademeister'); if r then return r end
        end

        -- 6) Angler: fishing pole.
        if right and effRec and isAnglerWeapon(right, effRec) then
            local r = pick('angler'); if r then return r end
        end

        -- 7) Huntsman: bow or crossbow.
        if effRec and isBowOrCrossbow(effRec) then
            local r = pick('huntsman'); if r then return r end
        end

        -- 7b) Apothecary: a thrown concoction or venefic vial (each gated on its
        --     own integration toggle, mirroring the live resolver).
        if right and effRec then
            local apoMatch =
                (integrationEnabled('thrownconcoctions') and isApothecaryWeapon(right, effRec))
                or (integrationEnabled('veneficvials') and isVeneficVialWeapon(right, effRec))
            if apoMatch then
                local r = pick('apothecary'); if r then return r end
            end
        end

        -- 7c) Axeman (throwing axe by name) — above the generic thrown branch.
        if right and effRec and isThrowingAxe(right, effRec) then
            local r = pick('axeman'); if r then return r end
        end

        -- 8) Twirler: thrown weapon.
        if effRec and isThrown(effRec) then
            local r = pick('twirler'); if r then return r end
        end

        -- 9) Thaumaturge: stave.
        if effRec and isStave(right, effRec) then
            local r = pick('thaumaturge'); if r then return r end
        end

        -- 10) Dualist: a Dual-Wielding off-hand WEAPON saved alongside a one-handed
        --     primary. The loadout stores that off-hand weapon separately, so
        --     secondIsWeapon stands in for the live isDualWielding() signal.
        if runtimeRec and isOneHandedMelee(runtimeRec) and secondIsWeapon then
            local r = pick('dualist'); if r then return r end
        end

        -- 11b) Forager: any Gardening and Farming tool/weapon (record-id match),
        --      above the weapon-type branches its tools would otherwise hit
        --      (Guisarmier/Axeman/Mjölnir/Thief), mirroring the live resolver.
        if right and effRec and isForagerWeapon(right, effRec) then
            local r = pick('forager'); if r then return r end
        end

        -- 12) Guisarmier: spear.
        if effRec and isSpear(effRec) then
            local r = pick('guisarmier'); if r then return r end
        end

        -- 13) Pitmen: the miner's pick.
        if right and effRec and isPitmanWeapon(right, effRec) then
            local r = pick('pitmen'); if r then return r end
        end

        -- 14) Axeman: any axe by type.
        if effRec and isAxe(effRec) then
            local r = pick('axeman'); if r then return r end
        end

        -- 15) Mjolnir: blunt one-handed or two-handed-close.
        if effRec and not isReforgerWeapon(right, effRec) and isBluntMjolnir(effRec) then
            local r = pick('mjolnir'); if r then return r end
        end

        -- 16) Zweihänder: long-blade two-handed (excluding GRIP'd short blades,
        --     exactly as the live branch).
        if runtimeRec and isLongBladeTwoHand(runtimeRec)
            and not (effRec and isShortBlade(effRec)) then
            local r = pick('zweihander'); if r then return r end
        end

        -- 17) Soloist: long-blade one-handed.
        if runtimeRec and isLongBladeOneHand(runtimeRec) then
            local r = pick('soloist'); if r then return r end
        end

        -- 18) Thief: short blade.
        if effRec and isShortBlade(effRec) then
            local r = pick('thief'); if r then return r end
        end

        -- (Brawler is a drawn-fists runtime state — see header — so a weaponless
        --  loadout falls through to Commoner below.)

        -- 20) Commoner: the fallback.
        local r = pick('commoner'); if r then return r end
        return { id = 'commoner' }
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

        local function pick(id, reason)
            if not stanceEnabled(id) then return nil end
            return { id = id, reason = reason }
        end

        -- 1) Locksmith: a lockpick OR a probe is READIED in the right hand.
        --    Sheathing keeps the tool in the CarriedRight slot (equipping is
        --    separate from drawing in OpenMW), so a slot read alone would keep
        --    Locksmith active forever after one use. We therefore also require the
        --    weapon stance to be DRAWN (stanceMode == 'weapon'); when the player
        --    sheathes, getStance() reports Nothing and we fall through to Commoner
        --    below. Merely carrying tools in inventory never counts.
        if stanceMode == 'weapon' and hasLockpickOrProbeEquipped() then
            local r = pick('locksmith', 'lockpick or probe readied')
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
        --
        --    Explicitly excluded when Felthorn is in the off-hand: without this
        --    guard the hammer in the right hand wins at priority 4 and the
        --    Blademeister check at priority 5 is never reached, leaving Reforger
        --    active for the entire dual-wield session.
        if effRec and isReforgerWeapon(right, effRec) and not isFelthornInOffhand() then
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
        --    Comes before every weapon-type branch (Huntsman, etc.)
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

        -- 7b) Apothecary: a thrown APOTHECARY item is equipped — a Thrown Concoction
        --     OR a Throwning Venefic Vial. Both are MarksmanThrown weapons, so
        --     without this branch they would be claimed by the generic Twirler
        --     thrown-weapon branch (8) below. Each source is gated on its OWN
        --     integration toggle, so disabling one (e.g. Thrown Concoctions) still
        --     lets the other (Venefic Vials) route to Apothecary, and disabling both
        --     — or the Apothecary stance itself (pick → stanceEnabled) — lets the
        --     item fall through to Twirler. Sits here, after Huntsman and before
        --     Twirler, exactly as Angler (6) and Pitmen (13) sit above the broad
        --     weapon-type branch they would otherwise hit.
        if right and effRec then
            local apoMatch =
                (integrationEnabled('thrownconcoctions') and isApothecaryWeapon(right, effRec))
                or (integrationEnabled('veneficvials') and isVeneficVialWeapon(right, effRec))
            if apoMatch then
                local r = pick('apothecary', 'thrown apothecary item equipped')
                if r then return r end
            end
        end

        -- 7c) Axeman (throwing axe): a THROWN weapon whose name marks it a throwing
        --     axe routes to Axeman rather than the generic Twirler thrown-weapon
        --     branch (8) below, so throwing axes train and score as axes. Same shape
        --     as the Apothecary concoction branch (7b) above and Angler/Pitmen: a
        --     record-level match sits just above the broad weapon-type branch it
        --     would otherwise fall into. Falls through to Twirler when Axeman is
        --     disabled (pick → stanceEnabled). (Real axe-TYPE weapons are still
        --     handled by the type-based Axeman branch at 14.)
        if right and effRec and isThrowingAxe(right, effRec) then
            local r = pick('axeman', 'throwing axe equipped')
            if r then return r end
        end

        -- 8) Twirler: thrown weapon (effective type). Separate stance from Huntsman;
        --    boosts the Throwing skill (not Marksman).
        if effRec and isThrown(effRec) then
            local r = pick('twirler', 'thrown weapon equipped')
            if r then return r end
        end

        -- 9) Thaumaturge: stave (effective type).
        if effRec and isStave(right, effRec) then
            local r = pick('thaumaturge', 'stave equipped')
            if r then return r end
        end

        -- 10) Dualist: Dual Wielding off-hand active with a one-handed primary.
        --    We use the RUNTIME record (what is actually equipped right now), not
        --    the GRIP-original, so a weapon GRIP-converted TO one-handed in order
        --    to be dual-wielded correctly triggers Dualist. (Conversely a 1H weapon
        --    GRIP-converted to 2H would read as 2H here and fall through, which is
        --    also correct — you can't dual-wield a 2H weapon.)
        if runtimeRec and isOneHandedMelee(runtimeRec) and isDualWielding(now) then
            local r = pick('dualist', 'dual-wielding')
            if r then return r end
        end

        -- 11) Fortifier is DEPRECATED as a stance. A shield equipped alongside a
        --     one-handed melee weapon no longer claims its own stance here; instead
        --     it falls through to that weapon's normal stance (Soloist / Thief /
        --     Mjölnir / Axeman / Blademeister) below, which formatStanceName then
        --     decorates with a "Fortified" prefix, and refreshFortified grants a
        --     Block bonus while so equipped. The old branch sat here, above the 1H
        --     weapon-type branches, specifically to pre-empt them; removing it lets
        --     a 1H weapon + shield resolve to its weapon stance as desired. (The
        --     bare-shield / shield-plus-fists case still falls through to Brawler,
        --     and gets no Fortified prefix or bonus — "Fortified" requires a
        --     compatible weapon.)

        -- 11b) Forager: any Gardening and Farming tool/weapon, matched by record
        --      id. Sits here — above Guisarmier (spear) and the other weapon-type
        --      branches — because the Forager weapons span axe / blunt / short
        --      blade / spear types; a record-level match must claim them before
        --      Guisarmier (the Gardening Shovel is a spear), Axeman (the scythes
        --      and Harvest Hoe are axes), Mjölnir (the Gardening Hammer is blunt)
        --      or Thief (the Shears / Waterskins are short blades) can intercept.
        --      Falls through to those type branches when Forager is disabled.
        if right and effRec and isForagerWeapon(right, effRec) then
            local r = pick('forager', 'gardening/harvesting tool equipped')
            if r then return r end
        end

        -- 12) Guisarmier: spear (SpearTwoWide). Comes before Zweihänder so a
        --     spear's classification is unambiguous. (A spear is two-handed, so the
        --     effectively-impossible spear-plus-shield case does not arise.)
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
        --
        --    GRIP exclusion: Morrowind has no "ShortBladeTwoHand" type, so when
        --    GRIP converts a 1H short blade to a 2H form the converted (runtime)
        --    record is typed LongBladeTwoHand — which would wrongly route a
        --    GRIP'd shortsword to Zweihänder instead of Thief. We therefore skip
        --    Zweihänder when the GRIP-ORIGINAL record (effRec) is a short blade,
        --    letting it fall through to the Thief branch below.
        if runtimeRec and isLongBladeTwoHand(runtimeRec)
            and not (effRec and isShortBlade(effRec)) then
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

    return {
        resolveStance         = resolveStance,
        classifyRecord        = classifyRecord,
        isOneHandedMelee      = isOneHandedMelee,
        effectiveWeaponRecord = effectiveWeaponRecord,
        runtimeWeaponRecord   = runtimeWeaponRecord,
        getActiveForagerSubtype = getActiveForagerSubtype,
    }
end

return M
