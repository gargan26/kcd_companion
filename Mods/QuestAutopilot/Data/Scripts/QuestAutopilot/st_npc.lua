-- NPC search + interactability checks.
-- Adapted from kcd-cheat cheat_core_npc.lua (find_npc, get_npc_name).

st_npc = {}

function st_npc:get_display_name(npc)
  if not npc then return "UNKNOWN" end
  if npc["GetNpcName"] then
    local raw = npc:GetNpcName()
    if raw then return tostring(raw) end
  end
  if npc["class"] then return npc.class end
  return "UNKNOWN"
end

-- Substring + case-insensitive search across all loaded entities with actorStats.
function st_npc:find(name, range)
  if st:isBlank(name) then return {} end
  local searchKey = st:toUpper(name)
  local found = {}
  local pool
  if range then
    pool = System.GetEntitiesInSphere(player:GetPos(), range)
  else
    pool = System.GetEntities()
  end
  for _, npc in pairs(pool) do
    if npc and npc["actorStats"] ~= nil then
      local raw = st_npc:get_display_name(npc)
      if raw and string.find(st:toUpper(raw), searchKey, 1, true) then
        table.insert(found, npc)
      end
    end
  end
  return found
end

-- Find a loaded entity by sharedSoulGuid.
-- Filters to actor-typed entities first (cheap check) before touching
-- .properties, which on some non-actor entity types can fault inside the
-- CryEngine Lua bridge. Single pass across all entities.
function st_npc:find_by_soul(soul_id)
  if st:isBlank(soul_id) then return nil end
  local target = st:toLower(soul_id)
  for _, npc in pairs(System.GetEntities()) do
    if npc and npc["actorStats"] ~= nil and npc.properties and npc.properties.sharedSoulGuid then
      if st:toLower(npc.properties.sharedSoulGuid) == target then
        return npc
      end
    end
  end
  return nil
end

-- Find multiple souls in a single entity sweep. Returns map soul_id -> npc.
function st_npc:find_by_souls(soul_ids)
  local found = {}
  if not soul_ids or #soul_ids == 0 then return found end
  local targets = {}
  for _, sid in ipairs(soul_ids) do
    if not st:isBlank(sid) then targets[st:toLower(sid)] = sid end
  end
  for _, npc in pairs(System.GetEntities()) do
    if npc and npc["actorStats"] ~= nil and npc.properties and npc.properties.sharedSoulGuid then
      local sid = st:toLower(npc.properties.sharedSoulGuid)
      if targets[sid] and not found[targets[sid]] then
        found[targets[sid]] = npc
      end
    end
  end
  return found
end

-- Best-effort interactability check. Some AI states aren't observable from Lua;
-- callers should treat a true result as "probably ok, try anyway".
function st_npc:is_interactable(npc)
  if not npc then return false end
  if npc["IsDead"] and npc:IsDead() then return false end
  if npc["soul"] and npc.soul["GetState"] then
    local health = npc.soul:GetState("health")
    if health and health <= 0 then return false end
  end
  return true
end

function st_npc:get_position(name)
  local npcs = st_npc:find(name)
  if not npcs or #npcs == 0 then return nil end
  return npcs[1]:GetWorldPos()
end

-- Convenience: locate by name and summon to player (used by st_summon command).
function st_npc:summon(name)
  return st_teleport:npc_to_player(name)
end

st:logDebug("st_npc.lua loaded")
