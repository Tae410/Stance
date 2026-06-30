--[[
    Stance! — Settings Pages (MENU scope)

    Settings are split across FIVE pages so no single page is an endless scroll.
    The same nine groups as before are simply distributed across the pages; their
    storage keys are unchanged, so this is a pure UI reorganisation — saved
    settings carry over and readSetting() in init.lua needs no changes.

    Page / group layout:
        Stance (main)          1) General        — master toggles
                               2) Stances        — per-stance on/off (detection order)
        Stance — Perks & XP    3) Perks          — master + per-stance perk toggles
                               4) Progression    — race/class bonuses, XP sources, multiplier
        Stance — Integrations  5) Integrations   — external-mod hookups (grouped by category)
        Stance — Interface     6) HUD Indicator  — overlay show/lock/size/position/Muse readout
                               7) Tooltip        — what to show inside the skill tooltip
                               8) Notifications  — perk-unlocked popup style/position/duration
        Stance — Debug         9) Debug          — categorised log toggles

    Storage paths (UNCHANGED by the page split):
        Each group's settings live in `Settings_Stance` for General, or
        `Settings_Stance_<GroupName>` for everything else. The group-name
        suffix matches the readSetting() suffix used in init.lua. The `page`
        field only decides which page a group is displayed on.

    Setting key conventions:
        - Booleans use `enable*` or `show*` (positive sense — the toggle
          turns the feature ON when checked).
        - Numbers use the plain noun (e.g. `xpMultiplier`, `popupDuration`).
        - Selects (dropdowns) use the plain noun returning a string value
          that init.lua compares to named constants.

    All settings reference l10n keys via the `name` and `description`
    fields; the actual display strings live in l10n/Stance/en.yaml.
]]

local I = require('openmw.interfaces')

local MODNAME = 'Stance'

-- Page keys. The main page keeps MODNAME ('Stance') so existing storage and
-- readSetting() calls are untouched. The other four are sub-pages that group
-- related settings so no single page is an endless scroll. IMPORTANT: only which
-- page each group is shown under changes here — every group `key` (the storage
-- path) is unchanged, so saved settings carry over with no migration.
local PAGE_MAIN         = MODNAME
local PAGE_PERKS_XP     = MODNAME .. 'PerksXp'
local PAGE_INTEGRATIONS = MODNAME .. 'Integrations'
local PAGE_INTERFACE    = MODNAME .. 'Interface'
local PAGE_DEBUG        = MODNAME .. 'Debug'

I.Settings.registerPage {
    key = PAGE_MAIN,
    l10n = MODNAME,
    name = 'PageName',
    description = 'PageDescription',
}
I.Settings.registerPage {
    key = PAGE_PERKS_XP,
    l10n = MODNAME,
    name = 'PagePerksXpName',
    description = 'PagePerksXpDescription',
}
I.Settings.registerPage {
    key = PAGE_INTEGRATIONS,
    l10n = MODNAME,
    name = 'PageIntegrationsName',
    description = 'PageIntegrationsDescription',
}
I.Settings.registerPage {
    key = PAGE_INTERFACE,
    l10n = MODNAME,
    name = 'PageInterfaceName',
    description = 'PageInterfaceDescription',
}
I.Settings.registerPage {
    key = PAGE_DEBUG,
    l10n = MODNAME,
    name = 'PageDebugName',
    description = 'PageDebugDescription',
}

-- ─── 1. General ───────────────────────────────────────────────────────────
-- High-level on/off switches. Most users will only touch the first one.
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME,
    page = MODNAME,
    l10n = MODNAME,
    name = 'GroupGeneralName',
    description = 'GroupGeneralDescription',
    order = 1,
    permanentStorage = true,
    settings = {
        { key = 'enabled',                 renderer = 'checkbox',
          name = 'SettingEnabled',                 description = 'SettingEnabledDescription',                 default = true },
        { key = 'enableSkillRegistration', renderer = 'checkbox',
          name = 'SettingEnableSkillRegistration', description = 'SettingEnableSkillRegistrationDescription', default = true },
        { key = 'enableAttributeSwap',     renderer = 'checkbox',
          name = 'SettingEnableAttributeSwap',     description = 'SettingEnableAttributeSwapDescription',     default = true },
        { key = 'announceStanceChange',    renderer = 'checkbox',
          name = 'SettingAnnounceStanceChange',    description = 'SettingAnnounceStanceChangeDescription',    default = true },
        { key = 'announceMuseSummary',     renderer = 'checkbox',
          name = 'SettingAnnounceMuseSummary',     description = 'SettingAnnounceMuseSummaryDescription',     default = true },
    },
}

