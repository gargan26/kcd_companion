-- Quest navigator: safe single-objective advance + DAG-walking skip-to-decision.
-- Built on top of st_graph (database-derived dependency info) and st_registry.

st_navigator = {}

-- ---------------------------------------------------------------------------
-- safe_advance: complete one objective, with prerequisite check.
-- ---------------------------------------------------------------------------

function st_navigator:safe_advance(quest_name, obj_name, force)
  local graph = st_graph:get(quest_name)
  if not graph then return false end

  -- Find objective record by name (graph keys by id; we need a name lookup).
  local target = nil
  for _, obj in pairs(graph.objectives) do
    if obj.name == obj_name then target = obj; break end
  end
  if not target then
    st:logError("Objective [%s] not found in quest [%s]", tostring(obj_name), tostring(quest_name))
    return false
  end

  -- Prerequisite check.
  if not force then
    st_graph:refresh_states(quest_name)
    local missing = {}
    for _, pre_id in ipairs(target.depends_on) do
      local pre = graph.objectives[pre_id]
      if pre and pre.state ~= "completed" then
        table.insert(missing, pre.name)
      end
    end
    if #missing > 0 then
      st:logWarn("Objective [%s] has unmet prerequisites: %s. Use force=true to override.",
        obj_name, table.concat(missing, ", "))
      return false
    end
  end

  if not QuestSystem.IsQuestStarted(quest_name) then
    st:logInfo("Starting quest [%s]", quest_name)
    QuestSystem.StartQuest(quest_name)
  end
  if not QuestSystem.IsQuestActivated(quest_name) then
    st:logInfo("Activating quest [%s]", quest_name)
    QuestSystem.ActivateQuest(quest_name, 1)
  end
  if not QuestSystem.IsObjectiveStarted(quest_name, obj_name) then
    st:logInfo("Starting objective [%s]", obj_name)
    QuestSystem.StartObjective(quest_name, obj_name)
  end
  -- the way play completes it (st_skip.lua): replayed, from its items or the objective its tree reacts to
  st_skip:complete(quest_name, obj_name)
  return true
end

-- ---------------------------------------------------------------------------
-- skip_to_decision: walk unlocks edges, advance busywork, stop at branches/decisions.
-- ---------------------------------------------------------------------------

local function find_active_frontier(graph)
  -- Active frontier = started objectives that aren't yet completed.
  local frontier = {}
  for _, obj in pairs(graph.objectives) do
    if obj.state == "started" then
      table.insert(frontier, obj)
    end
  end
  return frontier
end

local function enabled_unlocks(graph, obj)
  -- Future: filter by current quest_transition.enabled flag if dynamic.
  -- For now, all unlocks loaded into the graph are already "enabled" per scan.
  local out = {}
  for _, succ in ipairs(obj.unlocks) do
    table.insert(out, graph.objectives[succ])
  end
  return out
end

-- BT-aware predicates. st_bt_awareness is built at extraction time from
-- KCD's BehaviorTree XMLs and tells us, per quest+objective, which states the
-- BT actually watches: 's' = Started, 'c' = Completed, 'x' = Cancelled,
-- 'u' = Unchanged. An objective absent from the table has no BT references at
-- all - it's a journal/UI flag, force-completing it does nothing.
local function bt_codes(quest_name, obj_name)
  local q = st_bt_awareness and st_bt_awareness[quest_name] or nil
  if not q then return nil end
  return q[obj_name]
end

local function bt_completion_triggers(quest_name, obj_name)
  local codes = bt_codes(quest_name, obj_name)
  return codes and codes:find("c", 1, true) ~= nil
end

-- A stable signature of the started frontier - used to detect "no progress"
-- between iterations of the auto-advance loop.
local function frontier_signature(frontier)
  local names = {}
  for _, obj in ipairs(frontier) do table.insert(names, obj.name) end
  table.sort(names)
  return table.concat(names, "|")
end

