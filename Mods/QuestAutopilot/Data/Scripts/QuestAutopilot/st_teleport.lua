-- Player + NPC teleportation wrappers.
-- Adapted from kcd-cheat cheat_core_player.lua / cheat_core_npc.lua patterns.

st_teleport = {}

-- Always lift the destination z this much above the marker / terrain. Quest
-- markers are routinely placed underground (invisible volumes that shouldn't
-- block player movement). Materializing inside terrain triggers a multi-tick
-- physics ejection that sensitizes the engine and can crash later. A small
-- lift puts the player above local geometry without lethal fall damage
-- (KCD's threshold is around 15-20m).
st_teleport.Z_LIFT = 5

local function safe_z(x, y, z)
  -- Bonus: query terrain height when available, use whichever is higher.
  -- If the API is missing or fails, fall back to marker z + lift.
  local terrain_z = nil
  if System and System.GetTerrainElevation then
    local ok, val = pcall(System.GetTerrainElevation, x, y)
    if ok and type(val) == "number" then terrain_z = val end
  end
  local base = math.max(z or 0, terrain_z or 0)
  return base + st_teleport.Z_LIFT
end

local function raw_teleport(x, y, z)
  player:SetWorldPos({ x = x, y = y, z = safe_z(x, y, z) })
end

function st_teleport:player_to(x, y, z)
  local before = player:GetWorldPos()
  raw_teleport(x, y, z)
  st:logInfo("Teleported player from (%d,%d,%d) to (%d,%d,%d)",
    before.x, before.y, before.z, x, y, z)
  return true
end

-- Pick a spawn point near a target, optionally offset so we don't stack on the player.
function st_teleport:spawn_point_near(x, y, z, radius, avoidExact)
  radius = radius or 3
  for _ = 1, 8 do
    local sx = math.random(x - radius, x + radius)
    local sy = math.random(y - radius, y + radius)
    if not avoidExact or (sx ~= x or sy ~= y) then
      return { x = sx, y = sy, z = z }
    end
  end
  return { x = x + radius, y = y, z = z }
end

function st_teleport:npc_to_player(name)
  local npcs = st_npc:find(name)
  if not npcs or #npcs == 0 then
    st:logError("NPC [%s] not found (not loaded in world)", tostring(name))
    return false
  end
  local npc = npcs[1]
  local pp = player:GetWorldPos()
  local spawn = st_teleport:spawn_point_near(pp.x, pp.y, pp.z, 3, true)
  npc:SetWorldPos(spawn)
  st:logInfo("Summoned NPC [%s] to player at (%d,%d,%d)",
    st_npc:get_display_name(npc), spawn.x, spawn.y, spawn.z)
  return true
end

function st_teleport:player_to_npc(name)
  local npcs = st_npc:find(name)
  if not npcs or #npcs == 0 then
    st:logError("NPC [%s] not found (not loaded in world)", tostring(name))
    return false
  end
  local npc = npcs[#npcs]  -- prefer last match (kcd-cheat default)
  local p = npc:GetWorldPos()
  local spawn = st_teleport:spawn_point_near(p.x, p.y, p.z, 2, true)
  st_teleport:player_to(spawn.x, spawn.y, spawn.z)
  return true
end

st:logDebug("st_teleport.lua loaded")
