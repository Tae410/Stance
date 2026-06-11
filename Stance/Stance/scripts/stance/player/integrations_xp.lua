--[[
    Stance! — external-mod XP event handlers (player/integrations_xp.lua)

    The per-integration XP handlers: N'Garde parries, Simply Mining, Fishing,
    Oblivion-Style Lockpicking, deployable hazards (Traps / Oil Flask),
    merchant + Commercium barter, Disenchanting, Transcribe, Commoner talking,
    and Gothic Style Knockout. Each is a pure consumer: it reads settings and
    the active stance, then credits XP through the injected grant functions.

    Mid-save safety: these handlers own no persisted state. The only module
    state is talkSpokenNPCs (the session-scoped spoken-NPC set), which by
    design never enters the save file — identical lifecycle to before the
    extraction. Event registration stays in init.lua with the same event
    names, bound to these functions. (talkDebounce remains in init.lua with
    the UiModeChanged wrapper that owns it.)

    Dependencies (injected via ctx):
        self, types, core    — engine handles
        config               — scripts.stance.config
        Perks                — scripts.stance.perks
        readSetting          — function(group, key, default) → value
        debugLog             — function(msg, debugFlagKey)
        stanceEnabled        — function(stanceId) → boolean
        integrationEnabled   — function(integrationId) → boolean
        grantStanceXp        — function(amount, source, stanceId)
        grantStanceXpDirect  — function(amount, source, stanceId)
        getCoreSkillLevel    — function() → number
        getStanceLevel       — function(stanceId) → number
        getActiveStance      — function() → activeStanceId (string|nil)
]]

local M = {}

