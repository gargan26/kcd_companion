-- Console command interface. Each command parses its own free-form line.
--
-- KCD's System.AddCCommand passes the entire argument string as %line, so we
-- split on whitespace ourselves rather than fight the kcd-cheat key:value
-- argument parser - simpler and the commands have at most 2-3 positional args.

st_cmd = {}

local function split_words(line)
  local out = {}
  for word in string.gmatch(tostring(line or ""), "%S+") do
    table.insert(out, word)
  end
  return out
end

-- The game's quest calls and Quest Autopilot's tables take a quest's name with its exact capitals
-- (q_millerDate); a typed name in any case becomes that one.
local function quest_name(typed)
  local _, name = st_graph:find_quest(typed or "")
  return name or typed
end

local function add(name, body, help)
  System.AddCCommand(name, body, help or name)
end

-- ---------------------------------------------------------------------------
-- st_help
-- ---------------------------------------------------------------------------
function st_cmd:help()
  st:logInfo("Quest Autopilot commands:")
  st:logInfo("  st_status <quest>          - show objectives + states for a quest")
  st:logInfo("  st_quests                  - list all started quests")
  st:logInfo("  st_skip <quest>            - advance to next decision point")
  st:logInfo("  st_advance <quest> <obj>   - complete one objective (add 'force' to bypass prereq check)")
  st:logInfo("  st_goto                    - teleport to current objective of your TRACKED quest")
  st:logInfo("  st_goto <quest>            - teleport to current objective of <quest>")
  st:logInfo("  st_goto x y z              - teleport to raw coordinates")
  st:logInfo("  st_summon <npc-name>       - bring NPC to player")
  st:logInfo("  st_graph <quest> [log]     - dump dependency graph")
  st:logInfo("  st_endings <quest>         - list all known endings for a quest")
  st:logInfo("  st_good <quest>            - auto-advance to the best ending")
  st:logInfo("  st_bad <quest>             - auto-advance to the worst ending")
  st:logInfo("  st_help                    - this message")
end
add("st_help", "st_cmd:help()", "Show Quest Autopilot command reference.")

-- ---------------------------------------------------------------------------
-- st_quests - list active quests
-- ---------------------------------------------------------------------------
function st_cmd:quests()
  Database.LoadTable("quest")
  local info = Database.GetTableInfo("quest")
  local count = 0
  for i = 0, info.LineCount - 1 do
    local row = Database.GetTableLine("quest", i)
    if row and QuestSystem.IsQuestStarted(row.quest_name) then
      local active = QuestSystem.IsQuestActivated(row.quest_name)
      st:logInfo("  [%s] active=%s", row.quest_name, tostring(active))
      count = count + 1
    end
  end
  if count == 0 then
    st:logInfo("No started quests.")
  else
    st:logInfo("%d started quest(s).", count)
  end
end
add("st_quests", "st_cmd:quests()", "List all started quests.")

-- ---------------------------------------------------------------------------
-- st_status <quest>
-- ---------------------------------------------------------------------------
function st_cmd:status(line)
  local args = split_words(line)
  local quest = quest_name(args[1])
  if not quest then st:logError("Usage: st_status <quest>"); return end

  local graph = st_graph:refresh_states(quest)
  if not graph then return end

  st:logInfo("Quest [%s] (id %s)", graph.quest_name, tostring(graph.quest_id))
  for _, id in ipairs(graph.topo_order) do
    local obj = graph.objectives[id]
    local marker = obj.is_decision and "*" or " "
    local edges = ""
    if #obj.unlocks > 0 then
      local ns = {}
      for _, n in ipairs(obj.unlocks) do
        table.insert(ns, graph.objectives[n] and graph.objectives[n].name or tostring(n))
      end
      edges = " -> " .. table.concat(ns, ", ")
    end
    st:logInfo("  %s [%s] %s (%s)%s",
      marker, obj.state, obj.name, tostring(obj.id), edges)
  end
  if #graph.npcs > 0 then
    st:logInfo("  NPCs (souls): %s", table.concat(graph.npcs, ", "))
  end