-- One step of the iterative skip loop. KCD's quest_transition DAG only
-- partly encodes progression - the rest lives in BehaviorTree gates that
-- watch objective state changes. We force-complete the started frontier
-- (BT-watched and decorative alike, since decorative completes are no-ops)
-- and let the BT fire whatever it gates on next, then re-scan and repeat.
-- Stops at: graph branch (real player choice), no-progress, or iteration cap.
function st_navigator:skip_iterate(quest_name, snapshot, prev_sig, iteration, max_iter, entry)
  st_graph:refresh_states(quest_name)
  local graph = st_graph:get(quest_name)
  if not graph then return end

  local frontier = find_active_frontier(graph)
  if #frontier == 0 then
    st:logInfo("Skip done: no active objectives remaining in [%s] (quest may be complete)", quest_name)
    self:verify_post_skip(quest_name, snapshot, {})
    return
  end

  -- Detect a real graph branch in the frontier - any started objective whose
  -- unlocks fan out to multiple successors is a true player-choice fork.
  -- Stop and let the player decide.
  for _, obj in ipairs(frontier) do
    if #obj.unlocks > 1 then
      local paths = {}
      for _, n in ipairs(obj.unlocks) do
        table.insert(paths, graph.objectives[n].name)
      end
      st:logWarn("Skip stopped at branch [%s]. Available next objectives: %s. " ..
        "Pick one with st_advance <quest> <obj>.", obj.name, table.concat(paths, ", "))
      self:position_for_decision(quest_name, obj, entry)
      self:verify_post_skip(quest_name, snapshot, {})
      return
    end
  end

  -- No-progress detection: same frontier as last iteration means our
  -- previous force-completes didn't move anything new into 'started'. The
  -- BT is gated on something we can't trigger via CompleteObjective alone -
  -- typically a dialogue line, item check, or cross-quest condition.
  local cur_sig = frontier_signature(frontier)
  if iteration > 1 and cur_sig == prev_sig then
    st:logWarn("Skip stopped: no progress after iteration %d. Frontier unchanged " ..
      "(%d objective(s)). The BT is waiting for something CompleteObjective can't " ..
      "trigger - likely dialogue, item, or cross-quest gate. Frontier: %s",
      iteration - 1, #frontier, cur_sig)
    -- Teleport to the first frontier obj that has a registry hint, if any.
    local resolved = nil
    for _, obj in ipairs(frontier) do
      if entry and entry.npc_hints and entry.npc_hints[obj.name] then resolved = obj; break end
    end
    self:position_for_decision(quest_name, resolved or frontier[1], entry)
    self:verify_post_skip(quest_name, snapshot, {})
    return
  end

  if iteration > max_iter then
    st:logWarn("Skip stopped: hit iteration cap (%d). Frontier still has %d active " ..
      "objective(s). Run st_skip again to continue, or st_status to inspect.",
      max_iter, #frontier)
    self:verify_post_skip(quest_name, snapshot, {})
    return
  end

  -- Build the advance list. BT-watched objectives go first (their completion
  -- triggers progression); decorative ones go after (they're no-ops but we
  -- complete them for state hygiene). Already-completed objs are skipped.
  local watched, decorative = {}, {}
  for _, obj in ipairs(frontier) do
    if bt_completion_triggers(quest_name, obj.name) then
      table.insert(watched, obj)
    else
      table.insert(decorative, obj)
    end
  end

  local advance_list = {}
  for _, o in ipairs(watched) do table.insert(advance_list, o) end
  for _, o in ipairs(decorative) do table.insert(advance_list, o) end

  st:logInfo("Skip iteration %d: completing %d started objective(s) (%d BT-watched, %d decorative)",
    iteration, #advance_list, #watched, #decorative)

  -- Schedule the completions on a timer chain (DL-002: never bulk-complete).
  for i, obj in ipairs(advance_list) do
    Script.SetTimer((i - 1) * 100, function()
      st_navigator:safe_advance(quest_name, obj.name, true) -- force=true: ignore prereqs since
                                                            -- we're working from live frontier
    end)
  end

  -- After the chain finishes + a settle window for the BT to react, recurse.
  -- 800ms is empirical: enough for a single BT tick + objective state propagation.
  local next_delay = #advance_list * 100 + 800
  Script.SetTimer(next_delay, function()
    st_navigator:skip_iterate(quest_name, snapshot, cur_sig, iteration + 1, max_iter, entry)
  end)
end

function st_navigator:skip_to_decision(quest_name)
  -- ROLLED BACK 2026-05-04. The previous BT-driven auto-advance loop produced
  -- a worst-case outcome on q_plagueInMerhojed: KCD arms "conditional trigger"
  -- objectives (killMelichar, killNikodem, somePeopleDied, etc.) in 'started'
  -- state alongside genuine progression. Force-completing them tells the
  -- engine those events happened, propagating layersAreChangedDead and
  -- failing the quest. The BT awareness data shows these as 'c'-watched but
  -- can't distinguish "good progression" from "fail consequence" - the BT
  -- simply reacts when either fires.
  --
  -- For now: stop at registry decisions, stop at graph branches, do not
  -- auto-complete the frontier. Use st_advance for surgical control. Real
  -- fix tracked separately: a per-quest outcome registry derived from BT
  -- causality analysis (good ending / bad ending paths).
  local graph = st_graph:get(quest_name)
  if not graph then return false end

  local entry = st_registry and st_registry:get(quest_name) or nil
  if not entry then
    st:logError("No registry entry for [%s] - st_skip needs decision-point flags. " ..
      "Try st_advance for individual steps.", quest_name)
    return false
  end

  st_graph:refresh_states(quest_name)
  local frontier = find_active_frontier(graph)
  if #frontier == 0 then
    st:logWarn("Quest [%s] has no active objectives - nothing to skip from", quest_name)
    return false
  end

  -- Multi-frontier classification (no advance, just report).
  local at_decisions, branches, real_frontier = {}, {}, {}
  for _, obj in ipairs(frontier) do
    if obj.is_decision then
      table.insert(at_decisions, obj)
    elseif #obj.unlocks > 1 then
      table.insert(branches, obj)
    else
      table.insert(real_frontier, obj)
    end
  end

  if #at_decisions > 0 then
    local names = {}
    for _, o in ipairs(at_decisions) do table.insert(names, o.name) end
    st:logInfo("At decision point(s): %s. Use st_advance <quest> <obj> to flip a specific " ..
      "flag (check the BT first - some 'started' objectives are conditional triggers like " ..
      "killMelichar that fail the quest if force-completed).", table.concat(names, ", "))
    self:position_for_decision(quest_name, at_decisions[1], entry)
    return true
  end

  if #branches > 0 then
    local b = branches[1]
    local paths = {}
    for _, n in ipairs(b.unlocks) do
      table.insert(paths, graph.objectives[n].name)
    end
    st:logWarn("Graph branch at [%s]. Available next objectives: %s. " ..
      "Pick one with st_advance.", b.name, table.concat(paths, ", "))
    self:position_for_decision(quest_name, b, entry)
    return true
  end

  if #real_frontier > 0 then
    local names = {}
    for _, o in ipairs(real_frontier) do table.insert(names, o.name) end
    st:logInfo("Active frontier (%d objective(s)): %s. None are registered decisions or " ..
      "graph branches. st_skip auto-advance is disabled until per-quest outcome support " ..
      "lands - use st_advance <quest> <obj> for surgical control.",
      #real_frontier, table.concat(names, ", "))
    return true
  end

  return false
end

-- ---------------------------------------------------------------------------
-- Position the player + summon NPCs at the decision point.
-- ---------------------------------------------------------------------------

function st_navigator:position_for_decision(quest_name, target, entry)
  if not target then return end

  local hint = entry and entry.npc_hints and entry.npc_hints[target.name] or nil
  local npc_name = nil
  local home = nil

  if hint then
    npc_name = hint.npc
    home = hint.home
  else
    -- fall back to first decision NPC mention
    local dec = entry and entry.decisions and entry.decisions[target.name] or nil
    if dec then npc_name = dec.npc end
  end

  if npc_name then
    local npcs = st_npc:find(npc_name)
    if npcs and #npcs > 0 then
      st:logInfo("NPC [%s] is loaded - teleporting player to NPC", npc_name)
      st_teleport:player_to_npc(npc_name)
      return
    end
    if home then
      st:logInfo("NPC [%s] not loaded - teleporting to known home location", npc_name)
      st_teleport:player_to(home.x, home.y, home.z)
      return
    end
    st:logWarn("NPC [%s] not loaded and no home hint - staying in place", npc_name)
    return
  end

  -- No registry hint, try quest_npc soul_ids - single entity sweep.
  local graph = st_graph:get(quest_name)
  if graph and graph.npcs and #graph.npcs > 0 then
    local matches = st_npc:find_by_souls(graph.npcs)
    for soul, npc in pairs(matches) do
      local p = npc:GetWorldPos()
      st:logInfo("Found quest NPC by soul [%s] - teleporting player there", soul)
      st_teleport:player_to(p.x, p.y, p.z)
      return
    end
  end

  st:logInfo("No location data for [%s] - player not moved", target.name)
end

function st_navigator:verify_post_skip(quest_name, snapshot, expected_changes)
  local unexpected = st_graph:diff_against(quest_name, snapshot, expected_changes)
  if #unexpected == 0 then
    st:logInfo("Post-skip verification: no unexpected state changes")
    return
  end
  for _, u in ipairs(unexpected) do
    st:logWarn("Unexpected state change: [%s] %s -> %s", u.name, tostring(u.from), tostring(u.to))
  end
end

st:logDebug("st_navigator.lua loaded")