-- ─── 2. Stances ───────────────────────────────────────────────────────────
-- All 15 stance enable toggles. Ordered by detection priority so reading
-- the list top-to-bottom matches the order Stance! checks each stance.
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Stances',
    page = MODNAME,
    l10n = MODNAME,
    name = 'GroupStancesName',
    description = 'GroupStancesDescription',
    order = 2,
    permanentStorage = true,
    settings = {
        { key = 'enableLocksmith',   renderer = 'checkbox', name = 'SettingEnableLocksmith',   description = 'SettingEnableLocksmithDescription',   default = true },
        { key = 'enableCommoner',    renderer = 'checkbox', name = 'SettingEnableCommoner',    description = 'SettingEnableCommonerDescription',    default = true },
        { key = 'enableMuse',        renderer = 'checkbox', name = 'SettingEnableMuse',        description = 'SettingEnableMuseDescription',        default = true },
        { key = 'enableArcanist',     renderer = 'checkbox', name = 'SettingEnableArcanist',     description = 'SettingEnableArcanistDescription',     default = true },
        { key = 'enableReforger',     renderer = 'checkbox', name = 'SettingEnableReforger',     description = 'SettingEnableReforgerDescription',     default = true },
        { key = 'enableBlademeister', renderer = 'checkbox', name = 'SettingEnableBlademeister', description = 'SettingEnableBlademeisterDescription', default = true },
        { key = 'enableHuntsman',     renderer = 'checkbox', name = 'SettingEnableHuntsman',     description = 'SettingEnableHuntsmanDescription',     default = true },
        { key = 'enableTwirler',     renderer = 'checkbox', name = 'SettingEnableTwirler',     description = 'SettingEnableTwirlerDescription',     default = true },
        { key = 'enableThaumaturge', renderer = 'checkbox', name = 'SettingEnableThaumaturge', description = 'SettingEnableThaumaturgeDescription', default = true },
        { key = 'enableDualist',     renderer = 'checkbox', name = 'SettingEnableDualist',     description = 'SettingEnableDualistDescription',     default = true },
        { key = 'enableFortified',   renderer = 'checkbox', name = 'SettingEnableFortified',   description = 'SettingEnableFortifiedDescription',   default = true },
        { key = 'enableSneaky',      renderer = 'checkbox', name = 'SettingEnableSneaky',      description = 'SettingEnableSneakyDescription',      default = true },
        { key = 'enableGuisarmier',  renderer = 'checkbox', name = 'SettingEnableGuisarmier',  description = 'SettingEnableGuisarmierDescription',  default = true },
        { key = 'enableAxeman',      renderer = 'checkbox', name = 'SettingEnableAxeman',      description = 'SettingEnableAxemanDescription',      default = true },
        { key = 'enablePitmen',      renderer = 'checkbox', name = 'SettingEnablePitmen',      description = 'SettingEnablePitmenDescription',      default = true },
        { key = 'enableAngler',      renderer = 'checkbox', name = 'SettingEnableAngler',      description = 'SettingEnableAnglerDescription',      default = true },
        { key = 'enableMjolnir',     renderer = 'checkbox', name = 'SettingEnableMjolnir',     description = 'SettingEnableMjolnirDescription',     default = true },
        { key = 'enableZweihander',  renderer = 'checkbox', name = 'SettingEnableZweihander',  description = 'SettingEnableZweihanderDescription',  default = true },
        { key = 'enableSoloist',     renderer = 'checkbox', name = 'SettingEnableSoloist',     description = 'SettingEnableSoloistDescription',     default = true },
        { key = 'enableThief',       renderer = 'checkbox', name = 'SettingEnableThief',       description = 'SettingEnableThiefDescription',       default = true },
        { key = 'enableBrawler',     renderer = 'checkbox', name = 'SettingEnableBrawler',     description = 'SettingEnableBrawlerDescription',     default = true },
        { key = 'enableBrawlerGauntlets', renderer = 'checkbox', name = 'SettingEnableBrawlerGauntlets', description = 'SettingEnableBrawlerGauntletsDescription', default = true },
        { key = 'enableApothecary',  renderer = 'checkbox', name = 'SettingEnableApothecary',  description = 'SettingEnableApothecaryDescription',  default = true },
        { key = 'enableForager',     renderer = 'checkbox', name = 'SettingEnableForager',     description = 'SettingEnableForagerDescription',     default = true },
        { key = 'enableForagerGardeningXp', renderer = 'checkbox', name = 'SettingEnableForagerGardeningXp', description = 'SettingEnableForagerGardeningXpDescription', default = true },
    },
}

