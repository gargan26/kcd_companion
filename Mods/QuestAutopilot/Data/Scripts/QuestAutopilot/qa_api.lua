-- KCD Companion's API for KCD1: every tab and button of both faces (the browser panel and the F6 window) comes from
-- here, in the same model as KCD2 Companion's (KCD2/src/Data/Scripts/QuestTravel/qt_api.lua, DL-K202):
--   tabs              -> [{id, title}]
--   tab?name=<id>&q=  -> {status, filter, refresh, options[], inputs[], actions[], groups[{title, sub, open, actions[], rows[]}], doc}
--   <action>?...      -> {ok, msg}
-- The plugin (KCD/native) reaches it through the bridge below: KCD1's mod Lua has no io, so a request arrives as a Lua
-- file it loads and the answer leaves through the game's log, from which the plugin takes it. Steam is the plugin's
-- part: it writes the achievement list into the bridge folder before the Achievements tab is read, and runs an unlock
-- before passing its result here.

QuestAutopilot = QuestAutopilot or {}
local QA = QuestAutopilot
QA.api = {}
QA.tabs = {}
QA.opts = QA.opts or { skip_teleport = true, bring_horse = false, skip_warning = true }

-- Play options from the last session: the plugin keeps each opt call in the bridge folder (prefs.lua), since the
-- mod's Lua cannot write a file.
function QA.load_prefs()
  local f = loadfile("quest_autopilot_bridge/prefs.lua")
  local ok, t = pcall(f or function() end)
  if ok and type(t) == "table" then
    for k, v in pairs(t) do QA.opts[k] = v == "1" end
  end
end
QA.load_prefs()

-- ---------------------------------------------------------------------------
-- JSON out, query in (as in the KCD2 trainer)
-- ---------------------------------------------------------------------------
local ARRAY = {}
local function arr(t) return setmetatable(t or {}, ARRAY) end

local function json_str(s)
  -- control bytes only: %c also matches 0x80-0x9F under the Windows C runtime, and those are UTF-8 continuation bytes;
  -- and $, % and @, which the game's log reads as a colour code or a format, and the bridge as its own marker
  s = string.gsub(s, '[%z\1-\31\127"\\%$%%@]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
    elseif c == "\n" then return "\\n" elseif c == "\t" then return "\\t"
    else return string.format("\\u%04x", string.byte(c)) end
  end)
  return '"' .. s .. '"'
end