end
add("st_status", "st_cmd:status(%line)", "st_status <quest> - show objectives and states.")

-- ---------------------------------------------------------------------------
-- st_graph <quest> [log]
-- ---------------------------------------------------------------------------
function st_cmd:graph(line)
  local args = split_words(line)
  local quest = quest_name(args[1])
  local to_log = args[2] == "log"
  if not quest then st:logError("Usage: st_graph <quest> [log]"); return end

  local graph = st_graph:get(quest)
  if not graph then return end

  local lines = {}
  table.insert(lines, string.format("Graph for [%s] (id %s)", graph.quest_name, tostring(graph.quest_id)))
  for _, id in ipairs(graph.topo_order) do
    local obj = graph.objectives[id]
    local marker = obj.is_decision and "*DECISION*" or "busywork  "
    local depnames = {}
    for _, d in ipairs(obj.depends_on) do
      table.insert(depnames, graph.objectives[d] and graph.objectives[d].name or tostring(d))
    end
    local unlnames = {}
    for _, u in ipairs(obj.unlocks) do
      table.insert(unlnames, graph.objectives[u] and graph.objectives[u].name or tostring(u))
    end
    table.insert(lines, string.format("  %s %s (id %s)", marker, obj.name, tostring(obj.id)))
    if #depnames > 0 then table.insert(lines, "      depends_on: " .. table.concat(depnames, ", ")) end
    if #unlnames > 0 then table.insert(lines, "      unlocks   : " .. table.concat(unlnames, ", ")) end
  end
  for _, ln in ipairs(lines) do st:logInfo("%s", ln) end

  if to_log then
    local f, err = io.open("QuestAutopilot_graph_" .. quest .. ".txt", "w")
    if f then
      for _, ln in ipairs(lines) do f:write(ln); f:write("\n") end
      f:close()
      st:logInfo("Graph also written to QuestAutopilot_graph_%s.txt", quest)
    else
      st:logError("Could not open log file: %s", tostring(err))
    end
  end
end
add("st_graph", "st_cmd:graph(%line)", "st_graph <quest> [log] - dump dependency graph.")

-- ---------------------------------------------------------------------------
-- st_advance <quest> <obj> [force]
-- ---------------------------------------------------------------------------
function st_cmd:advance(line)
  local args = split_words(line)
  local quest, obj, force = quest_name(args[1]), args[2], args[3] == "force"
  if not quest or not obj then
    st:logError("Usage: st_advance <quest> <objective> [force]")
    return
  end
  st_navigator:safe_advance(quest, obj, force)
end
add("st_advance", "st_cmd:advance(%line)", "st_advance <quest> <objective> [force] - complete one objective.")

-- ---------------------------------------------------------------------------
-- st_skip <quest>
-- ---------------------------------------------------------------------------
function st_cmd:skip(line)
  local args = split_words(line)
  local quest = quest_name(args[1])
  if not quest then st:logError("Usage: st_skip <quest>"); return end
  st_navigator:skip_to_decision(quest)
end
add("st_skip", "st_cmd:skip(%line)", "st_skip <quest> - advance to next decision point.")

-- ---------------------------------------------------------------------------
-- st_goto                  -> auto-detect tracked quest, teleport to its objective
-- st_goto <quest>          -> teleport to that quest's current objective
-- st_goto <x> <y> <z>      -> raw coordinate teleport
-- ---------------------------------------------------------------------------