-- ─── 3. Perks ─────────────────────────────────────────────────────────────
-- Master perks toggle plus one toggle per stance. Stance order matches the
-- Stances group above so the two pages line up visually.
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Perks',
    page = PAGE_PERKS_XP,
    l10n = MODNAME,
    name = 'GroupPerksName',
    description = 'GroupPerksDescription',
    order = 3,
    permanentStorage = true,
    settings = {
        { key = 'enableAllPerks',         renderer = 'checkbox', name = 'SettingEnableAllPerks',         description = 'SettingEnableAllPerksDescription',         default = true },
        { key = 'enableLocksmithPerks',   renderer = 'checkbox', name = 'SettingEnableLocksmithPerks',   description = 'SettingEnableLocksmithPerksDescription',   default = true },
        { key = 'enableCommonerPerks',    renderer = 'checkbox', name = 'SettingEnableCommonerPerks',    description = 'SettingEnableCommonerPerksDescription',    default = true },
        { key = 'enableArcanistPerks',     renderer = 'checkbox', name = 'SettingEnableArcanistPerks',     description = 'SettingEnableArcanistPerksDescription',     default = true },
        { key = 'enableReforgerPerks',     renderer = 'checkbox', name = 'SettingEnableReforgerPerks',     description = 'SettingEnableReforgerPerksDescription',     default = true },
        { key = 'enableBlademeisterPerks', renderer = 'checkbox', name = 'SettingEnableBlademeisterPerks', description = 'SettingEnableBlademeisterPerksDescription', default = true },
        { key = 'enableHuntsmanPerks',     renderer = 'checkbox', name = 'SettingEnableHuntsmanPerks',     description = 'SettingEnableHuntsmanPerksDescription',     default = true },
        { key = 'enableTwirlerPerks',     renderer = 'checkbox', name = 'SettingEnableTwirlerPerks',     description = 'SettingEnableTwirlerPerksDescription',     default = true },
        { key = 'enableThaumaturgePerks', renderer = 'checkbox', name = 'SettingEnableThaumaturgePerks', description = 'SettingEnableThaumaturgePerksDescription', default = true },
        { key = 'enableDualistPerks',     renderer = 'checkbox', name = 'SettingEnableDualistPerks',     description = 'SettingEnableDualistPerksDescription',     default = true },
        { key = 'enableGuisarmierPerks',  renderer = 'checkbox', name = 'SettingEnableGuisarmierPerks',  description = 'SettingEnableGuisarmierPerksDescription',  default = true },
        { key = 'enableAxemanPerks',      renderer = 'checkbox', name = 'SettingEnableAxemanPerks',      description = 'SettingEnableAxemanPerksDescription',      default = true },
        { key = 'enablePitmenPerks',      renderer = 'checkbox', name = 'SettingEnablePitmenPerks',      description = 'SettingEnablePitmenPerksDescription',      default = true },
        { key = 'enableAnglerPerks',      renderer = 'checkbox', name = 'SettingEnableAnglerPerks',      description = 'SettingEnableAnglerPerksDescription',      default = true },
        { key = 'enableMjolnirPerks',     renderer = 'checkbox', name = 'SettingEnableMjolnirPerks',     description = 'SettingEnableMjolnirPerksDescription',     default = true },
        { key = 'enableZweihanderPerks',  renderer = 'checkbox', name = 'SettingEnableZweihanderPerks',  description = 'SettingEnableZweihanderPerksDescription',  default = true },
        { key = 'enableSoloistPerks',     renderer = 'checkbox', name = 'SettingEnableSoloistPerks',     description = 'SettingEnableSoloistPerksDescription',     default = true },
        { key = 'enableThiefPerks',       renderer = 'checkbox', name = 'SettingEnableThiefPerks',       description = 'SettingEnableThiefPerksDescription',       default = true },
        { key = 'enableBrawlerPerks',     renderer = 'checkbox', name = 'SettingEnableBrawlerPerks',     description = 'SettingEnableBrawlerPerksDescription',     default = true },
        { key = 'enableApothecaryPerks',  renderer = 'checkbox', name = 'SettingEnableApothecaryPerks',  description = 'SettingEnableApothecaryPerksDescription',  default = true },
        { key = 'enableForagerPerks',     renderer = 'checkbox', name = 'SettingEnableForagerPerks',     description = 'SettingEnableForagerPerksDescription',     default = true },
    },
}

