-- KCD Companion (Quest Autopilot inside) entry point.
-- KCD loads this automatically from Mods/QuestAutopilot/Data/data.pak on startup.
st = {}
st.versionMajor = 1
st.versionMinor = 3
st.versionPatch = 2

System.LogAlways("@@@@@@@@@ Quest Autopilot st_main.lua called @@@@@@@@")

function st:loadFile(file)
  Script.ReloadScript("Scripts/" .. file)
  System.LogAlways("$5[QA] Loaded [" .. tostring(file) .. "].")
end

function st:loadFiles()
  -- Order matters: util first (provides logging used by everything),
  -- registry/graph/teleport/npc next, navigator after graph+registry,
  -- commands last so all targets exist when registered.
  st:loadFile("QuestAutopilot/st_util.lua")
  st:loadFile("QuestAutopilot/st_teleport.lua")
  st:loadFile("QuestAutopilot/st_npc.lua")
  st:loadFile("QuestAutopilot/st_quest_graph.lua")
  st:loadFile("QuestAutopilot/st_registry.lua")
  st:loadFile("QuestAutopilot/Registry/st_registry_main.lua")
  -- Auto-generated entity name -> world coords table (build/extraction step).
  -- Provides universal st_goto coverage without per-quest registry entries.
  st:loadFile("QuestAutopilot/Data/st_entity_homes.lua")
  -- Auto-generated quest table snapshot (quests/objectives/transitions/npcs/places).
  -- Replaces runtime Database.LoadTable("quest_objective") which arms a delayed CTD.
  -- Must load before st_tracker / st_navigator / st_commands so st_graph can read it.
  st:loadFile("QuestAutopilot/Data/st_quest_data.lua")
  -- Auto-generated BehaviorTree awareness map (per-quest, per-objective state
  -- watch codes). st_navigator uses this to know which objectives' Completed
  -- state actually triggers BT progression vs. which are decorative flags.
  st:loadFile("QuestAutopilot/Data/st_bt_awareness.lua")
  -- Auto-generated quest outcome catalog (good/bad/neutral endings with
  -- required_completions and avoid_completions per outcome). Drives st_good/st_bad.
  st:loadFile("QuestAutopilot/Data/st_outcomes.lua")
  -- UI listener that captures the player's tracked quest from the journal.
  -- Loaded after util/registry/graph so logging + helpers are available.
  -- Auto-generated per-objective skip data (tools/extract_skip_effects.py) and the completion that uses it: each
  -- objective completed the way play completes it. Before st_navigator, whose advance goes through it.
  st:loadFile("QuestAutopilot/Data/st_skip.lua")
  st:loadFile("QuestAutopilot/st_skip.lua")
  st:loadFile("QuestAutopilot/st_tracker.lua")
  st:loadFile("QuestAutopilot/st_navigator.lua")
  st:loadFile("QuestAutopilot/st_commands.lua")
  -- The trainer: world data (tools/extract_world.py), the Me/Achievements/journal data (tools/extract_trainer_data.py),
  -- the trainer's Chinese, French and German (Data/qa_lang_<ui>.lua) and the tab model both faces render (qa_api.lua).
  st:loadFile("QuestAutopilot/Data/qa_world.lua")
  st:loadFile("QuestAutopilot/Data/qa_data.lua")
  st:loadFile("QuestAutopilot/Data/qa_lang_zh.lua")
  st:loadFile("QuestAutopilot/Data/qa_lang_fr.lua")
  st:loadFile("QuestAutopilot/Data/qa_lang_de.lua")
  st:loadFile("QuestAutopilot/qa_api.lua")
end

function st:init()
  st:loadFiles()
  st:logInfo("KCD Companion %d.%d.%d loaded",
    st.versionMajor, st.versionMinor, st.versionPatch)
end

st:init()
