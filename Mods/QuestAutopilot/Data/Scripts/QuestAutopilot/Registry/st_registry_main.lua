-- Main quest line registry.
--
-- Objective names taken from extracted BehaviorTree XMLs in reference_data/.
-- Names that appear in the BT are the same identifiers the database stores
-- as objective_name (BT gates reference DB-defined objectives), and the same
-- ones QuestSystem.IsObjectiveStarted() etc. accept.
--
-- Decision classification is conservative: when in doubt, mark as decision so
-- the skip stops there rather than auto-advancing past a player choice.

-- ---------------------------------------------------------------------------
-- q_skalitz - opening prologue (every player encounters this first)
-- ---------------------------------------------------------------------------
st_registry:register("q_skalitz", {
  decisions = {
    speakWithFather       = { description = "Talk to your father after the morning brawl" },
    getDebtMoney          = { description = "Collect debt money - choose how to handle Kunesh" },
    getDebtMoneyDifferently = { description = "Alternative debt-collection branch" },
    paintAndFight         = { description = "Paint Kunesh's house then fight" },
    paintAndFightWH       = { description = "Paint-and-fight (Woman's Hand variant)" },
    henrySaidHeIsNotGoing = { description = "Refuse to go fight - dialogue branch" },
    partyGoesThere        = { description = "Lead the party to confront Kunesh" },
    mountHorse            = { description = "Mount the horse to flee Skalitz" },
    callHorse             = { description = "Call the horse" },
    endQuest              = { description = "Final beat - escape sequence" },
  },
  npc_hints = {
    -- Kunesh's house is in lower Skalitz. Approximate (x,y,z) lifted from
    -- cheat_core_player.lua place table for SKALITZ as a coarse fallback.
    getDebtMoney = { npc = "Kunesh", home = { x = 829, y = 3522, z = 51 } },
    paintAndFight = { npc = "Kunesh", home = { x = 829, y = 3522, z = 51 } },
    speakWithFather = { npc = "Father", home = { x = 829, y = 3522, z = 51 } },
  },
})

-- ---------------------------------------------------------------------------
-- q_plagueInMerhojed - the proof-of-concept plague investigation
-- ---------------------------------------------------------------------------
st_registry:register("q_plagueInMerhojed", {
  decisions = {
    investigateIllness  = { description = "Choose how to investigate the plague",
                            npc = "Melichar" },
    talkToNikodem       = { description = "Discuss the cure with Nicodemus",
                            npc = "Nicodemus" },
    nikodemGivesTheCure = { description = "Decide whether/how to take Nicodemus's cure",
                            npc = "Nicodemus" },
    cureApplied         = { description = "Choose who receives the cure" },
    slamaForcedDialog   = { description = "Forced dialogue with Slama - decision moment",
                            npc = "Slama" },
  },
  npc_hints = {
    -- Merhojed bailiff is at Merhojed (x:1636 y:2618 z:126 per kcd-cheat).
    investigateIllness = { npc = "Melichar", home = { x = 1636, y = 2618, z = 126 } },
    talkToNikodem      = { npc = "Nicodemus", home = { x = 1636, y = 2618, z = 126 } },
    nikodemGivesTheCure= { npc = "Nicodemus", home = { x = 1636, y = 2618, z = 126 } },
  },
})

-- ---------------------------------------------------------------------------
-- q_package - Miller's Apprentice questline (Pesek + the package-delivery gigs)
-- VANILLA quest, not DLC. Pesek is the Rattay miller; the apothecary debt
-- objective sends you to the Rattay apothecary on the central square.
-- Coordinates: Rattay center (2534, 572, 81), Rattay Mill (2445, 690, 29).
-- ---------------------------------------------------------------------------
st_registry:register("q_package", {
  decisions = {
    -- Pesek dialogue gates
    talkToPesek            = { description = "First conversation with Pesek - accept the lockpick lessons" },
    talkToPesekAgain       = { description = "Follow-up with Pesek" },
    talkToPesekAgainAndAgain = { description = "Yet another Pesek follow-up" },
    acceptTask             = { description = "Accept the package-delivery job" },
    lockpickTutorial       = { description = "Lockpicking practice with Pesek - gameplay, not skippable" },
    -- Apothecary debt branch
    checkApothecary        = { description = "Visit the Rattay apothecary about the unpaid debt", npc = "Apothecary" },
    payApothecaryDebt      = { description = "Decide whether to pay the apothecary's debt" },
    payDebt                = { description = "Settle the debt - pay or not" },
    shouldPayDebt          = { description = "Decision: pay the debt or push back" },
    -- Herman ring sub-quest branch
    getRingFromHerman      = { description = "Get Herman's ring - choose method" },
    hermanSpokenTo         = { description = "Talk to Herman" },
    hermanAgreedToSellRing = { description = "Herman agrees to sell - dialogue branch" },
    hermanLuredAway        = { description = "Lure Herman away - alternative path" },
    -- Enforcer encounter branches
    enforcersSpokenTo      = { description = "Talk to the miller's enforcers" },
    enforcersThreatened    = { description = "Threaten the enforcers - branches into combat" },
    enforcerFight          = { description = "Fight the enforcers" },
    -- Other miller visits
    visitVojtech           = { description = "Visit Vojtech (Kuchelbad miller)", npc = "Vojtech" },
    giveRingToVojtech      = { description = "Hand the ring to Vojtech" },
    checkGrave             = { description = "Investigate the grave Pesek mentioned" },
  },
  npc_hints = {
    -- Apothecary is on Rattay's central square - close enough to walk from town center.
    checkApothecary    = { npc = "Apothecary", home = { x = 2534, y = 572, z = 81 } },
    payApothecaryDebt  = { npc = "Apothecary", home = { x = 2534, y = 572, z = 81 } },
    -- Pesek lives at the Rattay Mill (NW of Rattay).
    talkToPesek        = { npc = "Pesek",  home = { x = 2445, y = 690, z = 29 } },
    talkToPesekAgain   = { npc = "Pesek",  home = { x = 2445, y = 690, z = 29 } },
    talkToPesekAgainAndAgain = { npc = "Pesek", home = { x = 2445, y = 690, z = 29 } },
    acceptTask         = { npc = "Pesek",  home = { x = 2445, y = 690, z = 29 } },
    lockpickTutorial   = { npc = "Pesek",  home = { x = 2445, y = 690, z = 29 } },
    -- Herman is in Rattay (the slums - same coarse hint).
    getRingFromHerman  = { npc = "Herman", home = { x = 2534, y = 572, z = 81 } },
    hermanSpokenTo     = { npc = "Herman", home = { x = 2534, y = 572, z = 81 } },
    -- Vojtech is at Kuchelbad mill - no precise coord; fall back to Rattay center.
    visitVojtech       = { npc = "Vojtech", home = { x = 2534, y = 572, z = 81 } },
    giveRingToVojtech  = { npc = "Vojtech", home = { x = 2534, y = 572, z = 81 } },
  },
})

st:logDebug("st_registry_main.lua loaded - %d quest(s)", #st_registry:list())