-- ─── 4. Progression ───────────────────────────────────────────────────────
-- Race / class bonuses, every XP source, and the global XP multiplier.
-- One group for "how does the player gain Stance levels?"
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Progression',
    page = PAGE_PERKS_XP,
    l10n = MODNAME,
    name = 'GroupProgressionName',
    description = 'GroupProgressionDescription',
    order = 4,
    permanentStorage = true,
    settings = {
        { key = 'enableRaceBonuses', renderer = 'checkbox', name = 'SettingEnableRaceBonuses', description = 'SettingEnableRaceBonusesDescription', default = true },
        { key = 'enableClassBonus',  renderer = 'checkbox', name = 'SettingEnableClassBonus',  description = 'SettingEnableClassBonusDescription',  default = true },
        { key = 'xpOnHit',           renderer = 'checkbox', name = 'SettingXpOnHit',           description = 'SettingXpOnHitDescription',           default = true },
        { key = 'xpOnKill',          renderer = 'checkbox', name = 'SettingXpOnKill',          description = 'SettingXpOnKillDescription',          default = true },
        { key = 'xpOnSpellCast',     renderer = 'checkbox', name = 'SettingXpOnSpellCast',     description = 'SettingXpOnSpellCastDescription',     default = true },
        { key = 'xpOnBlock',         renderer = 'checkbox', name = 'SettingXpOnBlock',         description = 'SettingXpOnBlockDescription',         default = true },
        { key = 'xpOnParry',         renderer = 'checkbox', name = 'SettingXpOnParry',         description = 'SettingXpOnParryDescription',         default = true },
        { key = 'xpOnTime',          renderer = 'checkbox', name = 'SettingXpOnTime',          description = 'SettingXpOnTimeDescription',          default = true },
        { key = 'xpOnMerchant',      renderer = 'checkbox', name = 'SettingXpOnMerchant',      description = 'SettingXpOnMerchantDescription',      default = true },
        { key = 'xpOnUpgrade',       renderer = 'checkbox', name = 'SettingXpOnUpgrade',       description = 'SettingXpOnUpgradeDescription',       default = true },
        { key = 'xpOnMining',        renderer = 'checkbox', name = 'SettingXpOnMining',        description = 'SettingXpOnMiningDescription',        default = true },
        { key = 'xpOnFishing',       renderer = 'checkbox', name = 'SettingXpOnFishing',       description = 'SettingXpOnFishingDescription',       default = true },
        { key = 'xpOnLockpick',      renderer = 'checkbox', name = 'SettingXpOnLockpick',      description = 'SettingXpOnLockpickDescription',      default = true },
        { key = 'xpOnTalk',          renderer = 'checkbox', name = 'SettingXpOnTalk',          description = 'SettingXpOnTalkDescription',          default = true },
        { key = 'xpOnDisenchant',    renderer = 'checkbox', name = 'SettingXpOnDisenchant',    description = 'SettingXpOnDisenchantDescription',    default = true },
        { key = 'xpOnCommercium',    renderer = 'checkbox', name = 'SettingXpOnCommercium',    description = 'SettingXpOnCommerciumDescription',    default = true },
        { key = 'xpOnTranscribe',    renderer = 'checkbox', name = 'SettingXpOnTranscribe',    description = 'SettingXpOnTranscribeDescription',    default = true },
        { key = 'xpOnConcoctionHit', renderer = 'checkbox', name = 'SettingXpOnConcoctionHit', description = 'SettingXpOnConcoctionHitDescription', default = true },
        { key = 'xpOnTrapHit',       renderer = 'checkbox', name = 'SettingXpOnTrapHit',       description = 'SettingXpOnTrapHitDescription',       default = true },
        { key = 'xpOnOilBurn',       renderer = 'checkbox', name = 'SettingXpOnOilBurn',       description = 'SettingXpOnOilBurnDescription',       default = true },
        { key = 'xpOnTrain',         renderer = 'checkbox', name = 'SettingXpOnTrain',         description = 'SettingXpOnTrainDescription',         default = true },
        { key = 'xpOnMltCritical',   renderer = 'checkbox', name = 'SettingXpOnMltCritical',   description = 'SettingXpOnMltCriticalDescription',   default = true },
        { key = 'xpOnMltMobility',   renderer = 'checkbox', name = 'SettingXpOnMltMobility',   description = 'SettingXpOnMltMobilityDescription',   default = true },
        {
            key = 'xpMultiplier',
            renderer = 'number',
            name = 'SettingXpMultiplier',
            description = 'SettingXpMultiplierDescription',
            default = 100,
            argument = { min = 0, max = 500, integer = true },
        },
    },
}

