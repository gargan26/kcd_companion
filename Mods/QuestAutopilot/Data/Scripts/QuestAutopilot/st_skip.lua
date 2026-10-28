-- Completing an objective the way play completes it. A bare QuestSystem.CompleteObjective sets the state, and the
-- engine then starts the next objectives, pays the rewards and runs the trees waiting on it; whatever else the
-- conversation, tree or rule that completes it in play does at that moment is missed (findings.md § Quest skip side
-- effects). Data/st_skip.lua (tools/extract_skip_effects.py) says, per objective, what to do instead:
--   s (absent from its quest's table)  complete it: play does nothing more
--   g  give the items it tracks; the engine completes it itself
--   r  replay what completes it in play: the conversation's objective steps in their order with their conditions,
--      its lines on Henry's side (items, money, globals, perks), or the tree's steps around the completion
--   u  complete (or start) the objective the quest's tree reacts to; the tree completes this one
--   w  play needs a conversation, scene or world event: complete it, the faces warn first
--   n  the game never completes it; ?  not worked out
-- What a replay or a hand-over could not finish is completed directly after a short wait, and said.

st_skip = st_skip or {}

st_skip.SETTLE_MS = 1500
st_skip.MONEY = "5ef63059-322e-4e1b-abe8-926e100c770e"

-- A delayed outcome goes to the trainer's status line too (qa_api sets this).
st_skip.note = st_skip.note or function() end

function st_skip:info(quest, obj)
  local q = st_skip_data and st_skip_data[quest]
  if not q then return "?", "" end
  local e = q[obj]
  if not e then return "s", "" end
  return e[1], e[2] or "", e[3]
end

-- Whether completing it through this module does all play does at that moment.
function st_skip:full(v)
  return v == "s" or v == "g" or v == "r" or v == "u"
end

local function ask(fn, ...)
  local f = QuestSystem[fn]
  if not f then return false end
  local ok, v = pcall(f, ...)
  return ok and v and true or false
end

local function done(q, o) return ask("IsObjectiveCompleted", q, o) or ask("IsObjectiveCanceled", q, o) end
local function begun(q, o) return ask("IsObjectiveStarted", q, o) or done(q, o) end

-- The conditions of a conversation's objective rows, as the game's dialogue conditions read them.
local ENV = {
  IsObjectiveStarted = function(q, o) return begun(q, o) end,
  IsObjectiveCompleted = function(q, o) return ask("IsObjectiveCompleted", q, o) end,
  IsObjectiveCanceled = function(q, o) return ask("IsObjectiveCanceled", q, o) end,
  IsObjectiveUnchanged = function(q, o) return not begun(q, o) end,
  IsObjectiveTrackedCompleted = function(q, o) return ask("IsObjectiveCompleted", q, o) end,
  IsQuestStarted = function(q) return ask("IsQuestStarted", q) end,
  IsQuestCompleted = function(q) return ask("IsQuestCompleted", q) end,
  IsQuestCanceled = function(q) return ask("IsQuestCanceled", q) end,
  IsQuestActivated = function(q) return ask("IsQuestActivated", q) end,
  IsQuestUnchanged = function(q) return not ask("IsQuestStarted", q) end,
  IsQuestAvailable = function(q) return not ask("IsQuestStarted", q) end,
  gvar = function(k)
    local ok, v = pcall(Variables.GetGlobal, k)
    return ok and tonumber(v) or 0
  end,
}

local function holds(cond)
  if not cond then return true end
  local fn = loadstring("return " .. cond)
  if not fn then return false end
  setfenv(fn, ENV)
  local ok, v = pcall(fn)
  return ok and v and true or false
end

local function count_of(id)
  local ok, n = pcall(function() return player.inventory:GetCountOfClass(id) end)
  return ok and tonumber(n) or 0
end

local function give(id, n)
  for _ = 1, n do player.inventory:AddItem(ItemManager.CreateItem(id, 1, 1)) end
end

local function complete(q, o)
  if not begun(q, o) then QuestSystem.StartObjective(q, o) end
  if not done(q, o) then QuestSystem.CompleteObjective(q, o, true) end
end

local STEP = {
  S = function(s) if not begun(s[2], s[3]) then QuestSystem.StartObjective(s[2], s[3]) end end,
  C = function(s) complete(s[2], s[3]) end,
  X = function(s) if not done(s[2], s[3]) then QuestSystem.CancelObjective(s[2], s[3]) end end,
  Q = function(s) QuestSystem[s[2]](s[3], 1) end,
  give = function(s) give(s[2], s[3]) end,
  take = function(s) Utils.RemoveInvItem(player, s[2], s[3], false) end,
  money = function(s)
    -- the money item's own units, as the dialogue scripts move it
    if s[2] > 0 then player.inventory:AddItem(ItemManager.CreateItem(st_skip.MONEY, 1, s[2]))
    else Utils.RemoveInvItem(player, st_skip.MONEY, -s[2], false) end
  end,
  lua = function(s) assert(loadstring(s[2]))() end,
}

function st_skip:replay(quest, obj, steps)
  local failed = 0
  for _, s in ipairs(steps) do
    if (s[1] ~= "S" and s[1] ~= "C" and s[1] ~= "X") or holds(s[4]) then
      local ok, err = pcall(STEP[s[1]], s)
      if not ok then
        failed = failed + 1
        st:logWarn("Replay step %s failed: %s", tostring(s[1]), tostring(err))
      end
    end
  end
  if not done(quest, obj) then complete(quest, obj) end
  if failed > 0 then
    st:logWarn("Completed [%s] the way the game does; %d step(s) of it failed", obj, failed)
  else
    st:logInfo("Completed [%s] the way the game does", obj)
  end
end

-- After the game has had time to react: complete it directly if it did not, and say which happened. up: the
-- objective fired instead, or nil for the items.
function st_skip:settle(quest, obj, up)
  Script.SetTimer(st_skip.SETTLE_MS, function()
    if done(quest, obj) and up then
      st:logInfo("The game completed [%s] from [%s]", obj, up)
      st_skip.note("The game completed [%s] from [%s]", obj, up)
    elseif done(quest, obj) then
      st:logInfo("The game completed [%s] from the items", obj)
      st_skip.note("The game completed [%s] from the items", obj)
    elseif up then
      complete(quest, obj)
      st:logWarn("The game did not complete [%s] from [%s]: completed it directly", obj, up)
      st_skip.note("The game did not complete [%s] from [%s]: completed it directly", obj, up)
    else
      complete(quest, obj)
      st:logWarn("The game did not complete [%s] from the items: completed it directly", obj)
      st_skip.note("The game did not complete [%s] from the items: completed it directly", obj)
    end
  end)
end

-- Complete one objective (its quest started and active, the objective started) the way play does.
function st_skip:complete(quest, obj, depth)
  local v, kinds, fire = self:info(quest, obj)
  if v == "r" and fire then
    return self:replay(quest, obj, fire)
  end
  if v == "g" and fire then
    local n = 0
    for _, it in ipairs(fire) do
      local need = math.max(0, it[2] - count_of(it[1]))
      if need > 0 then
        local ok, err = pcall(give, it[1], need)
        if ok then n = n + need else st:logWarn("Could not give item %s: %s", tostring(it[1]), tostring(err)) end
      end
    end
    st:logInfo("Gave the %d item(s) [%s] tracks; the game completes it from them", n, obj)
    return self:settle(quest, obj, nil)
  end
  if v == "u" and fire and (depth or 0) == 0 then
    local up, state = fire[1], fire[2]
    if state == "Started" then
      if not begun(quest, up) then QuestSystem.StartObjective(quest, up) end
    elseif not done(quest, up) then
      if not begun(quest, up) then QuestSystem.StartObjective(quest, up) end
      self:complete(quest, up, 1)
    end
    st:logInfo("Fired [%s], which the quest completes [%s] from", up, obj)
    return self:settle(quest, obj, up)
  end
  complete(quest, obj)
  if v == "n" then
    st:logWarn("The game never completes [%s] itself: completed it anyway", obj)
  elseif not self:full(v) then
    st:logWarn("Completed [%s]; play does more here, which was not done", obj)
  else
    st:logInfo("Completed [%s]", obj)
  end
end

st:logDebug("st_skip.lua loaded")
