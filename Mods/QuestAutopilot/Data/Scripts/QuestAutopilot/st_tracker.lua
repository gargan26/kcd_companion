-- Captures the quest the player most recently SELECTED in the journal.
--
-- KCD doesn't fire a Quest:TrackQuest Lua event despite ui_actions.txt
-- listing it. Empirical finding from the UI listener firehose: when the
-- player clicks a quest in the journal, KCD fires QuestLog:OnQuestDiary
-- and OnQuestInfoEx events with the quest_name in args[0]. The user's
-- last-selected quest is almost always the one they care about.
--
-- This is a heuristic, not the literal HUD tracker - but in practice it
-- matches the user's intent better than the DB-iteration order fallback.

st.tracked_quest = nil

function st:onUIEventSys(actionName, eventName, argTable)
  if actionName ~= "QuestLog" then return end
  if eventName ~= "OnQuestDiary" and eventName ~= "OnQuestInfoEx" then return end
  if not argTable then return end
  -- Field [0] carries the quest_name in OnQuestDiary / OnQuestInfoEx.
  local q = argTable[0]
  if q and tostring(q) ~= "" and tostring(q) ~= st.tracked_quest then
    st.tracked_quest = tostring(q)
    st:logInfo("Journal selection -> [%s] (will be used by st_goto)", st.tracked_quest)
  end
end

UIAction.RegisterEventSystemListener(st, "", "", "onUIEventSys")

st:logDebug("st_tracker.lua loaded - tracking journal selection via QuestLog:OnQuestDiary")