-- ─── 5. Integrations ──────────────────────────────────────────────────────
-- 12 external-mod hookups, ordered by category:
--   * Magic mods: Incantation, Meditation
--   * Combat mods: N'Garde, Dual Wielding, Gothic Style Knockout
--   * Weapon-style mods: Throwing, Staves, Bullseye, GRIP
--   * Crafting mods: Weapon Upgrade, Armor Upgrade
--   * Sibling mods: Toxicology
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Integrations',
    page = PAGE_INTEGRATIONS,
    l10n = MODNAME,
    name = 'GroupIntegrationsName',
    description = 'GroupIntegrationsDescription',
    order = 5,
    permanentStorage = true,
    settings = {
        -- Magic
        { key = 'integrateIncantation',    renderer = 'checkbox', name = 'SettingIntegrateIncantation',    description = 'SettingIntegrateIncantationDescription',    default = true },
        { key = 'integrateMeditation',     renderer = 'checkbox', name = 'SettingIntegrateMeditation',     description = 'SettingIntegrateMeditationDescription',     default = true },
        { key = 'integrateOSSC',           renderer = 'checkbox', name = 'SettingIntegrateOSSC',           description = 'SettingIntegrateOSSCDescription',           default = true },
        -- Combat
        { key = 'integrateNGarde',         renderer = 'checkbox', name = 'SettingIntegrateNGarde',         description = 'SettingIntegrateNGardeDescription',         default = true },
        { key = 'integrateDualWielding',   renderer = 'checkbox', name = 'SettingIntegrateDualWielding',   description = 'SettingIntegrateDualWieldingDescription',   default = true },
        { key = 'integrateGothicKnockout', renderer = 'checkbox', name = 'SettingIntegrateGothicKnockout', description = 'SettingIntegrateGothicKnockoutDescription', default = true },
        { key = 'integrateIronfist',       renderer = 'checkbox', name = 'SettingIntegrateIronfist',       description = 'SettingIntegrateIronfistDescription',       default = true },
        -- Weapon style
        { key = 'integrateThrowing',       renderer = 'checkbox', name = 'SettingIntegrateThrowing',       description = 'SettingIntegrateThrowingDescription',       default = true },
        { key = 'integrateStaves',         renderer = 'checkbox', name = 'SettingIntegrateStaves',         description = 'SettingIntegrateStavesDescription',         default = true },
        { key = 'integrateBullseye',       renderer = 'checkbox', name = 'SettingIntegrateBullseye',       description = 'SettingIntegrateBullseyeDescription',       default = true },
        { key = 'integrateGRIP',           renderer = 'checkbox', name = 'SettingIntegrateGRIP',           description = 'SettingIntegrateGRIPDescription',           default = true },
        { key = 'integrateBlademeister',   renderer = 'checkbox', name = 'SettingIntegrateBlademeister',   description = 'SettingIntegrateBlademeisterDescription',   default = true },
        { key = 'integrateSolTimedDirAttacks',      renderer = 'checkbox', name = 'SettingIntegrateSolTimedDirAttacks',      description = 'SettingIntegrateSolTimedDirAttacksDescription',      default = true },
        { key = 'integrateSolWeightyChargeAttacks', renderer = 'checkbox', name = 'SettingIntegrateSolWeightyChargeAttacks', description = 'SettingIntegrateSolWeightyChargeAttacksDescription', default = true },
        { key = 'integrateMoveLikeThis',            renderer = 'checkbox', name = 'SettingIntegrateMoveLikeThis',            description = 'SettingIntegrateMoveLikeThisDescription',            default = true },
        { key = 'integrateBardcraft',               renderer = 'checkbox', name = 'SettingIntegrateBardcraft',               description = 'SettingIntegrateBardcraftDescription',               default = true },
        -- Crafting / mining
        { key = 'integrateWeaponUpgrade',  renderer = 'checkbox', name = 'SettingIntegrateWeaponUpgrade',  description = 'SettingIntegrateWeaponUpgradeDescription',  default = true },
        { key = 'integrateArmorUpgrade',   renderer = 'checkbox', name = 'SettingIntegrateArmorUpgrade',   description = 'SettingIntegrateArmorUpgradeDescription',   default = true },
        { key = 'integrateSimplyMining',   renderer = 'checkbox', name = 'SettingIntegrateSimplyMining',   description = 'SettingIntegrateSimplyMiningDescription',   default = true },
        { key = 'integrateFishing',        renderer = 'checkbox', name = 'SettingIntegrateFishing',        description = 'SettingIntegrateFishingDescription',        default = true },
        { key = 'integrateOblivionLockpicking', renderer = 'checkbox', name = 'SettingIntegrateOblivionLockpicking', description = 'SettingIntegrateOblivionLockpickingDescription', default = true },
        { key = 'integrateThrownConcoctions',  renderer = 'checkbox', name = 'SettingIntegrateThrownConcoctions',  description = 'SettingIntegrateThrownConcoctionsDescription',  default = true },
        { key = 'integrateVeneficVials',   renderer = 'checkbox', name = 'SettingIntegrateVeneficVials',   description = 'SettingIntegrateVeneficVialsDescription',   default = true },
        { key = 'integrateTraps',          renderer = 'checkbox', name = 'SettingIntegrateTraps',          description = 'SettingIntegrateTrapsDescription',          default = true },
        { key = 'integrateOilFlask',       renderer = 'checkbox', name = 'SettingIntegrateOilFlask',       description = 'SettingIntegrateOilFlaskDescription',       default = true },
        { key = 'integrateSpellsword',     renderer = 'checkbox', name = 'SettingIntegrateSpellsword',     description = 'SettingIntegrateSpellswordDescription',     default = true },
        { key = 'integrateHackleLoPipes',  renderer = 'checkbox', name = 'SettingIntegrateHackleLoPipes',  description = 'SettingIntegrateHackleLoPipesDescription',  default = true },
        { key = 'integrateTalkingTrains',  renderer = 'checkbox', name = 'SettingIntegrateTalkingTrains',  description = 'SettingIntegrateTalkingTrainsDescription',  default = true },
        { key = 'integrateDisenchanting',  renderer = 'checkbox', name = 'SettingIntegrateDisenchanting',  description = 'SettingIntegrateDisenchantingDescription',  default = true },
        { key = 'integrateCommercium',     renderer = 'checkbox', name = 'SettingIntegrateCommercium',     description = 'SettingIntegrateCommerciumDescription',     default = true },
        { key = 'integrateTranscribe',     renderer = 'checkbox', name = 'SettingIntegrateTranscribe',     description = 'SettingIntegrateTranscribeDescription',     default = true },
        -- Religion
        { key = 'integrateEveningStar',    renderer = 'checkbox', name = 'SettingIntegrateEveningStar',    description = 'SettingIntegrateEveningStarDescription',    default = true },
        -- Sibling
        { key = 'integrateSneakIsGoodNow',  renderer = 'checkbox', name = 'SettingIntegrateSneakIsGoodNow',  description = 'SettingIntegrateSneakIsGoodNowDescription',  default = true },
        { key = 'integrateToxicology',     renderer = 'checkbox', name = 'SettingIntegrateToxicology',     description = 'SettingIntegrateToxicologyDescription',     default = true },
        { key = 'integrateEvasion',        renderer = 'checkbox', name = 'SettingIntegrateEvasion',        description = 'SettingIntegrateEvasionDescription',        default = true },
    },
}