-- Known-safe town coords copied from kcd-cheat
-- (Source/Scripts/cheat_core_player.lua, places["1"]..places["17"]).
-- These entries have a long history of surviving cold teleports across
-- versions, so when our primary pick is a TriggerArea (entering a trigger
-- volume can run BehaviorTree code that crashes the engine) we snap here
-- instead. Trades precision for a low-CTD floor.
local SAFE_TOWNS = {
  { x = 1363, y = 2481, z = 109 },
  { x = 2052, y = 1304, z = 30  },
  { x = 1636, y = 2618, z = 126 },
  { x = 1408, y = 2713, z = 129 },
  { x = 929,  y = 1617, z = 36  },
  { x = 3522, y = 1524, z = 131 },
  { x = 1557, y = 3719, z = 107 },
  { x = 2534, y = 572,  z = 81  },
  { x = 2725, y = 667,  z = 102 },
  { x = 1261, y = 3129, z = 25  },
  { x = 1139, y = 2239, z = 71  },
  { x = 896,  y = 1186, z = 27  },
  { x = 829,  y = 3522, z = 51  },
  { x = 2360, y = 2846, z = 105 },
  { x = 2128, y = 2959, z = 74  },
  { x = 3041, y = 3324, z = 156 },
  { x = 930,  y = 913,  z = 130 },
}

local function nearest_safe_town(x, y)
  local best, best_d2 = nil, math.huge
  for _, t in ipairs(SAFE_TOWNS) do
    local dx, dy = t.x - x, t.y - y
    local d2 = dx * dx + dy * dy
    if d2 < best_d2 then best, best_d2 = t, d2 end
  end
  return best, math.sqrt(best_d2)
end

-- Find the player's currently-tracked quest. Picks the first activated quest
-- in database iteration order. If KCD has multiple activated at once, this
-- is essentially arbitrary - use st_goto <name> to override.
local function find_tracked_quest()
  Database.LoadTable("quest")
  local info = Database.GetTableInfo("quest")
  for i = 0, info.LineCount - 1 do
    local row = Database.GetTableLine("quest", i)
    if row and QuestSystem.IsQuestStarted(row.quest_name)
           and QuestSystem.IsQuestActivated(row.quest_name) then
      return row.quest_name
    end
  end
  return nil
end

