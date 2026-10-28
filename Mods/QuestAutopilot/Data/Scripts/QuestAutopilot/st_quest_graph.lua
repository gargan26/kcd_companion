-- Quest dependency graph builder. All structure comes from a build-time
-- snapshot of KCD's quest tables (st_quest_data); the registry only
-- contributes decision-point flags and NPC location hints.
--
-- Why static, not Database.LoadTable: calling Database.LoadTable("quest_objective")
-- at runtime arms a delayed CTD - the engine resolves scripted bindings on
-- objectives that then dangle and crash on later state changes (dialogue,
-- teleports). Build-time extraction sidesteps the issue entirely. quest,
-- quest_npc, and quest_place have been individually verified safe at runtime
-- but live in the same static snapshot for uniformity.
--
-- Important: quest_transition uses integer objective_ids; QuestSystem API uses
-- string objective_names. We map between them via quest_objective.

st_graph = {}
st_graph.cache = {}  -- quest_name -> graph

-- ---------------------------------------------------------------------------
-- Static-table scanning helpers (st_quest_data is loaded at startup)
-- ---------------------------------------------------------------------------

local function scan_static(table_key, predicate, project)
  local rows = st_quest_data and st_quest_data[table_key] or {}
  local out = {}
  for _, row in ipairs(rows) do
    if predicate(row) then
      table.insert(out, project and project(row) or row)
    end
  end
  return out
end

local function find_quest_id(quest_name)
  local target = st:toUpper(quest_name)
  local quests = st_quest_data and st_quest_data.quests or {}
  for _, row in ipairs(quests) do
    if row.quest_name and st:toUpper(row.quest_name) == target then
      return row.quest_id, row.quest_name
    end
  end
  return nil, nil
end

-- ---------------------------------------------------------------------------
-- Graph construction
-- ---------------------------------------------------------------------------

function st_graph:find_quest(name)
  local qid, qname = find_quest_id(name)
  if qid then
    st:logDebug("Resolved quest [%s] -> id [%s]", tostring(qname), tostring(qid))
  end
  return qid, qname
end

function st_graph:load_objectives(quest_id)
  local objectives = {}
  scan_static("objectives",
    function(row) return row.quest_id == quest_id end,
    function(row)
      objectives[row.objective_id] = {
        id = row.objective_id,
        name = row.objective_name,
        is_hidden = row.is_hidden,
        is_exclusive = row.is_exclusive,
        depends_on = {},
        unlocks = {},
        state = "unchanged",
        is_decision = false,
      }
      return row
    end)
  return objectives
end

function st_graph:load_transitions(quest_id, objectives)
  local edges = {}
  scan_static("transitions",
    function(row)
      return row.quest_id == quest_id and (row.enabled == nil or row.enabled == true)
    end,
    function(row)
      local from = row.from_objective_id
      local to = row.to_objective_id
      if objectives[from] and objectives[to] then
        table.insert(objectives[from].unlocks, to)
        table.insert(objectives[to].depends_on, from)
        table.insert(edges, { from = from, to = to })
      end
      return row
    end)
  return edges
end

-- Kahn topological sort on the unlocks edges.
-- Branches/cycles are tolerated: leftover nodes are appended after the sorted prefix.
function st_graph:topo_sort(objectives)
  local in_deg = {}
  for id, obj in pairs(objectives) do
    in_deg[id] = #obj.depends_on
  end

  local order = {}
  local queue = {}
  -- deterministic iteration via sorted ids
  for _, id in ipairs(st:sortedKeys(in_deg)) do
    if in_deg[id] == 0 then table.insert(queue, id) end
  end

  while #queue > 0 do
    local id = table.remove(queue, 1)
    table.insert(order, id)
    for _, succ in ipairs(objectives[id].unlocks) do
      in_deg[succ] = in_deg[succ] - 1
      if in_deg[succ] == 0 then
        table.insert(queue, succ)
      end
    end
  end

  -- append any remaining (cycle / unreached) so display still includes them
  for _, id in ipairs(st:sortedKeys(in_deg)) do
    local seen = false
    for _, v in ipairs(order) do
      if v == id then seen = true; break end
    end
    if not seen then table.insert(order, id) end
  end
  return order
end

function st_graph:load_npcs(quest_id)
  local souls = {}
  scan_static("npcs",
    function(row) return row.quest_id == quest_id end,
    function(row)
      table.insert(souls, row.soul_id)
      return row
    end)
  return souls
end