-- ─── 6. HUD Indicator ─────────────────────────────────────────────────────
-- The on-screen text label that shows the active stance name. Draggable
-- when an inventory-like menu is open. Lock toggle disables drag without
-- hiding the indicator.
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_HUD',
    page = PAGE_INTERFACE,
    l10n = MODNAME,
    name = 'GroupHUDName',
    description = 'GroupHUDDescription',
    order = 6,
    permanentStorage = true,
    settings = {
        { key = 'showHudIndicator',         renderer = 'checkbox', name = 'SettingShowHudIndicator',         description = 'SettingShowHudIndicatorDescription',         default = true },
        { key = 'enableStanceCodex',        renderer = 'checkbox', name = 'SettingEnableStanceCodex',        description = 'SettingEnableStanceCodexDescription',        default = true },
        { key = 'codexHotkey',              renderer = 'select',   name = 'SettingCodexHotkey',              description = 'SettingCodexHotkeyDescription', default = 'K',
            argument = { items = { 'K', 'L', 'O', 'P', 'U', 'I', 'G', 'H', 'J', 'N', 'M', 'C', 'V', 'B', 'X', 'Z', 'Tab', 'Caps Lock', 'Left Bracket', 'Right Bracket' } } },
        { key = 'hudShowStanceName',        renderer = 'checkbox', name = 'SettingHudShowStanceName',        description = 'SettingHudShowStanceNameDescription',        default = true },
        { key = 'hudShowMusePerformance',   renderer = 'checkbox', name = 'SettingHudShowMusePerformance',   description = 'SettingHudShowMusePerformanceDescription',   default = true },
        { key = 'hudIndicatorLockPosition', renderer = 'checkbox', name = 'SettingHudIndicatorLockPosition', description = 'SettingHudIndicatorLockPositionDescription', default = false },
        {
            key = 'hudIndicatorIconSize',
            renderer = 'number',
            name = 'SettingHudIndicatorIconSize',
            description = 'SettingHudIndicatorIconSizeDescription',
            default = 48,
            argument = { min = 8, max = 96, integer = true },
        },
        {
            key = 'hudIndicatorX',
            renderer = 'number',
            name = 'SettingHudIndicatorX',
            description = 'SettingHudIndicatorXDescription',
            default = 0,
            argument = { min = 0, max = 10000, integer = true },
        },
        {
            key = 'hudIndicatorY',
            renderer = 'number',
            name = 'SettingHudIndicatorY',
            description = 'SettingHudIndicatorYDescription',
            default = 0,
            argument = { min = 0, max = 10000, integer = true },
        },
    },
}