function st_cmd:goto_(line)
  local args = split_words(line)
  if #args == 3 then
    local x = tonumber(args[1]); local y = tonumber(args[2]); local z = tonumber(args[3])
    if not x or not y or not z then
      st:logError("Usage: st_goto <x> <y> <z> (numbers), st_goto <quest>, or st_goto with no args")
      return
    end
    st_teleport:player_to(x, y, z)
    return
  end
  local quest = quest_name(args[1])
  if not quest then
    -- Prefer the journal tracker captured by st_tracker. Falls back to the
    -- DB scan only if we haven't seen a TrackQuest UI event yet (e.g. after
    -- mod load before player has touched the journal).
    if st.tracked_quest then
      quest = st.tracked_quest
      st:logInfo("Using journal-tracked quest [%s]", quest)
    else
      quest = find_tracked_quest()
      if not quest then
        st:logError("No tracked quest found. Use st_goto <quest> or st_quests to see what's started.")
        return
      end
      st:logInfo("No journal tracker captured yet - falling back to first activated quest [%s]. " ..
        "Open journal and re-track the quest you want to see this work properly.", quest)
    end
  end

  -- refresh_states is back in the goto path: QuestSystem.IsObjective*
  -- isolation-tested in Session 5 (st_status + 5-10 min play, no delayed CTD).
  -- This unlocks active-objective resolution, which the registry-hint path
  -- below depends on.
  local graph = st_graph:refresh_states(quest)
  if not graph then return end

  -- Active objective. KCD often has many objectives 'started' simultaneously
  -- (knowledge flags like henryKnowsMelichar coexist with the real destination
  -- objective). The first-in-topo pick lands on a knowledge flag and misses
  -- the hint. So scan twice: prefer a started objective that HAS a registry
  -- hint (curated "this is the destination step"), fall back to first-started
  -- only for the `where` log message when no hint matches.
  local current, hint = nil, nil
  local entry = st_registry:get(quest)
  if entry and entry.npc_hints then
    for _, id in ipairs(graph.topo_order) do
      local obj = graph.objectives[id]
      if obj.state == "started" and entry.npc_hints[obj.name] then
        current, hint = obj, entry.npc_hints[obj.name]
        break
      end
    end
  end
  if not current then
    for _, id in ipairs(graph.topo_order) do
      local obj = graph.objectives[id]
      if obj.state == "started" then current = obj; break end
    end
  end

  -- 1. Registry hint for the active objective. Hand-authored, narrowest scope:
  -- per-objective home coord (e.g. "talkToPesek -> Rattay Mill") beats
  -- quest_place because quest_place is per-quest, not per-step.
  if hint and hint.home then
    st:logInfo("registry hint for [%s]: %s @ (%d,%d,%d)",
      current.name, hint.npc or "?", hint.home.x, hint.home.y, hint.home.z)
    st_teleport:player_to(hint.home.x, hint.home.y, hint.home.z)
    return
  end

  -- 2. quest_place entity from database.
  -- Quest_place can include both destination markers (where the player should
  -- go - usually TriggerAreas, often far from current position) and info
  -- markers (e.g. where the player's journal entry was set - often near the
  -- player, often non-trigger). Heuristic: pick the FARTHEST entry, since
  -- "go to" destinations are far and info markers are nearby.
  -- For TriggerArea destinations, offset XY so we land NEAR the volume,
  -- not inside it (entry triggers BehaviorTree code that crashes the engine).
  local function class_of(name)
    local s = st_homes and st_homes[name]
    return s and s.c or nil
  end
  local function is_trigger(name)
    return class_of(name) == "TriggerArea"
  end

  if graph.places and #graph.places > 0 then
    local pp = player:GetWorldPos()
    -- Build candidate list: {entity_name, x, y, z, dist} for every resolvable place.
    local candidates = {}
    for _, place in ipairs(graph.places) do
      local px, py, pz, source
      local trig = is_trigger(place.entity)
      if trig then
        -- Triggers are the known engine-crash path - never poke the live
        -- entity. The live coord wouldn't inform us anyway since we're
        -- snapping to a hardcoded town. Static-only matches kcd-cheat's
        -- "look up coord, teleport" zero-touch pipeline.
        if st_homes and st_homes[place.entity] then
          local h = st_homes[place.entity]; px, py, pz, source = h.x, h.y, h.z, "static"
        end
      else
        -- Non-triggers (NPC homes, info markers): prefer live so we follow
        -- entities that have moved since extraction.
        local entity = System.GetEntityByName(place.entity)
        if entity then
          local p = entity:GetWorldPos(); px, py, pz, source = p.x, p.y, p.z, "live"
        elseif st_homes and st_homes[place.entity] then
          local h = st_homes[place.entity]; px, py, pz, source = h.x, h.y, h.z, "static"
        end
      end
      if px then
        local dx, dy = px - pp.x, py - pp.y
        local dist = math.sqrt(dx * dx + dy * dy)
        table.insert(candidates, {
          name = place.entity, x = px, y = py, z = pz,
          dist = dist, source = source, trigger = trig,
        })
      end
    end
    -- Sort farthest first.
    table.sort(candidates, function(a, b) return a.dist > b.dist end)
    if #candidates > 0 then
      local pick = candidates[1]
      local tx, ty, tz = pick.x, pick.y, pick.z
      if pick.trigger then
        -- Snap to the nearest hardcoded safe town. The 8m-offset-outside-volume
        -- heuristic still landed in unstreamed terrain on some pulls (Merhojed
        -- Pestilence trigger CTD). Empirically the kcd-cheat town list is the
        -- low-CTD floor, at the cost of dropping the player up to ~1km from the
        -- intended quest spot - they can fast-travel the rest from a town.
        local town, snap_dist = nearest_safe_town(pick.x, pick.y)
        tx, ty, tz = town.x, town.y, town.z
        st:logInfo("quest_place [%s] (trigger, %s, %dm away) - snapping to safe town %dm from destination",
          pick.name, pick.source, math.floor(pick.dist), math.floor(snap_dist))
      else
        st:logInfo("quest_place [%s] (%s, %dm away)",
          pick.name, pick.source, math.floor(pick.dist))
      end
      st_teleport:player_to(tx, ty, tz)
      return
    end
    st:logDebug("quest_place had %d entries; none resolved", #graph.places)
  end

  -- 3. Loaded quest NPC by soul (single entity sweep, actor-filtered).
  if graph.npcs and #graph.npcs > 0 then
    local matches = st_npc:find_by_souls(graph.npcs)
    for soul, npc in pairs(matches) do
      local p = npc:GetWorldPos()
      st:logInfo("Found loaded quest NPC by soul - teleporting there")
      st_teleport:player_to(p.x, p.y, p.z)
      return
    end
  end

  -- 4. Soul-id home from extracted entity table. quest_npc.soul_id maps to a
  -- spawned NPC entity whose name often matches a Storm role name. Try direct
  -- lookup of the soul_id as a key in case of cross-mapping.
  if graph.npcs and st_homes then
    for _, soul in ipairs(graph.npcs) do
      local home = st_homes[soul]
      if home then
        st:logInfo("soul-id home: [%s] at (%d,%d,%d)", soul, home.x, home.y, home.z)
        st_teleport:player_to(home.x, home.y, home.z)
        return
      end
    end
  end

  local where = current and ("objective [" .. current.name .. "]") or "any marker"
  st:logWarn("No location data for %s in quest [%s]. " ..
    "Try st_status to see objectives, or use kcd-cheat's cheat_teleport for raw coords.",
    where, quest)
end
-- "goto" is a reserved Lua keyword, hence goto_
add("st_goto", "st_cmd:goto_(%line)", "st_goto [quest|x y z] - teleport to tracked quest's objective, named quest's objective, or raw coords.")

-- ---------------------------------------------------------------------------
-- st_summon <npc>
-- ---------------------------------------------------------------------------
function st_cmd:summon(line)
  local name = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then st:logError("Usage: st_summon <npc-name>"); return end
  st_npc:summon(name)
end
add("st_summon", "st_cmd:summon(%line)", "st_summon <npc-name> - bring NPC to player.")

-- ---------------------------------------------------------------------------
-- st_endings <quest> - list all known endings
-- ---------------------------------------------------------------------------
function st_cmd:endings(line)
  local args = split_words(line)
  local quest = quest_name(args[1])
  if not quest then st:logError("Usage: st_endings <quest>"); return end
  if not st_outcomes or not st_outcomes[quest] then
    st:logWarn("No outcome data for [%s]. Quest may be linear or unanalyzed.", quest)
    return
  end
  local count = 0
  for name, o in pairs(st_outcomes[quest]) do
    count = count + 1
    st:logInfo("  [%s] %s - %s", o.morality, name, o.description)
    if o.required_completions and #o.required_completions > 0 then
      st:logInfo("    requires: %s", table.concat(o.required_completions, ", "))
    end
    if o.avoid_completions and #o.avoid_completions > 0 then
      st:logInfo("    avoid:    %s", table.concat(o.avoid_completions, ", "))
    end
  end
  st:logInfo("%d ending(s) for [%s]", count, quest)
end
add("st_endings", "st_cmd:endings(%line)", "st_endings <quest> - list all known endings.")

-- ---------------------------------------------------------------------------
-- st_good / st_bad <quest> - auto-advance toward best/worst ending
-- ---------------------------------------------------------------------------

local function find_outcome(quest, morality)
  if not st_outcomes or not st_outcomes[quest] then return nil end
  for name, o in pairs(st_outcomes[quest]) do
    if o.morality == morality then return name, o end
  end
  return nil
end

function st_cmd:run_outcome(quest, outcome_name, outcome)
  local graph = st_graph:refresh_states(quest)
  if not graph then return end

  if not QuestSystem.IsQuestStarted(quest) then
    st:logInfo("Starting quest [%s]", quest)
    QuestSystem.StartQuest(quest)
  end
  if not QuestSystem.IsQuestActivated(quest) then
    st:logInfo("Activating quest [%s]", quest)
    QuestSystem.ActivateQuest(quest, 1)
  end

  local avoid_set = {}
  for _, name in ipairs(outcome.avoid_completions or {}) do
    avoid_set[name] = true
  end

  -- One step at a time, each the way play completes it (st_skip.lua); a step only a conversation, scene or world
  -- event finishes stops the run there, and a step the game never completes is passed over.
  local steps = {}
  for _, obj_name in ipairs(outcome.required_completions or {}) do
    local v = st_skip:info(quest, obj_name)
    local known = graph.objectives and (function()
      for _, o in pairs(graph.objectives) do if o.name == obj_name then return true end end
    end)()
    if avoid_set[obj_name] then
      st:logWarn("Skipping [%s] - listed in both required and avoid (safety)", obj_name)
    elseif known and v ~= "n" then
      table.insert(steps, obj_name)
    end
  end
  st:logInfo("Outcome [%s] (%s): %d step(s)", outcome_name, outcome.morality, #steps)
  st_cmd:outcome_step(quest, steps, 1)
end

function st_cmd:outcome_step(quest, steps, i)
  local obj_name = steps[i]
  if not obj_name then
    st:logInfo("Ending run done: %d step(s)", #steps)
    st_skip.note("Ending run done: %d step(s)", #steps)
    return
  end
  if QuestSystem.IsObjectiveCompleted(quest, obj_name) then
    return st_cmd:outcome_step(quest, steps, i + 1)
  end
  local v = st_skip:info(quest, obj_name)
  if not st_skip:full(v) then
    st:logWarn("Stopped at '%s': play does more there than a skip would. Skip it by hand if you want.", obj_name)
    st_skip.note("Stopped at '%s': play does more there than a skip would. Skip it by hand if you want.", obj_name)
    return
  end
  if not QuestSystem.IsObjectiveStarted(quest, obj_name) then
    QuestSystem.StartObjective(quest, obj_name)
  end
  st_skip:complete(quest, obj_name)
  -- items and fired objectives finish after the game reacts; the next step waits for that
  local wait = (v == "g" or v == "u") and (st_skip.SETTLE_MS + 300) or 300
  Script.SetTimer(wait, function() st_cmd:outcome_step(quest, steps, i + 1) end)
end

function st_cmd:good(line)
  local args = split_words(line)
  local quest = quest_name(args[1])
  if not quest then st:logError("Usage: st_good <quest>"); return end
  local name, o = find_outcome(quest, "good")
  if not o then
    st:logWarn("No 'good' ending found for [%s]. Try st_endings %s", quest, quest)
    return
  end
  st:logInfo("Advancing [%s] toward good ending: %s", quest, name)
  st:logInfo("  %s", o.description)
  st_cmd:run_outcome(quest, name, o)
end
add("st_good", "st_cmd:good(%line)", "st_good <quest> - auto-advance to the best ending.")

function st_cmd:bad(line)
  local args = split_words(line)
  local quest = quest_name(args[1])
  if not quest then st:logError("Usage: st_bad <quest>"); return end
  local name, o = find_outcome(quest, "bad")
  if not o then
    st:logWarn("No 'bad' ending found for [%s]. Try st_endings %s", quest, quest)
    return
  end
  st:logInfo("Advancing [%s] toward bad ending: %s", quest, name)
  st:logInfo("  %s", o.description)
  st_cmd:run_outcome(quest, name, o)
end
add("st_bad", "st_cmd:bad(%line)", "st_bad <quest> - auto-advance to the worst ending.")

st:logDebug("st_commands.lua loaded")
