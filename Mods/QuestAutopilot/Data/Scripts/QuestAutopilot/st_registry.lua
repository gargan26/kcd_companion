-- Decision-point + NPC-hint registry.
--
-- This is the only hand-authored content in the mod. Every other piece of
-- quest structure (objective list, dependency edges, NPC associations) is
-- pulled live from the database by st_quest_graph.
--
-- A registry entry classifies which objectives are meaningful decisions
-- (where the player makes a choice) vs busywork (traversal / fetch). The
-- skip flow stops at decisions, advances through busywork.
--
-- Entry shape:
--   st_registry.entries[quest_name] = {
--     decisions = {
--       [objective_name] = { description = "...", npc = "..." (optional) }
--     },
--     npc_hints = {
--       [objective_name] = { npc = "...", home = {x=, y=, z=} }
--     }
--   }

st_registry = {}
st_registry.entries = {}

function st_registry:register(quest_name, entry)
  st_registry.entries[quest_name] = entry
  st:logDebug("Registered quest [%s]", quest_name)
end

function st_registry:get(quest_name)
  return st_registry.entries[quest_name]
end

function st_registry:list()
  return st:sortedKeys(st_registry.entries)
end

st:logDebug("st_registry.lua loaded")