-- ─── 7. Tooltip ───────────────────────────────────────────────────────────
-- What goes inside the dynamic Stance-skill tooltip in the stats window.
-- All toggles default to ON so first-time players see the full tooltip.
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Tooltip',
    page = PAGE_INTERFACE,
    l10n = MODNAME,
    name = 'GroupTooltipName',
    description = 'GroupTooltipDescription',
    order = 7,
    permanentStorage = true,
    settings = {
        { key = 'showMechanicTooltips',    renderer = 'checkbox', name = 'SettingShowMechanicTooltips',    description = 'SettingShowMechanicTooltipsDescription',    default = true },
        { key = 'showPerkTooltips',        renderer = 'checkbox', name = 'SettingShowPerkTooltips',        description = 'SettingShowPerkTooltipsDescription',        default = true },
        { key = 'tooltipUnlockedOnly',     renderer = 'checkbox', name = 'SettingTooltipUnlockedOnly',     description = 'SettingTooltipUnlockedOnlyDescription',     default = false },
    },
}

-- ─── 8. Notifications ─────────────────────────────────────────────────────
-- Perk-unlocked popup style, position, duration, and stack behavior.
-- Uses `select` dropdowns instead of opaque integer codes so labels match
-- behavior at a glance.
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Notifications',
    page = PAGE_INTERFACE,
    l10n = MODNAME,
    name = 'GroupNotificationsName',
    description = 'GroupNotificationsDescription',
    order = 8,
    permanentStorage = true,
    settings = {
        {
            key = 'perkMessageStyle',
            renderer = 'select',
            name = 'SettingPerkMessageStyle',
            description = 'SettingPerkMessageStyleDescription',
            default = 'Popup',
            argument = {
                -- Display strings; init.lua compares against these exact
                -- strings so they double as the storage values.
                items = { 'Disabled', 'Popup', 'Message' },
            },
        },
        {
            key = 'popupPosition',
            renderer = 'select',
            name = 'SettingPopupPosition',
            description = 'SettingPopupPositionDescription',
            default = 'Bottom Center',
            argument = {
                items = {
                    'Top Left',
                    'Top Center',
                    'Center',
                    'Bottom Left',
                    'Bottom Center',
                },
            },
        },
        {
            key = 'popupDuration',
            renderer = 'number',
            name = 'SettingPopupDuration',
            description = 'SettingPopupDurationDescription',
            default = 1.35,
            argument = { min = 0.5, max = 10, step = 0.05 },
        },
        {
            key = 'popupMaxVisible',
            renderer = 'number',
            name = 'SettingPopupMaxVisible',
            description = 'SettingPopupMaxVisibleDescription',
            default = 5,
            argument = { integer = true, min = 1, max = 10 },
        },
    },
}