function M.new(ctx)
    local self  = ctx.self
    local types = ctx.types
    local core  = ctx.core
    local config = ctx.config
    local Perks  = ctx.Perks
    local readSetting         = ctx.readSetting
    local debugLog            = ctx.debugLog
    local stanceEnabled       = ctx.stanceEnabled
    local integrationEnabled  = ctx.integrationEnabled
    local grantStanceXp       = ctx.grantStanceXp
    local grantStanceXpDirect = ctx.grantStanceXpDirect
    local getCoreSkillLevel   = ctx.getCoreSkillLevel
    local getStanceLevel      = ctx.getStanceLevel
    local getActiveStance     = ctx.getActiveStance

    local function onNGardeParrySuccess(payload)
        if not readSetting('', 'enabled', true) then return end
        if not readSetting('Progression', 'xpOnParry', true) then return end

        -- N'Garde sends 'ngarde_parrySelf' to the parrying actor (the player, when
        -- the player parries) with { damageRemainingRatio, isPerfect, originalDamage }.
        -- 'isPerfect' is the authoritative perfect-parry flag (confirmed in
        -- N'Garde 1.3.0 controllers/parry.lua). The global 'ngarde_ParrySuccess'
        -- event is sound/VFX only and carries no perfect flag, so we do NOT use it.
        local perfect = (type(payload) == 'table') and payload.isPerfect or false

        if getActiveStance() then
            if perfect then
                grantStanceXp(config.xp.perfectParrySuccess or 2.4, 'perfectparry', getActiveStance())
            else
                grantStanceXp(config.xp.parrySuccess or 1.2, 'parry', getActiveStance())
            end
            debugLog(string.format('%s credited for a %sparry.',
                getActiveStance(), perfect and 'perfect ' or ''), 'debugPerkMessages')
        end

        -- Dispatch Fortifier parry perks (Warden Stance, Perfect Guard, Bulwark).
        Perks.onParry()
    end

    -- ─── SimplyMining integration ─────────────────────────────────────────────
    -- SimplyMining fires SimplyMining_notifyItem at the player whenever an ore
    -- mine completes successfully (regardless of tool used). We only act when:
    --   * the Pitmen stance is active (miner's pick equipped)
    --   * the SimplyMining integration is enabled in settings
    -- On success we grant mining XP and, if the relevant perks are unlocked,
    -- expose them via the Stance interface so SimplyMining (or a bridge mod)
    -- can read and apply the bonuses.
    local function onSimplyMiningOreSuccess(_payload)
        if not readSetting('', 'enabled', true) then return end
        if getActiveStance() ~= 'pitmen' then return end
        if not stanceEnabled('pitmen') then return end
        -- Integration gate: respect the player's toggle in settings.
        if not integrationEnabled('simplymining') then return end

        grantStanceXp(config.xp.miningSuccess or 3.0, 'mining', 'pitmen')
        debugLog('Pitmen credited for successful ore mine.', 'debugPerkMessages')
    end

    -- SimplyMining_startMining fires when the player begins mining a node.
    -- Pitmen checks whether the active perks should modify the mining duration
    -- and broadcasts a Stance_PitmenMiningStart event that a SimplyMining patch
    -- or bridge script can consume to adjust speed/yield accordingly.
    local function onSimplyMiningStartMining(_payload)
        if getActiveStance() ~= 'pitmen' then return end
        if not stanceEnabled('pitmen') then return end
        if not integrationEnabled('simplymining') then return end

        local coreLevel = getCoreSkillLevel()
        -- Vein Reader (level 50): 20% faster mining.
        local speedBonus  = (coreLevel >= 50)  and 0.20 or 0.0
        -- Pit Boss (level 100): stacks another 10% (total 30%).
        if coreLevel >= 100 then speedBonus = speedBonus + 0.10 end
        -- Prospector (level 75): 15% ore yield bonus.
        local yieldBonus  = (coreLevel >= 75)  and 0.15 or 0.0

        -- Broadcast for any interested listener (SimplyMining bridge, etc.).
        core.sendGlobalEvent('Stance_PitmenMiningStart', {
            speedBonus  = speedBonus,
            yieldBonus  = yieldBonus,
            stanceLevel = getStanceLevel('pitmen'),
            coreLevel   = coreLevel,
        })
    end

    -- ─── Fishing integration ──────────────────────────────────────────────────
    -- The Fishing mod fires 'Fishing_playerCaughtFish' at the player whenever a
    -- fish is successfully landed. We only act when:
    --   * the Angler stance is active (fishing pole equipped)
    --   * the Fishing integration is enabled in settings
    -- On success we grant fishing XP and, if the relevant perks are unlocked,
    -- broadcast a 'Stance_AnglerCatch' event that the Fishing mod (or a bridge)
    -- can consume to apply the Catch and Release / Trophy Cast bonuses.
    --
    -- NOTE: If your Fishing mod fires a different event name (e.g.
    -- 'Fishing_CaughtFish', 'Fishing_notifyItem'), add an alias entry in
    -- the eventHandlers table at the bottom of this file.
    local function onFishingCatch(payload)
        if not readSetting('', 'enabled', true) then return end
        if getActiveStance() ~= 'angler' then return end
        if not stanceEnabled('angler') then return end
        if not integrationEnabled('fishing') then return end

        grantStanceXp(config.xp.fishingCatch or 3.0, 'fishing', 'angler')
        debugLog('Angler credited for successful fish catch.', 'debugPerkMessages')

        -- Broadcast perk-bonus data for any listener (Fishing bridge, etc.).
        local coreLevel = getCoreSkillLevel()
        -- Catch and Release (level 50): +10% bonus-fish chance.
        local bonusFishChance = (coreLevel >= 50) and 0.10 or 0.0
        -- Trophy Cast (level 75): treat Fishing skill as 10 points higher.
        local skillBonus      = (coreLevel >= 75) and 10  or 0
        -- Master Angler (level 100): 20% faster cast time.
        local castSpeedBonus  = (coreLevel >= 100) and 0.20 or 0.0

        core.sendGlobalEvent('Stance_AnglerCatch', {
            bonusFishChance = bonusFishChance,
            skillBonus      = skillBonus,
            castSpeedBonus  = castSpeedBonus,
            stanceLevel     = getStanceLevel('angler'),
            coreLevel       = coreLevel,
        })
    end

    -- Oblivion-Style Lockpicking integration.
    -- OSL fires 'OSL_LockpickSuccess' (global) on every successful pick/probe;
    -- Stance's global script relays it here as 'Stance_LockpickSuccess'. We grant
    -- Locksmith XP when Locksmith is the active stance (which it is whenever a
    -- lockpick or probe is readied, since that's exactly how Locksmith is
    -- detected). The `probe` flag distinguishes trap-disarming from lock-picking;
    -- both grant the same XP here, but it's passed through for future use.
    local function onLockpickSuccess(payload)
        if not readSetting('', 'enabled', true) then return end
        if getActiveStance() ~= 'locksmith' then return end
        if not stanceEnabled('locksmith') then return end
        if not integrationEnabled('oblivionlockpicking') then return end
        if not readSetting('Progression', 'xpOnLockpick', true) then return end

        grantStanceXp(config.xp.lockpickSuccess or 2.0, 'lockpick', 'locksmith')
        local what = (type(payload) == 'table' and payload.probe) and 'trap disarm' or 'lock pick'
        debugLog('Locksmith credited for successful ' .. what .. '.', 'debugPerkMessages')
    end

    -- Deployable-hazard integrations (Traps → Thief, Oil Flask → Apothecary).
    -- scripts/stance/hazard.lua (a local script on ACTIVATOR/LIGHT objects) detects
    -- a non-player actor caught by an armed trap or standing in a burning oil pool
    -- and fires 'Stance_HazardHit' { kind, victim }; the global script relays it
    -- here. Unlike the weapon stances, these hazards are deployed and trigger while
    -- the player may be wielding anything, so they credit a FIXED stance directly
    -- (grantStanceXpDirect) rather than the active one — trapping is Thief's craft,
    -- a lit oil pool is Apothecary's. Each credit is gated on the relevant
    -- integration toggle, the stance being enabled, and its Progression XP toggle
    -- (the gate is enforced inside grantStanceXpDirect via the source key).
    local function onHazardHit(payload)
        if not readSetting('', 'enabled', true) then return end
        if type(payload) ~= 'table' then return end
        local kind = payload.kind

        if kind == 'trap' then
            if not integrationEnabled('traps') then return end
            if not stanceEnabled('thief') then return end
            grantStanceXpDirect(config.xp.trapHit or 3.0, 'trap', 'thief')
            debugLog('A trap caught an enemy — Thief credited.', 'debugPerkMessages')
        elseif kind == 'oil' then
            if not integrationEnabled('oilflask') then return end
            if not stanceEnabled('apothecary') then return end
            grantStanceXpDirect(config.xp.oilBurnTick or 0.5, 'oilburn', 'apothecary')
            debugLog('An enemy burned in an oil fire — Apothecary credited.', 'debugPerkMessages')
        end
    end

    local function onMerchantTransaction(_payload)
        if not readSetting('', 'enabled', true) then return end
        -- Commoner XP only credits while Commoner is the active stance
        -- (grantStanceXp self-guards, but checking here avoids a wasted call).
        if getActiveStance() == 'commoner' then
            grantStanceXp(config.xp.merchantTransaction or 1.5, 'merchant', 'commoner')
        end
    end

    -- ── Disenchanting integration (Arcanist + Thaumaturge) ────────────────────
    -- The Disenchanting mod fires the PLAYER event
    -- 'disenchanting_finishedDisenchanting' { enchPoints, effects, ... } on every
    -- SUCCESSFUL disenchant. Unravelling an enchantment is arcane work, so both
    -- the Arcanist (spellcasting) and Thaumaturge (stave) stances earn from it —
    -- whichever is active at the time. The reward is a flat base plus a capped
    -- bonus scaled by the enchantment magnitude (enchPoints).
    local DISENCHANT_STANCES = { arcanist = true, thaumaturge = true }

    local function onDisenchantFinished(payload)
        if not readSetting('', 'enabled', true) then return end
        if not DISENCHANT_STANCES[getActiveStance()] then return end
        if not stanceEnabled(getActiveStance()) then return end
        if not integrationEnabled('disenchanting') then return end
        if not readSetting('Progression', 'xpOnDisenchant', true) then return end

        local points = 0
        if type(payload) == 'table' then points = tonumber(payload.enchPoints) or 0 end
        local base  = config.xp.disenchantBase or 1.5
        local bonus = math.min((config.xp.disenchantMaxBonus or 6.0),
                               points * (config.xp.disenchantPerPoint or 0.05))
        grantStanceXp(base + bonus, 'disenchant', getActiveStance())
        debugLog(string.format('%s credited for a disenchant (%.1f points).',
            getActiveStance(), points), 'debugPerkMessages')
    end

    -- ── Commercium / Fair Trade integration (Commoner) ────────────────────────
    -- Relayed from the FairTrade_Transaction global event via global.lua as
    -- 'Stance_CommerciumTransaction' { absValue, isBuying }. Driving a hard bargain
    -- is a Commoner's craft, so it earns Commoner XP: a flat base plus a capped
    -- bonus scaled by the value of the deal. This is independent of the vanilla
    -- merchant XP source (onMerchantTransaction) — with Commercium installed,
    -- transactions flow through Commercium's event instead, and this handles them.
    local function onCommerciumTransaction(payload)
        if not readSetting('', 'enabled', true) then return end
        if getActiveStance() ~= 'commoner' then return end
        if not stanceEnabled('commoner') then return end
        if not integrationEnabled('commercium') then return end
        if not readSetting('Progression', 'xpOnCommercium', true) then return end

        local value = 0
        if type(payload) == 'table' then value = tonumber(payload.absValue) or 0 end
        local base  = config.xp.commerciumBase or 1.5
        local bonus = math.min((config.xp.commerciumMaxBonus or 4.0),
                               value * (config.xp.commerciumPerValue or 0.002))
        grantStanceXp(base + bonus, 'commercium', 'commoner')
        debugLog(string.format('Commoner credited for a Commercium deal (value %d).',
            math.floor(value)), 'debugPerkMessages')
    end

    -- ── Transcribe integration (Arcanist + Thaumaturge) ───────────────────────
    -- Relayed from the TRAN_doTranscribe global event via global.lua as
    -- 'Stance_TranscribeSuccess'. Copying an enchantment into a castable spell is
    -- arcane work, so whichever of Arcanist or Thaumaturge is active earns XP.
    local function onTranscribeSuccess(_payload)
        if not readSetting('', 'enabled', true) then return end
        if not DISENCHANT_STANCES[getActiveStance()] then return end  -- arcanist/thaumaturge
        if not stanceEnabled(getActiveStance()) then return end
        if not integrationEnabled('transcribe') then return end
        if not readSetting('Progression', 'xpOnTranscribe', true) then return end

        grantStanceXp(config.xp.transcribeSuccess or 3.0, 'transcribe', getActiveStance())
        debugLog(getActiveStance() .. ' credited for a spell transcription.', 'debugPerkMessages')
    end

    -- ── Commoner: talking to NPCs (pairs with Talking Trains Speechcraft) ─────
    -- A conversation is a Commoner's stock-in-trade. When the player opens dialogue
    -- with an NPC while Commoner is the active stance (weapons sheathed), grant
    -- Commoner XP. The first conversation with a given NPC is worth more than
    -- repeat visits, so grinding one NPC isn't optimal.
    --
    -- Driven by the engine UiModeChanged signal (newMode == 'Dialogue', oldMode ==
    -- nil, NPC in data.arg) — the same signal the Talking Trains Speechcraft mod
    -- uses. This source therefore works whether or not Talking Trains is installed;
    -- when both are present, vanilla Speechcraft and Commoner XP both advance.
    -- talkDebounce prevents a double-grant for one open; the spoken-NPC set is
    -- session-scoped (resets on load) to keep the save clean while still rewarding
    -- breadth over repetition.
    local talkSpokenNPCs = {}

    local function onDialogueStarted(npc)
        if not readSetting('', 'enabled', true) then return end
        if getActiveStance() ~= 'commoner' then return end
        if not stanceEnabled('commoner') then return end
        if not readSetting('Progression', 'xpOnTalk', true) then return end

        local npcId = nil
        if npc then
            local ok = pcall(function()
                if npc.type == types.NPC then npcId = npc.id end
            end)
            if not ok then npcId = nil end
        end

        local isFirst = true
        if npcId then
            if talkSpokenNPCs[npcId] then isFirst = false else talkSpokenNPCs[npcId] = true end
        end

        local amount = isFirst and (config.xp.dialogueTalkFirst or 1.0)
                                or  (config.xp.dialogueTalkRepeat or 0.25)
        grantStanceXp(amount, 'talk', 'commoner')
        debugLog(string.format('Commoner credited for %s conversation%s.',
            isFirst and 'a new' or 'a repeat',
            npcId and (' with ' .. tostring(npcId)) or ''), 'debugPerkMessages')
    end

    local function onGskKnockdown(payload)
        if not readSetting('', 'enabled', true) then return end
        if type(payload) ~= 'table' then return end
        local attacker = payload.attacker
        if not attacker then return end
        local attackerId, playerId
        pcall(function() attackerId = attacker.id end)
        pcall(function() playerId = self.object.id end)
        if not attackerId or attackerId ~= playerId then return end
        if getActiveStance() == 'brawler' and stanceEnabled('brawler') then
            grantStanceXp(config.xp.combatKill or 2.0, 'kill', 'brawler')
            debugLog('GSK knockout credited to Brawler.', 'debugPerkMessages')
        end
    end

    return {
        onNGardeParrySuccess = onNGardeParrySuccess,
        onSimplyMiningOreSuccess = onSimplyMiningOreSuccess,
        onSimplyMiningStartMining = onSimplyMiningStartMining,
        onFishingCatch = onFishingCatch,
        onLockpickSuccess = onLockpickSuccess,
        onHazardHit = onHazardHit,
        onMerchantTransaction = onMerchantTransaction,
        onDisenchantFinished = onDisenchantFinished,
        onCommerciumTransaction = onCommerciumTransaction,
        onTranscribeSuccess = onTranscribeSuccess,
        onDialogueStarted = onDialogueStarted,
        onGskKnockdown = onGskKnockdown,
    }
end

return M