function QA.json(v)
  local t = type(v)
  if t == "string" then return json_str(v) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.3f", v)
  end
  if t == "boolean" then return v and "true" or "false" end
  if t ~= "table" then return "null" end
  local parts = {}
  if getmetatable(v) == ARRAY or (#v > 0) then
    for i = 1, #v do parts[i] = QA.json(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for k, x in pairs(v) do
    if type(x) ~= "function" then table.insert(parts, json_str(tostring(k)) .. ":" .. QA.json(x)) end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function urldecode(s)
  s = string.gsub(s, "+", " ")
  return (string.gsub(s, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function QA.parse_query(q)
  local t = {}
  for pair in string.gmatch(q or "", "[^&]+") do
    local k, v = string.match(pair, "^([^=]*)=?(.*)$")
    if k and k ~= "" then t[urldecode(k)] = urldecode(v or "") end
  end
  return t
end

local function enc(s)
  return (string.gsub(tostring(s), "[^A-Za-z0-9%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function args(t)
  local keys = {}
  for k in pairs(t) do table.insert(keys, k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if type(v) == "string" and string.match(v, "^{%w+}$") then table.insert(parts, k .. "=" .. v)
    else table.insert(parts, k .. "=" .. enc(v)) end
  end
  return table.concat(parts, "&")
end

local function action(label, call, a, tip)
  return { label = label, call = call, args = args(a or {}), tip = tip }
end

local function result(ok, msg) return { ok = ok and true or false, msg = msg } end

-- ---------------------------------------------------------------------------
-- Language: the game's g_language picks both the game's own text (names, journal lines, read by key from the loaded
-- language's tables) and the trainer's words (QA.LANG[ui], Data/qa_lang_<ui>.lua; English is the key).
-- ---------------------------------------------------------------------------
QA.LANG = QA.LANG or {}
local UI_LANG = { chineses = "zh", chineset = "zh", french = "fr", german = "de" }
QA.game_lang, QA.ui = "english", "en"

function QA.read_lang()
  local ok, v = pcall(System.GetCVar, "g_language")
  QA.game_lang = (ok and type(v) == "string" and v ~= "") and string.lower(v) or "english"
  QA.ui = UI_LANG[QA.game_lang] or "en"
end

local function L(s)
  local t = QA.LANG[QA.ui]
  return t and t[s] or s
end
QA.L = L

local function F(fmt, ...) return string.format(L(fmt), ...) end

function QA.api_json(name, query)
  QA.read_lang()
  local fn = QA.api[name]
  if not fn then return QA.json({ ok = false, msg = "unknown call '" .. tostring(name) .. "'" }) end
  local ok, res = pcall(fn, QA.parse_query(query))
  if not ok then
    System.LogAlways("[QuestAutopilot] api " .. tostring(name) .. " failed: " .. tostring(res))
    return QA.json({ ok = false, msg = "error: " .. tostring(res) })
  end
  return QA.json(res)
end

-- Quest Autopilot's functions report through st:logInfo/logWarn/logError; run one and keep what it said, in the
-- trainer's language (each format string is a key of the language table).
local function captured(fn)
  local lines, saved = {}, {}
  for _, k in ipairs({ "logInfo", "logWarn", "logError" }) do
    saved[k] = st[k]
    st[k] = function(self, fmt, ...)
      local ok, s = pcall(string.format, L(fmt), ...)
      if not ok then ok, s = pcall(string.format, fmt, ...) end
      table.insert(lines, ok and s or tostring(fmt))
      saved[k](self, fmt, ...)
    end
  end
  local ok, err = pcall(fn)
  for k, f in pairs(saved) do st[k] = f end
  if not ok then table.insert(lines, "error: " .. tostring(err)) end
  return ok, lines
end

local function last_lines(lines, n)
  local out = {}
  for i = math.max(1, #lines - (n or 2) + 1), #lines do table.insert(out, lines[i]) end
  return table.concat(out, " · ")
end

local function in_game() return player ~= nil and type(player.GetWorldPos) == "function" end
local function no_game() return { status = L("No game loaded: load a save first."), filter = false, refresh = 2, groups = arr() } end

local function dist2d(x, y)
  local p = player:GetWorldPos()
  return math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2)
end

local function matches(q, ...)
  if not q or q == "" then return true end
  q = string.lower(q)
  for i = 1, select("#", ...) do
    local s = select(i, ...)
    if s and string.find(string.lower(s), q, 1, true) then return true end
  end
  return false
end

-- "stealAxe" -> "steal axe"
local function humanize(s)
  s = string.gsub(tostring(s), "(%l)(%u)", "%1 %2")
  s = string.gsub(s, "_", " ")
  return string.lower(s)
end

local function world() return QA.world or { items = {}, places = {}, shops = {}, benches = {}, stashes = {}, sources = {}, quest_titles = {} } end

-- ---------------------------------------------------------------------------
-- Text the game shows (names of people, quests, objectives, items, places), read from the loaded language's tables
-- ---------------------------------------------------------------------------
QA.text = QA.text or {}

function QA.load_text(file)
  local cache = QA.game_lang .. "/" .. file
  if QA.text[cache] then return QA.text[cache] end
  local t = {}
  local ok, xml = pcall(System.LoadTextFile, "Localization/" .. file)
  if ok and type(xml) == "string" then
    for key, a, b in string.gmatch(xml, "<Row>%s*<Cell>(.-)</Cell>%s*<Cell>(.-)</Cell>%s*<Cell>(.-)</Cell>") do
      local v = (b ~= "" and b) or a
      v = string.gsub(v, "&apos;", "'")
      v = string.gsub(v, "&quot;", '"')
      t[key] = string.gsub(v, "&amp;", "&")
    end
  end
  QA.text[cache] = t
  return t
end

-- The game's own text for a key in its current language; the English baked into the data otherwise.
function QA.gt(file, key, english)
  if QA.game_lang == "english" or not key or key == "" then return english end
  local v = QA.load_text(file)[key]
  return (v and v ~= "") and v or english
end

QA.PLACE_TEXT = "text_ui_quest.xml"  -- the table the place names' keys live in (tools/extract_world.py)

function QA.person_name(e)
  local ok, key = pcall(function() return e:GetNpcName() end)
  if ok and key and key ~= "" then
    local name = QA.load_text("text_ui_soul.xml")[key]
    if name and name ~= "" then return name end
  end
  return e:GetName()
end

function QA.quest_title(q)
  local W = world()
  local title = QA.gt("text_ui_quest.xml", W.quest_title_keys and W.quest_title_keys[q], W.quest_titles[q])
  return (title and title ~= "") and title or q
end

-- An objective by its journal line (Data/qa_data.lua), else its name made readable.
function QA.obj_text(q, oname)
  local j = QA.journal and QA.journal[q] and QA.journal[q][oname]
  if j then return QA.gt("text_ui_quest.xml", j.key, j.en) end
  return humanize(oname)
end

function QA.item_name(it) return QA.gt("text_ui_items.xml", it.key, it.name) end
function QA.place_name(pl) return QA.gt(QA.PLACE_TEXT, pl.key, pl.name) end

-- ---------------------------------------------------------------------------
-- Teleporting
-- ---------------------------------------------------------------------------
QA.MAX_JUMP = 6000
QA.MAP_SIZE = 4096  -- both levels' terrain runs 0..this on X and Y (level.pak levelinfo.xml: TerrainInfo HeightmapSize)
QA.back_pos = QA.back_pos or nil

function QA.mount()
  local ok, mounted = pcall(function() return player.human:IsMounted() end)
  if not (ok and mounted) then return nil end
  local ok2, horse = pcall(function() return XGenAIModule.GetEntityByWUID(player.human:GetHorse()) end)
  return ok2 and horse or nil
end

-- The floor under a point: a ray from just above it (markers sit under roofs and trees), else from high up, else
-- Quest Autopilot's terrain-plus-lift.
function QA.ground(x, y, z)
  local ok, hitz = pcall(function()
    for _, from in ipairs({ 1.2, 60 }) do
      local hits = {}
      local n = Physics.RayWorldIntersection({ x = x, y = y, z = z + from }, { x = 0, y = 0, z = -(from + 60) },
        1, ent_all, player.id, nil, hits)
      if n and n > 0 and hits[1] and hits[1].pos then return hits[1].pos.z + 0.1 end
    end
  end)
  if ok and hitz then return hitz end
  return z + 0.5
end

-- Where to stand at a typed X and Y (t: the terrain's height there). Every surface on the vertical line is found top
-- down: a ray from well above the highest thing there, then again from just under each surface it meets. The
-- engine's rays meet faces from behind too, so the line crosses every face: from the sky down, a face looking up
-- enters a solid and one looking down leaves it, and a surface is in open air only when as many have been left as
-- entered (overlapping rocks in a quarry, the ground in a tree or under a floor are not). From the bottom up, the
-- first surface in open air that faces up no steeper than QA.WALKABLE wins, when the next face above it is an
-- underside at least QA.HEADROOM higher (more under a sloping roof), or there is none, and level rays from it do not
-- show it inside a solid the line passed through. A surface more than half a metre under water does not
-- count; with no dry one, the water's surface. Surfaces more than a metre under the terrain are left out.
-- Returns the height, nil when there is nowhere to stand, and true as well when it is the top surface over dry
-- surfaces more than 1 m under it that had no room (furniture up to a shelf or the roof): QA.fit looks beside it.
QA.HEADROOM, QA.HEADROOM_MOUNTED, QA.BODY_RADIUS = 1.9, 2.8, 0.35
QA.WALKABLE = 0.6  -- the least normal.z one can stand on (about 53°); a quarry's cliff face under an overhang is not
local SCAN_ABOVE, SCAN_BELOW, SCAN_RAYS = 150, 1, 64

local function hit(from, dir)
  local hits = {}
  local flags = (ent_all and ent_living) and (ent_all - ent_living) or ent_all  -- people and animals are not ground
  local ok, n = pcall(Physics.RayWorldIntersection, from, dir, 1, flags, player.id, nil, hits)
  local h = ok and n and n > 0 and hits[1]
  if h and h.pos then return h end
end

local function ray(x, y, z, dz)
  local h = hit({ x = x, y = y, z = z }, { x = 0, y = 0, z = dz })
  if h then
    local nz = h.normal and h.normal.z or 1
    return { z = h.pos.z, nz = nz, up = nz > 0, walk = nz >= QA.WALKABLE }
  end
end

-- Inside a solid the line itself showed no sign of (a wall it passed through a gap of, a thick wall whose top is a
-- ledge): level rays from chest height meet a face from behind in most directions (Talmberg, 2026-10-20: 7 of 8).
local function enclosed(x, y, z)
  local behind = 0
  for k = 0, 7 do
    local dx, dy = math.cos(k * math.pi / 4), math.sin(k * math.pi / 4)
    local h = hit({ x = x, y = y, z = z + 1.2 }, { x = dx * 4, y = dy * 4, z = 0 })
    if h and h.normal and h.normal.x * dx + h.normal.y * dy > 0 then behind = behind + 1 end
  end
  return behind >= 6
end

-- The water's surface at a point, when the point (just above the bed) is in water; the engine answers from level
-- data, and dry ground reads -1e6.
function QA.water_level(x, y, z)
  local ok, w = pcall(function() return CryAction.GetWaterInfo({ x = x, y = y, z = z }) end)
  if ok and type(w) == "number" and w > z then return w end
end

function QA.terrain(x, y)
  local ok, t = pcall(System.GetTerrainElevation, { x = x, y = y, z = 0 })
  if ok and type(t) == "number" then return t end
end

function QA.stand(x, y, t)
  local s, z, bottom = {}, t + SCAN_ABOVE, t - SCAN_BELOW
  for _ = 1, SCAN_RAYS do
    local h = z > bottom and ray(x, y, z, bottom - z)
    if not h then break end
    table.insert(s, 1, h)  -- bottom up
    z = h.z - 0.005  -- close under it: a crate's underside sits 1 cm over the ground, a plank is 2 cm thick
  end
  local depth, open = 0, {}
  for i = #s, 1, -1 do
    open[i] = depth == 0
    depth = math.max(0, depth + (s[i].up and 1 or -1))
  end
  local water = QA.water_level(x, y, t + 0.05)
  local head = QA.mount() and QA.HEADROOM_MOUNTED or QA.HEADROOM
  local top, cramped = s[#s], false
  for i, c in ipairs(s) do
    if c.walk and not (water and c.z < water - 0.5) then
      local above = s[i + 1]
      -- a sloping ceiling comes down within a body's width of the line: an attic roof at 51° needs 0.43 m more
      local slope = above and math.min(3, math.sqrt(math.max(0, 1 - above.nz * above.nz)) / math.max(0.2, math.abs(above.nz)))
      if open[i] and (not above or (not above.up and above.z - c.z >= head + QA.BODY_RADIUS * slope))
          and not enclosed(x, y, c.z) then
        return c.z + 0.1, c == top and cramped
      end
      if c.z < top.z - 1 then cramped = true end  -- nearer the top, it is the top's own timbers (a jetty's deck)
    end
  end
  if water then return water + 0.1 end
end

-- Where a typed X and Y lands: x, y, z. A point that only leaves the top surface, 2 m or more above the terrain, over
-- floors without room (a cupboard under a shelf, a stove under the attic) lands on the nearest spot within
-- QA.FIT_AROUND m that has room and lies more than 1.5 m lower, beside the furniture instead of on the roof. A top
-- nearer the terrain is a floor at ground level, kept rather than traded for a cellar beside it. A point with nowhere
-- to stand at all (inside a cart, a log pile, a stall whose top is too steep) lands on the nearest spot around it that
-- has one; nil when none does.
QA.FIT_AROUND = { 0.6, 1.2, 1.8, 2.4 }
function QA.fit(x, y, t)
  local z, cramped = QA.stand(x, y, t)
  if z and not (cramped and z - t >= 2) then return x, y, z end
  for _, r in ipairs(QA.FIT_AROUND) do
    for k = 0, 7 do
      local nx, ny = x + r * math.cos(k * math.pi / 4), y + r * math.sin(k * math.pi / 4)
      local nz, ncramped = QA.stand(nx, ny, QA.terrain(nx, ny) or t)
      if nz and not ncramped and (not z or nz < z - 1.5) then return nx, ny, nz end
    end
  end
  return x, y, z
end

-- Trees load their solid parts only near Henry, so a line read from afar can miss the tree he then lands in. Once
-- the place has loaded, QA.REFIT_MS after the jump, the line is read again and he (or his horse) is moved to what it
-- gives now; one who has already moved is left alone.
QA.REFIT_MS = { 1000, 3000 }
function QA.refit(x, y, t, lx, ly, lz)
  for _, ms in ipairs(QA.REFIT_MS) do
    Script.SetTimer(ms, function()
      local who = QA.mount() or player
      local p = who:GetWorldPos()
      if math.abs(p.x - lx) > 0.5 or math.abs(p.y - ly) > 0.5 or math.abs(p.z - lz) > 1 then return end
      local fx, fy, fz = QA.fit(x, y, QA.terrain(x, y) or t)
      if fz and (math.abs(fz - lz) > 0.3 or math.abs(fx - lx) > 0.1 or math.abs(fy - ly) > 0.1) then
        who:SetWorldPos({ x = fx, y = fy, z = fz })
        lx, ly, lz = fx, fy, fz
      end
    end)
  end
end

function QA.player_horse()
  local ok, wuid = pcall(function() return player.player:GetPlayerHorse() end)
  if not ok or not wuid or wuid == __null then return nil end
  local ok2, horse = pcall(XGenAIModule.GetEntityByWUID, wuid)
  return ok2 and horse or nil
end

function QA.horse_to_player()
  local horse = QA.player_horse()
  if not horse then return false, L("you have no horse") end
  local p = player:GetWorldPos()
  horse:SetWorldPos({ x = p.x + 2.5, y = p.y + 1, z = QA.ground(p.x + 2.5, p.y + 1, p.z) })
  return true, L("your horse is beside you")
end

function QA.teleport(x, y, z, what, ground)
  local p = player:GetWorldPos()
  local d = math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2)
  if d > QA.MAX_JUMP then return false, F("refusing a %.0f m jump to %s", d, what) end
  QA.back_pos = { x = p.x, y = p.y, z = p.z }
  local zz = ground and QA.ground(x, y, z) or z
  local mount = QA.mount()
  if mount then
    mount:SetWorldPos({ x = x, y = y, z = zz })
    what = what .. L(" (on horseback)")
  else
    player:SetWorldPos({ x = x, y = y, z = zz })
    if QA.opts.bring_horse then QA.horse_to_player() end
  end
  return true, "-> " .. what
end

-- The loaded level: the main map (rataje) or A Woman's Lot's prologue (rataje_dlc4), whose places share the main
-- map's coordinates; the world data carries a level on each record.
function QA.current_level()
  local ok, v = pcall(System.GetCVar, "sv_map")
  if ok and type(v) == "string" and v ~= "" then return string.lower(v) end
  return "rataje"
end

local function here(t, level) return not t.level or t.level == level end

local function go_args(t, what, beside)
  return { x = string.format("%.2f", t.x), y = string.format("%.2f", t.y), z = string.format("%.2f", t.z), what = what,
           beside = beside and "1" or nil }
end

-- ---------------------------------------------------------------------------
-- Quests: Quest Autopilot's graph (st_quest_data), live states (QuestSystem), registry, outcomes, journal tracker
-- ---------------------------------------------------------------------------
function QA.started_quests()
  local out = {}
  for _, row in ipairs((st_quest_data and st_quest_data.quests) or {}) do
    local q = row.quest_name
    local ok, s = pcall(QuestSystem.IsQuestStarted, q)
    if ok and s then
      local okc, c = pcall(function() return QuestSystem.IsQuestCompleted and QuestSystem.IsQuestCompleted(q) end)
      table.insert(out, { name = q, done = okc and c or false })
    end
  end
  return out
end

-- Where the quest's current objective is, as Quest Autopilot's st_goto resolves it: dest {x, y, z} or nil, why.
function QA.quest_dest(q)
  local dest
  local real = st_teleport.player_to
  st_teleport.player_to = function(_, x, y, z) dest = { x = x, y = y, z = z } return true end
  local ok, lines = captured(function() st_cmd:goto_(q) end)
  st_teleport.player_to = real
  if dest then return dest end
  return nil, L("no place is known for the current objective")
end

local function npc_rows(graph)
  local rows = arr()
  if not (graph.npcs and #graph.npcs > 0) then return rows end
  for _, npc in pairs(st_npc:find_by_souls(graph.npcs)) do
    local p = npc:GetWorldPos()
    table.insert(rows, { text = QA.person_name(npc), tag = L("person"), dist = dist2d(p.x, p.y),
      actions = arr({ action(L("Go"), "go", { npc = npc:GetName() }), action(L("Summon"), "summon", { npc = npc:GetName() }) }) })
  end
  return rows
end

-- What completing an objective through the trainer does, from Data/st_skip.lua (st_skip.lua; findings.md § Quest
-- skip side effects): the kinds play does beyond it, the tip's line, the "(risky)" label and the question first.
local SKIP_KIND = {
  i = "an item", f = "a flag or counter", n = "a person or thing in the world",
  d = "a cutscene or conversation", o = "another objective or quest", r = "a reward or other change",
}
local SKIP_RISK = "A skip does only what the objective's own trigger does: anything else the quest does at that moment (an item handed over, a flag another quest reads) is missed and can leave the quest stuck. Keep a save from before it."

local function kinds_text(kinds)
  local parts = {}
  for k in string.gmatch(kinds or "", ".") do
    if SKIP_KIND[k] then table.insert(parts, L(SKIP_KIND[k])) end
  end
  return #parts > 0 and table.concat(parts, L(", ")) or nil
end

-- The tip's line: what play does here and how the trainer does it, or what it misses.
local function skip_note(q, v, kinds, fire)
  if v == "s" then return "" end
  if v == "r" then
    local what = kinds_text(kinds)
    return what and (L("Does what the game does here as well: ") .. what .. ".") or ""
  end
  if v == "g" then return L("Gives you the items it tracks; the game then completes it itself.") end
  if v == "u" and fire and fire[2] == "Started" then
    return F("Starts '%s'; the quest completes this from there.", QA.obj_text(q, fire[1]))
  end
  if v == "u" and fire then
    return F("Completes '%s'; the quest completes this from there.", QA.obj_text(q, fire[1]))
  end
  local what = kinds_text(kinds) or L("what play does here could not be worked out")
  return L("Play does more here than the skip: ") .. what .. ". " .. L(SKIP_RISK)
end

-- A completion that misses what play does reads "(risky)" and, while the skip_warning option is on, asks first;
-- "Don't remind me again" turns the option off.
local function skip_action(q, v, kinds, fire, label, a, tip)
  local full = st_skip:full(v)
  local note = skip_note(q, v, kinds, fire)
  local act = action(full and label or (label .. " " .. L("(risky)")), "advance", a, note ~= "" and (tip .. " " .. note) or tip)
  if QA.opts.skip_warning and not full then
    act.confirm = note
    act.confirm_yes, act.confirm_no, act.confirm_mute = L("Skip anyway"), L("Cancel"), L("Don't remind me again")
    act.mute = "key=skip_warning&v=0"
  end
  return act
end

-- An ending's name and description in the trainer's language (Data/st_outcomes.lua is English).
local function ending_label(name) return L(humanize(name)) end
local function ending_desc(o) return o.description and L(o.description) or nil end

function QA.tabs.quests(a)
  if not in_game() then return no_game() end
  local all, endings, finished = a.all == "1", a.endings == "1", a.finished == "1"
  local groups = arr()
  for _, sq in ipairs(QA.started_quests()) do
    local q = sq.name
    local graph = st_graph:refresh_states(q)
    if graph and (finished or not sq.done) then
      local title = QA.quest_title(q)
      local rows, ncurrent, ndone, total = arr(), 0, 0, 0
      for _, id in ipairs(graph.topo_order) do
        local o = graph.objectives[id]
        total = total + 1
        if o.state == "completed" then ndone = ndone + 1 end
        -- a hidden objective is the quest's own bookkeeping (a watcher for a death, a flag), never a step to press
        local current = o.state == "started" and not o.is_hidden
        if current then ncurrent = ncurrent + 1 end
        local text = QA.obj_text(q, o.name)
        if (current or all) and matches(a.q, text, o.name, title, q) then
          local unl = {}
          for _, u in ipairs(o.unlocks or {}) do
            table.insert(unl, graph.objectives[u] and QA.obj_text(q, graph.objectives[u].name) or tostring(u))
          end
          local row = { text = text, tag = o.is_decision and L("decision") or (o.is_hidden and L("hidden"))
              or (not current and L(o.state) or nil),
            sub = (#unl > 0) and ("→ " .. table.concat(unl, L(", "))) or nil, tip = o.name, actions = arr() }
          -- an objective the game never completes itself gets no button
          local v, kinds, fire = st_skip:info(q, o.name)
          if v ~= "n" then
            if current or o.state == "unchanged" then
              table.insert(row.actions, skip_action(q, v, kinds, fire, current and L("Advance") or L("Complete"),
                { quest = q, obj = o.name },
                current and L("Complete this objective (refuses when its prerequisites are not met)")
                  or L("Complete an objective that has not started (prerequisites checked)")))
            end
            local unmet = false
            for _, pre in ipairs(o.depends_on or {}) do
              local po = graph.objectives[pre]
              if po and po.state ~= "completed" then unmet = true end
            end
            if (all and o.state == "unchanged") or (current and unmet) then
              table.insert(row.actions, skip_action(q, v, kinds, fire, L("Force"), { quest = q, obj = o.name, force = "1" },
                L("Complete it even with its prerequisites unmet. The quest may not expect this; save first.")))
            end
          end
          table.insert(rows, row)
        end
      end
      for _, r in ipairs(npc_rows(graph)) do table.insert(rows, r) end
      if (ncurrent > 0 or finished or all) and #rows > 0 then
        local gacts = arr({ action(L("Go"), "goquest", { quest = q }, L("To the current objective")) })
        -- Skip to next decision walks Quest Autopilot's decision registry, which covers only some quests
        if st_registry:get(q) then
          table.insert(gacts, action(L("Skip to next decision"), "skip", { quest = q },
            L("Completes busywork and stops at the next decision or branch, then takes you there")))
        end
        local outs = st_outcomes and st_outcomes[q]
        if outs then
          for _, m in ipairs({ { "good", "Best ending" }, { "bad", "Worst ending" } }) do
            for name, o in pairs(outs) do
              if o.morality == m[1] then
                table.insert(gacts, action(L(m[2]), "ending", { quest = q, ending = name }, (ending_desc(o) or ending_label(name))
                  .. L(" — completes the steps this ending needs, avoiding those that would fail it. You choose; the trainer never picks.")))
                break
              end
            end
          end
        end
        table.insert(groups, { title = title, sub = F("%s · %d of %d objectives done", q, ndone, total),
          open = true, actions = gacts, rows = rows, order = ncurrent > 0 and 0 or 1 })
      end
      if endings and st_outcomes and st_outcomes[q] then
        local erows = arr()
        for name, o in pairs(st_outcomes[q]) do
          table.insert(erows, { text = ending_label(name), tag = L(o.morality), sub = ending_desc(o), tip = ending_desc(o),
            actions = arr({ action(L("Finish this way"), "ending", { quest = q, ending = name },
              L("Completes the steps this ending needs, avoiding those that would fail it. The choice is yours.")) }) })
        end
        table.insert(groups, { title = F("Endings: %s", title), open = false, rows = erows, order = 2 })
      end
    end
  end
  table.sort(groups, function(x, y)
    if x.order ~= y.order then return x.order < y.order end
    return x.title < y.title
  end)
  for _, g in ipairs(groups) do g.order = nil end
  local status = QA.last_status
  if st.tracked_quest then status = (status and (status .. "   ·   ") or "") .. F("Tracked: %s", QA.quest_title(st.tracked_quest)) end
  return {
    status = status, refresh = 3, groups = groups,
    options = arr({ { key = "all", label = L("Every objective"), on = all }, { key = "endings", label = L("Endings"), on = endings },
                    { key = "finished", label = L("Finished quests"), on = finished } }),
  }
end

-- What finishes after the game reacts (items handed in, an objective fired, an ending run) reaches the status line.
st_skip.note = function(fmt, ...) QA.last_status = F(fmt, ...) end

local function say(ok, lines)
  local msg = last_lines(lines, 2)
  QA.last_status = msg
  return result(ok, msg ~= "" and msg or L("done"))
end

function QA.api.advance(a)
  return say(captured(function() st_navigator:safe_advance(a.quest, a.obj, a.force == "1") end))
end

function QA.api.skip(a)
  local real = st_teleport.player_to
  if not QA.opts.skip_teleport then st_teleport.player_to = function() return true end end
  local ok, lines = captured(function() st_navigator:skip_to_decision(a.quest) end)
  st_teleport.player_to = real
  return say(ok, lines)
end

function QA.api.ending(a)
  local o = st_outcomes and st_outcomes[a.quest] and st_outcomes[a.quest][a.ending]
  if not o then return result(false, L("no such ending")) end
  return say(captured(function() st_cmd:run_outcome(a.quest, a.ending, o) end))
end

function QA.api.goquest(a)
  if not in_game() then return result(false, L("no game loaded")) end
  local dest, why = QA.quest_dest(a.quest)
  if not dest then return result(false, F("can't go: %s", tostring(why))) end
  return result(QA.teleport(dest.x, dest.y, dest.z, QA.quest_title(a.quest), true))
end

-- F8: the journal-tracked quest's current objective (st_tracker), as st_goto finds it.
function QA.api.hotkey()
  if not in_game() then return result(false, L("load a save first")) end
  local q = st.tracked_quest
  if not q then
    for _, sq in ipairs(QA.started_quests()) do
      if not sq.done and QuestSystem.IsQuestActivated(sq.name) then q = sq.name break end
    end
  end
  if not q then return result(false, L("no tracked quest: open the journal and pick one")) end
  return QA.api.goquest({ quest = q })
end

-- ---------------------------------------------------------------------------
-- Go, summon, mark/back
-- ---------------------------------------------------------------------------
QA.BESIDE, QA.BESIDE_MOUNTED = 1.2, 2.5

function QA.api.go(a)
  if not in_game() then return result(false, L("no game loaded")) end
  if a.npc then
    local e = System.GetEntityByName(a.npc)
    if not e then return result(false, F("%s is not loaded", a.npc)) end
    local p = e:GetWorldPos()
    return result(QA.teleport(p.x + 1.5, p.y, p.z, QA.person_name(e), true))
  end
  local x, y, z = tonumber(a.x), tonumber(a.y), tonumber(a.z)
  if not (x and y and z) then return result(false, L("nowhere to go")) end
  if a.beside == "1" then
    local p = player:GetWorldPos()
    local dx, dy = p.x - x, p.y - y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 0.01 then dx, dy, d = 1, 0, 1 end
    local step = QA.mount() and QA.BESIDE_MOUNTED or QA.BESIDE
    x, y = x + dx / d * step, y + dy / d * step
  end
  return result(QA.teleport(x, y, z, a.what or L("there"), true))
end

-- A typed coordinate (the Places tab's X and Y), landed where one can stand there (QA.fit). A comma is read as a
-- decimal point.
local function typed(s)
  local v = tonumber((string.gsub(tostring(s or ""), ",", ".")))
  if v and v == v then return v end  -- not NaN ("nan" reads as a number)
end

function QA.api.goxy(a)
  if not in_game() then return result(false, L("no game loaded")) end
  local x, y = typed(a.x), typed(a.y)
  if not (x and y) then return result(false, L("type a number in X and in Y")) end
  local t = QA.terrain(x, y) or player:GetWorldPos().z
  if x < 0 or y < 0 or x > QA.MAP_SIZE or y > QA.MAP_SIZE or t <= 0 then
    return result(false, F("%.0f, %.0f is off the map", x, y))
  end
  local fx, fy, z = QA.fit(x, y, t)
  if not z then return result(false, F("no ground at %.0f, %.0f", x, y)) end
  local ok, msg = QA.teleport(fx, fy, z, string.format("%.0f, %.0f", x, y), false)
  if ok then QA.refit(x, y, t, fx, fy, z) end
  return result(ok, msg)
end

function QA.api.summon(a)
  if not in_game() then return result(false, L("no game loaded")) end
  local e = a.npc and System.GetEntityByName(a.npc)
  if not e then return result(false, L("they are not loaded nearby")) end
  local p = player:GetWorldPos()
  e:SetWorldPos({ x = p.x + 1.5, y = p.y, z = QA.ground(p.x + 1.5, p.y, p.z) })
  return result(true, F("%s is beside you", QA.person_name(e)))
end

function QA.api.mark()
  if not in_game() then return result(false, L("no game loaded")) end
  local p = player:GetWorldPos()
  QA.back_pos = { x = p.x, y = p.y, z = p.z }
  return result(true, F("marked (%.0f, %.0f)", p.x, p.y))
end

function QA.api.back()
  if not in_game() then return result(false, L("no game loaded")) end
  if not QA.back_pos then return result(false, L("nothing to go back to")) end
  local b = QA.back_pos
  return result(QA.teleport(b.x, b.y, b.z, L("back"), false))
end

function QA.api.horse()
  if not in_game() then return result(false, L("no game loaded")) end
  return result(QA.horse_to_player())
end

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
function QA.tabs.people(a)
  if not in_game() then return no_game() end
  local rows = arr()
  for _, e in pairs(System.GetEntities() or {}) do
    if e and e.actorStats ~= nil and e ~= player and e.GetNpcName then
      local name, id = QA.person_name(e), e:GetName()
      local p = e:GetWorldPos()
      if matches(a.q, name, id) and (a.near ~= "1" or dist2d(p.x, p.y) <= 50) then
        table.insert(rows, { text = name, sub = (name ~= id) and id or nil, dist = dist2d(p.x, p.y),
          actions = arr({ action(L("Go"), "go", { npc = id }), action(L("Summon"), "summon", { npc = id }) }) })
      end
    end
  end
  table.sort(rows, function(x, y) return x.dist < y.dist end)
  local shown = arr()
  for i = 1, math.min(#rows, a.all == "1" and #rows or 150) do shown[i] = rows[i] end
  return { status = F("%d people loaded%s", #rows, (#rows > #shown) and F(", nearest %d shown", #shown) or ""),
    refresh = 3, options = arr({ { key = "near", label = L("Within 50 m"), on = a.near == "1" },
                                 { key = "all", label = L("Show all"), on = a.all == "1" } }),
    groups = arr({ { title = L("People, nearest first"), rows = shown } }) }
end

-- ---------------------------------------------------------------------------
-- Places, chests, items: qa_world.lua (tools/extract_world.py)
-- ---------------------------------------------------------------------------
local PLACE_ORDER = { shop = 1, Smithy = 2, ["Alchemy table"] = 2, Grindstone = 2, Bath = 2, Barber = 2,
                      ["Player bed"] = 3, ["Inn bed"] = 3, Bed = 4 }

local function fold(rows)
  local out = {}
  for _, r in ipairs(rows) do
    local same
    for _, o in ipairs(out) do
      if o.text == r.text and math.abs(o.x - r.x) < 15 and math.abs(o.y - r.y) < 15 then same = o break end
    end
    if same then same.n = same.n + 1 else r.n = 1; table.insert(out, r) end
  end
  for _, r in ipairs(out) do
    if r.n > 1 then r.text = string.format("%s ×%d", r.text, r.n) end
    r.x, r.y, r.n, r.kind = nil, nil, nil, nil
  end
  return arr(out)
end

function QA.tabs.places(a)
  if not in_game() then return no_game() end
  local W, beds, level = world(), a.beds == "1", QA.current_level()
  local shops_only, services_only = a.shops == "1", a.services == "1"
  local inside = {}
  local function add(i, row, x, y) if i then row.x, row.y = x, y; inside[i] = inside[i] or {}; table.insert(inside[i], row) end end
  if not services_only then
    for _, s in ipairs(W.shops) do
      if here(s, level) then add(s.place, { text = L(s.name), sub = L("shop"), kind = "shop", dist = dist2d(s.x, s.y),
        actions = arr({ action(L("Go"), "go", go_args(s, L(s.name), true)) }) }, s.x, s.y) end
    end
  end
  if not shops_only then
    for _, b in ipairs(W.benches) do
      if (beds or b.what ~= "Bed") and here(b, level) then
        add(b.place, { text = L(b.what), kind = b.what, dist = dist2d(b.x, b.y),
          actions = arr({ action(L("Go"), "go", go_args(b, L(b.what), true)) }) }, b.x, b.y)
      end
    end
  end
  local groups = arr()
  for i, pl in ipairs(W.places) do
    local name = QA.place_name(pl)
    local rows, hit = arr(), here(pl, level) and matches(a.q, name, pl.name)
    for _, r in ipairs(inside[i] or {}) do if hit or matches(a.q, r.text, r.sub) then table.insert(rows, r) end end
    if (hit and not (shops_only or services_only)) or #rows > 0 then
      table.sort(rows, function(x, y)
        local ox, oy = PLACE_ORDER[x.kind] or 2, PLACE_ORDER[y.kind] or 2
        if ox ~= oy then return ox < oy end
        return x.dist < y.dist
      end)
      rows = fold(rows)
      table.insert(rows, 1, { text = name .. L(" (centre)"), dist = dist2d(pl.x, pl.y), actions = arr({ action(L("Go"), "go", go_args(pl, name)) }) })
      table.insert(groups, { title = name, sub = L(pl.kind or "place"), rows = rows, near = dist2d(pl.x, pl.y) })
    end
  end
  table.sort(groups, function(x, y) return x.near < y.near end)
  for n, g in ipairs(groups) do g.open = (a.q and a.q ~= "") or n <= 3; g.near = nil end
  local p = player:GetWorldPos()
  local status = F("%d places", #groups) .. F(" · you are at %.0f, %.0f", p.x, p.y)
  if QA.back_pos then status = status .. L(" · Back returns to where the last jump started") end
  local go_xy = action(L("Go"), "goxy", { x = "{x}", y = "{y}" }, L("Go to the X and Y typed beside it, on the ground there"))
  go_xy.enter = true
  return { status = status, groups = groups,
    options = arr({ { key = "shops", label = L("Shops only"), on = shops_only },
                    { key = "services", label = L("Benches, baths and beds only"), on = services_only },
                    { key = "beds", label = L("Every bed"), on = beds } }),
    inputs = arr({ { key = "x", label = "X", value = "" }, { key = "y", label = "Y", value = "" } }),
    actions = arr({ go_xy, action(L("Mark here"), "mark", {}, L("Back will return here")),
                    action(L("Back"), "back", {}, L("Return to the mark or to where the last jump started")) }) }
end

function QA.tabs.chests(a)
  if not in_game() then return no_game() end
  local W, level = world(), QA.current_level()
  local rows = arr()
  for _, s in ipairs(W.stashes) do
    if here(s, level) then
    local place = s.place and W.places[s.place] and QA.place_name(W.places[s.place]) or nil
    local name = L(s.name)
    if matches(a.q, name, s.name, place, s.preset) and not (a.locked == "1" and not s.locked)
        and not (a.open == "1" and s.locked) and not (a.stocked == "1" and not s.preset) then
      table.insert(rows, { text = name, sub = place, tag = s.locked and L("locked") or nil, dist = dist2d(s.x, s.y),
        tip = s.preset and (L("contents: ") .. humanize(string.gsub(s.preset, "^inventory_", ""))) or nil,
        actions = arr({ action(L("Go"), "go", go_args(s, name, true)) }) })
    end
    end
  end
  table.sort(rows, function(x, y) return x.dist < y.dist end)
  local shown = arr()
  for i = 1, math.min(#rows, a.all == "1" and #rows or 200) do shown[i] = rows[i] end
  return { status = F("%d chests and stashes%s", #rows, (#rows > #shown) and F(", nearest %d shown", #shown) or ""),
    options = arr({ { key = "locked", label = L("Locked only"), on = a.locked == "1" },
                    { key = "open", label = L("Unlocked only"), on = a.open == "1" },
                    { key = "stocked", label = L("Stocked with loot"), on = a.stocked == "1" },
                    { key = "all", label = L("Show all"), on = a.all == "1" } }),
    groups = arr({ { title = L("Chests, nearest first"), rows = shown } }) }
end

-- The Items tab is laid out the way a player shops: a category bar like the inventory's own tabs, each category's
-- groups in the order one looks for them (head to feet, swords before shields), best first inside a group, and
-- beside every name the numbers that decide a pick, as the inventory's item info shows them. Categories, groups,
-- stats and the in-group score come from tools/extract_world.py (classify_items).
local ITEM_CATS = {
  { "weapons", "Weapons", { "sword", "sabre", "longsword", "axe", "mace", "polearm", "dagger", "shield", "bow", "crossbow", "ammo" } },
  { "armour", "Armour and clothing", { "head_helmet", "head_mail", "head_cap", "body_plate", "body_mail", "body_cloth",
                                       "body_coat", "arms", "hands", "legs_plate", "legs_mail", "legs_cloth", "feet",
                                       "spurs", "jewellery", "other" } },
  { "horse", "Horse", { "saddle", "bridle", "horseshoe", "cover" } },
  { "food", "Food and drink", { "meat", "bread", "veg", "dairy", "offal", "drink", "food_other" } },
  { "potions", "Potions", { "healing", "effect", "poison", "other" } },
  { "alchemy", "Herbs and alchemy", { "herb", "ingredient", "base", "recipe" } },
  { "books", "Books and maps", { "skill", "map", "book" } },
  { "tools", "Tools", { "lockpick", "repair", "bandage", "tool" } },
  { "keys", "Keys", { "door", "chest", "keyring" } },
  { "dice", "Dice", { "die" } },
  { "other", "Other", { "valuable", "hide", "trophy", "quest", "money", "other" } },
}
local ITEM_GROUP_LABEL = {
  sword = "Swords", sabre = "Sabres and hunting swords", longsword = "Longswords", axe = "Axes",
  mace = "Maces and hammers", polearm = "Polearms", dagger = "Daggers", shield = "Shields", bow = "Bows",
  crossbow = "Crossbows", ammo = "Arrows",
  head_helmet = "Head: helmets and hats", head_mail = "Head: mail coifs and collars",
  head_cap = "Head: padded coifs and scarves", body_plate = "Body: plate and brigandines",
  body_mail = "Body: mail and cotehardies", body_cloth = "Body: shirts, tunics and gambesons",
  body_coat = "Body: coats, jupons and hoods", arms = "Arms: pauldrons and vambraces",
  hands = "Hands: gloves and gauntlets", legs_plate = "Legs: plate chausses", legs_mail = "Legs: padded and mail chausses",
  legs_cloth = "Legs: hose and breeches", feet = "Feet: shoes and boots", spurs = "Spurs",
  jewellery = "Rings and neck chains",
  saddle = "Saddles", bridle = "Bridles and chanfrons", horseshoe = "Horseshoes", cover = "Caparisons and barding",
  meat = "Meat", bread = "Bread and pastry", veg = "Vegetables, fruit and mushrooms", dairy = "Dairy and eggs",
  offal = "Offal, soups and stews", drink = "Drinks", food_other = "Dried and other food",
  healing = "Healing, cures and saving", effect = "Boosts", poison = "Poisons and sleeping draughts",
  herb = "Herbs", ingredient = "Ingredients", base = "Bases", recipe = "Recipes",
  skill = "Skill books", map = "Maps and treasure maps", book = "Books and letters",
  lockpick = "Lockpicks", repair = "Repair kits", bandage = "Bandages", tool = "Torches and spades",
  die = "Dice",
  valuable = "Valuables and cloth", hide = "Hides", trophy = "Ears", quest = "Quest objects", money = "Money",
  other = "Other",
}
QA.items_more = QA.items_more or {}  -- groups whose cap Show all lifted, by "cat/grp"

-- A stat's label is the game's own item-info word (text_ui_menus.xml), so it reads as the inventory does.
local STAT_LABEL = {
  stab = { "ui_tip_stab", "Stab" }, slash = { "ui_tip_slash", "Slash" }, smash = { "ui_tip_blunt", "Blunt" },
  def = { "ui_tip_defence", "Defence" }, str = { "ui_min_strength", "Min. Strength" }, agi = { "ui_min_agility", "Min. Agility" },
  power = { "ui_power", "Power" }, noise = { "ui_noise", "Noise" }, cha = { "ui_charisma", "Charisma" },
  nut = { "ui_nutrition", "Nourishment" }, nrg = { "ui_refreshment", "Energy" }, alc = { "ui_alcohol", "Alcohol" },
}
local STAT_ORDER = { "stab", "slash", "smash", "def", "power", "noise", "cha", "nut", "nrg", "alc", "str", "agi" }

function QA.count_of(id)
  local ok, n = pcall(function() return player.inventory:GetCountOfClass(id) end)
  return ok and tonumber(n) or 0
end

local function skill_label(name)
  for _, s in ipairs((QA.player_data or {}).skills or {}) do
    if s.name == name then return QA.gt("text_ui_soul.xml", s.key, s.en) end
  end
  return humanize(name)
end

local function groschen(p)
  return F("%s groschen", p == math.floor(p) and string.format("%d", p) or string.format("%.1f", p))
end

-- What decides a pick, in the inventory's own words: damage and defence, power, noise, charisma, nourishment …
function QA.item_stats(it)
  local st, out = it.st or {}, {}
  if it.grp == "skill" and st.skill then
    table.insert(out, skill_label(st.skill))
    table.insert(out, F("level %d needed", st.lvl or 0))
    table.insert(out, F("+%d XP", st.xp or 0))
  else
    for _, k in ipairs(STAT_ORDER) do
      local v = st[k]
      if v and not (k == "str" or k == "agi") or (v and v > 0) then
        local lab = QA.gt("text_ui_menus.xml", STAT_LABEL[k][1], STAT_LABEL[k][2])
        table.insert(out, lab .. " " .. tostring(v) .. (k == "alc" and "%" or ""))
      end
    end
    if st.days then table.insert(out, F("keeps %d days", st.days)) end
  end
  if it.price and it.price > 0 then table.insert(out, groschen(it.price)) end
  return table.concat(out, " · ")
end

-- The game's own description of an item (player_item ui_info), without its markup.
local function item_info(it)
  if not it.info then return nil end
  local s = QA.load_text("text_ui_items.xml")[it.info]
  if not s or s == "" then return nil end
  s = string.gsub(string.gsub(s, "<[^>]*>", ""), "%s+", " ")
  if #s > 300 then
    local cut = 297
    while cut > 0 and string.byte(s, cut + 1) and string.byte(s, cut + 1) >= 0x80 and string.byte(s, cut + 1) < 0xC0 do
      cut = cut - 1  -- never inside a character: the cut ends before a UTF-8 lead byte
    end
    s = string.sub(s, 1, cut) .. "…"
  end
  return s
end

-- A house key says whose door or chest it opens (tools/extract_world.py key_where): the village, by the place that
-- carries its code (the settlement, not an inn that shares it), and the house number, the shop or the inn room.
local KEY_PLACES = { mon = "Monastery", rato = "Rattay Mill" }
QA.key_places = QA.key_places or {}

local function key_place(v)
  if QA.key_places[v] == nil then
    local found, score = false, -1
    for _, pl in ipairs(world().places) do
      local sc = pl.name == KEY_PLACES[v] and 9 or pl.code == v and ((pl.kind == "Town" and 4 or pl.kind == "Village" and 2 or 0)
                                                                  + (pl.ft and 1 or 0)) or -1
      if sc > score then found, score = pl, sc end
    end
    QA.key_places[v] = score >= 0 and found or false
  end
  return QA.key_places[v] or nil
end

local function key_detail(it)
  local st = it.st or {}
  if st.house then return F("house %d", st.house) end
  if st.room then return F("inn room %d", st.room) end
  if st.shop then return L(st.shop) end
  return nil
end

function QA.api.itemsmore(a)
  local k = a.g or ""
  QA.items_more[k] = not QA.items_more[k] or nil
  return result(true, "")
end

function QA.tabs.items(a)
  if not in_game() then return no_game() end
  local W = world()
  local q = a.q and string.lower(a.q) or ""
  local only_src, only_quest, only_mine, az = a.src == "1", a.questitems == "1", a.mine == "1", a.az == "1"
  -- A name, a quest-items or an in-my-bag view looks through every category; otherwise the bar's category.
  local everywhere = q ~= "" or only_quest or only_mine
  local cat = a.cat
  local known = false
  for _, c in ipairs(ITEM_CATS) do if c[1] == cat then known = true end end
  if not known then cat = ITEM_CATS[1][1] end

  local by, per_cat, total = {}, {}, 0
  for i, it in ipairs(W.items) do
    it.n = i  -- the data's own order (natural name order) breaks ties: table.sort is not stable
    local c = it.cat or "other"
    if (everywhere or c == cat)
        and (q == "" or string.find(string.lower(QA.item_name(it)), q, 1, true)
             or string.find(string.lower(it.name), q, 1, true) or string.lower(it.id) == q)
        and (not only_src or W.sources[it.id]) and (not only_quest or it.quest)
        and (not only_mine or QA.count_of(it.id) > 0) then
      local k = c .. "/" .. (it.grp or "other")
      by[k] = by[k] or {}
      table.insert(by[k], it)
      per_cat[c] = (per_cat[c] or 0) + 1
      total = total + 1
    end
  end

  local cap = everywhere and 60 or 120  -- every answer crosses the game's log; Show all lifts a group's cap
  -- Keys go by village: standing in Sasau, one looks for Sasau's keys. A key that names no village goes under Other.
  local key_groups = {}
  for _, g in ipairs({ "door", "chest", "keyring" }) do
    for _, it in ipairs(by["keys/" .. g] or {}) do
      local pl = key_place((it.st or {}).v or "")
      local name = pl and QA.place_name(pl) or L("Other keys")
      local kk = "keys/" .. name
      if not by[kk] then by[kk] = {}; table.insert(key_groups, { kk, name, pl ~= nil }) end
      table.insert(by[kk], it)
    end
    by["keys/" .. g] = nil
  end
  table.sort(key_groups, function(x, y) if x[3] ~= y[3] then return x[3] end return x[2] < y[2] end)

  local groups = arr()
  for _, c in ipairs(ITEM_CATS) do
    local glist = {}
    if c[1] == "keys" then
      for _, kg in ipairs(key_groups) do table.insert(glist, { kg[1], kg[2], "key" }) end
    else
      for _, g in ipairs(c[3]) do table.insert(glist, { c[1] .. "/" .. g, L(ITEM_GROUP_LABEL[g] or g), g }) end
    end
    for _, gl in ipairs(glist) do
      local k, gtitle, g = gl[1], gl[2], gl[3]
      local list = by[k]
      if list then
        table.sort(list, function(x, y)
          if az then
            local nx, ny = QA.item_name(x), QA.item_name(y)
            if nx ~= ny then return nx < ny end
          elseif g == "key" then
            -- house or room number, then door before chest (the item's own name)
            local sx, sy = x.st or {}, y.st or {}
            local hx, hy = sx.house or sx.room or 9999, sy.house or sy.room or 9999
            if hx ~= hy then return hx < hy end
            local nx, ny = QA.item_name(x), QA.item_name(y)
            if nx ~= ny then return nx < ny end
          elseif g == "skill" and x.st and y.st then
            if x.st.skill ~= y.st.skill then return skill_label(x.st.skill) < skill_label(y.st.skill) end
            if x.st.lvl ~= y.st.lvl then return (x.st.lvl or 0) < (y.st.lvl or 0) end
          elseif (x.best or 0) ~= (y.best or 0) then
            return (x.best or 0) > (y.best or 0)
          end
          return x.n < y.n
        end)
        -- Copies that read the same (one helmet in three colour variants) fold into one row: the copy that can be
        -- had somewhere, so its Go works. Keys and quest items stay apart: each "Door key" opens its own door.
        local folded, seen = {}, {}
        for _, it in ipairs(list) do
          local face = (g ~= "key" and not it.quest) and (QA.item_name(it) .. "|" .. QA.item_stats(it)) or it.id
          local at = seen[face]
          if not at then seen[face] = #folded + 1; table.insert(folded, it)
          elseif W.sources[it.id] and not W.sources[folded[at].id] then folded[at] = it end
        end
        list = folded
        local rows, more = arr(), QA.items_more[k]
        for i, it in ipairs(list) do
          if i > cap and not more then break end
          local acts = arr({ action(L("Give"), "give", { id = it.id, n = "{n}" }) })
          if W.sources[it.id] then table.insert(acts, action(L("Go"), "goitem", { id = it.id }, L("Where one can be had: each press goes to the next place, nearest first"))) end
          local tip = item_info(it)
          local sub = g == "key" and key_detail(it) or QA.item_stats(it)  -- a key is told apart by whose it is
          table.insert(rows, { text = QA.item_name(it), sub = sub, tag = it.quest and L("quest item") or nil,
            tip = tip and (tip .. "  [" .. it.id .. "]") or it.id, actions = acts })
        end
        local title = gtitle
        if everywhere then title = L(c[2]) .. " · " .. title end
        local gacts = nil
        if #list > cap then
          gacts = arr({ action(more and L("Show fewer") or F("Show all %d", #list), "itemsmore", { g = k }) })
        end
        table.insert(groups, { title = title, rows = rows, count = #list, actions = gacts,
                               open = everywhere or #list <= 12 })
      end
    end
  end

  local bar = arr()
  for _, c in ipairs(ITEM_CATS) do
    local label = L(c[2])
    if everywhere then label = label .. " (" .. tostring(per_cat[c[1]] or 0) .. ")" end
    table.insert(bar, { value = c[1], label = label })
  end
  local status
  if everywhere then status = F("%d match in every category", total)
  else
    for _, c in ipairs(ITEM_CATS) do if c[1] == cat then status = F("%s: %d items · type a name to search every category", L(c[2]), total) end end
  end
  return { status = status, groups = groups,
    choices = arr({ { key = "cat", value = cat, items = bar } }),
    options = arr({ { key = "src", label = L("Can be had somewhere"), on = only_src },
                    { key = "questitems", label = L("Quest items"), on = only_quest },
                    { key = "mine", label = L("In my bag"), on = only_mine },
                    { key = "az", label = L("A to Z"), on = az } }),
    inputs = arr({ { key = "n", label = L("Quantity"), value = "1" } }) }
end

function QA.api.give(a)
  if not in_game() then return result(false, L("no game loaded")) end
  local n = math.max(1, math.min(tonumber(a.n) or 1, 999))
  local name = a.id
  for _, it in ipairs(world().items) do if it.id == a.id then name = QA.item_name(it) break end end
  local ok, err = pcall(function()
    for _ = 1, n do player.inventory:AddItem(ItemManager.CreateItem(a.id, 1, 1)) end
  end)
  if not ok then return result(false, F("the game refused to create %s", tostring(name)) .. ": " .. tostring(err)) end
  pcall(Game.ShowItemsTransfer, a.id, n)
  return result(true, F("%d × %s added to your inventory", n, name))
end

QA.item_cycle = QA.item_cycle or {}

function QA.api.goitem(a)
  if not in_game() then return result(false, L("no game loaded")) end
  local W, level = world(), QA.current_level()
  local src = W.sources[a.id or ""]
  if not src then return result(false, L("nowhere known")) end
  local places = {}
  for _, i in ipairs(src.shops or {}) do local s = W.shops[i]; if s and here(s, level) then table.insert(places, { t = s, what = L("shop: ") .. L(s.name) }) end end
  for _, i in ipairs(src.stashes or {}) do local s = W.stashes[i]; if s and here(s, level) then table.insert(places, { t = s, what = L("stash: ") .. L(s.name) }) end end
  for _, s in ipairs(src.slots or {}) do if here(s, level) then table.insert(places, { t = s, what = L("lying here") }) end end
  if #places == 0 then return result(false, L("nowhere known")) end
  table.sort(places, function(x, y) return dist2d(x.t.x, x.t.y) < dist2d(y.t.x, y.t.y) end)
  local n = (QA.item_cycle[a.id] or 0) % #places + 1
  QA.item_cycle[a.id] = n
  local p = places[n]
  return QA.api.go({ x = p.t.x, y = p.t.y, z = p.t.z, what = F("%s (%d of %d)", p.what, n, #places), beside = "1" })
end

-- ---------------------------------------------------------------------------
-- Me: Henry's condition, money, stats and skills (Data/qa_data.lua, tools/extract_trainer_data.py), names from
-- text_ui_soul.xml in the game's language
-- ---------------------------------------------------------------------------
QA.MONEY_ID = "5ef63059-322e-4e1b-abe8-926e100c770e"  -- groschen; the item counts tenths, GetMoney() whole groschen
QA.LEVEL_CAP = 20
QA.XP_STEP = 20  -- the XP the cheapest level costs (rpg_param *XPLevelBase); the cost grows by 30 a level
local POOLS = { { "health", "Health" }, { "stamina", "Stamina" }, { "hunger", "Nourishment" }, { "exhaust", "Energy" } }
local POOL_FULL = { health = 1000, stamina = 1000, hunger = 100, exhaust = 100 }  -- the game clamps to the real top

local function soul_name(d) return QA.gt("text_ui_soul.xml", d.key, d.en) end

local function step_actions(what, key, steps, label)
  local acts = arr()
  for _, d in ipairs(steps) do
    table.insert(acts, action((d > 0 and "+" or "") .. tostring(d), "me", { what = what, key = key, d = tostring(d), label = label }))
  end
  return acts
end

function QA.money()
  local ok, m = pcall(function() return player.inventory:GetMoney() end)
  if ok and tonumber(m) then return math.floor(tonumber(m)) end
  return math.floor(QA.count_of(QA.MONEY_ID) / 10)
end

function QA.tabs.me(a)
  if not in_game() then return no_game() end
  local s = player.soul
  local groups = arr()
  local pools = arr()
  for _, p in ipairs(POOLS) do
    local v = s:GetState(p[1]) or 0
    local acts = step_actions("state", p[1], { 10 }, L(p[2]))
    table.insert(acts, action(L("Fill"), "me", { what = "state", key = p[1], d = "fill", label = L(p[2]) }))
    table.insert(pools, { text = L(p[2]), sub = string.format("%.0f", v), actions = acts })
  end
  table.insert(groups, { title = L("Condition"), rows = pools, open = true,
    actions = arr({ action(L("Fill all"), "me", { what = "fill_all" }) }) })
  table.insert(groups, { title = L("Money"), open = true, rows = arr({
    { text = L("Groschen"), sub = tostring(QA.money()), actions = step_actions("money", "groschen", { -100, 100, 1000, 10000 }, L("Groschen")) } }) })
  local function level_rows(list, what)
    local rows = arr()
    for _, d in ipairs(list) do
      local name = soul_name(d)
      if matches(a.q, name, d.en, d.name) then
        local ok, lv = pcall(what == "stat" and s.GetStatLevel or s.GetSkillLevel, s, d.name)
        local acts = step_actions(what, d.name, { 1, 5 }, name)
        table.insert(acts, action(L("Max"), "me", { what = what, key = d.name, d = "max", label = name }))
        table.insert(rows, { text = name, sub = ok and F("level %d", lv) or nil, actions = acts })
      end
    end
    return rows
  end
  local P = QA.player_data or { stats = {}, skills = {} }
  local general, combat = {}, {}
  for _, k in ipairs(P.skills) do table.insert(k.combat and combat or general, k) end
  table.insert(groups, { title = L("Attributes"), rows = level_rows(P.stats, "stat"), open = true })
  table.insert(groups, { title = L("Skills"), rows = level_rows(general, "skill"), open = true })
  table.insert(groups, { title = L("Combat skills"), rows = level_rows(combat, "skill"), open = true })
  return { status = F("Levels go up to %d; the game does not take a level back", QA.LEVEL_CAP), refresh = 2, groups = groups }
end

function QA.money_add(d)
  if d > 0 then
    player.inventory:AddItem(ItemManager.CreateItem(QA.MONEY_ID, 1, d * 10))
  elseif d < 0 then
    local take = math.min(-d, QA.money())
    if take > 0 then Utils.RemoveInvItem(player, QA.MONEY_ID, take * 10, false) end
  end
end

function QA.api.me(a)
  if not in_game() then return result(false, L("no game loaded")) end
  local s, label = player.soul, a.label or a.key or ""
  if a.what == "fill_all" then
    for k, v in pairs(POOL_FULL) do s:SetState(k, v) end
    return result(true, L("Condition filled"))
  elseif a.what == "state" then
    local old = s:GetState(a.key) or 0
    s:SetState(a.key, a.d == "fill" and POOL_FULL[a.key] or old + (tonumber(a.d) or 0))
    return result(true, F("%s: %.0f → %.0f", label, old, s:GetState(a.key) or 0))
  elseif a.what == "money" then
    local old = QA.money()
    QA.money_add(tonumber(a.d) or 0)
    return result(true, F("%s: %d → %d", label, old, QA.money()))
  elseif a.what == "stat" or a.what == "skill" then
    local get = a.what == "stat" and s.GetStatLevel or s.GetSkillLevel
    local add = a.what == "stat" and s.AddStatXP or s.AddSkillXP
    local ok, old = pcall(get, s, a.key)
    if not ok then return result(false, F("%s: not one the game knows", label)) end
    local want = a.d == "max" and QA.LEVEL_CAP or math.min(QA.LEVEL_CAP, old + (tonumber(a.d) or 0))
    if want <= old then return result(false, F("%s is already level %d", label, old)) end
    -- XP in steps no larger than the cheapest level, until the level shown reaches the target: the shown level can
    -- carry temporary bonuses that the game's set-level call does not, so asking it for a level can overshoot; the
    -- XP multiplier (Learn three times as fast) shrinks the step to match
    local okm, mult = pcall(s.GetDerivedStat, s, "xpm")
    local step = QA.XP_STEP / math.max(1, (okm and tonumber(mult)) or 1)
    for _ = 1, 4000 do
      if get(s, a.key) >= want then break end
      add(s, a.key, step)
    end
    return result(true, F("%s: level %d → %d", label, old, get(s, a.key)))
  end
  return result(false, L("nothing to change"))
end

-- ---------------------------------------------------------------------------
-- Cheat modes (Misc): refills on the mod's own once-a-second tick, and the mod's constant buffs
-- (Libs/Tables/rpg/buff__questautopilot.xml), added again after a load since they do not persist
-- ---------------------------------------------------------------------------
QA.CHEATS = {
  { key = "god", label = "God mode", tip = "Nothing kills you, and health refills", buff = "4c8f2e1a-7b3d-4e59-a1c6-0d2f8b9e6a71", refill = { health = 1000 } },
  { key = "stamina", label = "Infinite stamina", tip = "Stamina refills every second", refill = { stamina = 1000 } },
  { key = "needs", label = "Never hungry or tired", tip = "Nourishment and energy stay full", refill = { hunger = 100, exhaust = 100 } },
  { key = "unseen", label = "Unseen and unheard", tip = "People neither see nor hear you", buff = "9e3b7d52-1f6a-4c08-b2d4-6a5e8c1f3b97" },
  { key = "fast", label = "Run twice as fast", buff = "2d6a9f13-8c4e-4b71-9e05-3f7b1a6d8c24" },
  { key = "strong", label = "Hit twice as hard", tip = "Double weapon damage and attack speed", buff = "7f1c4b8e-3a9d-4f62-8b17-5e2a9c6d0f38" },
  { key = "carry", label = "Carry far more", tip = "A thousand more pounds before you are overloaded", buff = "b5e8a2d6-4c1f-4a93-9d70-8f3e6b2c1a45" },
  { key = "xp", label = "Learn three times as fast", tip = "Three times the experience in every skill", buff = "e3a7c9f1-6d2b-4e84-a5f0-1b8d4c7e9a62" },
}
QA.cheats_on = QA.cheats_on or {}
QA.cheat_ticks = QA.cheat_ticks or 0

function QA.cheat_tick()
  if not in_game() or not player.soul then return end
  QA.cheat_ticks = QA.cheat_ticks + 1
  local s = player.soul
  for _, c in ipairs(QA.CHEATS) do
    if QA.cheats_on[c.key] then
      for k, v in pairs(c.refill or {}) do
        if (s:GetState(k) or v) < v then s:SetState(k, v) end
      end
      -- a constant buff does not survive a load; the id-exclusive buff refuses a second copy, so adding again is safe
      if c.buff and QA.cheat_ticks % 5 == 1 then pcall(s.AddBuff, s, c.buff) end
    end
  end
end

function QA.api.cheat(a)
  local c
  for _, x in ipairs(QA.CHEATS) do if x.key == a.key then c = x end end
  if not c then return result(false, L("unknown option")) end
  local on = a.v == "1"
  QA.cheats_on[c.key] = on or nil
  if in_game() and c.buff then
    if on then pcall(player.soul.AddBuff, player.soul, c.buff) else pcall(player.soul.RemoveAllBuffsByGuid, player.soul, c.buff) end
  end
  if on then QA.cheat_tick() end
  return result(true, string.format("%s: %s", L(c.label), on and L("on") or L("off")))
end

-- ---------------------------------------------------------------------------
-- Achievements: Steam's list with earned state (written by the plugin into the bridge folder as steam.lua, from the
-- game's own steam_api64.dll), joined by name to the game's tables (Data/qa_data.lua) for the quest that grants it
-- or the counter that earns it
-- ---------------------------------------------------------------------------
-- A Unix time as YYYY-MM-DD (UTC), without os.date.
function QA.ymd(t)
  local z = math.floor(t / 86400) + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  local y = yoe + era * 400 + (m <= 2 and 1 or 0)
  return string.format("%04d-%02d-%02d", y, m, d)
end

function QA.tabs.achievements(a)
  local chunk = loadfile(QA.BRIDGE .. "steam.lua")
  local okr, raw = pcall(chunk or function() return "" end)
  raw = (okr and type(raw) == "string") and raw or ""
  if raw == "" then return { status = L("achievements need the plugin"), groups = arr() } end
  local err = string.match(raw, "^error\t([^\n]*)")
  if err then return { status = F("Steam: %s", err), groups = arr() } end
  local by = {}
  for _, d in ipairs(QA.achievements or {}) do by[string.lower(d.name)] = d; by[tostring(d.id)] = d end
  local list, shown = {}, {}
  for line in string.gmatch(raw, "[^\n]+") do
    local api, got, when, sname, sdesc, hidden = string.match(line, "^([^\t]*)\t([01])\t(%d*)\t([^\t]*)\t([^\t]*)\t?([^\t]*)$")
    if api then
      local e = { api = api, got = got == "1", when = tonumber(when), name = sname ~= "" and sname or api, desc = sdesc,
                  hidden = hidden == "1", d = by[string.lower(api)] }
      table.insert(list, e)
      if e.d then shown[e.d] = e end
    end
  end
  local todo, done, earned = arr(), arr(), 0
  for _, e in ipairs(list) do
    local d, from = e.d, nil
    if e.got then earned = earned + 1 end
    if d and d.quests then
      local titles = {}
      for _, q in ipairs(d.quests) do table.insert(titles, QA.quest_title(q)) end
      from = F("from the quest %s", table.concat(titles, L(", ")))
    elseif d and d.needs then
      local parts = {}
      for _, n in ipairs(d.needs) do table.insert(parts, string.format("%s %s", QA.gt("text_ui_soul.xml", n.key, n.en), tostring(n.at))) end
      from = F("earned at %s", table.concat(parts, L(", ")))
    end
    if matches(a.q, e.name, e.desc, e.api, from) then
      local row = { text = e.name, sub = e.desc, tip = from and (from .. " · " .. e.api) or e.api, actions = arr() }
      if e.got then
        row.tag = L("earned")
        if e.when and e.when > 0 then row.tip = F("earned %s", QA.ymd(e.when)) .. " · " .. row.tip end
        table.insert(done, row)
      else
        row.tag = e.hidden and L("hidden") or nil
        if from then row.sub = (e.desc ~= "" and (e.desc .. "  ·  ") or "") .. from end
        table.insert(row.actions, action(L("Unlock"), "unlock", { name = e.api, label = e.name },
          L("Unlocks it on your Steam account now; Steam keeps it for good")))
        table.insert(todo, row)
      end
    end
  end
  table.sort(todo, function(x, y) return x.text < y.text end)
  table.sort(done, function(x, y) return x.text < y.text end)
  return { status = F("%d of %d earned", earned, #list), refresh = 0,
    groups = arr({ { title = L("Not yet earned"), rows = todo, open = true },
                   { title = L("Earned"), rows = done, open = (a.q or "") ~= "" } }) }
end

-- The plugin has already asked Steam (r is its answer); this words it.
function QA.api.unlock(a)
  local label = (a.label and a.label ~= "") and a.label or a.name
  local r = a.r or ""
  if r == "" then return result(false, L("achievements need the plugin")) end
  System.LogAlways("[QuestAutopilot] unlock achievement " .. tostring(a.name) .. ": " .. r)
  if r == "ok" then return result(true, F("%s unlocked on Steam", label)) end
  if r == "already unlocked" then return result(true, F("%s was already unlocked", label)) end
  return result(false, F("%s: %s", label, r))
end

-- ---------------------------------------------------------------------------
-- Guides and Misc
-- ---------------------------------------------------------------------------
QA.GUIDE_DIR = "Scripts/QuestAutopilot/Guides/"
-- A guide translated as <name>_<ui>.md stands in for <name>.md in that language.
QA.GUIDES = { "trainer_guide.md", "findings.md" }

local function guide_file(f)
  local local_f = string.gsub(f, "%.md$", "") .. "_" .. QA.ui .. ".md"
  if QA.ui ~= "en" then
    local ok, text = pcall(System.LoadTextFile, QA.GUIDE_DIR .. local_f)
    if ok and type(text) == "string" and text ~= "" then return local_f end
  end
  return f
end

local function guide_title(f) return L(humanize(string.match(f, "^(.-)_%a%a%.md$") or string.gsub(f, "%.md$", ""))) end

function QA.tabs.guides(a)
  if QA.guide_open then
    local ok, text = pcall(System.LoadTextFile, QA.GUIDE_DIR .. QA.guide_open)
    return { filter = false, status = guide_title(QA.guide_open), doc = (ok and text) or L("(could not read the guide)"),
      actions = arr({ action(L("All guides"), "read", {}) }), groups = arr() }
  end
  local rows = arr()
  for _, g in ipairs(QA.GUIDES) do
    local f = guide_file(g)
    if matches(a.q, guide_title(f), f) then
      table.insert(rows, { text = guide_title(f), sub = f, actions = arr({ action(L("Read"), "read", { name = f }) }) })
    end
  end
  return { groups = arr({ { title = L("Guides"), rows = rows } }) }
end

function QA.api.read(a)
  QA.guide_open = (a.name and a.name ~= "") and a.name or nil
  return result(true, QA.guide_open and F("reading %s", guide_title(QA.guide_open)) or "")
end

local OPTIONS = {
  { "skip_teleport", "Skip to next decision takes you to where it stopped" },
  { "bring_horse", "Every jump brings your horse along" },
  { "skip_warning", "Warn before a skip that can leave a quest stuck" },
}

local function cheat_rows()
  local rows = arr()
  for _, c in ipairs(QA.CHEATS) do
    local on = QA.cheats_on[c.key] and true or false
    table.insert(rows, { text = L(c.label), tag = on and L("on") or L("off"), tip = c.tip and L(c.tip) or nil,
      actions = arr({ action(on and L("Turn off") or L("Turn on"), "cheat", { key = c.key, v = on and "0" or "1" }) }) })
  end
  return rows
end

function QA.tabs.misc()
  local rows = arr()
  for _, o in ipairs(OPTIONS) do
    local on = QA.opts[o[1]] and true or false
    table.insert(rows, { text = L(o[2]), tag = on and L("on") or L("off"),
      actions = arr({ action(on and L("Turn off") or L("Turn on"), "opt", { key = o[1], v = on and "0" or "1" }) }) })
  end
  return { filter = false, status = (not in_game()) and L("No game loaded.") or nil,
    actions = arr({ action(L("Save now"), "save", {}, L("Saves at the next moment the game allows; no schnapps needed")),
                    action(L("Bring my horse"), "horse", {}), action(L("Back"), "back", {}, L("Return to where the last jump started")) }),
    groups = arr({ { title = L("Cheat modes"), rows = cheat_rows(), open = true },
                   { title = L("Play options"), rows = rows, open = true } }) }
end

function QA.api.opt(a)
  QA.opts[a.key] = a.v == "1"
  local label = a.key
  for _, o in ipairs(OPTIONS) do if o[1] == a.key then label = L(o[2]) end end
  return result(true, string.format("%s: %s", label, QA.opts[a.key] and L("on") or L("off")))
end

function QA.api.save()
  if not in_game() then return result(false, L("no game loaded")) end
  if Game.IsLoadingEngineSaveGame and Game.IsLoadingEngineSaveGame() then return result(false, L("the game is still loading")) end
  Game.SaveGameViaResting()
  return result(true, L("saving (the game writes it at the next moment it allows)"))
end

-- Runs a Lua chunk in the game and returns what it returned (the KCD2 plugin's POST /lua, for testing on a live game).
function QA.api.lua(a)
  local fn, err = loadstring(a.code or "")
  if not fn then return result(false, tostring(err)) end
  local out = { pcall(fn) }
  local parts = {}
  for i = 2, table.maxn(out) do table.insert(parts, tostring(out[i])) end
  return result(out[1], table.concat(parts, "	"))
end

-- ---------------------------------------------------------------------------
-- The tab list and the faces' fixed words
-- ---------------------------------------------------------------------------
QA.TAB_ORDER = {
  { id = "quests", title = "Quests" }, { id = "me", title = "Me" }, { id = "places", title = "Places" },
  { id = "people", title = "People" }, { id = "items", title = "Items" }, { id = "chests", title = "Chests" },
  { id = "achievements", title = "Achievements" }, { id = "guides", title = "Guides" }, { id = "misc", title = "Misc" },
}

function QA.api.tabs()
  local out = arr()
  for i, t in ipairs(QA.TAB_ORDER) do out[i] = { id = t.id, title = L(t.title) } end
  return out
end

-- The faces' own fixed words (the panel page and the F6 window), in the game's language.
local FACE_TEXT = {
  filter = "filter", loading = "loading…", nothing = "nothing here", back = "Back", connecting = "connecting…",
  waiting = "waiting for the game (load a save)…", no_answer = "no answer from the game",
  no_plugin = "no answer from the game (is it running with the plugin?)", no_save = "game running, no save loaded",
}

function QA.api.tab(a)
  local fn = QA.tabs[a.name or ""]
  if not fn then return { status = L("unknown tab"), groups = arr() } end
  local t = fn(a)
  t.tab = a.name
  if t.groups == nil then t.groups = arr() end
  return t
end

function QA.api.state()
  local text = {}
  for k, v in pairs(FACE_TEXT) do text[k] = L(v) end
  local s = { inGame = false, title = L("KCD Companion"), lang = QA.ui, gameLang = QA.game_lang, text = text }
  -- every glyph the F6 window may need in this language (build.ps1 writes it beside the panel)
  if QA.ui == "zh" then s.glyphs = "quest_autopilot/glyphs_zh.txt" end
  if not in_game() then return s end
  local p = player:GetWorldPos()
  s.inGame, s.level, s.x, s.y, s.z, s.back = true, L(QA.current_level()), p.x, p.y, p.z, QA.back_pos ~= nil
  return s
end

-- ---------------------------------------------------------------------------
-- The bridge to the plugin. KCD1's mod Lua has no io: a request arrives as quest_autopilot_bridge/request.lua
-- (`return seq, call, query`, read with loadfile, which reads loose files), and the answer leaves through
-- System.LogAlways as entries "@QAB@<seq>@<i>/<n>@<chunk>@QAE@", which the plugin takes out of the game's log write (a line
-- longer than about 3,900 bytes is cut, so chunks stay well under). A timer set while the mod loads may not survive
-- the level load, so UI events re-arm a poller that has gone quiet. The same poller runs the cheat modes' tick.
-- ---------------------------------------------------------------------------
QA.BRIDGE = "quest_autopilot_bridge/"
QA.POLL_MS = 30
QA.CHUNK = 3000

-- Splits at a byte that starts a character, so no UTF-8 sequence is cut across two lines.
function QA.bridge_send(seq, json)
  local parts, i, n = {}, 1, #json
  while i <= n do
    local j = math.min(n, i + QA.CHUNK - 1)
    while j < n and j > i do
      local b = string.byte(json, j + 1)
      if b < 0x80 or b >= 0xC0 then break end
      j = j - 1
    end
    table.insert(parts, string.sub(json, i, j))
    i = j + 1
  end
  if #parts == 0 then parts[1] = "" end
  for k, p in ipairs(parts) do System.LogAlways(string.format("@QAB@%s@%d/%d@%s@QAE@", seq, k, #parts, p)) end
end

-- Seconds, from the engine's clock (os.clock as a fallback for the offline harness).
local function now()
  local ok, t = pcall(System.GetCurrTime)
  if ok and type(t) == "number" then return t end
  return (os and os.clock and os.clock()) or 0
end

function QA.bridge_poll()
  local chunk = loadfile(QA.BRIDGE .. "request.lua")
  if not chunk then return end
  local ok, seq, call, query = pcall(chunk)
  if not ok or type(seq) ~= "string" or seq == QA.bridge_seq then return end
  QA.bridge_seq = seq
  local t0 = now()
  local json = QA.api_json(call, query)
  QA.bridge_send(seq, json)
  local took = now() - t0
  if took > 1 then System.LogAlways(string.format("[QuestAutopilot] slow answer: %s?%s took %.1f s for %d bytes", call, query, took, #json)) end
end

-- One poller at a time: a re-arm starts a new generation and the old chain stops at its next tick.
QA.bridge_gen = QA.bridge_gen or 0

QA.bridge_ticks = 0

function QA.bridge_tick(gen)
  if gen ~= QA.bridge_gen then return end
  local t = now()
  QA.bridge_last = t
  QA.bridge_ticks = QA.bridge_ticks + 1
  if QA.bridge_ticks <= 2 then System.LogAlways(string.format("[QuestAutopilot] bridge tick %d (generation %d)", QA.bridge_ticks, gen)) end
  local ok, err = pcall(QA.bridge_poll)
  if not ok and QA.bridge_err ~= tostring(err) then
    QA.bridge_err = tostring(err)  -- once per distinct error, not every 30 ms
    System.LogAlways("[QuestAutopilot] bridge: " .. QA.bridge_err)
  end
  if not QA.cheat_last or t - QA.cheat_last >= 1 then
    QA.cheat_last = t
    local okc, errc = pcall(QA.cheat_tick)
    if not okc and QA.cheat_err ~= tostring(errc) then
      QA.cheat_err = tostring(errc)
      System.LogAlways("[QuestAutopilot] cheat tick: " .. QA.cheat_err)
    end
  end
  Script.SetTimer(QA.POLL_MS, function() QA.bridge_tick(gen) end)
end

function QA.bridge_arm(why)
  QA.bridge_gen = QA.bridge_gen + 1
  local gen = QA.bridge_gen
  QA.bridge_last = now()
  QA.bridge_ticks = 0
  System.LogAlways(string.format("[QuestAutopilot] bridge armed (generation %d, %s)", gen, tostring(why)))
  Script.SetTimer(QA.POLL_MS, function() QA.bridge_tick(gen) end)
end

local function rearm(why)
  if not QA.bridge_last or now() - QA.bridge_last > 1 or now() < QA.bridge_last then QA.bridge_arm(why) end
end

function QA:onUIEvent() rearm("ui event") end

-- The loading screen's end is the first moment a timer set for gameplay survives (kcd-cheat starts its own there).
function QA:onUIAction(actionName, eventName)
  if actionName == "sys_loadingimagescreen" and eventName == "OnEnd" then QA.bridge_arm("level loaded") else rearm("ui action") end
end

if not QA.bridge_started then
  QA.bridge_started = true
  UIAction.RegisterEventSystemListener(QA, "", "", "onUIEvent")
  UIAction.RegisterActionListener(QA, "", "", "onUIAction")
end
QA.bridge_arm("mod loaded")