-- ─── 9. Debug ─────────────────────────────────────────────────────────────
-- Categorised logging for troubleshooting. The master toggle gates ALL
-- categories; enabling a category alone has no effect until the master
-- is also on. Order: most-likely-needed categories first.
I.Settings.registerGroup {
    key = 'Settings_' .. MODNAME .. '_Debug',
    page = PAGE_DEBUG,
    l10n = MODNAME,
    name = 'GroupDebugName',
    description = 'GroupDebugDescription',
    order = 9,
    permanentStorage = true,
    settings = {
        { key = 'debugMessages',            renderer = 'checkbox', name = 'SettingDebugMessages',            description = 'SettingDebugMessagesDescription',            default = false },
        { key = 'debugDetectionMessages',   renderer = 'checkbox', name = 'SettingDebugDetectionMessages',   description = 'SettingDebugDetectionMessagesDescription',   default = false },
        { key = 'debugXpMessages',          renderer = 'checkbox', name = 'SettingDebugXpMessages',          description = 'SettingDebugXpMessagesDescription',          default = false },
        { key = 'debugPerkMessages',        renderer = 'checkbox', name = 'SettingDebugPerkMessages',        description = 'SettingDebugPerkMessagesDescription',        default = false },
        { key = 'debugIntegrationMessages', renderer = 'checkbox', name = 'SettingDebugIntegrationMessages', description = 'SettingDebugIntegrationMessagesDescription', default = false },
        { key = 'debugUiMessages',          renderer = 'checkbox', name = 'SettingDebugUiMessages',          description = 'SettingDebugUiMessagesDescription',          default = false },
    },
}