-- quest_place maps a quest to entity names that mark its locations
-- (trigger areas, NPC home markers, item spawn points). Entity names resolve
-- to world coordinates via st_homes (build-time extraction from level paks).
function st_graph:load_places(quest_id)
  local places = {}
  scan_static("places",
    function(row) return row.quest_id == quest_id end,
    function(row)
      table.insert(places, {
        entity = row.entity,
        asset_id = row.quest_asset_id,
        show_as_area = row.show_as_area,
      })
      return row
    end)
  return places
end

-- Apply registry decision flags to a built graph.
local function apply_registry(graph)
  if not st_registry then return end
  local entry = st_registry:get(graph.quest_name)
  if not entry then return end
  graph.registry = entry
  if entry.decisions then
    for _, obj in pairs(graph.objectives) do
      if entry.decisions[obj.name] then
        obj.is_decision = true
      end
    end
  end
end

function st_graph:build(quest_name)
  local qid, qname = st_graph:find_quest(quest_name)
  if not qid then
    st:logError("Quest [%s] not found in database", tostring(quest_name))
    return nil
  end

  local objectives = st_graph:load_objectives(qid)
  local edges = st_graph:load_transitions(qid, objectives)
  local order = st_graph:topo_sort(objectives)
  local npcs = st_graph:load_npcs(qid)
  local places = st_graph:load_places(qid)

  local graph = {
    quest_id = qid,
    quest_name = qname,
    objectives = objectives,
    edges = edges,
    topo_order = order,
    npcs = npcs,
    places = places,
  }
  apply_registry(graph)

  st_graph.cache[qname] = graph
  st:logDebug("Built graph for [%s]: %d objectives, %d edges, %d npcs",
    qname, #order, #edges, #npcs)
  return graph
end

function st_graph:get(quest_name)
  if st_graph.cache[quest_name] then return st_graph.cache[quest_name] end
  return st_graph:build(quest_name)
end

-- ---------------------------------------------------------------------------
-- Live state
-- ---------------------------------------------------------------------------

function st_graph:refresh_states(quest_name)
  local graph = st_graph:get(quest_name)
  if not graph then return nil end
  for _, obj in pairs(graph.objectives) do
    local n = obj.name
    if QuestSystem.IsObjectiveCompleted(quest_name, n) then
      obj.state = "completed"
    elseif QuestSystem.IsObjectiveCanceled and QuestSystem.IsObjectiveCanceled(quest_name, n) then
      obj.state = "cancelled"
    elseif QuestSystem.IsObjectiveStarted(quest_name, n) then
      obj.state = "started"
    else
      obj.state = "unchanged"
    end
  end
  return graph
end

function st_graph:current_objectives(quest_name)
  local graph = st_graph:refresh_states(quest_name)
  if not graph then return {} end
  local current = {}
  for _, id in ipairs(graph.topo_order) do
    local obj = graph.objectives[id]
    if obj.state == "started" then table.insert(current, obj) end
  end
  return current
end

function st_graph:next_objectives(quest_name, obj_id)
  local graph = st_graph:get(quest_name)
  if not graph or not graph.objectives[obj_id] then return {} end
  local out = {}
  for _, succ in ipairs(graph.objectives[obj_id].unlocks) do
    table.insert(out, graph.objectives[succ])
  end
  return out
end

function st_graph:prerequisites(quest_name, obj_id)
  local graph = st_graph:get(quest_name)
  if not graph or not graph.objectives[obj_id] then return {} end
  local out = {}
  for _, pre in ipairs(graph.objectives[obj_id].depends_on) do
    table.insert(out, graph.objectives[pre])
  end
  return out
end

-- Snapshot is a {obj_name -> state} map used for post-skip diff.
function st_graph:snapshot_states(quest_name)
  local graph = st_graph:refresh_states(quest_name)
  if not graph then return {} end
  local snap = {}
  for _, obj in pairs(graph.objectives) do
    snap[obj.name] = obj.state
  end
  return snap
end

function st_graph:diff_against(quest_name, snapshot, expected_changes)
  local graph = st_graph:refresh_states(quest_name)
  local unexpected = {}
  if not graph then return unexpected end
  local expected = {}
  for _, name in ipairs(expected_changes or {}) do expected[name] = true end
  for _, obj in pairs(graph.objectives) do
    local prev = snapshot[obj.name]
    if prev ~= obj.state and not expected[obj.name] then
      table.insert(unexpected, { name = obj.name, from = prev, to = obj.state })
    end
  end
  return unexpected
end

st:logDebug("st_quest_graph.lua loaded")
